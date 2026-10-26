// Die zwei Zeitleisten des Studios: oben die Komposition (Szenen mit Prompts auf vier Bahnen, darüber die Marker),
// unten der Schnitt (Spuren V2, V1, A1, A2). Ein Lineal und ein Abspielkopf für beide. Ziehen verschiebt, Kanten
// ändern die Länge bzw. trimmen, alles rastet an Kanten und am Abspielkopf ein. Jede Änderung geht als Befehl an
// den Server (onCommand), angezeigt wird während des Ziehens nur eine Vorschau.

import { useEffect, useRef, useState, type DragEvent, type MouseEvent as RMouseEvent, type PointerEvent as RPointerEvent, type ReactNode } from 'react'
import { TPS, type StudioClip, type StudioLane, type StudioMarker, type StudioProject, type StudioScene } from '../api'
import { t } from '../i18n'
import { clipEnd, sec, shortTime, snapFrame } from './time'

export type Selection = { type: 'scene' | 'clip' | 'marker' | 'asset'; id: string } | null
export const ASSET_MIME = 'application/x-nvai-asset'

interface Props {
  project: StudioProject
  playhead: number
  zoom: number
  selection: Selection
  onSelect: (s: Selection) => void
  onPlayhead: (t: number) => void
  onCommand: (command: string, params: Record<string, unknown>) => Promise<any>
  onZoom: (z: number) => void
}

const LANES: { id: StudioLane; label: string; height: number }[] = [
  { id: 'video', label: t('Bild/Video', 'Picture'), height: 46 },
  { id: 'voice', label: t('Sprecher', 'Voice'), height: 30 },
  { id: 'music', label: t('Musik', 'Music'), height: 30 },
  { id: 'sfx', label: t('Klang', 'Sound'), height: 30 },
]
const TRACK_HEIGHT: Record<string, number> = { V2: 40, V1: 52, A1: 32, A2: 32 }
const HEAD = 92
const SNAP_PX = 8

type DragKind = 'scene-move' | 'scene-end' | 'clip-move' | 'clip-start' | 'clip-end' | 'marker' | 'playhead'
interface Drag {
  kind: DragKind
  id: string
  x0: number
  delta: number // Ticks
  track?: string
  moved: boolean
}

