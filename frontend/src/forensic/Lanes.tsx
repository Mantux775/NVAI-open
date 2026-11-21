import { useEffect, useRef, useState } from 'react'
import type { AudioMarker, AudioTrack, TranscriptSegment, VdrEvent, VdrSeries } from '../api'
import { fmtClock } from '../audio/Timeline'
import type { Peaks } from '../audio/peaks'
import { t } from '../i18n'
import { loadActivity, paintSpec, specColumns } from './spectro'

// Zeitstrahl der Ton-Forensik (seit 17.11.2026 abends): Lineal mit Marken, dann Spuren übereinander wie im Studio:
// Ereignisse (Alarme, Türen, Maschine), Übersetzer-Spur (Satzblöcke, je Block Original oder Übersetzung),
// Sprachaktivität je Kanal, Tonspuren (Wellenform, Spektrogramm oder beides) und Datenspuren (Kurs, Geschwindigkeit, Ruder …).
// Ziehen wählt aus, Klicken setzt den Abspielkopf, Strg + Mausrad zoomt, Umschalt + Mausrad verschiebt.

export type TrackView = 'wave' | 'spec' | 'both'
/** Rechtsklick im Zeitstrahl: wo und auf was (Workspace baut daraus das Menü) */
export interface LaneContext {
  time: number
  kind: 'lane' | 'track' | 'head' | 'segment' | 'note' | 'event'
  track?: AudioTrack
  segment?: TranscriptSegment
  note?: AudioMarker
  event?: VdrEvent
}
export const HEAD_WIDTH = 275
export interface LaneState {
  /** sichtbare Tonspuren und ihre Darstellung */
  view: Record<string, TrackView>
  hidden: Record<string, boolean>
  height: number
  /** Datenspuren (Schlüssel aus series.json) */
  data: string[]
  events: boolean
  transcript: boolean
  activity: boolean
  /** Spektrogramm: dB-Fenster und oberste Frequenz */
  specLo: number
  specHi: number
  specFmax: number
  /** Verteilung im Kopfhörer je Spur: −1 links, 0 Mitte, 1 rechts */
  pan?: Record<string, number>
  /** Notizen-Spur ganz oben */
  notes?: boolean
}

const STEPS = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
const MARK_COLOR: Record<string, string> = { noise: '#ff6b6b', keep: '#76b900', note: '#7cc4ff' }
/** Deutsche Namen der Messreihen, die schon eingelesene Fälle noch anders in ihrer series.json tragen (Nutzer 17.11.:
 * „fahrt über grund ist misführend, dann wie im english Geschwindigkeit über…“). Die Datei des Falls bleibt unverändert. */
const SERIES_DE: Record<string, string> = { sog: 'Geschwindigkeit über Grund', stw: 'Geschwindigkeit durchs Wasser' }
export function seriesLabel(key: string, s: { label_de: string; label_en: string }): string {
  return t(SERIES_DE[key] ?? s.label_de, s.label_en)
}

export const EVENT_COLOR: Record<string, string> = {
  alarm: '#ff5d5d', alert: '#ff8a5d', digital: '#ffc857', analog: '#e0c060', telegraph: '#7cc4ff', autopilot: '#9ad0ff',
  ais: '#b39ddb', text: '#c8c8c8', gap: '#777', system: '#999', tone: '#ff8fab',
}

/** Ereignisarten in der Sprache der Oberfläche (vorher erschienen die Schlüssel roh: alarm, digital, gap …) */
export const EVENT_LABEL: Record<string, string> = {
  alarm: t('Alarm', 'alarm'), alert: t('Warnung', 'alert'), digital: t('Digital', 'digital'), analog: t('Analog', 'analog'),
  telegraph: t('Maschinentelegraf', 'telegraph'), autopilot: t('Autopilot', 'autopilot'), ais: 'AIS', text: t('Text', 'text'),
  gap: t('Lücke', 'gap'), system: t('System', 'system'), tone: t('Ton', 'tone'),
}

/** Uhrzeit (UTC) zu Sekunde x, wenn die Aufnahme einen Zeitbezug hat, sonst Laufzeit */
export function clockAt(x: number, origin: number | null | undefined, tenths = false): string {
  if (!origin) return fmtClock(x, tenths)
  const d = new Date((origin + x) * 1000)
  const p = (n: number) => String(n).padStart(2, '0')
  const base = `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`
  return tenths ? `${base}.${Math.floor((d.getUTCMilliseconds()) / 100)}` : base
}

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

