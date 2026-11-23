// A deterministic sin for rand()/noise().
//
// `rand(seed)` multiplies sin(…) by 43758.5453 and keeps the fraction, so a
// one-ulp difference in sin changes the result around the 12th digit. Dart's
// math.sin calls the platform libm (Apple, bionic, glibc, or JS Math.sin on the
// web), which differ in the last bit, so this is a pure-Dart port of fdlibm 5.3
// sin (s_sin.c, k_sin.c, k_cos.c, e_rem_pio2.c, k_rem_pio2.c): the same doubles
// on every Flutter platform. JS engines themselves disagree in the last bit
// (measured on 300k inputs: Node 22 / V8 12.4 vs Deno / V8 14.7 differ on 8 %);
// this port matches Node 22 on 99.6 % and V8 14.7 on 97.4 %, platform libm on
// ~96.6 %. The rand() value differs by at most ~1e-11 when the bits differ.
import 'dart:typed_data';

final ByteData _b = ByteData(8);

int _hi(double x) {
  _b.setFloat64(0, x, Endian.little);
  return _b.getInt32(4, Endian.little);
}

int _lo(double x) {
  _b.setFloat64(0, x, Endian.little);
  return _b.getUint32(0, Endian.little);
}

double _words(int hi, int lo) {
  _b.setUint32(4, hi & 0xffffffff, Endian.little);
  _b.setUint32(0, lo & 0xffffffff, Endian.little);
  return _b.getFloat64(0, Endian.little);
}


/// C `(int32_t)d` for |d| < 2^31.
int _i32(double d) => d.truncate();

const double _s1 = -1.66666666666666324348e-01,
    _s2 = 8.33333333332248946124e-03,
    _s3 = -1.98412698298579493134e-04,
    _s4 = 2.75573137070700676789e-06,
    _s5 = -2.50507602534068634195e-08,
    _s6 = 1.58969099521155010221e-10;

double _kernelSin(double x, double y, int iy) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix < 0x3e400000) {
    if (_i32(x) == 0) return x;
  }
  final z = x * x;
  final v = z * x;
  final r = _s2 + z * (_s3 + z * (_s4 + z * (_s5 + z * _s6)));
  if (iy == 0) return x + v * (_s1 + z * r);
  return x - ((z * (0.5 * y - v * r) - y) - v * _s1);
}

const double _c1 = 4.16666666666666019037e-02,
    _c2 = -1.38888888888741095749e-03,
    _c3 = 2.48015872894767294178e-05,
    _c4 = -2.75573143513906633035e-07,
    _c5 = 2.08757232129817482790e-09,
    _c6 = -1.13596475577881948265e-11;

double _kernelCos(double x, double y) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix < 0x3e400000) {
    if (_i32(x) == 0) return 1.0;
  }
  final z = x * x;
  final r = z * (_c1 + z * (_c2 + z * (_c3 + z * (_c4 + z * (_c5 + z * _c6)))));
  if (ix < 0x3FD33333) return 1.0 - (0.5 * z - (z * r - x * y));
  final double qx = ix > 0x3fe90000 ? 0.28125 : _words(ix - 0x00200000, 0);
  final hz = 0.5 * z - qx;
  final a = 1.0 - qx;
  return a - (hz - (z * r - x * y));
}

// 2/pi in 24-bit chunks (fdlibm two_over_pi), enough for any double.
const List<int> _twoOverPi = [
  0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62, 0x95993C, 0x439041, 0xFE5163, //
  0xABDEBB, 0xC561B7, 0x246E3A, 0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
  0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41, 0x3991D6, 0x398353, 0x39F49C,
  0x845F8B, 0xBDF928, 0x3B1FF8, 0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
  0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5, 0xF17B3D, 0x0739F7, 0x8A5292,
  0xEA6BFB, 0x5FB11F, 0x8D5D08, 0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
  0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880, 0x4D7327, 0x310606, 0x1556CA,
  0x73A8C9, 0x60E27B, 0xC08C6B,
];

const List<int> _npio2Hw = [
  0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, 0x4025FDBB, 0x402921FB, //
  0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C, 0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB,
  0x403AB41B, 0x403C463A, 0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
  0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB, 0x404858EB, 0x404921FB,
];

const double _two24 = 1.67772160000000000000e+07,
    _twon24 = 5.96046447753906250000e-08,
    _invpio2 = 6.36619772367581382433e-01,
    _pio21 = 1.57079632673412561417e+00,
    _pio21t = 6.07710050650619224932e-11,
    _pio22 = 6.07710050630396597660e-11,
    _pio22t = 2.02226624879595063154e-21,
    _pio23 = 2.02226624871116645580e-21,
    _pio23t = 8.47842766036889956997e-32;

