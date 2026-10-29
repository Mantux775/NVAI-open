// Programmmonitor: spielt die Schnitt-Zeitleiste im Browser ab. Der Browser dekodiert in Hardware; jeder sichtbare
// Clip hat ein eigenes Video-Element, der nächste wird kurz vor dem Schnitt geladen (so laufen Schnitte ohne Lücke),
// bei Überblendungen spielen beide mit wechselnder Deckkraft und Lautstärke. Eine eigene Uhr führt den Abspielkopf;
// die Medien werden nur nachgezogen, wenn sie mehr als eine Viertelsekunde abweichen (wie FilmCraft: das Bild folgt
// der Uhr, nicht umgekehrt). Der fertige Export rechnet das Gleiche genau (studio_render.py), auch beim Einpassen:
// Bei fast gleichem Seitenverhältnis füllt das Bild den Rahmen (LTX-2.5 rechnet 1080p als 1920 × 1088).
// Ein Klick im Material macht ihn zum Quellmonitor: Das Asset läuft mit eigenen Bedienelementen, bis wieder etwas im
// Schnitt gewählt wird.
// Skalieren (seit 0.5.16): jede Ebene mit transform: scale() um ihren Fokuspunkt (transform-origin), wie
// studio_render.place. Mit dem Werkzeug „Skalieren“ (Z) zieht man im Bild: nach oben größer, nach unten kleiner; das
// setzt beim Loslassen einen Keyframe am Abspielkopf. Ein Klick ohne Ziehen setzt den Fokuspunkt, das Mausrad
// skaliert fein.

import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from 'react'
import { api, TPS, type Asset, type StudioClip, type StudioProject } from '../api'
import { t } from '../i18n'
import { assetFacts, assetLabel, mediaKind, previewUrl } from './Bin'
import { SCALE_MAX, SCALE_MIN, clipAt, clipScaleAt, clipSpeed, previousClip, sec, timecode, tracksOf } from './time'
import type { Tool } from './Timelines'

interface Props {
  project: StudioProject
  playhead: number
  playing: boolean
  onPlayhead: (t: number) => void
  onStop: () => void
  /** Angeklicktes Material: der Monitor zeigt dann dieses statt des Schnitts */
  source: Asset | null
  onCloseSource: () => void
  /** Werkzeug der Zeitleiste: „scale“ macht das Bild zur Fläche zum Skalieren */
  tool?: Tool
  /** gewählter Clip: den skaliert das Werkzeug, wenn er am Abspielkopf liegt */
  selectedClip?: string | null
  onCommand?: (command: string, params: Record<string, unknown>) => Promise<any>
}

const COVER_TOLERANCE = 0.05

interface Layer {
  clip: StudioClip
  mediaTime: number // Sekunden im Material
  opacity: number
  volume: number
  /** Stapelhöhe: V1 unten (0), darüber V2 (1) … */
  order: number
  /** Wischblende: sichtbarer Anteil von links (0 bis 1) */
  wipe?: number
  /** ausgeblendete Spur: kein Bild, der Ton läuft weiter */
  hidden: boolean
  /** stumme Spur oder stummer Clip */
  muted: boolean
  /** Skalierung zu dieser Zeit (1 = 100 %) und Fokuspunkt */
  scale: number
  anchor: [number, number]
}

const CENTER: [number, number] = [0.5, 0.5]

/** CSS für Skalierung um den Fokuspunkt, wie studio_render.place. */
function scaleStyle(scale: number, anchor: [number, number]): CSSProperties {
  if (Math.abs(scale - 1) < 1e-4) return { transform: '', transformOrigin: '' }
  return { transform: `scale(${scale})`, transformOrigin: `${anchor[0] * 100}% ${anchor[1] * 100}%` }
}

/** Abblende über Schwarz oder Weiß: Farbfläche über einer Spur */
interface Dip {
  order: number
  color: string
  opacity: number
}

const PRELOAD = 2 * TPS
const WIPE_EDGE = 0.04 // wie studio_render.WIPE_EDGE

