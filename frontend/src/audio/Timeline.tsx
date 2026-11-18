import { useEffect, useRef, useState } from 'react'
import type { AudioMarker, AudioTrack } from '../api'
import { t } from '../i18n'
import type { Peaks } from './peaks'

// Zeitstrahl des Bereichs „Audio“: Lineal, Marken, Spuren mit Wellenform, Auswahl, Abspielkopf und eine Übersicht der
// ganzen Aufnahme (auch bei Stunden). Ziehen wählt aus, Klicken setzt den Abspielkopf, Strg + Mausrad zoomt,
// Umschalt + Mausrad verschiebt.

export function fmtClock(s: number, tenths = false): string {
  if (!Number.isFinite(s)) return '–'
  const neg = s < 0
  s = Math.abs(s)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const ss = tenths ? sec.toFixed(1).padStart(4, '0') : String(Math.floor(sec)).padStart(2, '0')
  return `${neg ? '−' : ''}${h ? `${h}:${String(m).padStart(2, '0')}` : m}:${ss}`
}

const STEPS = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
const MARK_COLOR: Record<string, string> = { noise: '#ff6b6b', keep: '#76b900', note: '#7cc4ff' }

function useWidth(): [React.RefObject<HTMLDivElement | null>, number] {
  const ref = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(800)
  useEffect(() => {
    if (!ref.current) return
    const ro = new ResizeObserver((e) => setW(Math.max(100, Math.floor(e[0].contentRect.width))))
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [])
  return [ref, w]
}

function Lane({ peaks, t0, t1, offset, color, width, height, sr, dim }: {
  peaks: Peaks | undefined
  t0: number
  t1: number
  offset: number
  color: string
  width: number
  height: number
  sr: number
  dim: boolean
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const c = ref.current
    if (!c) return
    const dpr = window.devicePixelRatio || 1
    c.width = Math.floor(width * dpr)
    c.height = Math.floor(height * dpr)
    const g = c.getContext('2d')
    if (!g) return
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, width, height)
    const mid = height / 2
    g.fillStyle = 'rgba(230,235,240,0.08)'
    g.fillRect(0, mid, width, 1)
    if (!peaks) return
    const cols = peaks.columns(t0 - offset, t1 - offset, width, sr)
    g.fillStyle = color
    g.globalAlpha = dim ? 0.3 : 0.9
    for (let x = 0; x < width; x++) {
      const mn = cols[2 * x], mx = cols[2 * x + 1]
      if (mn === 0 && mx === 0) continue
      const y0 = mid - mx * (mid - 2)
      const y1 = mid - mn * (mid - 2)
      g.fillRect(x, y0, 1, Math.max(1, y1 - y0))
    }
  }, [peaks, t0, t1, offset, color, width, height, sr, dim])
  return <canvas ref={ref} style={{ width, height, display: 'block' }} />
}