const List<double> _pio2 = [
  1.57079625129699707031e+00, 7.54978941586159635335e-08, 5.39030252995776476554e-15, 3.28200341580791294123e-22, //
  1.27065575308067607349e-29, 1.22933308981111328932e-36, 2.73370053816464559624e-44, 2.16741683877804819444e-51,
];

double _scalbn(double x, int n) {
  // exact for the ranges used here (results stay normal)
  var r = x;
  while (n > 1000) {
    r *= 8.98846567431158e307; // 2^1023
    n -= 1023;
  }
  while (n < -1000) {
    r *= 1.1125369292536007e-308; // 2^-1022
    n += 1022;
  }
  return r * _words((0x3ff + n) << 20, 0);
}

/// fdlibm __kernel_rem_pio2 with prec = 2 (double precision output in y[0], y[1]).
int _kernelRemPio2(List<double> x, List<double> y, int e0, int nx) {
  const jk = 4; // init_jk[prec=2]
  const jp = jk;
  final iq = List<int>.filled(20, 0);
  final f = List<double>.filled(20, 0);
  final fq = List<double>.filled(20, 0);
  final q = List<double>.filled(20, 0);
  final jx = nx - 1;
  var jv = (e0 - 3) ~/ 24;
  if (jv < 0) jv = 0;
  var q0 = e0 - 24 * (jv + 1);
  var j = jv - jx;
  final m = jx + jk;
  for (var i = 0; i <= m; i++, j++) {
    f[i] = j < 0 ? 0.0 : _twoOverPi[j].toDouble();
  }
  for (var i = 0; i <= jk; i++) {
    var fw = 0.0;
    for (j = 0; j <= jx; j++) {
      fw += x[j] * f[jx + i - j];
    }
    q[i] = fw;
  }
  var jz = jk;
  int n, ih;
  double z;
  for (;;) {
    // distill q[] into iq[] reversingly
    var i = 0;
    z = q[jz];
    for (j = jz; j > 0; i++, j--) {
      final fw = _i32(_twon24 * z).toDouble();
      iq[i] = _i32(z - _two24 * fw);
      z = q[j - 1] + fw;
    }
    // compute n
    z = _scalbn(z, q0);
    z -= 8.0 * (z * 0.125).floorToDouble();
    n = _i32(z);
    z -= n.toDouble();
    ih = 0;
    if (q0 > 0) {
      i = iq[jz - 1] >> (24 - q0);
      n += i;
      iq[jz - 1] -= i << (24 - q0);
      ih = iq[jz - 1] >> (23 - q0);
    } else if (q0 == 0) {
      ih = iq[jz - 1] >> 23;
    } else if (z >= 0.5) {
      ih = 2;
    }
    if (ih > 0) {
      n += 1;
      var carry = 0;
      for (i = 0; i < jz; i++) {
        j = iq[i];
        if (carry == 0) {
          if (j != 0) {
            carry = 1;
            iq[i] = 0x1000000 - j;
          }
        } else {
          iq[i] = 0xffffff - j;
        }
      }
      if (q0 > 0) {
        switch (q0) {
          case 1:
            iq[jz - 1] &= 0x7fffff;
          case 2:
            iq[jz - 1] &= 0x3fffff;
        }
      }
      if (ih == 2) {
        z = 1.0 - z;
        if (carry != 0) z -= _scalbn(1.0, q0);
      }
    }
    // check if recomputation is needed
    if (z == 0) {
      j = 0;
      for (i = jz - 1; i >= jk; i--) {
        j |= iq[i];
      }
      if (j == 0) {
        var k = 1;
        while (iq[jk - k] == 0) {
          k++;
        }
        for (i = jz + 1; i <= jz + k; i++) {
          f[jx + i] = _twoOverPi[jv + i].toDouble();
          var fw = 0.0;
          for (j = 0; j <= jx; j++) {
            fw += x[j] * f[jx + i - j];
          }
          q[i] = fw;
        }
        jz += k;
        continue;
      }
    }
    break;
  }
  // chop off zero terms
  if (z == 0.0) {
    jz -= 1;
    q0 -= 24;
    while (iq[jz] == 0) {
      jz--;
      q0 -= 24;
    }
  } else {
    z = _scalbn(z, -q0);
    if (z >= _two24) {
      final fw = _i32(_twon24 * z).toDouble();
      iq[jz] = _i32(z - _two24 * fw);
      jz += 1;
      q0 += 24;
      iq[jz] = _i32(fw);
    } else {
      iq[jz] = _i32(z);
    }
  }
  // convert integer "bit" chunk to floating-point value
  var fw = _scalbn(1.0, q0);
  for (var i = jz; i >= 0; i--) {
    q[i] = fw * iq[i].toDouble();
    fw *= _twon24;
  }
  // compute PIo2[0,...,jp]*q[jz,...,0]
  for (var i = jz; i >= 0; i--) {
    fw = 0.0;
    for (var k = 0; k <= jp && k <= jz - i; k++) {
      fw += _pio2[k] * q[i + k];
    }
    fq[jz - i] = fw;
  }
  // compress fq[] into y[] (prec 2)
  fw = 0.0;
  for (var i = jz; i >= 0; i--) {
    fw += fq[i];
  }
  y[0] = ih == 0 ? fw : -fw;
  fw = fq[0] - fw;
  for (var i = 1; i <= jz; i++) {
    fw += fq[i];
  }
  y[1] = ih == 0 ? fw : -fw;
  return n & 7;
}