/** Was zur Zeit t zu sehen und zu hören ist: Videospuren von V1 aufwärts, dann der Ton aller Spuren. Rechnet
 * Übergänge wie studio_render.blend: Überblendung über die Deckkraft, Abblenden mit einer Farbfläche (erste Hälfte
 * ab-, zweite aufblenden), Wischblende mit einer Maske von links. */
function layersAt(p: StudioProject, t: number): { layers: Layer[]; dips: Dip[] } {
  const layers: Layer[] = []
  const dips: Dip[] = []
  const video = [...tracksOf(p, 'video')].reverse()
  for (const track of [...video, ...tracksOf(p, 'audio')]) {
    const c = clipAt(p, track.id, t)
    if (!c) continue
    const order = track.kind === 'video' ? video.indexOf(track) : 0
    const hidden = !!(track.kind === 'video' && track.hidden)
    const local = t - c.start
    const tr = c.transition
    let opacity = 1
    let volume = 1
    let wipe: number | undefined
    if (tr && local < tr.duration) {
      const a = local / tr.duration
      volume = a
      let prevOpacity = 1
      if (tr.kind === 'dip_black' || tr.kind === 'dip_white') {
        opacity = a < 0.5 ? 0 : 1
        prevOpacity = a < 0.5 ? 1 : 0
        dips.push({ order, color: tr.kind === 'dip_black' ? '#000' : '#fff', opacity: a < 0.5 ? 2 * a : 2 - 2 * a })
      } else if (tr.kind === 'wipe') {
        wipe = a
      } else {
        opacity = a
      }
      const prev = previousClip(p, c)
      if (prev) {
        const prevMedia = prev.out + local * clipSpeed(prev)
        layers.push({ clip: prev, mediaTime: sec(prevMedia), opacity: prevOpacity, volume: 1 - a,
          order, hidden, muted: !!(track.muted || prev.muted), scale: clipScaleAt(prev, prevMedia),
          anchor: prev.anchor ?? CENTER })
      }
    }
    const media = c.in + local * clipSpeed(c)
    layers.push({ clip: c, mediaTime: sec(media), opacity: track.kind === 'video' ? opacity : 1, volume,
      order, wipe, hidden, muted: !!(track.muted || c.muted), scale: clipScaleAt(c, media), anchor: c.anchor ?? CENTER })
  }
  return { layers, dips }
}

/** Maske der Wischblende: links sichtbar, weiche Kante wie im Export. */
function wipeMask(a: number): CSSProperties {
  const x1 = a * (1 + WIPE_EDGE) * 100
  const mask = `linear-gradient(to right, #000 ${x1 - WIPE_EDGE * 100}%, transparent ${x1}%)`
  return { maskImage: mask, WebkitMaskImage: mask }
}
const NO_MASK: CSSProperties = { maskImage: '', WebkitMaskImage: '' }

/** Clips, die gleich beginnen: schon laden, damit der Schnitt sitzt. */
function upcoming(p: StudioProject, t: number): StudioClip[] {
  return p.clips.filter((c) => c.start > t && c.start - t < PRELOAD)
}

const gain = (db: number) => Math.min(1, Math.pow(10, db / 20))

