/**
 * TSVG — Timeseries Scalable Vector Graphics.
 *
 * A video format that is a document: vector shapes, text, images and sound on a
 * timeline, plus viewer options (language, audio mix, theme, layout). This module
 * is the reference web engine: parser, expression language, Canvas 2D renderer,
 * validator, `.tsvgz` packages and a player with real video controls.
 *
 * @example Play a package in a page
 * ```ts
 * import { TSVGPlayer } from "jsr:@panth977/tsvg";
 * const player = new TSVGPlayer(document.getElementById("video")!);
 * await player.open("demo.tsvgz");
 * ```
 *
 * @example From a CDN, no build step
 * ```html
 * <script type="module">
 *   import { TSVGPlayer } from "https://esm.sh/jsr/@panth977/tsvg@0.4.0";
 * </script>
 * <!-- or as a classic script that defines window.TSVG, TSVGZip, TSVGPlayer -->
 * <script src="https://esm.sh/jsr/@panth977/tsvg@0.4.0/dist/tsvg.js?raw"></script>
 * ```
 * @module
 */
import "./web/tsvg-core.js";
import "./web/tsvg-zip.js";
import "./web/tsvg-player.js";

/** Values in the viewer's option set, e.g. `{ lang: "gu", mix: "speech", theme: "dark" }`. */
export type TSVGOptions = Record<string, string>;

/** A coordinate space of the document, e.g. `{ id: "portrait", w: 1080, h: 1920 }`. */
export interface TSVGLayout {
  id: string;
  w: number;
  h: number;
}

/** A parsed TSVG document. */
export interface TSVGDocument {
  version: string;
  title: string;
  duration: number;
  layouts: TSVGLayout[];
  options: { id: string; label: string; default?: string; choices: { id: string; label: string }[] }[];
  mixes: Record<string, Record<string, number>>;
  themes: Record<string, Record<string, string>>;
  strings: Record<string, Record<string, string>>;
  chapters: { t: number; label: string }[];
  fonts: { family: string; src: string; weight: string; style: string }[];
  assets: Record<string, { src: string; type: string }>;
  // deno-lint-ignore no-explicit-any
  [key: string]: any;
}

/** One narration line resolved for an option set. */
export interface TSVGSayLine {
  key: string;
  start: number;
  dur: number;
  text: string;
  speak: string;
  clip: string | null;
  lang: string;
}

/** Sound to play for one option set: bus gains and clips. */
export interface TSVGAudioPlan {
  mix: Record<string, number>;
  clips: { bus: string; src: string; start: number; loop?: boolean; vol?: number }[];
}

/** Result of {@link TSVGCore.validate}. */
export interface TSVGValidation {
  ok: boolean;
  errors: string[];
  warnings: string[];
  doc: TSVGDocument | null;
  stats?: { duration: number; scenes: number; layouts: number; variants: number; says: number };
}

/** The engine core (also `window.TSVG` when loaded as a classic script). */
/** Loaded libraries by URL (from {@link TSVGCore.loadLibs}). */
// deno-lint-ignore no-explicit-any
export type TSVGLibs = Record<string, any>;
/** Where and how libraries load: `fetchText(url)` returns the file; `base` is the document's URL; `libBase` overrides where `tsvg:<name>` resolves. */
export interface TSVGLibOptions { base?: string; libBase?: string; fetchText(url: string): Promise<string> }
/** Result of {@link TSVGCore.flatten}: plain TSVG, the library files it needs (package path → URL), output line → source line. */
export interface TSVGFlat { xml: string; files: Record<string, string>; lineMap: number[]; errors: string[] }

