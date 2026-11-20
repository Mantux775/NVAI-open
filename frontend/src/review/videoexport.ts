// „Video mit Ton“ in der Prüf-App, ohne Server: wie NVAI-open (forensic_tools.cmd_videoexport), aber im Browser.
// Das Bild bleibt unverändert: die Proben ab dem Schlüsselbild vor dem Anfang werden aus der MP4 des Pakets kopiert.
// Der Ton kommt aus dem Originalton der Spuren im Paket (fall/original/*.wav), wird bandbegrenzt über die Zuordnung
// video_t = a·t + b auf die Video-Zeit gelegt, gemischt (Pegel je Spur), begrenzt und mit WebCodecs als AAC kodiert.
// Untertitel kommen danach als SRT daneben (srtForVideo), mit Zeiten ab dem ersten Bild des Videos. Mit `burn` werden sie
// stattdessen ins Bild gebrannt (Nutzer 20.11.2026: „die untertitel werden nicht in das video eingebaut“): Die Bildproben
// werden dekodiert, die Untertitel gezeichnet und das Bild mit WebCodecs als H.264 neu kodiert. Eine Untertitelspur im MP4
// hätte das Bild unverändert gelassen, aber der Windows Media Player zeigt sie nicht (gemessen mit Windows.Media: MP4 mit
// tx3g 0 Textspuren, MKV mit SRT 1).

import type { TranscriptSegment } from '../api'
import { t } from '../i18n'
import { activeCues, drawSubtitles, layoutCues, toSrt, type Cue, type LaidCue } from '../forensic/subtitles'
import { aacAsc, aacStsd, ascFrom, avcStsd, Mp4Error, Mp4Writer, readMp4, videoConfig, type Sink } from './mp4'
import { Sinc } from './resample'
import { toFloat, wavInfo, type WavInfo } from './wav'

const OUT_SR = 48000

export interface VTrack { file: Blob; gainDb: number }

export interface VOptions {
  video: Blob
  fit: { a: number; b: number }
  tracks: VTrack[]
  /** Aufnahme-Zeit in Sekunden */
  region: [number, number]
  mono: boolean
  kbps?: number
  sink: Sink
  progress: (f: number) => void
  signal?: AbortSignal
  /** Untertitel ins Bild einbrennen (das Bild wird dafür neu kodiert) */
  burn?: { segments: TranscriptSegment[]; mode: 'original' | 'translation'; lang: string }
}

export interface VResult {
  /** Video-Zeit des ersten Bildes (Schlüsselbild) und des Endes */
  videoStart: number
  videoEnd: number
  /** Aufnahme-Zeit des ersten Bildes */
  recordStart: number
  packets: number
  peak: number
  bytes: number
  /** gemessener Vorlauf des AAC-Kodierers in Proben (in der Schnittliste eingetragen) */
  priming: number
  codec: string
  /** Untertitel eingebrannt: Bild neu kodiert mit diesem Kodierer */
  burned: string | null
}

function readable(e: unknown): Error {
  if (e instanceof Mp4Error) {
    if (e.message.includes('fragmented')) return new Error(t('Das Video ist ein fragmentiertes MP4; das übernimmt die Prüf-App nicht.', 'The video is a fragmented MP4; the review app cannot take it over.'))
    return new Error(t(`Das Video lässt sich nicht lesen (${e.message}). Die Prüf-App übernimmt MP4- und MOV-Dateien.`, `The video cannot be read (${e.message}). The review app takes MP4 and MOV files.`))
  }
  return e instanceof Error ? e : new Error(String(e))
}

function bytesOf(d: AllowSharedBufferSource): Uint8Array {
  if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength) as ArrayBuffer)
  return new Uint8Array((d as ArrayBuffer).slice(0))
}

/** Vorlauf des AAC-Kodierers in Proben: Impuls kodieren, zurück dekodieren, Abstand messen (Chrome unter Windows: 0,
 * FFmpeg dekodiert denselben Strom gleich; gemessen 18.11.2026). */