export function Timeline({ tracks, peaks, sr, duration, view, setView, selection, setSelection, playhead, onSeek, markers,
  onMarkerSelect, onMarkerDelete, onTrack, onTrackDelete, busyTrack }: {
  tracks: AudioTrack[]
  peaks: Record<string, Peaks | undefined>
  sr: number
  duration: number
  view: [number, number]
  setView: (v: [number, number]) => void
  selection: [number, number] | null
  setSelection: (s: [number, number] | null) => void
  playhead: number
  onSeek: (t: number) => void
  markers: AudioMarker[]
  onMarkerSelect: (m: AudioMarker) => void
  onMarkerDelete: (m: AudioMarker) => void
  onTrack: (id: string, fields: Partial<AudioTrack>) => void
  onTrackDelete: (id: string) => void
  busyTrack?: string | null
}) {
  const [box, width] = useWidth()
  const [t0, t1] = view
  const span = Math.max(0.05, t1 - t0)
  const drag = useRef<{ start: number; x: number; moved: boolean } | null>(null)
  const anySolo = tracks.some((tr) => tr.solo)
  const toX = (time: number) => ((time - t0) / span) * width
  const toT = (x: number) => t0 + (x / width) * span

  const clampView = (a: number, b: number): [number, number] => {
    const len = Math.min(Math.max(0.2, b - a), Math.max(0.2, duration))
    let s = Math.max(0, a)
    if (s + len > duration) s = Math.max(0, duration - len)
    return [s, s + len]
  }
  const onWheel = (e: React.WheelEvent) => {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault()
      const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
      const at = toT(e.clientX - rect.left)
      const f = e.deltaY > 0 ? 1.25 : 0.8
      setView(clampView(at - (at - t0) * f, at + (t1 - at) * f))
    } else if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      const d = (e.shiftKey ? e.deltaY : e.deltaX) / width * span
      setView(clampView(t0 + d, t1 + d))
    }
  }
  const onDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
    drag.current = { start: toT(e.clientX - rect.left), x: e.clientX, moved: false }
    const move = (ev: MouseEvent) => {
      if (!drag.current) return
      if (Math.abs(ev.clientX - drag.current.x) > 3) drag.current.moved = true
      if (drag.current.moved) {
        const cur = Math.max(0, Math.min(duration, toT(ev.clientX - rect.left)))
        setSelection([Math.min(drag.current.start, cur), Math.max(drag.current.start, cur)])
      }
    }
    const up = (ev: MouseEvent) => {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
      if (drag.current && !drag.current.moved) {
        onSeek(Math.max(0, Math.min(duration, toT(ev.clientX - rect.left))))
        setSelection(null)
      }
      drag.current = null
    }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }

  // Lineal: Schritt so, dass Beschriftungen rund 110 px auseinanderliegen
  const step = STEPS.find((s) => (s / span) * width >= 110) ?? 3600
  const ticks: number[] = []
  for (let x = Math.ceil(t0 / step) * step; x <= t1; x += step) ticks.push(x)
  const ov = tracks.find((tr) => tr.kind === 'original') ?? tracks[0]

  return (
    <div className="au-tl">
      <div className="au-tl-row au-tl-ruler-row">
        <div className="au-tl-head au-tl-corner">
          <span className="muted small">{fmtClock(t0)} – {fmtClock(t1)}</span>
        </div>
        <div className="au-tl-ruler" ref={box} onMouseDown={onDown} onWheel={onWheel}>
          {ticks.map((x) => (
            <span key={x} className="au-tick" style={{ left: toX(x) }}>{fmtClock(x, step < 1)}</span>
          ))}
          {markers.map((m) => (
            <span key={m.id} className={`au-mark ${m.kind}`} style={{ left: toX(m.start), width: Math.max(3, toX(m.end) - toX(m.start)), background: MARK_COLOR[m.kind] }}
              title={`${m.label || m.kind} · ${fmtClock(m.start, true)} – ${fmtClock(m.end, true)}`}
              onMouseDown={(e) => { e.stopPropagation(); onMarkerSelect(m) }}
              onDoubleClick={(e) => { e.stopPropagation(); onMarkerDelete(m) }} />
          ))}
        </div>
      </div>
      {tracks.map((tr) => {
        const audible = anySolo ? tr.solo : !tr.mute
        return (
          <div key={tr.id} className={`au-tl-row${busyTrack === tr.id ? ' busy' : ''}`}>
            <div className="au-tl-head" style={{ borderLeftColor: tr.color }}>
              <div className="au-tl-name" title={tr.name}>{tr.name}</div>
              <div className="au-tl-ctl">
                <button className={`au-ms${tr.mute ? ' on' : ''}`} title={t('stumm', 'mute')} onClick={() => onTrack(tr.id, { mute: !tr.mute })}>M</button>
                <button className={`au-ms solo${tr.solo ? ' on' : ''}`} title={t('nur diese', 'solo')} onClick={() => onTrack(tr.id, { solo: !tr.solo })}>S</button>
                <input type="range" min={-30} max={12} step={0.5} value={tr.gain_db} title={`${tr.gain_db.toFixed(1)} dB`}
                  onChange={(e) => onTrack(tr.id, { gain_db: Number(e.target.value) })} />
                <span className="muted small au-db">{tr.gain_db > 0 ? '+' : ''}{tr.gain_db.toFixed(1)}</span>
                {tr.kind !== 'original' && (
                  <button className="au-x" title={t('Spur löschen', 'delete track')} onClick={() => onTrackDelete(tr.id)}>✕</button>
                )}
              </div>
            </div>
            <div className="au-lane" onMouseDown={onDown} onWheel={onWheel}>
              <Lane peaks={peaks[tr.id]} t0={t0} t1={t1} offset={tr.offset || 0} color={tr.color} width={width} height={70} sr={sr} dim={!audible} />
            </div>
          </div>
        )
      })}
      <div className="au-overlay" style={{ left: 'var(--au-head)', width }}>
        {selection && selection[1] > t0 && selection[0] < t1 && (
          <div className="au-sel" style={{ left: Math.max(0, toX(selection[0])), width: Math.min(width, toX(selection[1])) - Math.max(0, toX(selection[0])) }} />
        )}
        {playhead >= t0 && playhead <= t1 && <div className="au-head-line" style={{ left: toX(playhead) }} />}
      </div>
      <Overview peaks={ov ? peaks[ov.id] : undefined} sr={sr} duration={duration} view={view} width={width}
        onView={(a) => setView(clampView(a, a + span))} playhead={playhead} selection={selection} />
    </div>
  )
}