function Wave({ peaks, t0, t1, offset, color, width, height, sr, dim }: {
  peaks: Peaks | undefined; t0: number; t1: number; offset: number; color: string; width: number; height: number; sr: number; dim: boolean
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
      const y0 = mid - mx * (mid - 1)
      const y1 = mid - mn * (mid - 1)
      g.fillRect(x, y0, 1, Math.max(1, y1 - y0))
    }
  }, [peaks, t0, t1, offset, color, width, height, sr, dim])
  return <canvas ref={ref} style={{ width, height, display: 'block' }} />
}

function Spec({ pid, tr, t0, t1, width, height, lo, hi, fshow }: {
  pid: string; tr: AudioTrack; t0: number; t1: number; width: number; height: number; lo: number; hi: number; fshow: number
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const [missing, setMissing] = useState(false)
  useEffect(() => {
    let alive = true
    const c = ref.current
    if (!c || !tr.spec) return
    c.width = width
    c.height = height
    const off = tr.offset || 0
    const timer = window.setTimeout(() => {
      specColumns(pid, tr, t0 - off, t1 - off, width).then((v) => {
        if (!alive || !v) return
        const g = c.getContext('2d')
        if (g) paintSpec(g, v, height, tr.spec!.fmax, Math.min(fshow, tr.spec!.fmax), lo, hi)
        setMissing(false)
      }).catch(() => { if (alive) setMissing(true) })
    }, 60)
    return () => { alive = false; window.clearTimeout(timer) }
  }, [pid, tr, t0, t1, width, height, lo, hi, fshow])
  if (!tr.spec) return <div className="fx-spec-empty" style={{ height }}>{t('Kein Spektrogramm: in der Spur auf „Spektrogramm“ klicken.', 'No spectrogram: click “Spectrogram” in the track header.')}</div>
  return (
    <div className="fx-spec" style={{ height }}>
      <canvas ref={ref} style={{ width, height, display: 'block' }} />
      <span className="fx-spec-scale">{(Math.min(fshow, tr.spec.fmax) / 1000).toFixed(1)} kHz</span>
      {missing && <span className="fx-spec-scale bottom">{t('lädt …', 'loading …')}</span>}
    </div>
  )
}

function Activity({ pid, tracks, t0, t1, width }: { pid: string; tracks: AudioTrack[]; t0: number; t1: number; width: number }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const [data, setData] = useState<Record<string, Uint8Array>>({})
  const list = tracks.filter((x) => x.vad || x.activity)
  const key = list.map((x) => `${x.id}:${x.vad?.time ?? x.activity?.segments}`).join(',')
  useEffect(() => {
    let alive = true
    for (const tr of list) {
      loadActivity(pid, tr.id, Math.round(tr.vad?.time ?? tr.activity?.segments ?? 0), !!tr.vad)
        .then((a) => { if (alive) setData((d) => ({ ...d, [tr.id]: a })) }).catch(() => {})
    }
    return () => { alive = false }
  }, [pid, key]) // eslint-disable-line react-hooks/exhaustive-deps
  const row = 9
  const height = Math.max(row, list.length * row)
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
    list.forEach((tr, i) => {
      const a = data[tr.id]
      if (!a) return
      const off = tr.offset || 0
      g.fillStyle = tr.color
      for (let x = 0; x < width; x++) {
        const a0 = Math.floor((t0 + ((t1 - t0) * x) / width - off) * 10)
        const a1 = Math.max(a0 + 1, Math.floor((t0 + ((t1 - t0) * (x + 1)) / width - off) * 10))
        let m = 0
        for (let k = Math.max(0, a0); k < Math.min(a.length, a1); k++) if (a[k] > m) m = a[k]
        if (m < (tr.vad ? 128 : 60)) continue
        g.globalAlpha = Math.min(1, m / 255 + 0.15)
        g.fillRect(x, i * row + 1, 1, row - 2)
      }
    })
    g.globalAlpha = 1
  }, [data, t0, t1, width, height, key]) // eslint-disable-line react-hooks/exhaustive-deps
  if (!list.length) return <div className="fx-empty-lane">{t('Noch keine Sprachaktivität: links „Sprache finden“ (Silero VAD).', 'No speech activity yet: “Find speech” on the left (Silero VAD).')}</div>
  return <canvas ref={ref} style={{ width, height, display: 'block' }} />
}

