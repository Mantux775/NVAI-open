// Programmmonitor: spielt die Schnitt-Zeitleiste im Browser ab. Der Browser dekodiert in Hardware; jeder sichtbare
// Clip hat ein eigenes Video-Element, der nächste wird kurz vor dem Schnitt geladen (so laufen Schnitte ohne Lücke),
// bei Überblendungen spielen beide mit wechselnder Deckkraft und Lautstärke. Eine eigene Uhr führt den Abspielkopf;
// die Medien werden nur nachgezogen, wenn sie mehr als eine Viertelsekunde abweichen (wie FilmCraft: das Bild folgt
// der Uhr, nicht umgekehrt). Der fertige Export rechnet das Gleiche genau (studio_render.py), auch beim Einpassen:
// Bei fast gleichem Seitenverhältnis füllt das Bild den Rahmen (LTX-2.5 rechnet 1080p als 1920 × 1088).
// Ein Klick im Material macht ihn zum Quellmonitor: Das Asset läuft mit eigenen Bedienelementen, bis wieder etwas im
// Schnitt gewählt wird.

import { useEffect, useRef, type CSSProperties } from 'react'
import { api, TPS, type Asset, type StudioClip, type StudioProject } from '../api'
import { t } from '../i18n'
import { assetFacts, assetLabel, mediaKind, previewUrl } from './Bin'
import { clipAt, previousClip, sec, timecode } from './time'

interface Props {
  project: StudioProject
  playhead: number
  playing: boolean
  onPlayhead: (t: number) => void
  onStop: () => void
  /** Angeklicktes Material: der Monitor zeigt dann dieses statt des Schnitts */
  source: Asset | null
  onCloseSource: () => void
}

const COVER_TOLERANCE = 0.05

interface Layer {
  clip: StudioClip
  mediaTime: number // Sekunden im Material
  opacity: number
  volume: number
}

const PRELOAD = 2 * TPS

/** Was zur Zeit t zu sehen und zu hören ist; V1 unten, V2 darüber, Ton von allen Spuren. */
function layersAt(p: StudioProject, t: number): Layer[] {
  const out: Layer[] = []
  for (const track of ['V1', 'V2', 'A1', 'A2']) {
    const c = clipAt(p, track, t)
    if (!c) continue
    const local = t - c.start
    let alpha = 1
    if (c.transition && local < c.transition.duration) {
      alpha = local / c.transition.duration
      const prev = previousClip(p, c)
      if (prev) {
        out.push({ clip: prev, mediaTime: sec(prev.out + local), opacity: 1, volume: 1 - alpha })
      }
    }
    out.push({ clip: c, mediaTime: sec(c.in + local), opacity: track.startsWith('V') ? alpha : 1, volume: alpha })
  }
  return out
}

/** Clips, die gleich beginnen: schon laden, damit der Schnitt sitzt. */
function upcoming(p: StudioProject, t: number): StudioClip[] {
  return p.clips.filter((c) => c.start > t && c.start - t < PRELOAD)
}

const gain = (db: number) => Math.min(1, Math.pow(10, db / 20))

export function Monitor({ project, playhead, playing, onPlayhead, onStop, source, onCloseSource }: Props) {
  const els = useRef(new Map<string, HTMLMediaElement>())
  const clock = useRef({ wall: 0, tick: 0 })
  const now = useRef(playhead)
  const p = project
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
    const layers = layersAt(p, time)
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
      if (el instanceof HTMLVideoElement) el.style.opacity = String(layer.opacity)
      el.muted = layer.clip.muted
      el.volume = Math.max(0, Math.min(1, gain(layer.clip.gain_db) * layer.volume))
      const drift = Math.abs(el.currentTime - layer.mediaTime)
      if (isPlaying) {
        if (el.paused) el.play().catch(() => {})
        if (drift > 0.25) el.currentTime = layer.mediaTime
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
  const layers = layersAt(p, time)
  const mounted = new Map<string, StudioClip>()
  for (const l of layers) mounted.set(l.clip.id, l.clip)
  for (const c of upcoming(p, time)) mounted.set(c.id, c)
  const visual = layers.filter((l) => l.clip.track.startsWith('V'))
  const ratio = p.settings.width / p.settings.height

  return (
    <div className="st-monitor">
      <div className="st-stage">
      <div className="st-screen" style={{ '--ar': ratio } as CSSProperties}>
        {[...mounted.values()].map((c, i) => {
          const kind = kindOf(c)
          const z = c.track === 'V2' ? 20 + i : 10 + i
          const visible = visual.find((l) => l.clip.id === c.id)
          if (kind === 'image') {
            return visible ? (
              <img key={c.id} src={urlOf(c)} alt="" style={{ opacity: visible.opacity, zIndex: z, objectFit: fitOf(c) }} draggable={false} />
            ) : null
          }
          if (kind === 'audio' || c.track.startsWith('A')) {
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
              style={{ opacity: visible ? visible.opacity : 0, zIndex: z, objectFit: fitOf(c) }}
              ref={(el) => {
                if (el) els.current.set(c.id, el)
                else els.current.delete(c.id)
              }}
            />
          )
        })}
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
