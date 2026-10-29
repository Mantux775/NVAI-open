// Zeit im Studio: Ticks wie bei FilmCraft (254 016 000 000 je Sekunde), angezeigt als Zeitcode.

import { TPS, type StudioClip, type StudioProject } from '../api'
import { getLang } from '../i18n'

export const sec = (ticks: number) => ticks / TPS
/** Dezimalzeichen der Oberflächensprache: 7,5 auf Deutsch, 7.5 auf Englisch. */
export const decimal = (text: string) => (getLang() === 'de' ? text.replace('.', ',') : text)
export const ticks = (seconds: number) => Math.round(seconds * TPS)
/** Geschwindigkeit eines Clips (1 = 100 %); ältere Projekte kennen das Feld nicht. */
export const clipSpeed = (c: StudioClip) => c.speed ?? 1
/** Länge auf der Zeitleiste: Material (Out − In) durch die Geschwindigkeit, wie studio.clip_length. */
export const clipLength = (c: StudioClip) => Math.round((c.out - c.in) / clipSpeed(c))
export const clipEnd = (c: StudioClip) => c.start + clipLength(c)
/** Medienzeit (Ticks), die `offset` Ticks nach dem Clipanfang läuft. */
export const mediaAt = (c: StudioClip, offset: number) => c.in + Math.round(offset * clipSpeed(c))

/** Grenzen des Skalierens wie studio.SCALE_MIN/SCALE_MAX (10 bis 800 %). */
export const SCALE_MIN = 0.1
export const SCALE_MAX = 8

/** Skalierung zur Medienzeit `media` (Ticks): linear zwischen den Keyframes, davor und danach der erste bzw. letzte
 * Wert, ohne Keyframes `scale` (wie studio.clip_scale_at und studio_render.scale_of). */
export function clipScaleAt(c: StudioClip, media: number): number {
  const keys = c.scale_keys ?? []
  if (!keys.length) return c.scale ?? 1
  if (media <= keys[0].at) return keys[0].value
  for (let i = 1; i < keys.length; i++) {
    const a = keys[i - 1]
    const b = keys[i]
    if (media <= b.at) return a.value + ((b.value - a.value) * (media - a.at)) / Math.max(1, b.at - a.at)
  }
  return keys[keys.length - 1].value
}

/** Position eines Keyframes auf der Zeitleiste (Ticks), aus seiner Medienzeit. */
export const keyTime = (c: StudioClip, media: number) => c.start + Math.round((media - c.in) / clipSpeed(c))

/** Ein Bild in Ticks bei der Bildrate des Projekts. */
export const frameTicks = (p: StudioProject) => Math.round((TPS * p.settings.fps[1]) / p.settings.fps[0])

/** Auf das nächste ganze Bild runden. */
export function snapFrame(p: StudioProject, t: number): number {
  const f = frameTicks(p)
  return Math.max(0, Math.round(t / f) * f)
}

/** HH:MM:SS:FF bei der Bildrate des Projekts. */
export function timecode(t: number, fps: [number, number]): string {
  const rate = fps[0] / fps[1]
  const frames = Math.floor(sec(t) * rate + 1e-6)
  const perSecond = Math.round(rate)
  const f = frames % perSecond
  const s = Math.floor(frames / perSecond)
  const two = (n: number) => String(n).padStart(2, '0')
  return `${two(Math.floor(s / 3600))}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}:${two(f)}`
}

/** Kurz für Beschriftungen: 0:07,5 */
export function shortTime(t: number): string {
  const s = sec(t)
  const m = Math.floor(s / 60)
  const rest = s - m * 60
  return `${m}:${decimal(rest.toFixed(1).padStart(4, '0'))}`
}

/** Der Clip, der auf einer Spur zur Zeit t läuft. */
export function clipAt(p: StudioProject, track: string, t: number): StudioClip | undefined {
  return p.clips.find((c) => c.track === track && c.start <= t && t < clipEnd(c))
}

/** Der Clip derselben Spur, der genau dort endet, wo dieser beginnt (für Übergänge). */
export function previousClip(p: StudioProject, c: StudioClip): StudioClip | undefined {
  const tol = TPS / 1000
  return p.clips.find((o) => o.track === c.track && o.id !== c.id && Math.abs(clipEnd(o) - c.start) < tol)
}

/** Spuren einer Art in Anzeigereihenfolge (Video von oben: V3, V2, V1; Ton: A1, A2 …). */
export const tracksOf = (p: StudioProject, kind: 'video' | 'audio') => p.tracks.filter((tr) => tr.kind === kind)
export const trackKind = (p: StudioProject, id: string) => p.tracks.find((tr) => tr.id === id)?.kind
/** Die gewünschte Spur, sonst die mit der höchsten Nummer dieser Art (wie studio._track_or_highest). */
export function trackOrHighest(p: StudioProject, wanted: string, kind: 'video' | 'audio'): string {
  const ids = tracksOf(p, kind).map((tr) => tr.id)
  if (ids.includes(wanted)) return wanted
  return ids.reduce((a, b) => (Number(b.slice(1)) > Number(a.slice(1)) ? b : a), ids[0])
}