async function aacPriming(cfg: AudioEncoderConfig): Promise<number> {
  const chunks: EncodedAudioChunk[] = []
  let desc: AllowSharedBufferSource | undefined
  const enc = new AudioEncoder({
    output: (c, m) => {
      chunks.push(c)
      if (m?.decoderConfig?.description) desc = m.decoderConfig.description
    },
    error: () => undefined,
  })
  enc.configure(cfg)
  const n = 9600
  const at = 4800
  const ch = cfg.numberOfChannels
  const data = new Float32Array(n * ch)
  for (let c = 0; c < ch; c++) data[c * n + at] = 0.9
  const ad = new AudioData({ format: 'f32-planar', sampleRate: cfg.sampleRate, numberOfFrames: n, numberOfChannels: ch, timestamp: 0, data })
  enc.encode(ad)
  ad.close()
  await enc.flush()
  enc.close()
  const pcm: Float32Array[] = []
  let failed = false
  const dec = new AudioDecoder({
    output: (a) => {
      const x = new Float32Array(a.numberOfFrames)
      a.copyTo(x, { planeIndex: 0, format: 'f32-planar' })
      pcm.push(x)
      a.close()
    },
    error: () => { failed = true },
  })
  // WebKit (Mac-App) gibt als description einen ganzen ES-Deskriptor aus, an dem sein eigener Decoder scheitert
  // („decoding failed“): Bis 18.11. kam dann gar kein Ton zurück, die Messung ergab still 0 statt 2112 Proben, und der
  // Ton im Video lag 44 ms daneben. Mit der ausgepackten ASC dekodiert WebKit ungekürzt (Impuls bei 4800 + 2112).
  const asc = desc ? ascFrom(bytesOf(desc)) : null
  dec.configure({ codec: cfg.codec, sampleRate: cfg.sampleRate, numberOfChannels: ch, ...(asc ? { description: asc } : {}) })
  for (const c of chunks) dec.decode(c)
  await dec.flush().catch(() => { failed = true })
  dec.close()
  if (failed || !pcm.length) {
    throw new Error(t('Der AAC-Kodierer dieses Browsers ließ sich nicht vermessen. Das Video wird nicht gespeichert, damit der Ton nicht versetzt darauf liegt.',
      "This browser's AAC encoder could not be measured. The video is not saved, so that its sound is not shifted."))
  }
  let best = 0
  let pos = at
  let i = 0
  for (const x of pcm) {
    for (let k = 0; k < x.length; k++, i++) {
      const v = Math.abs(x[k])
      if (v > best) {
        best = v
        pos = i
      }
    }
  }
  return Math.max(0, pos - at)
}

interface Src { file: Blob; info: WavInfo; gain: number; sinc: Sinc; frames: number }

/** Proben [lo, hi) einer Spur je Kanal (mono: gemittelt), außerhalb der Aufnahme null */
async function readBlock(s: Src, lo: number, hi: number, mono: boolean): Promise<Float32Array[]> {
  const ch = s.info.channels
  const out = Array.from({ length: mono ? 1 : ch }, () => new Float32Array(hi - lo))
  const a = Math.max(0, lo)
  const z = Math.min(s.frames, hi)
  if (z > a) {
    const block = (ch * s.info.bits) / 8
    const x = toFloat(await s.file.slice(s.info.dataStart + a * block, s.info.dataStart + z * block).arrayBuffer(), s.info)
    const n = Math.min(z - a, Math.floor(x.length / ch))
    const o = a - lo
    if (mono) {
      const y = out[0]
      for (let i = 0; i < n; i++) {
        let v = 0
        for (let c = 0; c < ch; c++) v += x[i * ch + c]
        y[o + i] = v / ch
      }
    } else {
      for (let c = 0; c < ch; c++) {
        const y = out[c]
        for (let i = 0; i < n; i++) y[o + i] = x[i * ch + c]
      }
    }
  }
  return out
}

/** H.264-Kodierer für das eingebrannte Bild: Stufe nach Bildgröße und Bildrate, Profil High, sonst Main, sonst Baseline.
 * Bitrate das Doppelte der Quelle, mindestens 0,12 Bit je Bildpunkt und Bild: Mit fest 0,16 lag ein Testvideo mit
 * ständig wechselnder Fläche über den Untertiteln im Mittel bei 43 dB zum Original (der Server mit NVENC cq 20 bei 47). */
async function pickEncoder(w: number, h: number, fps: number, srcBps: number): Promise<VideoEncoderConfig> {
  const mbs = Math.ceil(w / 16) * Math.ceil(h / 16)
  const rate = mbs * fps
  const levels: [number, number, number][] = [[0x1f, 3600, 108000], [0x20, 5120, 216000], [0x28, 8192, 245760], [0x2a, 8704, 522240],
    [0x32, 22080, 589824], [0x33, 36864, 983040], [0x34, 36864, 2073600]]
  const level = (levels.find(([, fs, ps]) => mbs <= fs && rate <= ps) ?? levels[levels.length - 1])[0].toString(16)
  const bitrate = Math.round(Math.min(50e6, Math.max(2e6, 2 * srcBps, w * h * fps * 0.12)))
  for (const profile of ['6400', '4d00', '42e0']) {
    const cfg: VideoEncoderConfig = { codec: `avc1.${profile}${level}`, width: w, height: h, bitrate, framerate: fps, bitrateMode: 'variable',
      latencyMode: 'quality', avc: { format: 'avc' } }
    const ok = await VideoEncoder.isConfigSupported(cfg).then((r) => !!r.supported).catch(() => false)
    if (!ok) continue
    if (await encoderEmits(cfg)) return cfg
    // WebKit (Mac-App, macOS 27 auf M1) gibt in 'quality' kein einziges Bild heraus, und flush() kehrt nie zurück
    // (gemessen 20.11.2026: 60 Bilder, Warteschlange 56, aus Canvas, I420 und Bitmap gleich); 'realtime' liefert sofort
    // In 'realtime' blieb WebKit weit unter der verlangten Bitrate (1,25 statt 2,8 Mbit/s, 29 dB über den Untertiteln):
    // deshalb das Vierfache verlangen
    const rt: VideoEncoderConfig = { codec: cfg.codec, width: w, height: h, bitrate: Math.min(60e6, bitrate * 4), framerate: fps,
      latencyMode: 'realtime', avc: { format: 'avc' } }
    if (await encoderEmits(rt)) return rt
  }
  throw new Error(t('Dieser Browser kann kein H.264 kodieren; die Untertitel lassen sich hier nicht einbrennen.',
    'This browser cannot encode H.264; the subtitles cannot be burned in here.'))
}

