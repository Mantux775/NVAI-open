// Zeit im Studio: Ticks wie bei FilmCraft (254 016 000 000 je Sekunde), angezeigt als Zeitcode.

import { TPS, type StudioClip, type StudioProject } from '../api'
import { getLang } from '../i18n'

export const sec = (ticks: number) => ticks / TPS
/** Dezimalzeichen der Oberflächensprache: 7,5 auf Deutsch, 7.5 auf Englisch. */
export const decimal = (text: string) => (getLang() === 'de' ? text.replace('.', ',') : text)
export const ticks = (seconds: number) => Math.round(seconds * TPS)
export const clipEnd = (c: StudioClip) => c.start + (c.out - c.in)

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

/** Der Clip derselben Spur, der genau dort endet, wo dieser beginnt (für Überblendungen). */
export function previousClip(p: StudioProject, c: StudioClip): StudioClip | undefined {
  const tol = TPS / 1000
  return p.clips.find((o) => o.track === c.track && o.id !== c.id && Math.abs(clipEnd(o) - c.start) < tol)
}
