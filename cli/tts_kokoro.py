"""Kokoro (local, open source) TTS for `tsvg bake`.

stdin: JSON list of {"text", "voice", "lang", "speed", "out"} — writes one WAV per item.
stdout: JSON list of durations in seconds.
Model files: $TSVG_KOKORO_DIR or ~/.cache/explainer-video/py/models or ~/.config/cutaway/kokoro
(kokoro-v1.0.onnx + voices-v1.0.bin from github.com/thewh1teagle/kokoro-onnx releases).
"""
import json, os, sys

import soundfile as sf
from kokoro_onnx import Kokoro


def model_dir():
    for d in [os.environ.get("TSVG_KOKORO_DIR"), "~/.cache/explainer-video/py/models", "~/.config/cutaway/kokoro"]:
        if d and os.path.exists(os.path.join(os.path.expanduser(d), "kokoro-v1.0.onnx")):
            return os.path.expanduser(d)
    sys.exit("kokoro-v1.0.onnx not found; set TSVG_KOKORO_DIR")


def main():
    jobs = json.load(sys.stdin)
    d = model_dir()
    k = Kokoro(os.path.join(d, "kokoro-v1.0.onnx"), os.path.join(d, "voices-v1.0.bin"))
    out = []
    for j in jobs:
        samples, rate = k.create(j["text"], voice=j.get("voice") or "af_heart", speed=float(j.get("speed") or 1.0), lang=j.get("lang") or "en-us")
        sf.write(j["out"], samples, rate)
        out.append(len(samples) / rate)
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