/** NV12 oder I420 vom Vollbereich (0–255) in den Videobereich (Y 16–235, Farbe 16–240) umrechnen, an Ort und Stelle */
function toVideoRange(buf: Uint8Array, layout: PlaneLayout[], format: VideoPixelFormat, w: number, h: number): void {
  const y = layout[0]
  for (let r = 0; r < h; r++) {
    const o = y.offset + r * y.stride
    for (let c = 0; c < w; c++) buf[o + c] = 16 + (buf[o + c] * 219 + 127) / 255
  }
  const planes = format === 'NV12' ? [[layout[1], w]] : [[layout[1], w >> 1], [layout[2], w >> 1]]
  for (const [pl, n] of planes as [PlaneLayout, number][]) {
    for (let r = 0; r < h >> 1; r++) {
      const o = pl.offset + r * pl.stride
      for (let c = 0; c < n; c++) buf[o + c] = 128 + ((buf[o + c] - 128) * 224) / 255
    }
  }
}

/** Gibt der Kodierer mit dieser Einstellung laufend etwas heraus, ohne flush()? Acht graue Bilder, bis 1,5 s warten.
 * WebKit gibt in 'quality' wenige Bilder beim flush() heraus, laufend aber keins, bis seine Warteschlange voll ist
 * (gemessen 20.11.2026: eine Probe mit flush() ließ 'quality' durch, und der Export stand bei 0 kodierten Bildern). */
async function encoderEmits(cfg: VideoEncoderConfig): Promise<boolean> {
  let got = 0
  let enc: VideoEncoder | null = null
  try {
    enc = new VideoEncoder({ output: () => { got++ }, error: () => undefined })
    enc.configure(cfg)
    const w = cfg.width
    const h = cfg.height
    const buf = new Uint8Array((w * h * 3) / 2).fill(128)
    for (let i = 0; i < 8; i++) {
      const vf = new VideoFrame(buf, { format: 'I420', codedWidth: w, codedHeight: h, timestamp: i * 40000, duration: 40000 })
      enc.encode(vf, { keyFrame: i === 0 })
      vf.close()
    }
    for (let i = 0; i < 30 && !got; i++) await new Promise((r) => setTimeout(r, 50))
  } catch {
    got = 0
  } finally {
    try {
      enc?.close()
    } catch {
      /* schon zu */
    }
  }
  return got > 0
}

/** Untertitel einbrennen: Bildproben dekodieren, die Untertitel in die Bildebenen mischen, neu kodieren und in
 * Dekodier-Reihenfolge schreiben.
 *
 * Die dekodierten Bilder (NV12 oder I420) werden kopiert, die Schrift (aus einem Canvas als Maske gezeichnet) direkt in
 * Helligkeit und Farbe gemischt und als Puffer kodiert, in einer eigenen Schleife außerhalb des Dekoder-Rückrufs. Bis
 * 20.11.2026 lief alles im Rückruf über ein Canvas: In WebKit (Mac-App) gab der Kodierer dann kein einziges Bild heraus
 * (in einer nachgestellten Kette außerhalb des Rückrufs ging beides), und der Umweg YUV → RGB → YUV kostete in Chrome
 * Bildtreue (43 dB über den Untertiteln, der Server mischt direkt und kommt auf 47). Andere Formate gehen weiter über
 * das Canvas. Dekodierzeiten: bei geordneter Ausgabe die eigenen Zeitstempel, mit B-Frames die Darstellungszeiten der
 * eingereichten Bilder der Reihe nach (negative Versätze hebt Mp4Writer.liftCto am Ende auf). */
class Burner {
  private dec: VideoDecoder
  private enc: VideoEncoder
  private canvas: OffscreenCanvas
  private ctx: OffscreenCanvasRenderingContext2D
  /** Zeitstempel (µs) → Darstellungszeit in Ticks ab dem Schlüsselbild */
  private relOf = new Map<number, number>()
  private submitted: number[] = []
  private out: { pts: number; data: Uint8Array; key: boolean }[] = []
  private written = 0
  private lastKey = -Infinity
  /** Ausgabe nicht in Darstellungsreihenfolge (B-Frames): dann Dekodierzeiten aus den eingereichten Bildern */
  private reorder = false
  private lastOut = -Infinity
  /** dekodierte Bilder, die auf das Mischen warten, und die Schleife, die sie abarbeitet */
  private queue: VideoFrame[] = []
  private pump: Promise<void> | null = null
  /** Maske der gerade sichtbaren Untertitel: erste Zeile, Deckkraft und Helligkeit je Bildpunkt darunter */
  private maskKey = ''
  private mask: { top: number; alpha: Uint8ClampedArray; gray: Uint8ClampedArray } | null = null
  avcC: Uint8Array | null = null
  err: unknown = null
  frames = 0
  /** Proben an den Dekoder, Bilder aus ihm, letzter Fortschritt (für die Bremse) */
  private fed = 0
  private decoded = 0
  private progressAt = performance.now()

