// „Video mit Ton“ in der Prüf-App, ohne Server: wie NVAI-open (forensic_tools.cmd_videoexport), aber im Browser.
// Das Bild bleibt unverändert: die Proben ab dem Schlüsselbild vor dem Anfang werden aus der MP4 des Pakets kopiert.
// Der Ton kommt aus dem Originalton der Spuren im Paket (fall/original/*.wav), wird bandbegrenzt über die Zuordnung
// video_t = a·t + b auf die Video-Zeit gelegt, gemischt (Pegel je Spur), begrenzt und mit WebCodecs als AAC kodiert.
// Untertitel kommen danach als SRT daneben (srtForVideo), mit Zeiten ab dem ersten Bild des Videos.

import type { TranscriptSegment } from '../api'
import { t } from '../i18n'
import { aacAsc, aacStsd, ascFrom, Mp4Error, Mp4Writer, readMp4, type Sink } from './mp4'
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
  const vi = w.track({ handler: 'vide', timescale: ts, stsd: vt.stsd, width: vt.width, height: vt.height, matrix: vt.matrix, shift: vt.cto ? vt.cto[k] : 0 })
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
  const sampleDur = (i: number) => (i + 1 < vt.count ? vt.dts[i + 1] : vt.end) - vt.dts[i]
  let next = k
  let packets = 0
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
      w.sample(vi, data, sampleDur(i), !vt.sync || vt.sync[i] === 1, vt.cto ? vt.cto[i] : 0)
    }
    packets += i1 - i0
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
  } finally {
    try {
      encoder.close()
    } catch {
      /* schon zu */
    }
  }
  if (encErr) throw encErr
  w.set(ai, { stsd: aacStsd(OUT_SR, ch, asc ?? aacAsc(OUT_SR, ch), bitrate), shift: priming, presentation: nOut })
  const bytes = await w.finish()
  return { videoStart: kf, videoEnd: tau1, recordStart: (kf - b) / a, packets, peak, bytes, priming, codec: vt.codec }
}

function srtTime(x: number): string {
  const ms = Math.round(Math.max(0, x) * 1000)
  const p = (v: number, n = 2) => String(v).padStart(n, '0')
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)},${p(ms % 1000, 3)}`
}

/** Untertitel zum exportierten Video wie NVAI-open: Original oder Übersetzung, Geräusche in eckigen Klammern, Zeiten ab
 * dem ersten Bild des Videos (Schlüsselbild). */
export function srtForVideo(segments: TranscriptSegment[], mode: 'original' | 'translation', lang: string, fit: { a: number; b: number },
  videoStart: number, videoEnd: number): { text: string; cues: number } {
  const lines: string[] = []
  const total = videoEnd - videoStart
  for (const s of segments) {
    const txt = mode === 'original' ? s.text : (s.translation?.[lang] || '')
    if (!txt) continue
    const a0 = fit.a * s.start + fit.b - videoStart
    const b0 = fit.a * s.end + fit.b - videoStart
    if (b0 <= 0 || a0 >= total) continue
    lines.push(`${lines.length + 1}\n${srtTime(a0)} --> ${srtTime(b0)}\n${s.kind === 'sound' ? `[${txt}]` : txt}\n`)
  }
  return { text: '﻿' + lines.join('\n'), cues: lines.length }
}
