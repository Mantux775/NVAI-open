// Die zwei Zeitleisten des Studios: oben die Komposition (Szenen mit Prompts auf vier Bahnen, darüber die Marker),
// unten der Schnitt (Spuren V3, V2, V1 … und A1, A2 …). Ein Lineal und ein Abspielkopf für beide.
//
// Werkzeuge wie bei FilmCraft (Nutzer 27.10.2026): links oben im freien Feld Auswahl (V), Schneiden (C) und der
// Magnet (S). Mit der Auswahl verschiebt Ziehen, Kanten ändern Länge bzw. Trimmen, Ziehen im Leeren zieht einen Rahmen
// auf (mehrere Objekte), Umschalt- oder Strg-Klick nimmt dazu oder heraus; eine Gruppe wandert zusammen. Eingerastet
// (an Kanten, Markern, Abspielkopf) wird mit eingeschaltetem Magnet oder bei gedrückter Umschalttaste, sonst nur aufs
// ganze Bild. Mit Schneiden teilt ein Klick den Clip, mit Umschalt alle Spuren. Rechtsklick meldet, was getroffen
// wurde (onMenu); das Menü baut das Studio. Jede Änderung geht als Befehl an den Server (onCommand), angezeigt wird
// während des Ziehens nur eine Vorschau.

import { useEffect, useRef, useState, type DragEvent, type MouseEvent as RMouseEvent, type PointerEvent as RPointerEvent, type ReactNode } from 'react'
import { TPS, type StudioClip, type StudioLane, type StudioMarker, type StudioProject, type StudioScene, type StudioTrack } from '../api'
import { t } from '../i18n'
import { clipEnd, clipLength, clipSpeed, decimal, frameTicks, keyTime, sec, shortTime, snapFrame, tracksOf } from './time'

export type SelType = 'scene' | 'clip' | 'marker' | 'asset' | 'transition'
/** Auswahl; `ids` bei mehreren Objekten derselben Art (enthält `id`). Ein Übergang hat die ID seines Clips. */
export type Selection = { type: SelType; id: string; ids?: string[] } | null
export const selIds = (s: Selection, type: SelType): string[] => (s && s.type === type ? s.ids ?? [s.id] : [])
export const ASSET_MIME = 'application/x-nvai-asset'
export type Tool = 'select' | 'razor' | 'scale'

/** Was ein Rechtsklick getroffen hat; `at` ist die Zeit an der Maus (auf ganze Bilder). */
export type MenuTarget =
  | { kind: 'clip'; id: string; at: number }
  | { kind: 'scene'; id: string; at: number }
  | { kind: 'marker'; id: string; at: number }
  | { kind: 'transition'; id: string; at: number }
  | { kind: 'track-head'; track: string; at: number }
  | { kind: 'track'; track: string; at: number }
  | { kind: 'lane'; lane: StudioLane; at: number }
  | { kind: 'markers'; at: number }

interface Props {
  project: StudioProject
  playhead: number
  zoom: number
  selection: Selection
  tool: Tool
  magnet: boolean
  onTool: (tool: Tool) => void
  onMagnet: (on: boolean) => void
  onSelect: (s: Selection) => void
  onPlayhead: (t: number) => void
  onCommand: (command: string, params: Record<string, unknown>) => Promise<any>
  onZoom: (z: number) => void
  onMenu: (e: { clientX: number; clientY: number }, target: MenuTarget) => void
}

const LANES: { id: StudioLane; label: string; height: number }[] = [
  { id: 'video', label: t('Bild/Video', 'Picture'), height: 46 },
  { id: 'voice', label: t('Sprecher', 'Voice'), height: 30 },
  { id: 'music', label: t('Musik', 'Music'), height: 30 },
  { id: 'sfx', label: t('Klang', 'Sound'), height: 30 },
]
const trackHeight = (tr: StudioTrack) => (tr.kind === 'audio' ? 32 : tr.id === 'V1' ? 52 : 40)
const HEAD = 92
const SNAP_PX = 9 // wie FilmCraft

export const TRANSITION_LABEL: Record<string, string> = {
  dissolve: t('Überblendung', 'Cross dissolve'),
  dip_black: t('Über Schwarz', 'Dip to black'),
  dip_white: t('Über Weiß', 'Dip to white'),
  wipe: t('Wischblende', 'Wipe'),
}

type DragKind = 'scene-move' | 'scene-end' | 'clip-move' | 'clip-start' | 'clip-end' | 'marker' | 'playhead' | 'marquee' | 'transition-end'
interface Drag {
  kind: DragKind
  id: string
  /** wandern zusammen (Gruppe) */
  ids: string[]
  x0: number
  y0: number
  delta: number // Ticks, schon eingerastet und begrenzt
  shift: number // Spurversatz beim Verschieben von Clips
  moved: boolean
  snapAt: number | null
  area?: 'edit' | 'lanes' | 'markers'
  additive?: boolean
  x1?: number
  y1?: number
}