  constructor(private w: Mp4Writer, private vi: number, private ts: number, private laid: LaidCue[], readonly width: number,
    readonly height: number, dec: VideoDecoderConfig, private encCfg: VideoEncoderConfig, private lastDur: number) {
    this.canvas = new OffscreenCanvas(width, height)
    const ctx = this.canvas.getContext('2d', { willReadFrequently: true })
    if (!ctx) throw new Error(t('Kein Zeichenbereich für die Untertitel.', 'No drawing surface for the subtitles.'))
    this.ctx = ctx
    this.enc = new VideoEncoder({
      output: (c, m) => {
        const d = m?.decoderConfig?.description
        if (!this.avcC && d) this.avcC = bytesOf(d)
        const data = new Uint8Array(c.byteLength)
        c.copyTo(data)
        const pts = this.relOf.get(c.timestamp) ?? Math.round((c.timestamp * this.ts) / 1e6)
        if (pts < this.lastOut) this.reorder = true
        this.lastOut = Math.max(this.lastOut, pts)
        this.out.push({ pts, data, key: c.type === 'key' })
        this.progressAt = performance.now()
      },
      error: (e) => { this.err = e },
    })
    this.enc.configure(encCfg)
    this.dec = new VideoDecoder({ output: (f) => this.frame(f), error: (e) => { this.err = e } })
    this.dec.configure(dec)
  }