function DataLane({ s, t0, t1, width, height, origin }: {
  s: VdrSeries['series'][string]; t0: number; t1: number; width: number; height: number; origin: number | null | undefined
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const [hover, setHover] = useState<{ x: number; v: number | null; time: number } | null>(null)
  const vals = s.values
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
    const i0 = Math.max(0, Math.floor(t0))
    const i1 = Math.min(vals.length, Math.ceil(t1) + 1)
    let lo = Infinity, hi = -Infinity
    for (let i = i0; i < i1; i++) {
      const v = vals[i]
      if (v == null) continue
      if (v < lo) lo = v
      if (v > hi) hi = v
    }
    if (!Number.isFinite(lo)) return
    if (hi - lo < 1e-6) { lo -= 1; hi += 1 }
    const pad = (hi - lo) * 0.08
    lo -= pad; hi += pad
    const y = (v: number) => height - 2 - ((v - lo) / (hi - lo)) * (height - 4)
    g.strokeStyle = '#7cc4ff'
    g.fillStyle = 'rgba(124,196,255,0.25)'
    g.lineWidth = 1.5
    g.beginPath()
    let pen = false
    for (let x = 0; x < width; x++) {
      const a = Math.floor(t0 + ((t1 - t0) * x) / width)
      const b = Math.max(a + 1, Math.floor(t0 + ((t1 - t0) * (x + 1)) / width))
      let mn = Infinity, mx = -Infinity
      for (let i = Math.max(0, a); i < Math.min(vals.length, b); i++) {
        const v = vals[i]
        if (v == null) continue
        if (v < mn) mn = v
        if (v > mx) mx = v
      }
      if (!Number.isFinite(mn)) { pen = false; continue }
      if (mx - mn > (hi - lo) * 0.02) g.fillRect(x, y(mx), 1, Math.max(1, y(mn) - y(mx)))
      const v = (mn + mx) / 2
      if (pen) g.lineTo(x + 0.5, y(v)); else { g.moveTo(x + 0.5, y(v)); pen = true }
    }
    g.stroke()
    g.fillStyle = 'rgba(230,235,240,0.55)'
    g.font = '10px system-ui'
    g.fillText(`${(hi - pad).toFixed(1)}`, 3, 10)
    g.fillText(`${(lo + pad).toFixed(1)}`, 3, height - 3)
  }, [vals, t0, t1, width, height])
  return (
    <div className="fx-data" onMouseMove={(e) => {
      const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
      const x = e.clientX - rect.left
      const time = t0 + ((t1 - t0) * x) / width
      setHover({ x, v: vals[Math.floor(time)] ?? null, time })
    }} onMouseLeave={() => setHover(null)}>
      <canvas ref={ref} style={{ width, height, display: 'block' }} />
      {hover && (
        <span className="fx-data-tip" style={{ left: Math.min(width - 150, hover.x + 8) }}>
          {clockAt(hover.time, origin)} · {hover.v == null ? '–' : `${Number(hover.v.toFixed(2))} ${s.unit}`}
        </span>
      )}
    </div>
  )
}

/** Ab so vielen sichtbaren Blöcken zeichnet die Übersetzer-Spur auf einem Canvas */
const SEG_DENSE = 300

function segColor(s: TranscriptSegment): string {
  const unsure = s.origin === 'ai' && /low_confidence|repetition/.test(s.note || '')
  const a = unsure ? 0.45 : 0.85
  if (s.status === 'checked') return `rgba(118, 185, 0, ${a})`
  if (s.kind === 'sound') return `rgba(255, 143, 171, ${a})`
  if (s.kind === 'radio') return `rgba(124, 196, 255, ${a})`
  return `rgba(255, 209, 102, ${a})`
}

/** Übersicht der Übersetzer-Spur: jeder Block ein Strich (mindestens 1 px), Farben wie die Kästchen; Klick wählt den
 * Block unter dem Zeiger (sonst wie ein Klick in die Spur), Rechtsklick öffnet sein Menü. */
