// WAV-Export der Prüf-App aus dem Originalton im Paket (fall/original/<Spur>.wav, bitgenau aus der Arbeitsdatei).
// Eine Spur ohne Pegeländerung: die Bytes des Originals unverändert (bitgenau). Mehrere Spuren oder Pegel: verlustfrei
// gemischt als 32-Bit-Gleitkomma. Über 4 GB als RF64. Geschrieben wird stückweise über „Speichern unter“ (File System
// Access), damit auch Stunden nicht den Speicher füllen.

import { t } from '../i18n'
import { asBlob } from './native'

export interface WavInfo { dataStart: number; dataBytes: number; sr: number; channels: number; bits: number; float: boolean }

export async function wavInfo(f: Blob): Promise<WavInfo> {
  const head = new DataView(await f.slice(0, 1 << 16).arrayBuffer())
  const tag = (o: number) => String.fromCharCode(head.getUint8(o), head.getUint8(o + 1), head.getUint8(o + 2), head.getUint8(o + 3))
  const kind = tag(0)
  if (kind !== 'RIFF' && kind !== 'RF64') throw new Error(t('Keine WAV-Datei.', 'Not a WAV file.'))
  let pos = 12
  let sr = 0
  let channels = 0
  let bits = 0
  let float = false
  let ds64 = 0
  while (pos + 8 <= head.byteLength) {
    const id = tag(pos)
    const size = head.getUint32(pos + 4, true)
    if (id === 'ds64') ds64 = Number(head.getBigUint64(pos + 16, true))
    if (id === 'fmt ') {
      const fmt = head.getUint16(pos + 8, true)
      channels = head.getUint16(pos + 10, true)
      sr = head.getUint32(pos + 12, true)
      bits = head.getUint16(pos + 22, true)
      float = fmt === 3 || (fmt === 0xfffe && bits === 32 && head.getUint16(pos + 32, true) === 3)
    }
    if (id === 'data') {
      const bytes = size === 0xffffffff && ds64 ? ds64 : size
      return { dataStart: pos + 8, dataBytes: Math.min(bytes, f.size - pos - 8), sr, channels, bits, float }
    }
    pos += 8 + size + (size & 1)
  }
  throw new Error(t('WAV-Datei ohne Tondaten.', 'WAV file without audio data.'))
}

function header(sr: number, channels: number, bits: number, float: boolean, dataBytes: number): ArrayBuffer {
  const rf64 = dataBytes > 0xffffffff - 1024
  const buf = new ArrayBuffer(rf64 ? 80 : 44)
  const v = new DataView(buf)
  const put = (o: number, s: string) => { for (let i = 0; i < 4; i++) v.setUint8(o + i, s.charCodeAt(i)) }
  const block = (channels * bits) / 8
  let o = 0
  put(0, rf64 ? 'RF64' : 'RIFF')
  v.setUint32(4, rf64 ? 0xffffffff : 36 + dataBytes, true)
  put(8, 'WAVE')
  o = 12
  if (rf64) {
    put(o, 'ds64')
    v.setUint32(o + 4, 28, true)
    v.setBigUint64(o + 8, BigInt(72 + dataBytes), true)
    v.setBigUint64(o + 16, BigInt(dataBytes), true)
    v.setBigUint64(o + 24, BigInt(Math.floor(dataBytes / block)), true)
    v.setUint32(o + 32, 0, true)
    o += 36
  }
  put(o, 'fmt ')
  v.setUint32(o + 4, 16, true)
  v.setUint16(o + 8, float ? 3 : 1, true)
  v.setUint16(o + 10, channels, true)
  v.setUint32(o + 12, sr, true)
  v.setUint32(o + 16, sr * block, true)
  v.setUint16(o + 20, block, true)
  v.setUint16(o + 22, bits, true)
  put(o + 24, 'data')
  v.setUint32(o + 28, rf64 ? 0xffffffff : dataBytes, true)
  return buf
}