int _remPio2(double x, List<double> y) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  if (ix <= 0x3fe921fb) {
    y[0] = x;
    y[1] = 0;
    return 0;
  }
  if (ix < 0x4002d97c) {
    if (hx > 0) {
      var z = x - _pio21;
      if (ix != 0x3ff921fb) {
        y[0] = z - _pio21t;
        y[1] = (z - y[0]) - _pio21t;
      } else {
        z -= _pio22;
        y[0] = z - _pio22t;
        y[1] = (z - y[0]) - _pio22t;
      }
      return 1;
    } else {
      var z = x + _pio21;
      if (ix != 0x3ff921fb) {
        y[0] = z + _pio21t;
        y[1] = (z - y[0]) + _pio21t;
      } else {
        z += _pio22;
        y[0] = z + _pio22t;
        y[1] = (z - y[0]) + _pio22t;
      }
      return -1;
    }
  }
  if (ix <= 0x413921fb) {
    final t = x.abs();
    final n = _i32(t * _invpio2 + 0.5);
    final fn = n.toDouble();
    var r = t - fn * _pio21;
    var w = fn * _pio21t;
    if (n < 32 && ix != _npio2Hw[n - 1]) {
      y[0] = r - w;
    } else {
      final j = ix >> 20;
      y[0] = r - w;
      var i = j - ((_hi(y[0]) >> 20) & 0x7ff);
      if (i > 16) {
        var tt = r;
        w = fn * _pio22;
        r = tt - w;
        w = fn * _pio22t - ((tt - r) - w);
        y[0] = r - w;
        i = j - ((_hi(y[0]) >> 20) & 0x7ff);
        if (i > 49) {
          tt = r;
          w = fn * _pio23;
          r = tt - w;
          w = fn * _pio23t - ((tt - r) - w);
          y[0] = r - w;
        }
      }
    }
    y[1] = (r - y[0]) - w;
    if (hx < 0) {
      y[0] = -y[0];
      y[1] = -y[1];
      return -n;
    }
    return n;
  }
  if (ix >= 0x7ff00000) {
    y[0] = y[1] = x - x;
    return 0;
  }
  // z = scalbn(|x|, ilogb(x) - 23)
  final e0 = (ix >> 20) - 1046;
  var z = _words(ix - (e0 << 20), _lo(x));
  final tx = List<double>.filled(3, 0);
  for (var i = 0; i < 2; i++) {
    tx[i] = _i32(z).toDouble();
    z = (z - tx[i]) * _two24;
  }
  tx[2] = z;
  var nx = 3;
  while (tx[nx - 1] == 0.0) {
    nx--;
  }
  final n = _kernelRemPio2(tx, y, e0, nx);
  if (hx < 0) {
    y[0] = -y[0];
    y[1] = -y[1];
    return -n;
  }
  return n;
}

final List<double> _y = List<double>.filled(2, 0);

/// fdlibm sin (same algorithm as SpiderMonkey and pre-2023 V8 Math.sin).
double fdlibmSin(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) return _kernelSin(x, 0, 0);
  if (ix >= 0x7ff00000) return double.nan;
  final n = _remPio2(x, _y);
  switch (n & 3) {
    case 0:
      return _kernelSin(_y[0], _y[1], 1);
    case 1:
      return _kernelCos(_y[0], _y[1]);
    case 2:
      return -_kernelSin(_y[0], _y[1], 1);
    default:
      return -_kernelCos(_y[0], _y[1]);
  }
}