function Overview({ peaks, sr, duration, view, width, onView, playhead, selection }: {
  peaks: Peaks | undefined
  sr: number
  duration: number
  view: [number, number]
  width: number
  onView: (start: number) => void
  playhead: number
  selection: [number, number] | null
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const H = 34
  useEffect(() => {
    const c = ref.current
    if (!c) return
    const dpr = window.devicePixelRatio || 1
    c.width = Math.floor(width * dpr)
    c.height = H * dpr
    const g = c.getContext('2d')
    if (!g) return
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, width, H)
    if (!peaks || !duration) return
    const cols = peaks.columns(0, duration, width, sr)
    g.fillStyle = 'rgba(230,235,240,0.35)'
    for (let x = 0; x < width; x++) {
      const y0 = H / 2 - cols[2 * x + 1] * (H / 2 - 1)
      const y1 = H / 2 - cols[2 * x] * (H / 2 - 1)
      g.fillRect(x, y0, 1, Math.max(1, y1 - y0))
    }
  }, [peaks, sr, duration, width])
  const k = duration ? width / duration : 0
  const drag = (e: React.MouseEvent) => {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
    const len = view[1] - view[0]
    const go = (cx: number) => onView(Math.max(0, (cx - rect.left) / Math.max(1, k) - len / 2))
    go(e.clientX)
    const move = (ev: MouseEvent) => go(ev.clientX)
    const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up) }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }
  return (
    <div className="au-tl-row au-ov-row">
      <div className="au-tl-head au-tl-corner"><span className="muted small">{t('Übersicht', 'Overview')} · {fmtClock(duration)}</span></div>
      <div className="au-ov" onMouseDown={drag} title={t('Ziehen verschiebt den Ausschnitt', 'Drag to move the view')}>
        <canvas ref={ref} style={{ width, height: H, display: 'block' }} />
        {selection && <div className="au-ov-sel" style={{ left: selection[0] * k, width: Math.max(2, (selection[1] - selection[0]) * k) }} />}
        <div className="au-ov-view" style={{ left: view[0] * k, width: Math.max(4, (view[1] - view[0]) * k) }} />
        <div className="au-ov-head" style={{ left: playhead * k }} />
      </div>
    </div>
  )
}