function SegOverview({ segs, t0, t1, width, selected, onPick, onContext }: {
  segs: TranscriptSegment[]
  t0: number
  t1: number
  width: number
  selected: string | null | undefined
  onPick: (s: TranscriptSegment) => void
  onContext: (s: TranscriptSegment, e: React.MouseEvent) => void
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const c = ref.current
    if (!c || width <= 0 || t1 <= t0) return
    const dpr = window.devicePixelRatio || 1
    const h = c.clientHeight || 40
    c.width = Math.round(width * dpr)
    c.height = Math.round(h * dpr)
    const g = c.getContext('2d')
    if (!g) return
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, width, h)
    const sx = width / (t1 - t0)
    let sel: [number, number] | null = null
    for (const s of segs) {
      const x0 = Math.max(0, (s.start - t0) * sx)
      const x1 = Math.min(width, (s.end - t0) * sx)
      g.fillStyle = segColor(s)
      g.fillRect(x0, 5, Math.max(1, x1 - x0), h - 10)
      if (s.id === selected) sel = [x0, Math.max(1, x1 - x0)]
    }
    if (sel) {
      g.strokeStyle = '#fff'
      g.lineWidth = 2
      g.strokeRect(sel[0] - 1, 3, sel[1] + 2, h - 6)
    }
  }, [segs, t0, t1, width, selected])
  const hit = (e: React.MouseEvent): TranscriptSegment | null => {
    const r = (e.currentTarget as HTMLCanvasElement).getBoundingClientRect()
    const x = e.clientX - r.left
    const sx = width / (t1 - t0)
    let best: TranscriptSegment | null = null
    let dist = 4 // Pixel Spielraum für schmale Striche
    for (const s of segs) {
      const x0 = (s.start - t0) * sx
      const x1 = Math.max(x0 + 1, (s.end - t0) * sx)
      const d = x < x0 ? x0 - x : x > x1 ? x - x1 : 0
      if (d < dist || (d === 0 && dist === 0)) {
        dist = d
        best = s
      }
    }
    return best
  }
  return (
    <canvas ref={ref} className="fx-seg-canvas" style={{ width, height: '100%' }}
      onMouseDown={(e) => { const s = hit(e); if (s) { e.stopPropagation(); onPick(s) } }}
      onContextMenu={(e) => { const s = hit(e); if (s) { e.stopPropagation(); onContext(s, e) } }} />
  )
}