  /** eine Bildprobe dekodieren; rel = Darstellungszeit in Ticks ab dem Schlüsselbild (davor negativ) */
  decode(data: Uint8Array, rel: number, dur: number, key: boolean): void {
    const us = Math.round((rel * 1e6) / this.ts)
    this.relOf.set(us, rel)
    this.dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: us, duration: Math.round((dur * 1e6) / this.ts), data }))
    this.fed++
  }

  /** Rückruf des Dekoders: nur einreihen, gemischt und kodiert wird in run() */
  private frame(f: VideoFrame): void {
    this.decoded++
    this.progressAt = performance.now()
    const rel = this.relOf.get(f.timestamp)
    if (rel == null || rel < 0 || this.err) {
      f.close() // vor dem Schlüsselbild (offene Bildgruppe): nicht im Export
      return
    }
    this.queue.push(f)
    if (!this.pump) this.pump = this.run().finally(() => { this.pump = null })
  }

  private async run(): Promise<void> {
    while (this.queue.length) {
      const f = this.queue.shift() as VideoFrame
      try {
        if (!this.err) await this.process(f)
      } catch (e) {
        this.err = e
      } finally {
        f.close()
      }
    }
  }

  private async process(f: VideoFrame): Promise<void> {
    const rel = this.relOf.get(f.timestamp) as number
    const cues = activeCues(this.laid, rel / this.ts)
    const dur = f.duration ? { duration: f.duration } : {}
    let vf: VideoFrame
    if (f.format === 'NV12' || f.format === 'I420') {
      // nur der sichtbare Ausschnitt, und das neue Bild mit so wenig Angaben wie möglich: Mit Farbraum, Ausschnitt und
      // Anzeigegröße des dekodierten Bildes gab WebKits Kodierer nichts heraus
      const vr = f.visibleRect
      const rect = vr ? { x: vr.x & ~1, y: vr.y & ~1, width: vr.width & ~1, height: vr.height & ~1 } : undefined
      const buf = new Uint8Array(f.allocationSize(rect ? { rect } : {}))
      const layout = await f.copyTo(buf, rect ? { rect } : {})
      const cw = rect ? rect.width : f.codedWidth
      const ch = rect ? rect.height : f.codedHeight
      // WebKit dekodiert in den Vollbereich (0–255); ohne Farbangabe gilt ein neues Bild als Videobereich (16–235), und
      // die Mac-Ausgabe war um 255/219 gestreckt (gemessen 20.11.2026: Y ≈ 1,164 · Quelle − 18,6). Deshalb hier umrechnen.
      if (f.colorSpace.fullRange) toVideoRange(buf, layout, f.format, cw, ch)
      if (cues.length) this.blend(buf, layout, f.format, cw, ch, false, cues)
      vf = new VideoFrame(buf, { format: f.format, codedWidth: cw, codedHeight: ch, timestamp: f.timestamp, layout, ...dur })
    } else {
      this.ctx.drawImage(f, 0, 0, this.width, this.height)
      drawSubtitles(this.ctx, this.width, this.height, cues)
      vf = new VideoFrame(this.canvas, { timestamp: f.timestamp, ...dur })
    }
    const key = rel - this.lastKey >= 2 * this.ts // ein Schlüsselbild alle 2 s
    if (key) this.lastKey = rel
    this.enc.encode(vf, { keyFrame: key })
    vf.close()
    this.submitted.push(rel)
    this.frames++
  }

  /** Maske der Untertitel (einmal je sichtbarer Kombination): auf transparentem Canvas gezeichnet, ausgelesen */
  private maskFor(cues: LaidCue[]): { top: number; alpha: Uint8ClampedArray; gray: Uint8ClampedArray } {
    const key = cues.map((c) => `${c.start}|${c.lines.join('\n')}`).join('\u0001')
    if (key === this.maskKey && this.mask) return this.mask
    const w = this.width
    const h = this.height
    this.ctx.clearRect(0, 0, w, h)
    drawSubtitles(this.ctx, w, h, cues)
    const img = this.ctx.getImageData(0, 0, w, h).data
    let top = h
    for (let y = 0; y < h && top === h; y++) {
      for (let x = 0; x < w; x++) {
        if (img[(y * w + x) * 4 + 3]) {
          top = y
          break
        }
      }
    }
    top &= ~1
    const n = (h - top) * w
    const alpha = new Uint8ClampedArray(n)
    const gray = new Uint8ClampedArray(n)
    for (let i = 0; i < n; i++) {
      const p = (top * w + i) * 4
      alpha[i] = img[p + 3]
      gray[i] = img[p]
    }
    this.maskKey = key
    this.mask = { top, alpha, gray }
    return this.mask
  }

  /** Untertitel in NV12 oder I420 mischen: Helligkeit nach Deckkraft, Farbe zum Grau hin (Schwarz und Weiß haben keine) */
  private blend(buf: Uint8Array, layout: PlaneLayout[], format: VideoPixelFormat, vw: number, vh: number, full: boolean, cues: LaidCue[]): void {
    const { top, alpha, gray } = this.maskFor(cues)
    const ox = 0
    const oy = 0
    const w = this.width
    const h = this.height
    const lo = full ? 0 : 16
    const span = full ? 255 : 219
    const y0 = layout[0]
    for (let y = top; y < h; y++) {
      const sy = oy + Math.min(vh - 1, Math.round((y * vh) / h))
      const row = y0.offset + sy * y0.stride
      const mrow = (y - top) * w
      for (let x = 0; x < w; x++) {
        const a = alpha[mrow + x]
        if (!a) continue
        const i = row + ox + Math.min(vw - 1, Math.round((x * vw) / w))
        const target = lo + (gray[mrow + x] * span) / 255
        buf[i] = (buf[i] * (255 - a) + target * a) / 255
      }
    }
    // Farbe: halbe Auflösung, Deckkraft aus dem Mittel des 2 × 2-Blocks
    const nv12 = format === 'NV12'
    for (let y = top; y < h; y += 2) {
      const cy = (oy >> 1) + Math.min((vh >> 1) - 1, Math.round(((y >> 1) * vh) / h))
      for (let x = 0; x < w; x += 2) {
        const m = (y - top) * w + x
        const a = (alpha[m] + alpha[m + 1] + (y + 1 < h ? alpha[m + w] + alpha[m + w + 1] : alpha[m] + alpha[m + 1])) / 4
        if (!a) continue
        const cx = (ox >> 1) + Math.min((vw >> 1) - 1, Math.round(((x >> 1) * vw) / w))
        const keep = (255 - a) / 255
        if (nv12) {
          const p = layout[1].offset + cy * layout[1].stride + cx * 2
          buf[p] = 128 + (buf[p] - 128) * keep
          buf[p + 1] = 128 + (buf[p + 1] - 128) * keep
        } else {
          const pu = layout[1].offset + cy * layout[1].stride + cx
          const pv = layout[2].offset + cy * layout[2].stride + cx
          buf[pu] = 128 + (buf[pu] - 128) * keep
          buf[pv] = 128 + (buf[pv] - 128) * keep
        }
      }
    }
  }

  /** Warten, solange zu viele Bilder unterwegs sind. Nicht über decodeQueueSize: WebKit (Mac-App) gibt bei B-Frames
   * Bilder erst nach weiteren Proben heraus und zählt die Warteschlange erst dabei herunter; mit „> 4“ hing der Export
   * dort ohne Meldung (gemessen 20.11.2026). Steht alles 30 s still, kommt eine Fehlermeldung mit den Zählern. */
  async throttle(): Promise<void> {
    while (!this.err && (this.fed - this.decoded > 48 || this.queue.length > 8 || this.enc.encodeQueueSize > 16)) {
      if (performance.now() - this.progressAt > 30000) {
        const how = `${this.encCfg.codec} ${this.encCfg.latencyMode ?? ''}, ${this.enc.state}, ${this.enc.encodeQueueSize}`
        throw new Error(t(`Das Einbrennen kommt nicht voran (dekodiert ${this.decoded} von ${this.fed}, kodiert ${this.out.length} von ${this.frames}; ${how}).`,
          `Burning in makes no progress (decoded ${this.decoded} of ${this.fed}, encoded ${this.out.length} of ${this.frames}; ${how}).`))
      }
      await new Promise((r) => setTimeout(r, 2))
    }
    if (this.err) throw this.err
  }

  /** Kodierte Bilder schreiben, deren Dekodierzeit und Dauer feststehen (am Ende alle). Geordnete Ausgabe: Dekodierzeit =
   * eigene Darstellungszeit, Dauer bis zum nächsten Bild (so stören auch ausgelassene Bilder nicht). Mit B-Frames: die
   * Darstellungszeiten der eingereichten Bilder der Reihe nach, der Rest als Kompositionsversatz. */
  write(final = false): void {
    while (this.written < this.out.length) {
      const j = this.written
      const o = this.out[j]
      if (!this.reorder) {
        if (!final && j + 1 >= this.out.length) break
        const dur = j + 1 < this.out.length ? this.out[j + 1].pts - o.pts : this.lastDur
        if (dur <= 0 && j + 1 < this.out.length) {
          this.reorder = true // spät erkannt: ab hier wie mit B-Frames
          continue
        }
        this.w.sample(this.vi, o.data, Math.max(1, dur), o.key, 0)
      } else {
        if (!final && j + 1 >= this.submitted.length) break
        const dts = this.submitted[j]
        const dur = j + 1 < this.submitted.length ? this.submitted[j + 1] - dts : this.lastDur
        this.w.sample(this.vi, o.data, Math.max(1, dur), o.key, o.pts - dts)
      }
      this.written++
    }
  }

  async finish(): Promise<void> {
    await this.dec.flush()
    while (this.pump) await this.pump
    if (this.err) throw this.err
    const flushed = this.enc.flush()
    const t0 = performance.now()
    // flush() kehrt bei manchen Kodierern nie zurück (WebKit in 'quality'); dann reicht es, wenn alles heraus ist
    while (this.out.length < this.frames && performance.now() - t0 < 30000) {
      const done = await Promise.race([flushed.then(() => true), new Promise<boolean>((r) => setTimeout(() => r(false), 50))])
      if (done) break
    }
    if (this.err) throw this.err
    this.write(true)
  }

  close(): void {
    for (const f of this.queue) f.close()
    this.queue = []
    for (const c of [this.dec, this.enc]) {
      try {
        c.close()
      } catch {
        /* schon zu */
      }
    }
  }
}