// Kleine Symbole, in der Schriftfarbe gezeichnet
const ICON = {
  select: <path d="M4 2v11l3-3 2.3 4.4 1.6-.8L8.6 9.3H13z" fill="currentColor" stroke="none" />,
  razor: (
    <>
      <circle cx="4.5" cy="12" r="2.1" />
      <circle cx="11.5" cy="12" r="2.1" />
      <path d="M6 10.4 12.2 2.2M10 10.4 3.8 2.2" />
    </>
  ),
  magnet: (
    <>
      <path d="M4 2.5v5.6a4 4 0 0 0 8 0V2.5" strokeWidth="2.6" />
      <path d="M2.6 5.2h2.8M10.6 5.2h2.8" strokeWidth="1.2" />
    </>
  ),
  // Skalieren: kleiner Rahmen in einem großen, Pfeil nach außen
  scale: (
    <>
      <rect x="1.8" y="1.8" width="12.4" height="12.4" rx="1.2" />
      <rect x="1.8" y="8.6" width="5.6" height="5.6" fill="currentColor" stroke="none" />
      <path d="M8.4 7.6 12.6 3.4M9.4 3.2h3.4v3.4" />
    </>
  ),
  eye: (
    <>
      <path d="M1.2 8S3.6 3.8 8 3.8 14.8 8 14.8 8 12.4 12.2 8 12.2 1.2 8 1.2 8z" />
      <circle cx="8" cy="8" r="1.9" />
    </>
  ),
  eyeOff: (
    <>
      <path d="M1.2 8S3.6 3.8 8 3.8 14.8 8 14.8 8 12.4 12.2 8 12.2 1.2 8 1.2 8z" opacity=".45" />
      <path d="M2.5 2.5l11 11" />
    </>
  ),
  sound: (
    <>
      <path d="M2 6h2.6L8 3.2v9.6L4.6 10H2z" fill="currentColor" stroke="none" />
      <path d="M10.4 5.6a3.2 3.2 0 0 1 0 4.8M12.2 3.9a5.6 5.6 0 0 1 0 8.2" />
    </>
  ),
  soundOff: (
    <>
      <path d="M2 6h2.6L8 3.2v9.6L4.6 10H2z" fill="currentColor" stroke="none" opacity=".45" />
      <path d="M10.2 6.2l3.6 3.6M13.8 6.2l-3.6 3.6" />
    </>
  ),
}
const Icon = ({ name }: { name: keyof typeof ICON }) => (
  <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
    {ICON[name]}
  </svg>
)