export function ForensicLanes({ pid, tracks, peaks, sr, duration, view, setView, selection, setSelection, playhead, onSeek,
  markers, onMarkerSelect, onMarkerDelete, onTrack, onTrackDelete, onSpectro, lanes, setLanes, origin, segments, showTranslation,
  targetLang, flipped, onFlip, onSegment, selectedSegment, events, onEvent, series, busyTracks, blind, headWidth, onHeadWidth,
  onContext, onNoteEdit }: {
  pid: string
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
  onSpectro: (id: string) => void
  lanes: LaneState
  setLanes: (fn: (l: LaneState) => LaneState) => void
  origin: number | null | undefined
  segments: TranscriptSegment[]
  showTranslation: boolean
  targetLang: string
  flipped: Record<string, boolean>
  onFlip: (id: string) => void
  onSegment: (s: TranscriptSegment) => void
  selectedSegment: string | null
  events: VdrEvent[]
  onEvent: (e: VdrEvent) => void
  series: VdrSeries | null
  busyTracks: Set<string>
  /** Blind hören: Text der KI (Entwurf) ausblenden, damit er das Hören nicht lenkt */
  blind?: boolean
  /** Breite der Spurköpfe links (ziehbar, Nutzer 17.11.: „sollte breiter sein (+10 %) und die breite einstellen lassen“) */
  headWidth: number
  onHeadWidth: (w: number) => void
  onContext: (e: React.MouseEvent, ctx: LaneContext) => void
  onNoteEdit: (m: AudioMarker) => void
}) {
  const [box, width] = useWidth()
  const root = useRef<HTMLDivElement>(null)
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
  // Mausrad: Strg + Rad zoomt um die Mausstelle, Umschalt + Rad (oder seitlich) verschiebt. Als eigener, nicht passiver
  // Listener: Reacts onWheel ist passiv, preventDefault wirkte nicht und der Browser zoomte die ganze Seite.
  const wheelState = useRef({ t0, t1, width, duration, setView })
  wheelState.current = { t0, t1, width, duration, setView }
  useEffect(() => {
    const el = root.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      const st = wheelState.current
      const spanNow = Math.max(0.05, st.t1 - st.t0)
      const clamp = (a: number, b: number): [number, number] => {
        const len = Math.min(Math.max(0.2, b - a), Math.max(0.2, st.duration))
        let s0 = Math.max(0, a)
        if (s0 + len > st.duration) s0 = Math.max(0, st.duration - len)
        return [s0, s0 + len]
      }
      const left = box.current?.getBoundingClientRect().left ?? 0
      const x = e.clientX - left
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault()
        const at = x >= 0 && x <= st.width ? st.t0 + (x / st.width) * spanNow : (st.t0 + st.t1) / 2
        const f = e.deltaY > 0 ? 1.25 : 0.8
        st.setView(clamp(at - (at - st.t0) * f, at + (st.t1 - at) * f))
      } else if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
        e.preventDefault()
        const d = ((e.shiftKey ? e.deltaY : e.deltaX) / st.width) * spanNow
        st.setView(clamp(st.t0 + d, st.t1 + d))
      }
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [box])
  const timeAt = (e: React.MouseEvent) => {
    const left = box.current?.getBoundingClientRect().left ?? 0
    return Math.max(0, Math.min(duration, toT(e.clientX - left)))
  }
  const ctx = (kind: LaneContext['kind'], extra: Partial<LaneContext> = {}) => (e: React.MouseEvent) => {
    e.preventDefault()
    e.stopPropagation()
    onContext(e, { time: timeAt(e), kind, ...extra })
  }
  const dragHead = (e: React.PointerEvent) => {
    const startX = e.clientX
    const startW = headWidth
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const move = (ev: PointerEvent) => onHeadWidth(Math.round(Math.max(170, Math.min(520, startW + ev.clientX - startX))))
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up) }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
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

  const step = STEPS.find((s) => (s / span) * width >= 110) ?? 7200
  const ticks: number[] = []
  if (origin) {
    // Striche auf runden Uhrzeiten (UTC)
    const first = Math.ceil((origin + t0) / step) * step - origin
    for (let x = first; x <= t1; x += step) ticks.push(x)
  } else {
    for (let x = Math.ceil(t0 / step) * step; x <= t1; x += step) ticks.push(x)
  }
  const visibleSegs = segments.filter((s) => s.end >= t0 && s.start <= t1)
  // viele Blöcke im Bild: alle als Striche auf einem Canvas statt der ersten 600 als Kästchen
  const denseSegs = visibleSegs.length > SEG_DENSE
  const visibleEvents = events.filter((e) => (e.end ?? e.t) >= t0 && e.t <= t1)
  const h = lanes.height
  const audioTracks = tracks.filter((tr) => !lanes.hidden[tr.id])
  const ov = tracks.find((tr) => tr.kind === 'original') ?? tracks[0]

  return (
    <div className="au-tl fx-lanes" ref={root} style={{ ['--au-head' as string]: `${headWidth}px` } as React.CSSProperties}>
      <div className="fx-headsplit" style={{ left: headWidth - 3 }} onPointerDown={dragHead} onDoubleClick={() => onHeadWidth(HEAD_WIDTH)}
        title={t('Ziehen: Breite der Spurköpfe; Doppelklick: zurücksetzen', 'Drag: width of the track headers; double-click: reset')} />
      <div className="au-tl-row au-tl-ruler-row">
        <div className="au-tl-head au-tl-corner">
          <span className="muted small">{clockAt(t0, origin)} – {clockAt(t1, origin)}{origin ? ' UTC' : ''}</span>
        </div>
        <div className="au-tl-ruler" ref={box} onMouseDown={onDown} onContextMenu={ctx('lane')}>
          {ticks.map((x) => (
            <span key={x} className="au-tick" style={{ left: toX(x) }}>{clockAt(x, origin, step < 1)}</span>
          ))}
          {markers.filter((m) => m.kind !== 'note').map((m) => (
            <span key={m.id} className={`au-mark ${m.kind}`} style={{ left: toX(m.start), width: Math.max(3, toX(m.end) - toX(m.start)), background: MARK_COLOR[m.kind] }}
              title={`${m.label || (EVENT_LABEL[m.kind] ?? m.kind)} · ${clockAt(m.start, origin, true)} – ${clockAt(m.end, origin, true)}`}
              onMouseDown={(e) => { e.stopPropagation(); onMarkerSelect(m) }}
              onDoubleClick={(e) => { e.stopPropagation(); onMarkerDelete(m) }} />
          ))}
        </div>
      </div>

      {(lanes.notes ?? true) && (
        <div className="au-tl-row fx-row-notes">
          <div className="au-tl-head fx-lane-head" onContextMenu={ctx('head')}><span className="au-tl-name">{t('Notizen', 'Notes')}</span>
            <span className="muted small">{markers.filter((m) => m.kind === 'note').length}</span></div>
          <div className="au-lane fx-notes" onMouseDown={onDown} onContextMenu={ctx('lane')}>
            {markers.filter((m) => m.kind === 'note' && m.end >= t0 && m.start <= t1).slice(0, 800).map((m) => {
              const x0 = toX(m.start)
              const x1 = Math.max(x0 + 3, toX(m.end))
              return (
                <div key={m.id} className="fx-note" style={{ left: Math.max(0, x0), width: Math.max(3, Math.min(width, x1) - Math.max(0, x0)) }}
                  title={`${clockAt(m.start, origin, true)}${m.end > m.start ? ` – ${clockAt(m.end, origin, true)}` : ''}${m.author ? ` · ${m.author}` : ''}\n${m.label || t('(ohne Text)', '(no text)')}`}
                  onMouseDown={(e) => { e.stopPropagation(); onMarkerSelect(m) }}
                  onDoubleClick={(e) => { e.stopPropagation(); onNoteEdit(m) }}
                  onContextMenu={ctx('note', { note: m })}>
                  {x1 - x0 > 30 && <span className="fx-note-text">{m.label || '…'}</span>}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {lanes.events && (
        <div className="au-tl-row fx-row-events">
          <div className="au-tl-head fx-lane-head"><span className="au-tl-name">{t('Ereignisse', 'Events')}</span>
            <span className="muted small">{events.length}</span></div>
          <div className="au-lane fx-events" onMouseDown={onDown} onContextMenu={ctx('lane')}>
            {visibleEvents.length > 1500
              ? <span className="muted small fx-lane-note">{t(`${visibleEvents.length} Ereignisse: näher heranzoomen`, `${visibleEvents.length} events: zoom in`)}</span>
              : visibleEvents.map((e, i) => {
                // drei Zeilen: Alarme oben, Eingänge (Türen, Rampen) in der Mitte, Übriges unten; Dauer blass, Beginn als Strich
                const row = e.kind === 'alarm' || e.kind === 'alert' || e.kind === 'tone' ? 0 : e.kind === 'digital' || e.kind === 'analog' ? 1 : 2
                const x0 = toX(e.t)
                const x1 = e.end != null ? toX(e.end) : x0
                const color = EVENT_COLOR[e.kind] ?? '#aaa'
                const title = `${clockAt(e.t, origin)}${e.end != null ? ` – ${clockAt(e.end, origin)}` : ''} · ${e.label}${e.detail ? ` · ${e.detail}` : ''}`
                return (
                  <span key={i} className="fx-ev-wrap" style={{ top: 2 + row * 9 }}>
                    {x1 - x0 > 2 && <span className="fx-ev-dur" style={{ left: Math.max(0, x0), width: Math.min(width, x1) - Math.max(0, x0), background: color }} title={title}
                      onMouseDown={(ev) => { ev.stopPropagation(); onEvent(e) }} onContextMenu={ctx('event', { event: e })} />}
                    {x0 >= 0 && x0 <= width && <span className="fx-ev" style={{ left: x0, background: color }} title={title}
                      onMouseDown={(ev) => { ev.stopPropagation(); onEvent(e) }} onContextMenu={ctx('event', { event: e })} />}
                  </span>
                )
              })}
          </div>
        </div>
      )}

      {lanes.transcript && (
        <div className="au-tl-row fx-row-transcript">
          <div className="au-tl-head fx-lane-head">
            <span className="au-tl-name">{t('Übersetzer-Spur', 'Translation track')}</span>
            <span className="muted small">{segments.length ? `${segments.length} ${t('Blöcke', 'blocks')}` : t('leer', 'empty')} · {showTranslation ? targetLang.toUpperCase() : t('Original', 'original')}</span>
          </div>
          <div className="au-lane fx-transcript" onMouseDown={onDown} onContextMenu={ctx('lane')}>
            {denseSegs && <SegOverview segs={visibleSegs} t0={t0} t1={t1} width={width} selected={selectedSegment} onPick={onSegment}
              onContext={(s, e) => ctx('segment', { segment: s })(e)} />}
            {!denseSegs && visibleSegs.map((s) => {
              const x0 = Math.max(0, toX(s.start))
              const x1 = Math.min(width, toX(s.end))
              const flip = !!flipped[s.id]
              const tr = (s.translation ?? {})[targetLang]
              const useTr = showTranslation !== flip && !!tr
              const hide = blind && s.status === 'draft'
              const text = hide ? '' : useTr ? tr : s.text
              return (
                <div key={s.id} className={`fx-seg ${s.kind} ${s.status}${selectedSegment === s.id ? ' on' : ''}${s.origin === 'ai' && /low_confidence|repetition/.test(s.note) ? ' unsure' : ''}`}
                  style={{ left: x0, width: Math.max(4, x1 - x0) }}
                  title={`${clockAt(s.start, origin)} · ${s.speaker || s.track}\n${s.text}${tr ? `\n— ${tr}` : ''}`}
                  onMouseDown={(e) => { e.stopPropagation(); onSegment(s) }} onContextMenu={ctx('segment', { segment: s })}>
                  {x1 - x0 > 26 && tr && !hide && (
                    <button className={`fx-seg-lang${useTr ? ' tr' : ''}`} title={t('Original / Übersetzung', 'Original / translation')}
                      onMouseDown={(e) => { e.stopPropagation(); onFlip(s.id) }}>{useTr ? targetLang.toUpperCase() : (s.lang || 'OR').toUpperCase()}</button>
                  )}
                  {x1 - x0 > 34 && <span className="fx-seg-text">{s.kind === 'sound' ? `[${text}]` : text}</span>}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {lanes.activity && (
        <div className="au-tl-row">
          <div className="au-tl-head fx-lane-head"><span className="au-tl-name">{t('Sprachaktivität', 'Speech activity')}</span>
            <span className="muted small">{audioTracks.some((x) => x.vad) ? 'Silero VAD' : t('grob, je Kanal', 'rough, per channel')}</span></div>
          <div className="au-lane" onMouseDown={onDown} onContextMenu={ctx('lane')}>
            <Activity pid={pid} tracks={audioTracks} t0={t0} t1={t1} width={width} />
          </div>
        </div>
      )}

      {audioTracks.map((tr) => {
        const audible = anySolo ? tr.solo : !tr.mute
        const mode = lanes.view[tr.id] ?? 'wave'
        const trSr = tr.sr ?? sr
        const specH = mode === 'both' ? Math.max(48, Math.round(h * 1.4)) : Math.max(48, Math.round(h * 1.6))
        return (
          <div key={tr.id} className={`au-tl-row${busyTracks.has(tr.id) ? ' busy' : ''}`}>
            <div className="au-tl-head" style={{ borderLeftColor: tr.color }} onContextMenu={ctx('head', { track: tr })}>
              <div className="au-tl-name" title={`${tr.name}${tr.channel?.position ? ` · ${tr.channel.position}` : ''}`}>
                {tr.name}{tr.channel?.position ? <span className="muted small"> · {tr.channel.position}</span> : null}
              </div>
              <div className="au-tl-ctl">
                <button className={`au-ms${tr.mute ? ' on' : ''}`} title={t('stumm', 'mute')} onClick={() => onTrack(tr.id, { mute: !tr.mute })}>M</button>
                <button className={`au-ms solo${tr.solo ? ' on' : ''}`} title={t('nur diese', 'solo')} onClick={() => onTrack(tr.id, { solo: !tr.solo })}>S</button>
                <button className={`au-ms pan${lanes.pan?.[tr.id] ? ' on' : ''}`}
                  title={t('Kopfhörer: Mitte, nur links, nur rechts (zwei Kanäle getrennt vergleichen)', 'Headphones: centre, left only, right only (compare two channels separately)')}
                  onClick={() => setLanes((l) => {
                    const cur = l.pan?.[tr.id] ?? 0
                    return { ...l, pan: { ...(l.pan ?? {}), [tr.id]: cur === 0 ? -1 : cur < 0 ? 1 : 0 } }
                  })}>{(lanes.pan?.[tr.id] ?? 0) < 0 ? 'L' : (lanes.pan?.[tr.id] ?? 0) > 0 ? 'R' : 'C'}</button>
                <input type="range" min={-30} max={24} step={0.5} value={tr.gain_db} title={`${tr.gain_db.toFixed(1)} dB`}
                  onChange={(e) => onTrack(tr.id, { gain_db: Number(e.target.value) })} />
                <span className="muted small au-db">{tr.gain_db > 0 ? '+' : ''}{tr.gain_db.toFixed(1)}</span>
                <select className="fx-viewsel" value={mode} title={t('Darstellung', 'Display')}
                  onChange={(e) => {
                    const v = e.target.value as TrackView
                    setLanes((l) => ({ ...l, view: { ...l.view, [tr.id]: v } }))
                    if (v !== 'wave' && !tr.spec && !busyTracks.has(tr.id)) onSpectro(tr.id)
                  }}>
                  <option value="wave">{t('Welle', 'Wave')}</option>
                  <option value="spec">{t('Spektrogramm', 'Spectrogram')}</option>
                  <option value="both">{t('beides', 'both')}</option>
                </select>
                {tr.kind !== 'original' && <button className="au-x" title={t('Spur löschen', 'delete track')} onClick={() => onTrackDelete(tr.id)}>✕</button>}
              </div>
            </div>
            <div className="au-lane" onMouseDown={onDown} onContextMenu={ctx('track', { track: tr })}>
              {mode !== 'spec' && <Wave peaks={peaks[tr.id]} t0={t0} t1={t1} offset={tr.offset || 0} color={tr.color} width={width} height={h} sr={trSr} dim={!audible} />}
              {mode !== 'wave' && (busyTracks.has(tr.id) && !tr.spec
                ? <div className="fx-spec-empty" style={{ height: specH }}>{t('Spektrogramm wird gerechnet …', 'Computing spectrogram …')}</div>
                : <Spec pid={pid} tr={tr} t0={t0} t1={t1} width={width} height={specH} lo={lanes.specLo} hi={lanes.specHi} fshow={lanes.specFmax} />)}
            </div>
          </div>
        )
      })}

      {series && lanes.data.map((k) => {
        const s = series.series[k]
        if (!s) return null
        return (
          <div key={k} className="au-tl-row">
            <div className="au-tl-head fx-lane-head">
              <span className="au-tl-name">{seriesLabel(k, s)}</span>
              <span className="muted small">{s.unit}</span>
              <button className="au-x" title={t('ausblenden', 'hide')} onClick={() => setLanes((l) => ({ ...l, data: l.data.filter((x) => x !== k) }))}>✕</button>
            </div>
            <div className="au-lane" onMouseDown={onDown} onContextMenu={ctx('lane')}>
              <DataLane s={s} t0={t0} t1={t1} width={width} height={46} origin={origin} />
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
      <Overview peaks={ov ? peaks[ov.id] : undefined} sr={ov?.sr ?? sr} duration={duration} view={view} width={width}
        onView={(a) => setView(clampView(a, a + span))} playhead={playhead} selection={selection} events={events} segments={segments} origin={origin} />
    </div>
  )
}

function Overview({ peaks, sr, duration, view, width, onView, playhead, selection, events, segments, origin }: {
  peaks: Peaks | undefined
  sr: number
  duration: number
  view: [number, number]
  width: number
  onView: (start: number) => void
  playhead: number
  selection: [number, number] | null
  events: VdrEvent[]
  segments: TranscriptSegment[]
  origin: number | null | undefined
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
    if (!duration) return
    if (peaks) {
      const cols = peaks.columns(0, duration, width, sr)
      g.fillStyle = 'rgba(230,235,240,0.35)'
      for (let x = 0; x < width; x++) {
        const y0 = H / 2 - cols[2 * x + 1] * (H / 2 - 1)
        const y1 = H / 2 - cols[2 * x] * (H / 2 - 1)
        g.fillRect(x, y0, 1, Math.max(1, y1 - y0))
      }
    }
    // Alarme und Übersetzer-Blöcke als Striche oben und unten
    const k = width / duration
    g.fillStyle = EVENT_COLOR.alarm
    for (const e of events) if (e.kind === 'alarm' || e.kind === 'alert') g.fillRect(Math.floor(e.t * k), 0, 1, 5)
    g.fillStyle = '#ffd166'
    for (const s of segments) g.fillRect(Math.floor(s.start * k), H - 4, Math.max(1, (s.end - s.start) * k), 4)
  }, [peaks, sr, duration, width, events, segments])
  const k = duration ? width / duration : 0
  const drag = (e: React.MouseEvent) => {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
    const len = view[1] - view[0]
    const go = (cx: number) => onView(Math.max(0, (cx - rect.left) / Math.max(1e-9, k) - len / 2))
    go(e.clientX)
    const move = (ev: MouseEvent) => go(ev.clientX)
    const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up) }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }
  return (
    <div className="au-tl-row au-ov-row">
      <div className="au-tl-head au-tl-corner"><span className="muted small">{t('Übersicht', 'Overview')} · {fmtClock(duration)}{origin ? ` · ${clockAt(0, origin)}–${clockAt(duration, origin)} UTC` : ''}</span></div>
      <div className="au-ov" onMouseDown={drag} title={t('Ziehen verschiebt den Ausschnitt', 'Drag to move the view')}>
        <canvas ref={ref} style={{ width, height: H, display: 'block' }} />
        {selection && <div className="au-ov-sel" style={{ left: selection[0] * k, width: Math.max(2, (selection[1] - selection[0]) * k) }} />}
        <div className="au-ov-view" style={{ left: view[0] * k, width: Math.max(4, (view[1] - view[0]) * k) }} />
        <div className="au-ov-head" style={{ left: playhead * k }} />
      </div>
    </div>
  )
}