export async function videoWithSound(o: VOptions): Promise<VResult> {
  const { a, b } = o.fit
  let info
  try {
    info = await readMp4(o.video, (h) => h === 'vide')
  } catch (e) {
    throw readable(e)
  }
  const vt = info.tracks[0]
  if (!vt || !vt.count) throw new Error(t('Im Video ist keine Bildspur.', 'The video has no picture track.'))
  const ts = vt.timescale
  const pt = (i: number) => (vt.dts[i] + (vt.cto ? vt.cto[i] : 0) - vt.shift) / ts
  const vdur = (vt.end - vt.shift) / ts
  const tau0 = Math.max(0, a * o.region[0] + b)
  const tau1 = Math.min(vdur, a * o.region[1] + b)
  if (tau1 - tau0 < 0.5) throw new Error(t('Der Bereich liegt nicht im Video.', 'The range is not inside the video.'))
  // Schlüsselbild vor dem Anfang (Dekodier-Reihenfolge), wie NVAI-open
  let k = -1
  let firstSync = -1
  for (let i = 0; i < vt.count; i++) {
    if (vt.sync && !vt.sync[i]) continue
    if (firstSync < 0) firstSync = i
    if (pt(i) <= tau0 + 1e-6) k = i
    else break
  }
  if (k < 0) k = firstSync
  if (k < 0) throw new Error(t('Kein Schlüsselbild im Bereich gefunden.', 'No key frame found in the range.'))
  let end = k
  while (end < vt.count && pt(end) <= tau1) end++
  const kf = pt(k)
  const nOut = Math.round((tau1 - kf) * OUT_SR)
  const presTick = (i: number) => vt.dts[i] + (vt.cto ? vt.cto[i] : 0) - vt.shift
  const kfTick = presTick(k)
  const sampleDur = (i: number) => (i + 1 < vt.count ? vt.dts[i + 1] : vt.end) - vt.dts[i]

  // Einbrennen: Dekoder und Kodierer vorher prüfen, damit nichts halb geschrieben wird
  let burnSetup: { dec: VideoDecoderConfig; enc: VideoEncoderConfig; laid: LaidCue[]; w: number; h: number } | null = null
  if (o.burn) {
    if (typeof VideoDecoder === 'undefined' || typeof VideoEncoder === 'undefined' || typeof OffscreenCanvas === 'undefined') {
      throw new Error(t('Dieser Browser kann kein Video neu kodieren; bitte Edge oder Chrome verwenden.', 'This browser cannot re-encode video; please use Edge or Chrome.'))
    }
    const vc = videoConfig(vt.stsd)
    if (!vc) throw new Error(t('Einbrennen geht nur mit H.264-Videos.', 'Burning in works only with H.264 videos.'))
    const bw = Math.max(2, Math.round(vt.width) & ~1)
    const bh = Math.max(2, Math.round(vt.height) & ~1)
    const fps = Math.max(1, Math.round(vt.count / Math.max(1e-3, (vt.end - vt.dts[0]) / ts)))
    const dec: VideoDecoderConfig = { codec: vc.codec, description: vc.description, codedWidth: bw, codedHeight: bh }
    const decOk = await VideoDecoder.isConfigSupported(dec).then((r) => !!r.supported).catch(() => false)
    if (!decOk) throw new Error(t(`Dieser Browser dekodiert ${vc.codec} nicht; die Untertitel lassen sich hier nicht einbrennen.`, `This browser does not decode ${vc.codec}; the subtitles cannot be burned in here.`))
    let bytes = 0
    for (let i = k; i < end; i++) bytes += vt.size[i]
    const enc = await pickEncoder(bw, bh, fps, (bytes * 8) / Math.max(1e-3, tau1 - kf))
    const laid = layoutCues(videoCues(o.burn.segments, o.burn.mode, o.burn.lang, o.fit, kf, tau1), undefined, undefined, [0, tau1 - kf])
    burnSetup = { dec, enc, laid, w: bw, h: bh }
  }

  const ch = o.mono ? 1 : 2
  const bitrate = (o.kbps ?? 192) * 1000
  const cfg: AudioEncoderConfig = { codec: 'mp4a.40.2', sampleRate: OUT_SR, numberOfChannels: ch, bitrate }
  const supported = typeof AudioEncoder !== 'undefined' && (await AudioEncoder.isConfigSupported(cfg).catch(() => ({ supported: false }))).supported
  if (!supported) throw new Error(t('Dieser Browser kann kein AAC kodieren. Bitte Edge oder Chrome unter Windows oder macOS verwenden.', 'This browser cannot encode AAC. Please use Edge or Chrome on Windows or macOS.'))
  let priming = 0
  try {
    priming = await aacPriming(cfg)
  } catch {
    priming = 0
  }
  const srcs: Src[] = await Promise.all(o.tracks.map(async (x) => {
    const wi = await wavInfo(x.file)
    const block = (wi.channels * wi.bits) / 8
    return { file: x.file, info: wi, gain: 10 ** (x.gainDb / 20), sinc: new Sinc((OUT_SR * a) / wi.sr), frames: Math.floor(wi.dataBytes / block) }
  }))

  const w = new Mp4Writer(o.sink)
  const vi = burnSetup
    ? w.track({ handler: 'vide', timescale: ts, width: burnSetup.w, height: burnSetup.h, matrix: vt.matrix })
    : w.track({ handler: 'vide', timescale: ts, stsd: vt.stsd, width: vt.width, height: vt.height, matrix: vt.matrix, shift: vt.cto ? vt.cto[k] : 0 })
  const ai = w.track({ handler: 'soun', timescale: OUT_SR })
  await w.start(vt.codec.startsWith('avc') ? ['avc1'] : [])
  let asc: Uint8Array | null = null
  let encErr: unknown = null
  const pending: EncodedAudioChunk[] = []
  const encoder = new AudioEncoder({
    output: (c, m) => {
      pending.push(c)
      const d = m?.decoderConfig?.description
      if (!asc && d) asc = ascFrom(bytesOf(d))
    },
    error: (e) => { encErr = e },
  })
  encoder.configure(cfg)
  const drain = () => {
    for (const c of pending) {
      const d = new Uint8Array(c.byteLength)
      c.copyTo(d)
      w.sample(ai, d, 1024) // AAC-LC: 1024 Proben je Paket
    }
    pending.length = 0
  }
  const d0 = vt.dts[k]
  let next = k
  let packets = 0
  const burner = burnSetup ? new Burner(w, vi, ts, burnSetup.laid, burnSetup.w, burnSetup.h, burnSetup.dec, burnSetup.enc, sampleDur(Math.max(k, end - 1))) : null
  // Bildproben [next, i1) kopieren; nah beieinander liegende in einem Stück lesen
  const copyVideo = async (i1: number) => {
    const i0 = next
    if (i1 <= i0) return
    let lo = Infinity
    let hi = 0
    for (let i = i0; i < i1; i++) {
      lo = Math.min(lo, vt.offset[i])
      hi = Math.max(hi, vt.offset[i] + vt.size[i])
    }
    const buf = hi - lo <= 64 * 1024 * 1024 ? new Uint8Array(await o.video.slice(lo, hi).arrayBuffer()) : null
    for (let i = i0; i < i1; i++) {
      const data = buf ? buf.subarray(vt.offset[i] - lo, vt.offset[i] - lo + vt.size[i])
        : new Uint8Array(await o.video.slice(vt.offset[i], vt.offset[i] + vt.size[i]).arrayBuffer())
      if (burner) {
        if (burner.err) throw burner.err
        burner.decode(data.slice(), presTick(i) - kfTick, sampleDur(i), !vt.sync || vt.sync[i] === 1)
        await burner.throttle()
        burner.write()
      } else {
        w.sample(vi, data, sampleDur(i), !vt.sync || vt.sync[i] === 1, vt.cto ? vt.cto[i] : 0)
      }
    }
    if (!burner) packets += i1 - i0
    next = i1
  }

  let done = 0
  let peak = 0
  try {
    while (done < nOut) {
      if (o.signal?.aborted) throw new DOMException('aborted', 'AbortError')
      if (encErr) throw encErr
      const n = Math.min(OUT_SR, nOut - done) // eine Sekunde je Runde
      const planes = Array.from({ length: ch }, () => new Float32Array(n))
      for (const s of srcs) {
        const sr = s.info.sr
        const step = sr / (OUT_SR * a)
        const p0 = ((kf + done / OUT_SR - b) / a) * sr // Quellposition der ersten Ausgabeprobe
        const lo = Math.floor(p0) - s.sinc.half - 2
        const hi = Math.ceil(p0 + n * step) + s.sinc.half + 2
        const block = await readBlock(s, lo, hi, o.mono)
        for (let c = 0; c < ch; c++) s.sinc.render(planes[c], n, block[Math.min(c, block.length - 1)], p0 - lo, step, s.gain)
      }
      const data = new Float32Array(n * ch)
      for (let c = 0; c < ch; c++) {
        const pl = planes[c]
        for (let i = 0; i < n; i++) {
          const v = pl[i]
          const m = v < 0 ? -v : v
          if (m > peak) peak = m
          data[c * n + i] = v > 1 ? 1 : v < -1 ? -1 : v
        }
      }
      const ad = new AudioData({ format: 'f32-planar', sampleRate: OUT_SR, numberOfFrames: n, numberOfChannels: ch, timestamp: Math.round((done / OUT_SR) * 1e6), data })
      encoder.encode(ad)
      ad.close()
      done += n
      // Bild bis zur gleichen Stelle (Dekodierzeit ab dem Schlüsselbild)
      const until = done / OUT_SR
      let i1 = next
      while (i1 < end && (vt.dts[i1] - d0) / ts < until) i1++
      await copyVideo(i1)
      drain()
      await w.flush()
      while (encoder.encodeQueueSize > 2) await new Promise((r) => setTimeout(r, 1))
      o.progress(done / nOut)
    }
    await encoder.flush()
    drain()
    await copyVideo(end)
    if (burner && burnSetup) {
      await burner.finish()
      if (!burner.avcC) throw new Error(t('Der H.264-Kodierer lieferte keine Beschreibung.', 'The H.264 encoder returned no description.'))
      w.set(vi, { stsd: avcStsd(burnSetup.w, burnSetup.h, burner.avcC) })
      w.liftCto(vi)
      packets = burner.frames
    }
  } finally {
    try {
      encoder.close()
    } catch {
      /* schon zu */
    }
    burner?.close()
  }
  if (encErr) throw encErr
  w.set(ai, { stsd: aacStsd(OUT_SR, ch, asc ?? aacAsc(OUT_SR, ch), bitrate), shift: priming, presentation: nOut })
  const bytes = await w.finish()
  return { videoStart: kf, videoEnd: tau1, recordStart: (kf - b) / a, packets, peak, bytes, priming, codec: vt.codec,
    burned: burnSetup ? burnSetup.enc.codec : null }
}