export function Monitor({ project, playhead, playing, onPlayhead, onStop, source, onCloseSource, tool, selectedClip, onCommand }: Props) {
  const els = useRef(new Map<string, HTMLMediaElement>())
  const clock = useRef({ wall: 0, tick: 0 })
  const now = useRef(playhead)
  const p = project
  // Skalieren im Bild: Vorschau während des Ziehens, erst beim Loslassen ein Befehl (ein Schritt im Rückgängig)
  const [preview, setPreview] = useState<{ id: string; scale: number } | null>(null)
  const dragRef = useRef<{ id: string; y: number; x: number; start: number; moved: boolean } | null>(null)
  const wheelTimer = useRef<number | undefined>(undefined)
  const scaleOf = (l: Layer) => (preview && preview.id === l.clip.id ? preview.scale : l.scale)
  // MKV, MOV & Co. spielt der Browser über ihre H.264-Vorschau
  const urlOf = (c: StudioClip) => p.assets[c.asset_id]?.preview ?? p.assets[c.asset_id]?.url ?? ''
  const kindOf = (c: StudioClip) => p.media[c.asset_id]?.kind ?? 'video'
  /** Füllen, wenn das Seitenverhältnis höchstens 5 % abweicht (wie studio_render.target_size), sonst einpassen. */
  const fitOf = (c: StudioClip): 'cover' | 'contain' => {
    const m = p.media[c.asset_id]
    if (!m?.width || !m?.height) return 'contain'
    const off = m.width / m.height / (p.settings.width / p.settings.height)
    return Math.abs(off - 1) <= COVER_TOLERANCE ? 'cover' : 'contain'
  }

  const sync = (time: number, isPlaying: boolean) => {
    const { layers } = layersAt(p, time)
    const byId = new Map(layers.map((l) => [l.clip.id, l]))
    els.current.forEach((el, id) => {
      const layer = byId.get(id)
      if (!layer) {
        if (!el.paused) el.pause()
        if (el instanceof HTMLVideoElement) el.style.opacity = '0'
        const c = p.clips.find((x) => x.id === id)
        if (c && Math.abs(el.currentTime - sec(c.in)) > 0.05 && el.readyState > 0) el.currentTime = sec(c.in)
        return
      }
      if (el instanceof HTMLVideoElement) {
        el.style.opacity = String(layer.hidden ? 0 : layer.opacity)
        Object.assign(el.style, layer.wipe !== undefined ? wipeMask(layer.wipe) : NO_MASK, scaleStyle(scaleOf(layer), layer.anchor))
      }
      el.muted = layer.muted
      el.volume = Math.max(0, Math.min(1, gain(layer.clip.gain_db) * layer.volume))
      // Geschwindigkeit: der Browser behält die Tonhöhe, wie der Export (atempo)
      const rate = clipSpeed(layer.clip)
      if (el.playbackRate !== rate) el.playbackRate = rate
      const drift = Math.abs(el.currentTime - layer.mediaTime)
      if (isPlaying) {
        if (el.paused) el.play().catch(() => {})
        if (drift > 0.25 * Math.max(1, rate)) el.currentTime = layer.mediaTime
      } else {
        if (!el.paused) el.pause()
        if (drift > 0.03) el.currentTime = layer.mediaTime
      }
    })
  }

  // Abspielen: eigene Uhr, Abspielkopf etwa 20-mal je Sekunde an die Zeitleiste melden
  useEffect(() => {
    if (!playing) {
      sync(playhead, false)
      return
    }
    clock.current = { wall: performance.now(), tick: playhead }
    let frame = 0
    let lastEmit = 0
    const step = (ms: number) => {
      const time = clock.current.tick + ((ms - clock.current.wall) / 1000) * TPS
      now.current = time
      if (time >= p.edit_duration) {
        sync(p.edit_duration, false)
        onPlayhead(p.edit_duration)
        onStop()
        return
      }
      sync(time, true)
      if (ms - lastEmit > 50) {
        lastEmit = ms
        onPlayhead(Math.round(time))
      }
      frame = requestAnimationFrame(step)
    }
    frame = requestAnimationFrame(step)
    return () => cancelAnimationFrame(frame)
    // Nur Start/Stopp und ein neues Projekt setzen die Uhr; der gemeldete Abspielkopf nicht.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing, p])

  useEffect(() => {
    if (!playing) sync(playhead, false)
  })

  if (source) {
    const kind = mediaKind(source)
    const m = source.meta ?? {}
    const ratio = m.width && m.height ? m.width / m.height : p.settings.width / p.settings.height
    return (
      <div className="st-monitor">
        <div className="st-stage">
          <div className="st-screen st-source" style={{ '--ar': ratio } as CSSProperties}>
            {kind === 'video' && previewUrl(source) && <video key={source.id} src={previewUrl(source)!} controls autoPlay playsInline />}
            {kind === 'video' && !previewUrl(source) && (
              <div className="st-empty">
                <div>
                  {t('Diese Datei spielt der Browser nicht ab (etwa FFV1 oder ProRes). NVAI-open legt eine Vorschau an; sie erscheint hier, sobald sie fertig ist.',
                    'The browser cannot play this file (e.g. FFV1 or ProRes). NVAI-open makes a preview; it shows up here as soon as it is ready.')}
                  <p className="st-actions" style={{ justifyContent: 'center' }}>
                    <button className="btn small" onClick={() => api.assetPreview(source.id).catch(() => {})}>{t('Vorschau erstellen', 'Make a preview')}</button>
                    <a className="btn small ghost" href={source.url} download>{t('Original herunterladen', 'Download the original')}</a>
                  </p>
                </div>
              </div>
            )}
            {kind === 'image' && <img key={source.id} src={source.url} alt="" draggable={false} />}
            {kind === 'audio' && (
              <div className="st-source-audio">
                <span>♪</span>
                <audio key={source.id} src={source.url} controls autoPlay />
              </div>
            )}
          </div>
        </div>
        <div className="st-monitor-bar">
          <span className="st-source-tag">{t('Quelle', 'Source')}</span>
          <span className="st-source-name" title={assetLabel(source)}>{assetLabel(source)}</span>
          <span className="muted small">
            {assetFacts(source).join(' · ')}
            {source.meta?.preview && <> · {t('Vorschau H.264', 'H.264 preview')} · <a href={source.url} download>{t('Original', 'original')}</a></>}
          </span>
          <button className="btn small ghost st-format" onClick={onCloseSource} title="Esc">
            {t('Zurück zum Schnitt', 'Back to the edit')}
          </button>
        </div>
      </div>
    )
  }

  const time = playing ? now.current : playhead
  const { layers, dips } = layersAt(p, time)
  const mounted = new Map<string, StudioClip>()
  for (const l of layers) mounted.set(l.clip.id, l.clip)
  for (const c of upcoming(p, time)) mounted.set(c.id, c)
  const videoIds = new Set(tracksOf(p, 'video').map((tr) => tr.id))
  const visual = layers.filter((l) => videoIds.has(l.clip.track))
  const ratio = p.settings.width / p.settings.height
  const bottomUp = [...tracksOf(p, 'video')].reverse().map((tr) => tr.id)

  // Werkzeug „Skalieren“: der gewählte Clip, wenn er am Abspielkopf zu sehen ist, sonst der oberste sichtbare
  const scaling = tool === 'scale' && !playing && !!onCommand
  const shown = visual.filter((l) => !l.hidden)
  const target = shown.find((l) => l.clip.id === selectedClip) ?? shown.reduce<Layer | undefined>((top, l) => (!top || l.order >= top.order ? l : top), undefined)
  const clampScale = (v: number) => Math.min(SCALE_MAX, Math.max(SCALE_MIN, v))
  const commitScale = async (id: string, value: number) => {
    await onCommand?.('clip.key', { id, at: playhead, value: Math.round(value * 1000) / 1000 })
    setPreview(null)
  }
  const onDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!scaling || !target || e.button !== 0) return
    e.currentTarget.setPointerCapture(e.pointerId)
    dragRef.current = { id: target.clip.id, y: e.clientY, x: e.clientX, start: scaleOf(target), moved: false }
  }
  const onMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const d = dragRef.current
    if (!d) return
    if (Math.abs(d.y - e.clientY) > 3 || Math.abs(d.x - e.clientX) > 3) d.moved = true
    if (d.moved) setPreview({ id: d.id, scale: clampScale(d.start * Math.exp((d.y - e.clientY) / 200)) })
  }
  const onUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    const d = dragRef.current
    dragRef.current = null
    if (!d) return
    if (!d.moved) {
      // Klick ohne Ziehen: dieser Punkt bleibt beim Skalieren stehen
      const r = e.currentTarget.getBoundingClientRect()
      const at = (v: number) => Math.round(Math.min(1, Math.max(0, v)) * 1000) / 1000
      onCommand?.('clip.update', { id: d.id, anchor: [at((e.clientX - r.left) / r.width), at((e.clientY - r.top) / r.height)] })
    } else if (preview) {
      commitScale(d.id, preview.scale)
    }
  }
  const onWheel = (e: ReactWheelEvent<HTMLDivElement>) => {
    if (!scaling || !target) return
    const id = target.clip.id
    const value = clampScale(scaleOf(target) * (e.deltaY < 0 ? 1.05 : 1 / 1.05))
    setPreview({ id, scale: value })
    window.clearTimeout(wheelTimer.current)
    wheelTimer.current = window.setTimeout(() => commitScale(id, value), 350)
  }

  return (
    <div className="st-monitor">
      <div className="st-stage">
      <div className={`st-screen${scaling ? ' st-scaling' : ''}`} style={{ '--ar': ratio } as CSSProperties}
        onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onWheel={onWheel}>
        {[...mounted.values()].map((c) => {
          const kind = kindOf(c)
          const visible = visual.find((l) => l.clip.id === c.id)
          // je Spur zehn Stufen: der vorige Clip, darüber der Clip, darüber die Farbfläche einer Abblende
          const z = 10 + Math.max(0, bottomUp.indexOf(c.track)) * 10 + (c.transition ? 2 : 1)
          if (kind === 'image') {
            return visible && !visible.hidden ? (
              <img key={c.id} src={urlOf(c)} alt="" draggable={false}
                style={{ opacity: visible.opacity, zIndex: z, objectFit: fitOf(c), ...(visible.wipe !== undefined ? wipeMask(visible.wipe) : {}),
                  ...scaleStyle(scaleOf(visible), visible.anchor) }} />
            ) : null
          }
          if (kind === 'audio' || !videoIds.has(c.track)) {
            return (
              <audio
                key={c.id}
                src={urlOf(c)}
                preload="auto"
                ref={(el) => {
                  if (el) els.current.set(c.id, el)
                  else els.current.delete(c.id)
                }}
              />
            )
          }
          return (
            <video
              key={c.id}
              src={urlOf(c)}
              preload="auto"
              playsInline
              style={{ opacity: visible && !visible.hidden ? visible.opacity : 0, zIndex: z, objectFit: fitOf(c) }}
              ref={(el) => {
                if (el) els.current.set(c.id, el)
                else els.current.delete(c.id)
              }}
            />
          )
        })}
        {dips.map((d) => (
          <div key={`dip-${d.order}`} className="st-dip" style={{ background: d.color, opacity: d.opacity, zIndex: 13 + d.order * 10 }} />
        ))}
        {scaling && target && (
          <>
            <div className="st-anchor" style={{ left: `${target.anchor[0] * 100}%`, top: `${target.anchor[1] * 100}%` }} />
            <div className="st-scale-hud">
              <b>{Math.round(scaleOf(target) * 100)} %</b>{' '}
              {t('Ziehen: skalieren (Keyframe am Abspielkopf) · Klick: Fokuspunkt · Mausrad: fein',
                'Drag: scale (keyframe at the playhead) · Click: focus point · Wheel: fine')}
            </div>
          </>
        )}
        {p.clips.length === 0 && (
          <div className="st-empty">
            {t('Noch nichts im Schnitt. Szenen erzeugen und „Übernehmen“, oder Material auf eine Spur ziehen.',
              'Nothing in the edit yet. Generate scenes and "Conform", or drag media onto a track.')}
          </div>
        )}
      </div>
      </div>
      <div className="st-monitor-bar">
        <span className="st-timecode">{timecode(time, p.settings.fps)}</span>
        <span className="muted small">/ {timecode(p.edit_duration, p.settings.fps)}</span>
        <span className="muted small st-format">
          {p.settings.width} × {p.settings.height} · {(p.settings.fps[0] / p.settings.fps[1]).toFixed(p.settings.fps[1] === 1 ? 0 : 2)} fps
        </span>
      </div>
    </div>
  )
}