export function Timelines({ project, playhead, zoom, selection, tool, magnet, onTool, onMagnet, onSelect, onPlayhead, onCommand, onZoom, onMenu }: Props) {
  const scroll = useRef<HTMLDivElement>(null)
  const [drag, setDrag] = useState<Drag | null>(null)
  const [razorAt, setRazorAt] = useState<{ at: number; track: string; all: boolean } | null>(null)
  const p = project
  const frame = frameTicks(p)

  const longest = Math.max(p.edit_duration, p.composition_duration, playhead, ...p.markers.map((m) => m.at + m.duration))
  const width = Math.max((sec(longest) + 30) * zoom, 800)

  // Strg + Mausrad zoomt um die Mausposition; ohne Strg scrollt es wie gewohnt.
  useEffect(() => {
    const el = scroll.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey) return
      e.preventDefault()
      onZoom(Math.min(400, Math.max(4, zoom * (e.deltaY < 0 ? 1.25 : 0.8))))
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [zoom, onZoom])

  // Esc bricht das Ziehen ab (der alte Stand bleibt)
  useEffect(() => {
    if (!drag) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        setDrag(null)
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [drag])

  const timeAt = (clientX: number) => {
    const el = scroll.current!
    const x = clientX - el.getBoundingClientRect().left - HEAD + el.scrollLeft
    return Math.max(0, (x / zoom) * TPS)
  }

  // ---------------------------------------------------------------------------------- Einrasten

  /** Kanten aller Szenen und Clips, Marker, Abspielkopf und 0, ohne die gerade gezogenen Objekte. */
  const targets = (except: Set<string>) => {
    const points = [0, playhead]
    for (const s of p.scenes) if (!except.has(s.id)) points.push(s.start, s.start + s.duration)
    for (const c of p.clips) if (!except.has(c.id)) points.push(c.start, clipEnd(c))
    for (const m of p.markers) if (!except.has(m.id)) points.push(m.at)
    return points
  }
  /** Verschiebung, die eine der Kanten auf das nächste Ziel legt (innerhalb von SNAP_PX). */
  const snapShift = (edges: number[], except: Set<string>) => {
    const range = (SNAP_PX / zoom) * TPS
    let best: { shift: number; at: number } | null = null
    for (const q of targets(except)) {
      for (const edge of edges) {
        const d = q - edge
        if (Math.abs(d) <= range && (!best || Math.abs(d) < Math.abs(best.shift))) best = { shift: d, at: q }
      }
    }
    return best
  }
  /** Ein einzelner Zeitpunkt (Ablegen, Schneiden, Abspielkopf): eingerastet oder aufs ganze Bild. */
  const snapPoint = (tick: number, snapping: boolean, except: Set<string> = new Set()) => {
    if (snapping) {
      const s = snapShift([tick], except)
      if (s) return s.at
    }
    return snapFrame(p, tick)
  }

  // ---------------------------------------------------------------------------------- Auswählen

  /** Klick auf ein Objekt: allein auswählen, mit Umschalt/Strg dazunehmen oder herausnehmen. Gibt die Gruppe
   * zurück, die gezogen wird (null: nichts ziehen). */
  const pick = (e: RPointerEvent, type: SelType, id: string): string[] | null => {
    const current = selIds(selection, type)
    if (e.shiftKey || e.ctrlKey || e.metaKey) {
      const next = current.includes(id) ? current.filter((x) => x !== id) : [...current, id]
      onSelect(next.length ? { type, id: next.includes(id) ? id : next[next.length - 1], ids: next.length > 1 ? next : undefined } : null)
      return next.includes(id) ? next : null
    }
    if (current.includes(id) && current.length > 1) {
      onSelect({ type, id, ids: current })
      return current
    }
    onSelect({ type, id })
    return [id]
  }

  const menuAt = (e: RMouseEvent, target: MenuTarget, type?: SelType, id?: string) => {
    e.preventDefault()
    e.stopPropagation()
    if (type && id && !selIds(selection, type).includes(id)) onSelect({ type, id })
    onMenu(e, target)
  }

  // ---------------------------------------------------------------------------------- Ziehen

  const begin = (e: RPointerEvent, kind: DragKind, id: string, ids: string[] = [id], extra: Partial<Drag> = {}) => {
    if (e.button !== 0) return
    e.stopPropagation()
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    setDrag({ kind, id, ids, x0: e.clientX, y0: e.clientY, delta: 0, shift: 0, moved: false, snapAt: null, ...extra })
    if (kind === 'playhead') onPlayhead(snapPoint(timeAt(e.clientX), magnet || e.shiftKey))
  }

  const media = (c: StudioClip) => p.media[c.asset_id]
  const trackIndex = (id: string) => {
    const kind = p.tracks.find((tr) => tr.id === id)?.kind
    return kind ? tracksOf(p, kind).findIndex((tr) => tr.id === id) : -1
  }

  const move = (e: RPointerEvent) => {
    if (tool === 'razor' && !drag) {
      const el = document.elementsFromPoint(e.clientX, e.clientY).find((x) => (x as HTMLElement).dataset?.clipId) as HTMLElement | undefined
      const c = el ? p.clips.find((x) => x.id === el.dataset.clipId) : undefined
      setRazorAt(c ? { at: snapPoint(timeAt(e.clientX), magnet || e.shiftKey), track: c.track, all: e.shiftKey } : null)
      return
    }
    if (!drag) return
    const snapping = magnet || e.shiftKey
    const moved = drag.moved || Math.abs(e.clientX - drag.x0) > 3 || Math.abs(e.clientY - drag.y0) > 3
    if (drag.kind === 'playhead') {
      onPlayhead(snapPoint(timeAt(e.clientX), snapping))
      return
    }
    if (drag.kind === 'marquee') {
      setDrag({ ...drag, x1: e.clientX, y1: e.clientY, moved })
      return
    }
    let delta = ((e.clientX - drag.x0) / zoom) * TPS
    let snapAt: number | null = null
    const except = new Set(drag.ids)
    /** Einrasten an den Kanten (um delta verschoben), sonst aufs ganze Bild. */
    const settle = (edges: number[]) => {
      const s = snapping ? snapShift(edges.map((x) => x + delta), except) : null
      return s ? { delta: delta + s.shift, at: s.at as number | null } : { delta: Math.round(delta / frame) * frame, at: null }
    }
    let shift = 0
    if (drag.kind === 'clip-move') {
      const group = p.clips.filter((c) => drag.ids.includes(c.id))
      const g = group.find((c) => c.id === drag.id)!
      ;({ delta, at: snapAt } = settle([g.start, clipEnd(g)]))
      delta = Math.max(delta, -Math.min(...group.map((c) => c.start)))
      // Spurwechsel: gleicher Versatz für alle, nur innerhalb der eigenen Art und der vorhandenen Spuren
      const under = document.elementsFromPoint(e.clientX, e.clientY).find((el) => (el as HTMLElement).dataset?.track) as HTMLElement | undefined
      const target = under?.dataset.track
      const kind = p.tracks.find((tr) => tr.id === g.track)?.kind
      if (target && kind && p.tracks.find((tr) => tr.id === target)?.kind === kind && group.every((c) => p.tracks.find((tr) => tr.id === c.track)?.kind === kind)) {
        const n = tracksOf(p, kind).length
        shift = trackIndex(target) - trackIndex(g.track)
        for (const c of group) shift = Math.max(-trackIndex(c.track), Math.min(n - 1 - trackIndex(c.track), shift))
      }
    } else if (drag.kind === 'clip-start') {
      const c = p.clips.find((x) => x.id === drag.id)!
      ;({ delta, at: snapAt } = settle([c.start]))
      const earliest = c.start - Math.floor(c.in / clipSpeed(c)) // nicht vor den Anfang des Materials
      delta = Math.max(earliest - c.start, Math.min(delta, clipLength(c) - frame))
    } else if (drag.kind === 'clip-end') {
      const c = p.clips.find((x) => x.id === drag.id)!
      ;({ delta, at: snapAt } = settle([clipEnd(c)]))
      const m = media(c)
      const most = m?.kind !== 'image' && m?.duration ? Math.floor((m.duration - c.out) / clipSpeed(c)) : Infinity
      delta = Math.max(frame - clipLength(c), Math.min(delta, most))
    } else if (drag.kind === 'scene-move') {
      const group = p.scenes.filter((s) => drag.ids.includes(s.id))
      const g = group.find((s) => s.id === drag.id)!
      ;({ delta, at: snapAt } = settle([g.start, g.start + g.duration]))
      delta = Math.max(delta, -Math.min(...group.map((s) => s.start)))
    } else if (drag.kind === 'scene-end') {
      const s = p.scenes.find((x) => x.id === drag.id)!
      ;({ delta, at: snapAt } = settle([s.start + s.duration]))
      delta = Math.max(delta, TPS / 4 - s.duration)
    } else if (drag.kind === 'marker') {
      const group = p.markers.filter((m) => drag.ids.includes(m.id))
      const g = group.find((m) => m.id === drag.id)!
      ;({ delta, at: snapAt } = settle([g.at]))
      delta = Math.max(delta, -Math.min(...group.map((m) => m.at)))
    } else if (drag.kind === 'transition-end') {
      const c = p.clips.find((x) => x.id === drag.id)!
      delta = Math.round(delta / frame) * frame
      delta = Math.max(frame - (c.transition?.duration ?? 0), Math.min(delta, clipLength(c) - (c.transition?.duration ?? 0)))
    }
    setDrag({ ...drag, delta, shift, moved, snapAt })
  }

  const end = async () => {
    const d = drag
    setDrag(null)
    if (!d || d.kind === 'playhead') return
    if (d.kind === 'marquee') {
      finishMarquee(d)
      return
    }
    if (!d.moved || (d.delta === 0 && d.shift === 0)) return
    const many = (command: string, items: Record<string, unknown>[]) =>
      items.length === 1 ? onCommand(command, items[0]) : onCommand('batch', { commands: items.map((params) => ({ command, params })) })
    if (d.kind === 'clip-move') {
      const moves = p.clips.filter((c) => d.ids.includes(c.id)).map((c) => {
        const kind = p.tracks.find((tr) => tr.id === c.track)!.kind
        const track = d.shift ? tracksOf(p, kind)[trackIndex(c.track) + d.shift]?.id ?? c.track : c.track
        return { id: c.id, start: c.start + d.delta, track }
      })
      await onCommand('clip.move', { moves })
    } else if (d.kind === 'clip-start') {
      const c = p.clips.find((x) => x.id === d.id)!
      await onCommand('clip.trim', { id: c.id, edge: 'start', to: c.start + d.delta })
    } else if (d.kind === 'clip-end') {
      const c = p.clips.find((x) => x.id === d.id)!
      await onCommand('clip.trim', { id: c.id, edge: 'end', to: clipEnd(c) + d.delta })
    } else if (d.kind === 'scene-move') {
      await many('scene.update', p.scenes.filter((s) => d.ids.includes(s.id)).map((s) => ({ id: s.id, start: s.start + d.delta })))
    } else if (d.kind === 'scene-end') {
      const s = p.scenes.find((x) => x.id === d.id)!
      await onCommand('scene.update', { id: s.id, duration: Math.max(s.duration + d.delta, TPS / 4) })
    } else if (d.kind === 'marker') {
      await many('marker.update', p.markers.filter((m) => d.ids.includes(m.id)).map((m) => ({ id: m.id, at: m.at + d.delta })))
    } else if (d.kind === 'transition-end') {
      const c = p.clips.find((x) => x.id === d.id)!
      if (c.transition) await onCommand('clip.update', { id: c.id, transition: { kind: c.transition.kind, duration: c.transition.duration + d.delta } })
    }
  }

  // ------------------------------------------------------------------------------- Rahmen aufziehen

  const startMarquee = (e: RPointerEvent, area: 'edit' | 'lanes' | 'markers') => {
    if (e.target !== e.currentTarget || e.button !== 0 || tool !== 'select') return
    begin(e, 'marquee', '', [], { area, additive: e.shiftKey || e.ctrlKey || e.metaKey, x1: e.clientX, y1: e.clientY })
  }

  const finishMarquee = (d: Drag) => {
    if (!d.moved) {
      if (!d.additive) onSelect(null) // Klick ins Leere hebt die Auswahl auf
      return
    }
    const box = { l: Math.min(d.x0, d.x1!), r: Math.max(d.x0, d.x1!), t: Math.min(d.y0, d.y1!), b: Math.max(d.y0, d.y1!) }
    const [type, attr]: [SelType, string] = d.area === 'edit' ? ['clip', 'clipId'] : d.area === 'lanes' ? ['scene', 'sceneId'] : ['marker', 'markerId']
    const hits: string[] = []
    scroll.current?.querySelectorAll<HTMLElement>(`[data-${attr.replace(/[A-Z]/g, (x) => '-' + x.toLowerCase())}]`).forEach((el) => {
      const r = el.getBoundingClientRect()
      if (r.left < box.r && r.right > box.l && r.top < box.b && r.bottom > box.t) hits.push(el.dataset[attr]!)
    })
    const ids = d.additive ? [...new Set([...selIds(selection, type), ...hits])] : hits
    onSelect(ids.length ? { type, id: ids[0], ids: ids.length > 1 ? ids : undefined } : d.additive ? selection : null)
  }

  // ------------------------------------------------------------------------------ Vorschau beim Ziehen

  const moving = (kind: DragKind, id: string) => drag?.kind === kind && drag.ids.includes(id)
  const sceneBox = (s: StudioScene) => {
    let start = s.start
    let duration = s.duration
    if (moving('scene-move', s.id)) start = s.start + drag!.delta
    if (drag?.id === s.id && drag.kind === 'scene-end') duration = s.duration + drag.delta
    return { left: sec(start) * zoom, width: Math.max(4, sec(duration) * zoom) }
  }
  const clipStart = (c: StudioClip) => {
    if (moving('clip-move', c.id)) return c.start + drag!.delta
    if (drag?.id === c.id && drag.kind === 'clip-start') return c.start + drag.delta
    return c.start
  }
  const clipBox = (c: StudioClip) => {
    let length = clipLength(c)
    if (drag?.id === c.id && drag.kind === 'clip-start') length -= drag.delta
    if (drag?.id === c.id && drag.kind === 'clip-end') length += drag.delta
    return { left: sec(clipStart(c)) * zoom, width: Math.max(3, sec(length) * zoom) }
  }
  const shownTrack = (c: StudioClip) => {
    if (!moving('clip-move', c.id) || !drag!.shift) return c.track
    const kind = p.tracks.find((tr) => tr.id === c.track)!.kind
    return tracksOf(p, kind)[trackIndex(c.track) + drag!.shift]?.id ?? c.track
  }

  // ------------------------------------------------------------------------- Ablegen aus der Medienleiste

  const acceptAsset = (e: DragEvent) => {
    if (e.dataTransfer.types.includes(ASSET_MIME)) {
      e.preventDefault()
      e.dataTransfer.dropEffect = 'copy'
    }
  }
  const dropOnTrack = async (e: DragEvent, track: string) => {
    const raw = e.dataTransfer.getData(ASSET_MIME)
    if (!raw) return
    e.preventDefault()
    const { id } = JSON.parse(raw)
    const r = await onCommand('clip.add', { track, asset_id: id, start: snapPoint(timeAt(e.clientX), magnet || e.shiftKey) })
    if (r?.id) onSelect({ type: 'clip', id: r.id })
  }
  const dropOnScene = async (e: DragEvent, scene: StudioScene) => {
    const raw = e.dataTransfer.getData(ASSET_MIME)
    if (!raw) return
    e.preventDefault()
    e.stopPropagation()
    await onCommand('scene.take', { id: scene.id, asset_id: JSON.parse(raw).id })
    onSelect({ type: 'scene', id: scene.id })
  }

  const addScene = async (e: RMouseEvent, lane: StudioLane) => {
    if (e.target !== e.currentTarget) return
    const r = await onCommand('scene.add', { lane, start: snapPoint(timeAt(e.clientX), magnet || e.shiftKey), duration_s: lane === 'video' ? 5 : 10 })
    if (r?.id) onSelect({ type: 'scene', id: r.id })
  }
  const addMarker = async (e: RMouseEvent) => {
    if (e.target !== e.currentTarget) return
    const r = await onCommand('marker.add', { at: snapPoint(timeAt(e.clientX), magnet || e.shiftKey), kind: 'note' })
    if (r?.id) onSelect({ type: 'marker', id: r.id })
  }

  // ---------------------------------------------------------------------------------- Zeichnen

  const thumb = (assetId: string | null | undefined) => {
    if (!assetId) return null
    const a = p.assets[assetId]
    if (!a) return null
    if (a.kind === 'image') return <img className="st-thumb" src={a.url} alt="" draggable={false} />
    if (a.kind === 'video') return <video className="st-thumb" src={`${a.preview ?? a.url}#t=0.1`} preload="metadata" muted />
    return <span className="st-wave">∿∿∿</span>
  }

  const isSel = (type: SelType, id: string) => selIds(selection, type).includes(id)

  const ruler = () => {
    const step = zoom >= 120 ? 1 : zoom >= 40 ? 5 : zoom >= 12 ? 10 : 30
    const marks = []
    for (let s = 0; s * zoom < width; s += step) {
      marks.push(
        <span key={s} className="st-tick" style={{ left: s * zoom }}>
          {shortTime(s * TPS)}
        </span>,
      )
    }
    return marks
  }

  const sceneEl = (s: StudioScene) => (
    <div
      key={s.id}
      data-scene-id={s.id}
      className={`st-scene st-s-${s.status}${isSel('scene', s.id) ? ' st-sel' : ''}`}
      style={sceneBox(s)}
      title={s.error ?? s.prompt}
      onPointerDown={(e) => {
        if (e.button !== 0) return
        const group = pick(e, 'scene', s.id)
        if (group) begin(e, 'scene-move', s.id, group)
        else e.stopPropagation()
      }}
      onContextMenu={(e) => menuAt(e, { kind: 'scene', id: s.id, at: snapFrame(p, timeAt(e.clientX)) }, 'scene', s.id)}
      onDragOver={acceptAsset}
      onDrop={(e) => dropOnScene(e, s)}
    >
      {s.lane === 'video' && thumb(s.take)}
      <span className="st-label">
        <b>{s.title || t('Szene', 'Scene')}</b> {s.prompt}
      </span>
      {s.chain_from && <span className="st-chain" title={t('Startbild = letztes Bild der vorigen Szene', 'Start image = last frame of the previous scene')}>⛓</span>}
      <span className="st-edge" onPointerDown={(e) => begin(e, 'scene-end', s.id)} />
    </div>
  )

  const clipEl = (c: StudioClip, track: StudioTrack) => {
    const box = clipBox(c)
    const scene = c.scene_id ? p.scenes.find((s) => s.id === c.scene_id) : undefined
    const label = scene?.title || p.assets[c.asset_id]?.prompt || c.asset_id
    const speed = clipSpeed(c)
    const off = c.muted || (track.kind === 'audio' && track.muted) || (track.kind === 'video' && track.hidden)
    return (
      <div
        key={c.id}
        data-clip-id={c.id}
        className={`st-clip st-${p.media[c.asset_id]?.kind ?? 'video'}${isSel('clip', c.id) ? ' st-sel' : ''}${off ? ' st-muted' : ''}${c.missing ? ' st-missing' : ''}${tool === 'razor' ? ' st-razor' : ''}`}
        style={box}
        title={c.missing ? t('Datei gelöscht: Clip löschen oder ersetzen', 'File deleted: delete or replace the clip') : label}
        onPointerDown={(e) => {
          if (e.button !== 0) return
          if (tool === 'razor') {
            e.stopPropagation()
            const at = snapPoint(timeAt(e.clientX), magnet || e.shiftKey)
            onCommand('clip.razor', e.shiftKey ? { at } : { at, track: c.track })
            return
          }
          if (tool === 'scale') {
            // Skalieren: Clip wählen und den Abspielkopf an die Stelle setzen, dann im Monitor ziehen
            e.stopPropagation()
            onSelect({ type: 'clip', id: c.id })
            onPlayhead(snapFrame(p, timeAt(e.clientX)))
            return
          }
          const group = pick(e, 'clip', c.id)
          if (group) begin(e, 'clip-move', c.id, group)
          else e.stopPropagation()
        }}
        onContextMenu={(e) => menuAt(e, { kind: 'clip', id: c.id, at: snapFrame(p, timeAt(e.clientX)) }, 'clip', c.id)}
      >
        {track.kind === 'video' && thumb(c.asset_id)}
        <span className="st-label">{label}</span>
        {track.kind === 'video' && (c.scale_keys ?? []).filter((k) => k.at >= c.in && k.at <= c.out).map((k) => {
          const at = keyTime(c, k.at)
          return (
            <span key={k.at} className="st-key" style={{ left: sec(at - c.start) * zoom }}
              title={`${t('Keyframe', 'Keyframe')} ${Math.round(k.value * 100)} % · ${t('Klick: hinspringen, Doppelklick: löschen', 'Click: jump there, double click: delete')}`}
              onPointerDown={(e) => { e.stopPropagation(); onSelect({ type: 'clip', id: c.id }); onPlayhead(at) }}
              onDoubleClick={(e) => { e.stopPropagation(); onCommand('clip.key', { id: c.id, at, delete: true }) }} />
          )
        })}
        {track.kind === 'video' && !(c.scale_keys ?? []).length && (c.scale ?? 1) !== 1 && (
          <span className="st-speed">{Math.round((c.scale ?? 1) * 100)} % ⤢</span>
        )}
        {speed !== 1 && <span className="st-speed">{decimal(String(Math.round(speed * 1000) / 10))} %</span>}
        {c.gain_db !== 0 && <span className="st-gain">{c.gain_db > 0 ? '+' : ''}{c.gain_db} dB</span>}
        {tool === 'select' && <span className="st-edge st-edge-start" onPointerDown={(e) => { e.stopPropagation(); onSelect({ type: 'clip', id: c.id }); begin(e, 'clip-start', c.id) }} />}
        {tool === 'select' && <span className="st-edge" onPointerDown={(e) => { e.stopPropagation(); onSelect({ type: 'clip', id: c.id }); begin(e, 'clip-end', c.id) }} />}
      </div>
    )
  }

  /** Übergang als eigener Block auf dem Schnitt, über dem Bild (Nutzer 27.10.2026: „soll gleich in der Videospur
   * liegen, über dem Video“): anklicken wählt ihn, die rechte Kante ändert die Dauer. */
  const transitionEl = (c: StudioClip) => {
    if (!c.transition) return null
    let duration = c.transition.duration
    if (drag?.kind === 'transition-end' && drag.id === c.id) duration += drag.delta
    return (
      <div
        key={`tr-${c.id}`}
        className={`st-trans st-trans-${c.transition.kind}${isSel('transition', c.id) ? ' st-sel' : ''}`}
        style={{ left: sec(clipStart(c)) * zoom, width: Math.max(10, sec(duration) * zoom) }}
        title={`${TRANSITION_LABEL[c.transition.kind] ?? c.transition.kind} · ${decimal(sec(c.transition.duration).toFixed(2))} s${c.transition.marker ? t(' (vom Übergang-Marker)', ' (from a transition marker)') : ''}`}
        onPointerDown={(e) => {
          if (e.button !== 0 || tool !== 'select') return
          e.stopPropagation()
          onSelect({ type: 'transition', id: c.id })
        }}
        onContextMenu={(e) => menuAt(e, { kind: 'transition', id: c.id, at: c.start }, 'transition', c.id)}
      >
        <span className="st-trans-label">{TRANSITION_LABEL[c.transition.kind] ?? c.transition.kind}</span>
        <span className="st-edge" onPointerDown={(e) => { e.stopPropagation(); onSelect({ type: 'transition', id: c.id }); begin(e, 'transition-end', c.id) }} />
      </div>
    )
  }

  const markerEl = (m: StudioMarker) => {
    const at = moving('marker', m.id) ? m.at + drag!.delta : m.at
    return (
      <div
        key={m.id}
        data-marker-id={m.id}
        className={`st-marker st-mk-${m.color}${m.done ? ' st-done' : ''}${isSel('marker', m.id) ? ' st-sel' : ''}`}
        style={{ left: sec(at) * zoom, width: Math.max(12, sec(m.duration) * zoom) }}
        title={`${m.name || m.kind}${m.comment ? ': ' + m.comment : ''}`}
        onPointerDown={(e) => {
          if (e.button !== 0) return
          const group = pick(e, 'marker', m.id)
          if (group) begin(e, 'marker', m.id, group)
          else e.stopPropagation()
        }}
        onContextMenu={(e) => menuAt(e, { kind: 'marker', id: m.id, at: m.at }, 'marker', m.id)}
      >
        ◆ {m.name}
      </div>
    )
  }

  const row = (key: string, head: ReactNode, height: number, body: ReactNode, extra: Record<string, any> = {}, headExtra: Record<string, any> = {}) => (
    <div className="st-row" key={key} style={{ height }}>
      <div className="st-head" {...headExtra}>{head}</div>
      <div className="st-body" style={{ width }} {...extra}>
        {body}
      </div>
    </div>
  )

  const trackHead = (tr: StudioTrack) => (
    <>
      <span className="st-track-name">{tr.id}</span>
      {tr.kind === 'video' && (
        <button
          className={`st-icon${tr.hidden ? ' off' : ''}`}
          title={tr.hidden ? t(`${tr.id} einblenden`, `Show ${tr.id}`) : t(`${tr.id} ausblenden (Bild aus, auch im Export)`, `Hide ${tr.id} (picture off, also in the export)`)}
          onClick={() => onCommand('track.update', { id: tr.id, hidden: !tr.hidden })}
        >
          <Icon name={tr.hidden ? 'eyeOff' : 'eye'} />
        </button>
      )}
      <button
        className={`st-icon${tr.muted ? ' off' : ''}`}
        title={tr.muted ? t(`Ton von ${tr.id} an`, `Unmute ${tr.id}`) : t(`${tr.id} stumm schalten (auch im Export)`, `Mute ${tr.id} (also in the export)`)}
        onClick={() => onCommand('track.update', { id: tr.id, muted: !tr.muted })}
      >
        <Icon name={tr.muted ? 'soundOff' : 'sound'} />
      </button>
    </>
  )

  const razorLine = (track: string) =>
    tool === 'razor' && razorAt && (razorAt.all || razorAt.track === track) ? <div className="st-razorline" style={{ left: sec(razorAt.at) * zoom }} /> : null

  const tools = (
    <div className="st-head st-tools">
      <button className={`st-tool${tool === 'select' ? ' active' : ''}`} onClick={() => onTool('select')}
        title={t('Auswahl (V): ziehen verschiebt, Kanten trimmen, Rahmen im Leeren wählt mehrere', 'Selection (V): drag moves, edges trim, a box in empty space selects several')}>
        <Icon name="select" /><kbd>V</kbd>
      </button>
      <button className={`st-tool${tool === 'razor' ? ' active' : ''}`} onClick={() => onTool('razor')}
        title={t('Schneiden (C): Klick teilt den Clip, mit Umschalt alle Spuren. Am Abspielkopf: Strg+K', 'Razor (C): a click cuts the clip, with Shift all tracks. At the playhead: Ctrl+K')}>
        <Icon name="razor" /><kbd>C</kbd>
      </button>
      <button className={`st-tool${tool === 'scale' ? ' active' : ''}`} onClick={() => onTool('scale')}
        title={t('Skalieren (Z): im Monitor ziehen setzt einen Keyframe am Abspielkopf, Klick setzt den Fokuspunkt. Rauten auf dem Clip: Klick springt hin, Doppelklick löscht',
          'Scale (Z): dragging in the monitor sets a keyframe at the playhead, a click sets the focus point. Diamonds on the clip: a click jumps there, a double click deletes')}>
        <Icon name="scale" /><kbd>Z</kbd>
      </button>
      <button className={`st-tool${magnet ? ' active' : ''}`} onClick={() => onMagnet(!magnet)}
        title={magnet
          ? t('Magnet an: Clips docken an Kanten, Markern und dem Abspielkopf an (an/aus auch mit S)', 'Magnet on: clips dock to edges, markers and the playhead (toggle with S too)')
          : t('Magnet aus: andocken mit gedrückter Umschalttaste ⇧ (an/aus auch mit S)', 'Magnet off: hold Shift ⇧ to dock (toggle with S too)')}>
        {/* Hinweis Umschalttaste statt Buchstabe (Nutzer 27.10.2026), so hoch wie die Buchstaben daneben */}
        <Icon name="magnet" /><kbd className="st-kbd-shift"><svg viewBox="0 0 8 8" width="5" height="5" aria-label="Shift"><path d="M4 .8 7.2 4.3H5.4v2.9H2.6V4.3H.8z" fill="none" stroke="currentColor" strokeWidth="1" strokeLinejoin="round" /></svg></kbd>
      </button>
    </div>
  )

  const marquee = drag?.kind === 'marquee' && drag.moved && drag.x1 !== undefined ? (
    <div
      className="st-marquee"
      style={{ left: Math.min(drag.x0, drag.x1), top: Math.min(drag.y0, drag.y1!), width: Math.abs(drag.x1 - drag.x0), height: Math.abs(drag.y1! - drag.y0) }}
    />
  ) : null

  return (
    <div
      className={`st-timelines${tool === 'razor' ? ' st-razor-mode' : ''}`}
      ref={scroll}
      onPointerMove={move}
      onPointerUp={end}
      onPointerCancel={() => setDrag(null)}
      onPointerLeave={() => setRazorAt(null)}
    >
      <div className="st-inner" style={{ width: width + HEAD }}>
        <div className="st-row st-ruler">
          {tools}
          <div className="st-body" style={{ width }} onPointerDown={(e) => begin(e, 'playhead', '')}>
            {ruler()}
          </div>
        </div>
        <div className="st-section">{t('Komposition', 'Composition')}</div>
        {row('markers', t('Marker', 'Markers'), 24, p.markers.map(markerEl), {
          className: 'st-body st-marker-row',
          onDoubleClick: addMarker,
          onPointerDown: (e: RPointerEvent) => startMarquee(e, 'markers'),
          onContextMenu: (e: RMouseEvent) => e.target === e.currentTarget && menuAt(e, { kind: 'markers', at: snapFrame(p, timeAt(e.clientX)) }),
        })}
        {LANES.map((lane) =>
          row(lane.id, lane.label, lane.height, p.scenes.filter((s) => s.lane === lane.id).map(sceneEl), {
            className: 'st-body st-lane',
            onDoubleClick: (e: RMouseEvent) => addScene(e, lane.id),
            onPointerDown: (e: RPointerEvent) => startMarquee(e, 'lanes'),
            onContextMenu: (e: RMouseEvent) => e.target === e.currentTarget && menuAt(e, { kind: 'lane', lane: lane.id, at: snapFrame(p, timeAt(e.clientX)) }),
            title: t('Doppelklick: neue Szene · Rechtsklick: Menü', 'Double-click: new scene · Right-click: menu'),
          }),
        )}
        <div className="st-section">{t('Schnitt', 'Edit')}</div>
        {p.tracks.map((tr) =>
          row(
            tr.id,
            trackHead(tr),
            trackHeight(tr),
            <>
              {p.clips.filter((c) => shownTrack(c) === tr.id).map((c) => clipEl(c, tr))}
              {p.clips.filter((c) => shownTrack(c) === tr.id && c.transition).map(transitionEl)}
              {razorLine(tr.id)}
            </>,
            {
              className: `st-body st-track st-${tr.kind}${tr.hidden ? ' st-hidden' : ''}`,
              'data-track': tr.id,
              onDragOver: acceptAsset,
              onDrop: (e: DragEvent) => dropOnTrack(e, tr.id),
              onPointerDown: (e: RPointerEvent) => startMarquee(e, 'edit'),
              onContextMenu: (e: RMouseEvent) => e.target === e.currentTarget && menuAt(e, { kind: 'track', track: tr.id, at: snapFrame(p, timeAt(e.clientX)) }),
            },
            {
              className: `st-head st-track-head${tr.hidden || tr.muted ? ' st-off' : ''}`,
              onContextMenu: (e: RMouseEvent) => menuAt(e, { kind: 'track-head', track: tr.id, at: playhead }),
              title: t('Rechtsklick: Spuren hinzufügen oder entfernen', 'Right-click: add or remove tracks'),
            },
          ),
        )}
        <div className="st-playhead" style={{ left: HEAD + sec(playhead) * zoom }} />
        {drag?.snapAt != null && <div className="st-snapline" style={{ left: HEAD + sec(drag.snapAt) * zoom }} />}
      </div>
      {marquee}
    </div>
  )
}