/** Untertitel-Blöcke zum exportierten Video wie NVAI-open: Original oder Übersetzung, Geräusche in eckigen Klammern, Zeiten
 * ab dem ersten Bild des Videos (Schlüsselbild); nur was ins Video reicht, noch nicht beschnitten (das macht layoutCues). */
export function videoCues(segments: TranscriptSegment[], mode: 'original' | 'translation', lang: string, fit: { a: number; b: number },
  videoStart: number, videoEnd: number): Cue[] {
  const out: Cue[] = []
  const total = videoEnd - videoStart
  for (const s of segments) {
    const txt = mode === 'original' ? s.text : (s.translation?.[lang] || '')
    if (!txt || !txt.trim()) continue
    const a0 = fit.a * s.start + fit.b - videoStart
    const b0 = fit.a * s.end + fit.b - videoStart
    if (b0 <= 0 || a0 >= total) continue
    out.push({ start: a0, end: b0, text: s.kind === 'sound' ? `[${txt}]` : txt })
  }
  return out
}

/** SRT zum exportierten Video (höchstens zwei Zeilen zu 42 Zeichen je Block, siehe subtitles.ts), mit BOM */
export function srtForVideo(segments: TranscriptSegment[], mode: 'original' | 'translation', lang: string, fit: { a: number; b: number },
  videoStart: number, videoEnd: number): { text: string; cues: number } {
  const r = toSrt(videoCues(segments, mode, lang, fit, videoStart, videoEnd), [0, videoEnd - videoStart])
  return { text: '\ufeff' + r.text, cues: r.cues }
}