/** Proben eines Ausschnitts als Gleitkomma, Kanäle verschränkt */
export function toFloat(buf: ArrayBuffer, info: WavInfo): Float32Array {
  if (info.float) return new Float32Array(buf)
  if (info.bits === 16) {
    const s = new Int16Array(buf)
    const out = new Float32Array(s.length)
    for (let i = 0; i < s.length; i++) out[i] = s[i] / 32768
    return out
  }
  if (info.bits === 24) {
    const b = new Uint8Array(buf)
    const n = Math.floor(b.length / 3)
    const out = new Float32Array(n)
    for (let i = 0; i < n; i++) {
      const x = b[3 * i] | (b[3 * i + 1] << 8) | (b[3 * i + 2] << 16)
      out[i] = (x & 0x800000 ? x - 0x1000000 : x) / 8388608
    }
    return out
  }
  if (info.bits === 32) {
    // 32-Bit-Ganzzahl (Mac-Fälle aus solchen Quellen, seit Mac 0.5.13 bitgenau)
    const s = new Int32Array(buf, 0, Math.floor(buf.byteLength / 4))
    const out = new Float32Array(s.length)
    for (let i = 0; i < s.length; i++) out[i] = s[i] / 2147483648
    return out
  }
  throw new Error(t(`WAV mit ${info.bits} Bit wird nicht unterstützt.`, `WAV with ${info.bits} bit is not supported.`))
}

type SaveTarget = { write: (d: BufferSource | Blob) => Promise<void>; close: () => Promise<void> }

async function saveTarget(name: string): Promise<SaveTarget> {
  const picker = (window as unknown as { showSaveFilePicker: (o: unknown) => Promise<{ createWritable: () => Promise<SaveTarget> }> }).showSaveFilePicker
  const handle = await picker({ suggestedName: name, types: [{ description: 'WAV', accept: { 'audio/wav': ['.wav'] } }] })
  return handle.createWritable()
}

export interface WavSource { name: string; file: Blob; gainDb: number }

/** Ausschnitt [a, b] (Sekunden) der Spuren als WAV speichern. Ergebnis: Bytes, bitgenau ja/nein. */
export async function exportWav(sources: WavSource[], a: number, b: number, mono: boolean, name: string,
  progress: (f: number) => void): Promise<{ bytes: number; exact: boolean }> {
  const infos = await Promise.all(sources.map((s) => wavInfo(s.file)))
  const sr = infos[0].sr
  if (infos.some((x) => x.sr !== sr)) {
    const rates = sources.map((s, i) => `${s.name} ${infos[i].sr} Hz`).join(', ')
    throw new Error(t(`Die Spuren haben verschiedene Abtastraten (${rates}). Als WAV nur Spuren mit gleicher Rate zusammen speichern; der Video-Export rechnet sie um.`,
      `The tracks have different sample rates (${rates}). Save only tracks with the same rate together as WAV; the video export converts them.`))
  }
  const outCh = mono ? 1 : Math.max(...infos.map((x) => x.channels))
  const exact = sources.length === 1 && sources[0].gainDb === 0 && outCh === infos[0].channels
  const frames = Math.max(0, Math.round((b - a) * sr))
  const target = await saveTarget(name)
  try {
    if (exact) {
      const info = infos[0]
      const block = (info.channels * info.bits) / 8
      const start = info.dataStart + Math.round(a * sr) * block
      const bytes = Math.min(frames * block, info.dataStart + info.dataBytes - start)
      await target.write(header(sr, info.channels, info.bits, info.float, bytes))
      const step = sr * block * 60
      for (let off = 0; off < bytes; off += step) {
        await target.write(await asBlob(sources[0].file.slice(start + off, start + Math.min(bytes, off + step))))
        progress(Math.min(1, (off + step) / bytes))
      }
      await target.close()
      return { bytes, exact: true }
    }
    const bytes = frames * outCh * 4
    await target.write(header(sr, outCh, 32, true, bytes))
    const stepFrames = sr * 30
    for (let f0 = 0; f0 < frames; f0 += stepFrames) {
      const n = Math.min(stepFrames, frames - f0)
      const mix = new Float32Array(n * outCh)
      for (let k = 0; k < sources.length; k++) {
        const info = infos[k]
        const block = (info.channels * info.bits) / 8
        const from = info.dataStart + (Math.round(a * sr) + f0) * block
        const to = Math.min(from + n * block, info.dataStart + info.dataBytes)
        if (to <= from) continue
        const x = toFloat(await sources[k].file.slice(from, to).arrayBuffer(), info)
        const g = 10 ** (sources[k].gainDb / 20)
        const got = Math.floor(x.length / info.channels)
        for (let i = 0; i < got; i++) {
          if (outCh === 1) {
            let s = 0
            for (let c = 0; c < info.channels; c++) s += x[i * info.channels + c]
            mix[i] += (s / info.channels) * g
          } else {
            for (let c = 0; c < outCh; c++) mix[i * outCh + c] += x[i * info.channels + Math.min(c, info.channels - 1)] * g
          }
        }
      }
      await target.write(mix)
      progress(Math.min(1, (f0 + n) / frames))
    }
    await target.close()
    return { bytes, exact: false }
  } catch (e) {
    try { await target.close() } catch { /* schon zu */ }
    throw e
  }
}
