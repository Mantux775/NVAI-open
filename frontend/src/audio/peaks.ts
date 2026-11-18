// Wellenform einer Spur: der Server liefert je 256 Proben ein Paar (min, max) als int8 (audio_tools.Peaks).
// Für stundenlange Aufnahmen baut der Browser daraus Stufen mit je 8-fach gröberer Auflösung, damit jeder Bildpunkt nur
// wenige Werte zusammenfassen muss.

export const PEAK_SPB = 256

export class Peaks {
  levels: Int8Array[] = []
  factors: number[] = []

  constructor(raw: Int8Array) {
    this.levels.push(raw)
    this.factors.push(1)
    let cur = raw
    let f = 1
    while (cur.length / 2 > 4096) {
      const n = Math.ceil(cur.length / 2 / 8)
      const next = new Int8Array(n * 2)
      for (let i = 0; i < n; i++) {
        let mn = 127, mx = -127
        const end = Math.min(cur.length / 2, (i + 1) * 8)
        for (let j = i * 8; j < end; j++) {
          if (cur[2 * j] < mn) mn = cur[2 * j]
          if (cur[2 * j + 1] > mx) mx = cur[2 * j + 1]
        }
        next[2 * i] = mn
        next[2 * i + 1] = mx
      }
      f *= 8
      this.levels.push(next)
      this.factors.push(f)
      cur = next
    }
  }

  get bars(): number { return this.levels[0].length / 2 }

  /** min/max (−1…1) je Bildpunkt für das Zeitfenster [t0, t1) in Sekunden der Spur */
  columns(t0: number, t1: number, width: number, sr: number): Float32Array {
    const out = new Float32Array(width * 2)
    const barsPerPx = ((t1 - t0) * sr) / PEAK_SPB / width
    let li = 0
    while (li + 1 < this.levels.length && this.factors[li + 1] * 2 <= barsPerPx) li++
    const lvl = this.levels[li]
    const f = this.factors[li]
    const n = lvl.length / 2
    for (let x = 0; x < width; x++) {
      const b0 = Math.floor(((t0 + ((t1 - t0) * x) / width) * sr) / PEAK_SPB / f)
      const b1 = Math.max(b0 + 1, Math.floor(((t0 + ((t1 - t0) * (x + 1)) / width) * sr) / PEAK_SPB / f))
      let mn = 0, mx = 0
      if (b1 > 0 && b0 < n) {
        mn = 127; mx = -127
        for (let b = Math.max(0, b0); b < Math.min(n, b1); b++) {
          if (lvl[2 * b] < mn) mn = lvl[2 * b]
          if (lvl[2 * b + 1] > mx) mx = lvl[2 * b + 1]
        }
        if (mn > mx) { mn = 0; mx = 0 }
      }
      out[2 * x] = mn / 127
      out[2 * x + 1] = mx / 127
    }
    return out
  }
}

const cache = new Map<string, Promise<Peaks>>()

export function loadPeaks(url: string): Promise<Peaks> {
  let p = cache.get(url)
  if (!p) {
    p = fetch(url).then(async (r) => {
      if (!r.ok) throw new Error(`peaks ${r.status}`)
      return new Peaks(new Int8Array(await r.arrayBuffer()))
    })
    cache.set(url, p)
    p.catch(() => cache.delete(url))
  }
  return p
}
