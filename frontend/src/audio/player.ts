// Mehrere Spuren synchron abspielen: je Spur ein <audio> mit der Opus-Vorschau (WebM, springt schnell, auch bei Stunden),
// über Web Audio mit eigener Lautstärke (auch über 0 dB). Die Uhr ist die des AudioContext. Spuren mit Versatz (Vorschau
// eines Ausschnitts) setzen erst an ihrer Stelle ein. Ton-Forensik: Abspieltempo ohne Tonhöhenänderung (0,5–1,5) und
// Verteilung links/rechts je Spur.
//
// Springen (17.11.2026, Nutzer: „wenn ich zu schnell in der timeline jumpe, dann gibt es auf einmal kein ton mehr bis ich
// längere pause mache“): Früher lief die Uhr während eines Sprungs weiter, und jede Spur, die mehr als 80 ms zurücklag,
// wurde alle 250 ms neu angesprungen. Dauerte ein Sprung länger (lange Dateien, viele Spuren, beschäftigter Server),
// sprang sie endlos und blieb stumm. Jetzt
// - wartet die Uhr nach einem Sprung, bis die hörbaren Spuren bereit sind (höchstens WAIT_MAX_MS), dann starten alle,
// - werden kleine Abweichungen (bis SEEK_DRIFT) über das Tempo der Spur ausgeglichen (höchstens ±NUDGE_MAX, Tonhöhe
//   bleibt); erst darüber wird neu angesprungen, höchstens alle RESEEK_MS je Spur und nie, solange sie noch springt,
// - spielen stumme Spuren nicht mit (weniger Last); beim Einschalten setzen sie an der richtigen Stelle ein,
// - wird ein vom System angehaltener AudioContext wieder fortgesetzt.

export interface PlayTrack { id: string; url: string; offset: number; gain: number; audible: boolean; pan?: number }

interface Voice {
  el: HTMLAudioElement
  node: MediaElementAudioSourceNode
  gain: GainNode
  pan: StereoPannerNode
  offset: number
  url: string
  audible: boolean
  /** performance.now() des letzten Anspringens */
  lastSeek: number
}

const READY = 3            // HTMLMediaElement.HAVE_FUTURE_DATA
const WAIT_MAX_MS = 2000   // so lange wartet die Uhr nach einem Sprung höchstens auf die Spuren
const SEEK_DRIFT = 0.5     // s; darüber wird eine Spur neu angesprungen, darunter über das Tempo nachgezogen
const DRIFT_OK = 0.03      // s; so genau genügt
const NUDGE_MAX = 0.05     // höchstens 5 % schneller oder langsamer zum Nachziehen
const RESEEK_MS = 2000     // eine Spur höchstens so oft neu anspringen
const TICK_MS = 100

export class MultiPlayer {
  private ctx: AudioContext | null = null
  private voices = new Map<string, Voice>()
  private startCtx = 0
  private startPos = 0
  private timer: number | null = null
  /** > 0: Die Uhr steht seit diesem Zeitpunkt (performance.now), bis die Spuren nach einem Sprung bereit sind */
  private waitingSince = 0
  playing = false
  loop: [number, number] | null = null
  onEnd: (() => void) | null = null
  duration = 0
  rate = 1

  private context(): AudioContext {
    if (!this.ctx) this.ctx = new AudioContext()
    return this.ctx
  }

  setTracks(tracks: PlayTrack[]): void {
    const ids = new Set(tracks.map((t) => t.id))
    for (const [id, v] of this.voices) {
      if (!ids.has(id)) {
        v.el.pause()
        v.el.removeAttribute('src')
        v.node.disconnect()
        v.gain.disconnect()
        v.pan.disconnect()
        this.voices.delete(id)
      }
    }
    for (const tr of tracks) {
      let v = this.voices.get(tr.id)
      let fresh = false
      if (v && v.url !== tr.url) {
        v.el.src = tr.url
        v.url = tr.url
        fresh = true
      }
      if (!v) {
        const ctx = this.context()
        const el = new Audio()
        el.preload = 'auto'
        el.src = tr.url
        el.preservesPitch = true
        el.playbackRate = this.rate
        const node = ctx.createMediaElementSource(el)
        const gain = ctx.createGain()
        const pan = ctx.createStereoPanner()
        node.connect(gain).connect(pan).connect(ctx.destination)
        v = { el, node, gain, pan, offset: tr.offset, url: tr.url, audible: tr.audible, lastSeek: 0 }
        this.voices.set(tr.id, v)
        fresh = true
      }
      const was = v.audible
      v.offset = tr.offset
      v.audible = tr.audible
      v.gain.gain.value = tr.audible ? tr.gain : 0
      v.pan.pan.value = Math.max(-1, Math.min(1, tr.pan ?? 0))
      if (!v.audible) {
        if (!v.el.paused) v.el.pause()
      } else if (this.playing && !this.waitingSince && (fresh || !was)) {
        this.place(v, this.position(), true)   // eben hörbar geworden: an der richtigen Stelle einsetzen
      }
    }
  }

