// Spektrogramm der Ton-Forensik: Der Server schreibt je Spur vier Stufen (forensic_tools.py: 20 ms, 0,16 s, 2,56 s, 41 s
// je Spalte, je Spalte `bins` Bänder als uint8 von −120 bis 0 dB). Der Browser holt per Range-Anfrage nur Stücke von
// 4096 Spalten (feinste Stufe: 82 s), die gröbste Stufe ganz.

import { audioSpecUrl, type AudioTrack } from '../api'

const HEAD = 32
const CHUNK = 4096
const cache = new Map<string, Promise<Uint8Array>>()

function chunk(url: string, bins: number, index: number, cols: number): Promise<Uint8Array> {
  const key = `${url}#${index}`
  let p = cache.get(key)
  if (!p) {
    const c0 = index * CHUNK
    const c1 = Math.min(cols, c0 + CHUNK)
    const a = HEAD + c0 * bins
    const b = HEAD + c1 * bins - 1
    p = fetch(url, { headers: { Range: `bytes=${a}-${b}` }, cache: 'no-store' }).then(async (r) => {
      if (!r.ok) throw new Error(`spec ${r.status}`)
      const buf = new Uint8Array(await r.arrayBuffer())
      // Server ohne Range-Unterstützung: ganze Datei, dann selbst ausschneiden
      return r.status === 200 && buf.length > b - a + 1 ? buf.slice(a, b + 1) : buf
    })
    cache.set(key, p)
    p.catch(() => cache.delete(key))
    // Speicher begrenzen: älteste Stücke verwerfen
    if (cache.size > 160) cache.delete(cache.keys().next().value as string)
  }
  return p
}

export function dropSpecCache(pid: string): void {
  for (const k of [...cache.keys()]) if (k.includes(`/projects/${encodeURIComponent(pid)}/`)) cache.delete(k)
}

export interface SpecView {
  /** Werte je Bildpunkt-Spalte und Band (Spalte für Spalte), 255 = kein Wert */
  data: Uint8Array
  width: number
  bins: number
}

/** Spektrogramm für das Fenster [t0, t1) (Sekunden der Spur) in `width` Spalten. */
export async function specColumns(pid: string, tr: AudioTrack, t0: number, t1: number, width: number): Promise<SpecView | null> {
  const s = tr.spec
  if (!s) return null
  const colSec = (f: number) => (s.hop * f) / s.sr
  // feinste Stufe, bei der höchstens 8 Spalten auf einen Bildpunkt fallen (sonst zu viele Daten)
  let li = 0
  while (li + 1 < s.levels.length && (t1 - t0) / colSec(s.levels[li].factor) > width * 8) li++
  const lvl = s.levels[li]
  const url = audioSpecUrl(pid, tr.id, String(li) as '0' | '1' | '2' | '3')
  const cs = colSec(lvl.factor)
  const c0 = Math.max(0, Math.floor(t0 / cs))
  const c1 = Math.min(lvl.cols, Math.ceil(t1 / cs) + 1)
  const out = new Uint8Array(width * s.bins).fill(0)
  if (c1 <= c0) return { data: out, width, bins: s.bins }
  const need = new Set<number>()
  for (let c = Math.floor(c0 / CHUNK); c <= Math.floor((c1 - 1) / CHUNK); c++) need.add(c)
  const parts = new Map<number, Uint8Array>()
  await Promise.all([...need].map(async (i) => { parts.set(i, await chunk(url, s.bins, i, lvl.cols)) }))
  const col = (c: number): Uint8Array | null => {
    const part = parts.get(Math.floor(c / CHUNK))
    if (!part) return null
    const off = (c % CHUNK) * s.bins
    return off + s.bins <= part.length ? part.subarray(off, off + s.bins) : null
  }
  for (let x = 0; x < width; x++) {
    const a = (t0 + ((t1 - t0) * x) / width) / cs
    const b = (t0 + ((t1 - t0) * (x + 1)) / width) / cs
    const ca = Math.floor(a)
    const cb = Math.max(ca + 1, Math.floor(b))
    if (cb <= 0 || ca >= lvl.cols) continue
    const o = x * s.bins
    for (let c = Math.max(0, ca); c < Math.min(lvl.cols, cb); c++) {
      const v = col(c)
      if (!v) continue
      for (let k = 0; k < s.bins; k++) if (v[k] > out[o + k]) out[o + k] = v[k]
    }
  }
  return { data: out, width, bins: s.bins }
}

// Farbskala (ähnlich „magma“): dunkel → violett → orange → hellgelb
const STOPS: [number, number, number, number][] = [
  [0, 4, 4, 12], [0.2, 40, 16, 80], [0.4, 110, 30, 120], [0.6, 200, 60, 90], [0.8, 248, 150, 60], [1, 252, 250, 190],
]
export const LUT: Uint8ClampedArray = (() => {
  const lut = new Uint8ClampedArray(256 * 3)
  for (let i = 0; i < 256; i++) {
    const x = i / 255
    let k = 0
    while (k + 1 < STOPS.length - 1 && STOPS[k + 1][0] < x) k++
    const [x0, r0, g0, b0] = STOPS[k]
    const [x1, r1, g1, b1] = STOPS[k + 1]
    const f = Math.max(0, Math.min(1, (x - x0) / (x1 - x0)))
    lut[3 * i] = r0 + (r1 - r0) * f
    lut[3 * i + 1] = g0 + (g1 - g0) * f
    lut[3 * i + 2] = b0 + (b1 - b0) * f
  }
  return lut
})()

/** In ein Canvas malen: dB-Fenster [lo, hi], Frequenzen bis fshow (Hz, oben). */
export function paintSpec(g: CanvasRenderingContext2D, v: SpecView, height: number, fmax: number, fshow: number, lo: number, hi: number): void {
  const img = g.createImageData(v.width, height)
  const bins = v.bins
  const topBin = Math.min(bins, Math.round((fshow / fmax) * bins))
  // uint8 → dB: −120 + u · 120 / 255
  const map = new Uint8Array(256)
  for (let u = 0; u < 256; u++) {
    const db = -120 + (u * 120) / 255
    map[u] = Math.round(Math.max(0, Math.min(1, (db - lo) / Math.max(1, hi - lo))) * 255)
  }
  for (let y = 0; y < height; y++) {
    const k = Math.min(bins - 1, Math.floor(((height - 1 - y) / height) * topBin))
    for (let x = 0; x < v.width; x++) {
      const c = map[v.data[x * bins + k]]
      const i = 4 * (y * v.width + x)
      img.data[i] = LUT[3 * c]
      img.data[i + 1] = LUT[3 * c + 1]
      img.data[i + 2] = LUT[3 * c + 2]
      img.data[i + 3] = 255
    }
  }
  g.putImageData(img, 0, 0)
}

const actCache = new Map<string, Promise<Uint8Array>>()

/** Sprachaktivität einer Spur: je 0,1 s ein Wert 0–255 (Silero-Karte, sonst die grobe aus dem Spektrogramm) */
export function loadActivity(pid: string, tid: string, stamp: number, vad = false): Promise<Uint8Array> {
  const url = `${audioSpecUrl(pid, tid, vad ? 'vad' : 'act')}?v=${stamp}`
  let p = actCache.get(url)
  if (!p) {
    p = fetch(url, { cache: 'no-store' }).then(async (r) => {
      if (!r.ok) throw new Error(`act ${r.status}`)
      return new Uint8Array(await r.arrayBuffer())
    })
    actCache.set(url, p)
    p.catch(() => actCache.delete(url))
  }
  return p
}