export function Timelines({ project, playhead, zoom, selection, onSelect, onPlayhead, onCommand, onZoom }: Props) {
  const scroll = useRef<HTMLDivElement>(null)
  const [drag, setDrag] = useState<Drag | null>(null)
  const p = project

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

  const timeAt = (clientX: number) => {
    const el = scroll.current!
    const x = clientX - el.getBoundingClientRect().left - HEAD + el.scrollLeft
    return Math.max(0, (x / zoom) * TPS)
  }

  /** Einrasten an Kanten aller Szenen und Clips, an Markern, am Abspielkopf und bei 0. */
  const snap = (tick: number, except: string): number => {
    const range = (SNAP_PX / zoom) * TPS
    const points = [0, playhead]
    for (const s of p.scenes) if (s.id !== except) points.push(s.start, s.start + s.duration)
    for (const c of p.clips) if (c.id !== except) points.push(c.start, clipEnd(c))
    for (const m of p.markers) if (m.id !== except) points.push(m.at)
    let best = tick
    let dist = range
    for (const q of points) {
      if (Math.abs(q - tick) < dist) {
        dist = Math.abs(q - tick)
        best = q
      }
    }
    return snapFrame(p, best)
  }

  // ---------------------------------------------------------------------------------- Ziehen

  const begin = (e: RPointerEvent, kind: DragKind, id: string, track?: string) => {
    if (e.button !== 0) return
    e.stopPropagation()
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    setDrag({ kind, id, x0: e.clientX, delta: 0, track, moved: false })
    if (kind === 'playhead') onPlayhead(snapFrame(p, timeAt(e.clientX)))
  }

  const move = (e: RPointerEvent) => {
    if (!drag) return
    if (drag.kind === 'playhead') {
      onPlayhead(snapFrame(p, timeAt(e.clientX)))
      return
    }
    const delta = ((e.clientX - drag.x0) / zoom) * TPS
    let track = drag.track
    if (drag.kind === 'clip-move') {
      const under = document.elementsFromPoint(e.clientX, e.clientY).find((el) => (el as HTMLElement).dataset?.track)
      const target = (under as HTMLElement | undefined)?.dataset.track
      const clip = p.clips.find((c) => c.id === drag.id)
      const kindOf = (id?: string) => p.tracks.find((tr) => tr.id === id)?.kind
      if (target && clip && kindOf(target) === kindOf(clip.track)) track = target
    }
    setDrag({ ...drag, delta, track, moved: drag.moved || Math.abs(e.clientX - drag.x0) > 3 })
  }

  const end = async () => {
    const d = drag
    setDrag(null)
    if (!d || d.kind === 'playhead' || !d.moved) return
    if (d.kind === 'scene-move' || d.kind === 'scene-end') {
      const s = p.scenes.find((x) => x.id === d.id)!
      if (d.kind === 'scene-move') await onCommand('scene.update', { id: s.id, start: snap(s.start + d.delta, s.id) })
      else {
        const endAt = snap(s.start + s.duration + d.delta, s.id)
        await onCommand('scene.update', { id: s.id, duration: Math.max(endAt - s.start, TPS / 4) })
      }
    } else if (d.kind === 'marker') {
      const m = p.markers.find((x) => x.id === d.id)!
      await onCommand('marker.update', { id: m.id, at: snap(m.at + d.delta, m.id) })
    } else {
      const c = p.clips.find((x) => x.id === d.id)!
      if (d.kind === 'clip-move') {
        await onCommand('clip.move', { id: c.id, start: snap(c.start + d.delta, c.id), track: d.track ?? c.track })
      } else if (d.kind === 'clip-start') {
        await onCommand('clip.trim', { id: c.id, edge: 'start', to: snap(c.start + d.delta, c.id) })
      } else {
        await onCommand('clip.trim', { id: c.id, edge: 'end', to: snap(clipEnd(c) + d.delta, c.id) })
      }
    }
  }

  // Vorschau während des Ziehens
  const sceneBox = (s: StudioScene) => {
    let start = s.start
    let duration = s.duration
    if (drag?.id === s.id && drag.kind === 'scene-move') start = Math.max(0, s.start + drag.delta)
    if (drag?.id === s.id && drag.kind === 'scene-end') duration = Math.max(TPS / 4, s.duration + drag.delta)
    return { left: sec(start) * zoom, width: Math.max(4, sec(duration) * zoom) }
  }
  const clipBox = (c: StudioClip) => {
    let start = c.start
    let length = c.out - c.in
    if (drag?.id === c.id && drag.kind === 'clip-move') start = Math.max(0, c.start + drag.delta)
    if (drag?.id === c.id && drag.kind === 'clip-start') {
      const d = Math.max(-c.in, Math.min(drag.delta, length - TPS / 24))
      start = c.start + d
      length -= d
    }
    if (drag?.id === c.id && drag.kind === 'clip-end') length = Math.max(TPS / 24, length + drag.delta)
    return { left: sec(start) * zoom, width: Math.max(3, sec(length) * zoom) }
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
    const r = await onCommand('clip.add', { track, asset_id: id, start: snap(timeAt(e.clientX), '') })
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
    const r = await onCommand('scene.add', { lane, start: snap(timeAt(e.clientX), ''), duration_s: lane === 'video' ? 5 : 10 })
    if (r?.id) onSelect({ type: 'scene', id: r.id })
  }
  const addMarker = async (e: RMouseEvent) => {
    if (e.target !== e.currentTarget) return
    const r = await onCommand('marker.add', { at: snap(timeAt(e.clientX), ''), kind: 'note' })
    if (r?.id) onSelect({ type: 'marker', id: r.id })
  }

  // ---------------------------------------------------------------------------------- Zeichnen

  const thumb = (assetId: string | null | undefined) => {
    if (!assetId) return null
    const a = p.assets[assetId]
    if (!a) return null
    if (a.kind === 'image') return <img className="st-thumb" src={a.url} alt="" draggable={false} />
    if (a.kind === 'video') return <video className="st-thumb" src={`${a.url}#t=0.1`} preload="metadata" muted />
    return <span className="st-wave">∿∿∿</span>
  }

  const selected = (type: string, id: string) => selection?.type === type && selection.id === id

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

  const sceneEl = (s: StudioScene) => {
    const box = sceneBox(s)
    return (
      <div
        key={s.id}
        className={`st-scene st-s-${s.status}${selected('scene', s.id) ? ' st-sel' : ''}`}
        style={box}
        title={s.error ?? s.prompt}
        onPointerDown={(e) => {
          onSelect({ type: 'scene', id: s.id })
          begin(e, 'scene-move', s.id)
        }}
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
  }

  const clipEl = (c: StudioClip) => {
    const box = clipBox(c)
    const scene = c.scene_id ? p.scenes.find((s) => s.id === c.scene_id) : undefined
    const label = scene?.title || p.assets[c.asset_id]?.prompt || c.asset_id
    const tr = c.transition ? sec(c.transition.duration) * zoom : 0
    return (
      <div
        key={c.id}
        className={`st-clip st-${p.media[c.asset_id]?.kind ?? 'video'}${selected('clip', c.id) ? ' st-sel' : ''}${c.muted ? ' st-muted' : ''}${c.missing ? ' st-missing' : ''}`}
        style={box}
        title={c.missing ? t('Datei gelöscht: Clip löschen oder ersetzen', 'File deleted: delete or replace the clip') : label}
        onPointerDown={(e) => {
          onSelect({ type: 'clip', id: c.id })
          begin(e, 'clip-move', c.id, c.track)
        }}
      >
        {tr > 0 && <span className="st-transition" style={{ width: tr }} />}
        {(c.track === 'V1' || c.track === 'V2') && thumb(c.asset_id)}
        <span className="st-label">{label}</span>
        {c.gain_db !== 0 && <span className="st-gain">{c.gain_db > 0 ? '+' : ''}{c.gain_db} dB</span>}
        <span className="st-edge st-edge-start" onPointerDown={(e) => begin(e, 'clip-start', c.id)} />
        <span className="st-edge" onPointerDown={(e) => begin(e, 'clip-end', c.id)} />
      </div>
    )
  }

  const markerEl = (m: StudioMarker) => {
    const at = drag?.id === m.id && drag.kind === 'marker' ? Math.max(0, m.at + drag.delta) : m.at
    return (
      <div
        key={m.id}
        className={`st-marker st-mk-${m.color}${m.done ? ' st-done' : ''}${selected('marker', m.id) ? ' st-sel' : ''}`}
        style={{ left: sec(at) * zoom, width: Math.max(12, sec(m.duration) * zoom) }}
        title={`${m.name || m.kind}${m.comment ? ': ' + m.comment : ''}`}
        onPointerDown={(e) => {
          onSelect({ type: 'marker', id: m.id })
          begin(e, 'marker', m.id)
        }}
      >
        ◆ {m.name}
      </div>
    )
  }

  const row = (key: string, label: string, height: number, body: ReactNode, extra: Record<string, any> = {}) => (
    <div className="st-row" key={key} style={{ height }}>
      <div className="st-head">{label}</div>
      <div className="st-body" style={{ width }} {...extra}>
        {body}
      </div>
    </div>
  )

  return (
    <div className="st-timelines" ref={scroll} onPointerMove={move} onPointerUp={end} onPointerCancel={() => setDrag(null)}>
      <div className="st-inner" style={{ width: width + HEAD }}>
        <div className="st-row st-ruler">
          <div className="st-head" />
          <div className="st-body" style={{ width }} onPointerDown={(e) => begin(e, 'playhead', '')}>
            {ruler()}
          </div>
        </div>
        <div className="st-section">{t('Komposition', 'Composition')}</div>
        {row('markers', t('Marker', 'Markers'), 24, p.markers.map(markerEl), {
          className: 'st-body st-marker-row',
          onDoubleClick: addMarker,
        })}
        {LANES.map((lane) =>
          row(lane.id, lane.label, lane.height, p.scenes.filter((s) => s.lane === lane.id).map(sceneEl), {
            className: 'st-body st-lane',
            onDoubleClick: (e: RMouseEvent) => addScene(e, lane.id),
            title: t('Doppelklick: neue Szene', 'Double-click: new scene'),
          }),
        )}
        <div className="st-section">{t('Schnitt', 'Edit')}</div>
        {p.tracks.map((tr) =>
          row(
            tr.id,
            tr.id,
            TRACK_HEIGHT[tr.id] ?? 40,
            p.clips.filter((c) => (drag?.id === c.id && drag.kind === 'clip-move' ? drag.track : c.track) === tr.id).map(clipEl),
            {
              className: `st-body st-track st-${tr.kind}`,
              'data-track': tr.id,
              onDragOver: acceptAsset,
              onDrop: (e: DragEvent) => dropOnTrack(e, tr.id),
              onPointerDown: (e: RPointerEvent) => {
                if (e.target === e.currentTarget) onSelect(null)
              },
            },
          ),
        )}
        <div className="st-playhead" style={{ left: HEAD + sec(playhead) * zoom }} />
      </div>
    </div>
  )
}