  /** Abspieltempo (Tonhöhe bleibt) */
  setRate(rate: number): void {
    const r = Math.max(0.25, Math.min(2, rate))
    if (this.playing && this.ctx && !this.waitingSince) {
      this.startPos = this.position()
      this.startCtx = this.ctx.currentTime
    }
    this.rate = r
    for (const v of this.voices.values()) {
      v.el.preservesPitch = true
      v.el.playbackRate = r
    }
  }

  position(): number {
    if (!this.playing || !this.ctx || this.waitingSince) return this.startPos
    return this.startPos + (this.ctx.currentTime - this.startCtx) * this.rate
  }

  async play(from: number): Promise<void> {
    const ctx = this.context()
    if (ctx.state !== 'running') await ctx.resume().catch(() => {})
    this.startPos = Math.max(0, from)
    this.playing = true
    this.waitingSince = performance.now()
    for (const v of this.voices.values()) {
      v.el.pause()
      if (v.audible) this.seekVoice(v, this.startPos)
    }
    if (this.timer) window.clearInterval(this.timer)
    this.timer = window.setInterval(() => this.tick(), TICK_MS)
    this.tick()
  }

  pause(): void {
    this.startPos = this.position()
    this.playing = false
    this.waitingSince = 0
    for (const v of this.voices.values()) v.el.pause()
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }

  seek(pos: number): void {
    if (this.playing) void this.play(pos)
    else this.startPos = Math.max(0, pos)
  }

  /** Zustand je Spur zum Nachsehen (Fehlersuche): pausiert, springt, bereit, Abweichung zur Uhr */
  debugState(): Record<string, { paused: boolean; seeking: boolean; ready: number; drift: number; rate: number; audible: boolean }> {
    const pos = this.position()
    const out: Record<string, { paused: boolean; seeking: boolean; ready: number; drift: number; rate: number; audible: boolean }> = {}
    for (const [id, v] of this.voices) {
      out[id] = { paused: v.el.paused, seeking: v.el.seeking, ready: v.el.readyState, drift: +(v.el.currentTime - (pos - v.offset)).toFixed(3),
        rate: +v.el.playbackRate.toFixed(3), audible: v.audible }
    }
    return out
  }

  private inRange(v: Voice, pos: number): boolean {
    const local = pos - v.offset
    const len = Number.isFinite(v.el.duration) ? v.el.duration : Infinity
    return local >= 0 && local < len
  }

  private seekVoice(v: Voice, pos: number): void {
    if (!this.inRange(v, pos)) return
    v.el.playbackRate = this.rate
    v.el.currentTime = pos - v.offset
    v.lastSeek = performance.now()
  }

  private place(v: Voice, pos: number, force: boolean): void {
    if (!v.audible || !this.inRange(v, pos)) {
      if (!v.el.paused) v.el.pause()
      return
    }
    if (force) {
      this.seekVoice(v, pos)
      void v.el.play().catch(() => {})
      return
    }
    if (v.el.seeking) return                       // springt noch: nicht nachsetzen
    const local = pos - v.offset
    if (v.el.paused) {                             // eben in den Bereich gekommen oder vom Browser angehalten
      if (Math.abs(v.el.currentTime - local) > SEEK_DRIFT) this.seekVoice(v, pos)
      void v.el.play().catch(() => {})
      return
    }
    if (v.el.readyState < READY) return            // puffert: abwarten statt springen
    const drift = v.el.currentTime - local         // > 0: Spur ist voraus
    if (Math.abs(drift) > SEEK_DRIFT) {
      if (performance.now() - v.lastSeek > RESEEK_MS) this.seekVoice(v, pos)
      return
    }
    const nudge = Math.abs(drift) <= DRIFT_OK ? 0 : Math.max(-NUDGE_MAX, Math.min(NUDGE_MAX, -drift))
    const want = this.rate * (1 + nudge)
    if (Math.abs(v.el.playbackRate - want) > 1e-3) v.el.playbackRate = want
  }

  private tick(): void {
    const ctx = this.ctx
    if (!ctx || !this.playing) return
    if (ctx.state === 'suspended') void ctx.resume().catch(() => {})
    if (this.waitingSince) {
      const waitFor = [...this.voices.values()].filter((v) => v.audible && this.inRange(v, this.startPos))
      const ready = waitFor.every((v) => !v.el.seeking && v.el.readyState >= READY)
      if (!ready && performance.now() - this.waitingSince < WAIT_MAX_MS) return
      this.waitingSince = 0
      this.startCtx = ctx.currentTime
      for (const v of waitFor) {
        v.el.playbackRate = this.rate
        void v.el.play().catch(() => {})
      }
      return
    }
    const pos = this.position()
    if (this.loop && pos >= this.loop[1]) {
      void this.play(this.loop[0])
      return
    }
    if (this.duration && pos >= this.duration) {
      this.pause()
      this.startPos = 0
      this.onEnd?.()
      return
    }
    for (const v of this.voices.values()) this.place(v, pos, false)
  }

  dispose(): void {
    this.pause()
    for (const v of this.voices.values()) {
      v.el.removeAttribute('src')
      v.node.disconnect()
    }
    this.voices.clear()
    void this.ctx?.close()
    this.ctx = null
  }
}