export interface TSVGCore {
  /** Format version. */
  VERSION: string;
  /** Package version; `tsvg:<lib>` imports resolve to this release's libs on jsr.io. */
  PKG: string;
  /** Parse a `.tsvg` document (XML text). Throws on malformed documents. Documents with imports need `libs`. */
  parse(xml: string, options?: { libs?: TSVGLibs } & Partial<TSVGLibOptions>): TSVGDocument;
  /** True when the document has `<import>` or `<component>` (it needs {@link TSVGCore.flatten}). */
  needsLibs(xml: string): boolean;
  /** Load every library a document imports (and theirs). */
  loadLibs(xml: string, options: TSVGLibOptions): Promise<TSVGLibs>;
  /** Expand imports and components into plain TSVG. */
  flatten(xml: string, libs?: TSVGLibs, options?: Partial<TSVGLibOptions>): TSVGFlat;
  /** Draw the frame at time `t` (seconds). `ctx` must already map layout units to the target. */
  renderFrame(ctx: CanvasRenderingContext2D, doc: TSVGDocument, t: number, opts: TSVGOptions, layout: TSVGLayout, images?: Record<string, CanvasImageSource>): void;
  /** Static checks plus a dry run of every frame sample under every option set and layout. */
  validate(xml: string, options?: { files?: { has(path: string): boolean }; samples?: number; libs?: TSVGLibs } & Partial<TSVGLibOptions>): TSVGValidation;
  sayLines(doc: TSVGDocument, opts: TSVGOptions): TSVGSayLine[];
  audioPlan(doc: TSVGDocument, opts: TSVGOptions): TSVGAudioPlan;
  /** Asset id or path → path inside the package. */
  assetPath(doc: TSVGDocument, ref: string): string;
  /** Default value of every option. */
  defaults(doc: TSVGDocument): TSVGOptions;
  /** Every combination of option values. */
  combos(doc: TSVGDocument): TSVGOptions[];
  /** Compile an expression of the TSVG expression language. */
  // deno-lint-ignore no-explicit-any
  compile(src: string): (env: any) => unknown;
}

/** `.tsvgz` packages: a zip with `main.tsvg` plus the files it references. */
export interface TSVGZipApi {
  MAIN: string;
  read(bytes: Uint8Array | ArrayBuffer, options?: { inflateRaw?: (b: Uint8Array) => Uint8Array }): Promise<Map<string, Uint8Array>>;
  write(entries: { path: string; data: Uint8Array | string }[], options?: { deflateRaw?: (b: Uint8Array) => Uint8Array }): Uint8Array;
  isZip(bytes: Uint8Array): boolean;
  crc32(bytes: Uint8Array): number;
  text(bytes: Uint8Array): string;
}

/** Options for {@link TSVGPlayer}. */
export interface TSVGPlayerInit {
  /** path → URL for package files (e.g. blob URLs). */
  files?: Record<string, string>;
  /** Base URL relative paths resolve against. */
  base?: string;
  /** Called whenever the viewer changes an option. */
  onOptions?: (opts: TSVGOptions) => void;
  /** false: frames only, no controls (posters, thumbnails). Default true. */
  controls?: boolean;
}

/** A player with real video controls, mounted into `host`. */
export interface TSVGPlayerInstance {
  doc: TSVGDocument;
  opts: TSVGOptions;
  /** Current time in seconds. */
  t: number;
  /** Playback rate (player-side; audio follows with pitch preserved). */
  rate: number;
  playing: boolean;
  /** Load a `.tsvg` document (XML text). */
  load(xml: string): Promise<TSVGDocument>;
  /** Load a `.tsvgz` package. */
  loadPackage(bytes: Uint8Array): Promise<TSVGDocument>;
  /** Fetch and load a `.tsvg` or `.tsvgz` URL. */
  open(url: string): Promise<TSVGDocument>;
  play(): Promise<void>;
  pause(): void;
  toggle(): void;
  seek(t: number): void;
  /** Set a document option, or `__layout` / `__rate` for the player's own. */
  setOption(id: string, value: string): void;
  /** Playback speed (0.25–2); audio follows with pitch kept. */
  setRate(rate: number): void;
  /** Volume 0–1 (master gain after the document's mix). */
  setVolume(volume: number): void;
  toggleMute(): void;
  /** Enter or leave fullscreen (falls back to filling the viewport where element fullscreen isn't available). */
  fullscreen(): void;
}

/** Constructor of {@link TSVGPlayerInstance}. */
export interface TSVGPlayerClass {
  new (host: HTMLElement, init?: TSVGPlayerInit): TSVGPlayerInstance;
}

// deno-lint-ignore no-explicit-any
const g = globalThis as any;

/** The engine core. */
export const TSVG: TSVGCore = g.TSVG;
/** `.tsvgz` package reader/writer. */
export const TSVGZip: TSVGZipApi = g.TSVGZip;
/** The web player (needs a DOM). */
export const TSVGPlayer: TSVGPlayerClass = g.TSVGPlayer;
