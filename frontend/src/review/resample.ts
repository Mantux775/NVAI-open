// Bandbegrenzte Umrechnung einer Spur auf die Video-Zeitachse (48 kHz) über die Zuordnung video_t = a·t + b, für die
// Video-Exporte der Prüf-App. Kaiser-gefensterter Sinc (β = 8, 32 Stützstellen beim Hochrechnen, beim Herunterrechnen
// entsprechend breiter), 256 Phasen mit linearer Zwischenstufe. NVAI-open rechnet dasselbe mit resample_poly und
// linearer Zwischenstufe; die Zeitlage ist gleich, die Höhen bleiben hier etwas sauberer.

function bessel0(x: number): number {
  let s = 1
  let t = 1
  for (let k = 1; k < 60; k++) {
    t *= (x / (2 * k)) ** 2
    s += t
    if (t < 1e-14 * s) break
  }
  return s
}

const PH = 256

export class Sinc {
  readonly half: number
  readonly taps: number
  private tab: Float32Array

  /** ratio = Ausgaberate / Eingaberate (unter 1: herunterrechnen, Grenzfrequenz entsprechend tiefer) */
  constructor(ratio: number) {
    const r = Math.min(1, ratio)
    const fc = 0.5 * r * 0.92
    const half = Math.ceil(16 / r)
    const taps = 2 * half
    const beta = 8
    const i0b = bessel0(beta)
    const tab = new Float32Array((PH + 1) * taps)
    for (let ph = 0; ph <= PH; ph++) {
      const frac = ph / PH
      let sum = 0
      for (let k = 0; k < taps; k++) {
        const d = frac + half - 1 - k
        const u = d / half
        const w = Math.abs(u) >= 1 ? 0 : bessel0(beta * Math.sqrt(1 - u * u)) / i0b
        const x = 2 * fc * d
        const c = (x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x)) * w
        tab[ph * taps + k] = c
        sum += c
      }
      for (let k = 0; k < taps; k++) tab[ph * taps + k] /= sum
    }
    this.half = half
    this.taps = taps
    this.tab = tab
  }

  /** out[n] += gain · x(p0 + n·step) für n < count; x(p) = bandbegrenzt zwischen den Proben, außerhalb von x null. */
  render(out: Float32Array, count: number, x: Float32Array, p0: number, step: number, gain: number): void {
    const { half, taps, tab } = this
    const len = x.length
    for (let n = 0; n < count; n++) {
      const p = p0 + n * step
      const i = Math.floor(p)
      const f = (p - i) * PH
      const ph = f | 0
      const g = f - ph
      const b0 = ph * taps
      const b1 = b0 + taps
      const j0 = i - half + 1
      let acc = 0
      if (j0 >= 0 && j0 + taps <= len) {
        for (let k = 0; k < taps; k++) {
          const c0 = tab[b0 + k]
          acc += x[j0 + k] * (c0 + (tab[b1 + k] - c0) * g)
        }
      } else {
        for (let k = 0; k < taps; k++) {
          const j = j0 + k
          if (j < 0 || j >= len) continue
          const c0 = tab[b0 + k]
          acc += x[j] * (c0 + (tab[b1 + k] - c0) * g)
        }
      }
      out[n] += acc * gain
    }
  }
}
