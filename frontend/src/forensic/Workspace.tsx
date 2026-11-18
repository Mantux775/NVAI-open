import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  api, audioFileUrl, CLIENT_ID, fileUrl, type AudioMarker, type AudioProject, type AudioStatus, type AudioTrack, type Job,
  type TranscriptDoc, type TranscriptSegment, type VdrEvent, type VdrImages, type VdrSeries,
} from '../api'
import { loadPeaks, type Peaks } from '../audio/peaks'
import { MultiPlayer } from '../audio/player'
import { fmtClock } from '../audio/Timeline'
import { t } from '../i18n'
import { ContextMenu, type MenuItem, type MenuState } from '../studio/ContextMenu'
import { ExportDialog, ExportPanel, parseClock, type ExportSection } from './Export'
import { clockAt, EVENT_COLOR, ForensicLanes, HEAD_WIDTH, seriesLabel, type LaneContext, type LaneState } from './Lanes'
import { newNote, NotesTool } from './Notes'
import { isReview } from '../review/mode'
import { ForensicMonitor, type AisData, type MonitorTab } from './Monitor'
import { dropSpecCache } from './spectro'
import { AiTool, FilterTool, fmtDur, LearnTool } from './tools'
import { TranscriptTool } from './Transcript'

/** Videoabgleich, eigener Reiter (Nutzer 17.11.: „bitte kompakter gestalten … am besten in eigenen Tab“): das zugeordnete
 * Video mit den Kennzahlen der Ausrichtung, darunter zuordnen oder ein anderes wählen. Exportieren steht im Export. */
function VideoLink({ proj, busy, onError, onNotice, onReload, onExport }: {
  proj: AudioProject
  busy: boolean
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
  onExport: () => void
}) {
  const v = proj.video
  const [open, setOpen] = useState(!v)
  const [path, setPath] = useState('')
  const [method, setMethod] = useState<'clock' | 'audio'>(proj.time_origin ? 'clock' : 'audio')
  const num = (x: number, d: number) => x.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d })
  const ro = (label: string, value: string, title?: string) => (
    <div className="fx-ro" title={title}><span className="fx-ro-label">{label}</span><span className="fx-ro-value">{value}</span></div>
  )
  const link = () => api.audioVideoLink(proj.id, path.trim().replace(/^"|"$/g, ''), method)
    .then(() => { onNotice(t('Richtet aus (bei 12 h rund eine Minute).', 'Aligning (about a minute for 12 h).')); setOpen(false); setPath(''); onReload() })
    .catch((e) => onError(String(e.message ?? e)))
  return (
    <div className="au-tool fx-vlink">
      {v ? (
        <>
          <div className="fx-vlink-head">
            <strong className="fx-vlink-name" title={v.path}>🎬 {v.name}</strong>
            <span className="fx-vlink-chip">{v.method === 'audio' ? t('über den Ton', 'by the sound') : t('Uhr im Bild', 'clock in the picture')}</span>
            <span className="au-spacer" />
            <button className="btn small" onClick={onExport}>{t('Video mit Ton exportieren …', 'Export video with sound …')}</button>
            <button className="btn small ghost" onClick={() => setOpen(!open)}>{open ? t('Abbrechen', 'Cancel') : t('Anderes Video …', 'Other video …')}</button>
          </div>
          <div className="fx-ro-grid">
            {ro(t('Versatz', 'Offset'), `${num(v.fit.b, 2)} s`, t('Videozeit minus Aufnahmezeit am Anfang', 'video time minus recording time at the start'))}
            {ro(t('Drift', 'Drift'), `${num(v.drift_ppm, 1)} ppm`, t('Gangunterschied der Uhren', 'clock rate difference'))}
            {ro(t('Restfehler', 'Residual'), `${Math.round(v.residual_ms.median)} ms`, t('Median über alle Messpunkte', 'median over all points'))}
            {ro(t('höchstens', 'at most'), `${Math.round(v.residual_ms.max)} ms`)}
            {ro(t('Messpunkte', 'Points'), String(v.points))}
          </div>
        </>
      ) : <p className="muted small">{t('Noch kein Video zugeordnet, z. B. die Bildschirmaufnahme des Wiedergabeprogramms.', 'No video linked yet, e.g. the screen recording of the playback program.')}</p>}
      {open && (
        <>
          <div className="fx-vlink-form">
            <input className="au-path" value={path} onChange={(e) => setPath(e.target.value)} autoFocus={!!v}
              onKeyDown={(e) => { if (e.key === 'Enter' && path.trim() && !busy) void link() }}
              placeholder={t('Pfad des Videos auf diesem Rechner', 'Path of the video on this computer')} />
            <select value={method} onChange={(e) => setMethod(e.target.value as 'clock' | 'audio')}>
              {proj.time_origin && <option value="clock">{t('nach der Uhr im Bild', 'by the clock in the picture')}</option>}
              <option value="audio">{t('über den Ton', 'by the sound')}</option>
            </select>
            <button className="btn small primary" disabled={busy || !path.trim()} onClick={() => void link()}>{t('Zuordnen', 'Link')}</button>
          </div>
          {proj.time_origin && <p className="muted small">{t('Live-Player-Aufnahmen nach der Uhr im Bild: Sein eigener Ton läuft rund 2 s nach.', 'Live Player recordings by the clock in the picture: its own sound runs about 2 s late.')}</p>}
        </>
      )}
    </div>
  )
}

// Arbeitsfläche der Ton-Forensik (seit 17.11.2026 abends), aufgebaut wie das Studio: oben links die Spuren und
// Ebenen, in der Mitte der Monitor (Video, Radar/ECDIS, Fahrstand, Karte …), rechts die Werkzeuge; darunter Transport
// und Zeitstrahl mit allen Spuren. Zwei Modi: „Forensik“ mit allen Werkzeugen und „Player“ (MaintenanceViewer) nur
// zum Ansehen, Markieren und Exportieren, ohne KI.

type Progress = { progress: number; stage: string }
export type WsMode = 'forensic' | 'player'
type ToolTab = 'transcript' | 'enhance' | 'separate' | 'learn' | 'video' | 'export' | 'log' | 'notes'
const RATES = [0.5, 0.6, 0.75, 0.9, 1, 1.25, 1.5]

// Aufteilung der Fläche (Nutzer 17.11. abends: „mach den Ereignisse Fenster um die hälfte schmaller dafür die anderen
// breiter, ich muss die audio spuren abschnitt höher ziehen können“): Spalten links/rechts und Höhe des oberen Teils
// ziehbar, Doppelklick stellt zurück; der Zeitstrahl füllt den Rest und rollt in sich.
const LAYOUT_KEY = 'nvai.forensic.layout'
type Layout = { left: number; right: number; upper: number; head: number }
function defaultLayout(): Layout {
  const w = window.innerWidth
  return { left: Math.round(Math.min(420, Math.max(250, w * 0.2))), right: Math.round(Math.max(360, w * 0.48)),
    upper: Math.round(Math.max(220, window.innerHeight * 0.4)), head: HEAD_WIDTH }
}
function loadLayout(): Layout {
  try {
    const raw = localStorage.getItem(LAYOUT_KEY)
    if (raw) return { ...defaultLayout(), ...JSON.parse(raw) }
  } catch { /* ohne Speicher: Vorgabe */ }
  return defaultLayout()
}

function loadJson<T>(url: string): Promise<T | null> {
  return fetch(url, { cache: 'no-store' }).then((r) => (r.ok ? (r.json() as Promise<T>) : null)).catch(() => null)
}

function defaultLanes(proj: AudioProject): LaneState {
  const vdr = proj.source.kind === 'vdr'
  return {
    view: {}, hidden: {}, height: vdr ? 44 : 64, data: vdr ? ['hdg', 'sog', 'rudder'] : [], events: true, transcript: true,
    activity: true, specLo: -95, specHi: -20, specFmax: vdr ? 8000 : 12000,
  }
}

export function Workspace({ st, proj, running, progress, paused, active, mode: initialMode, onResume, onDismiss, onInstall, setupBusy,
  onError, onNotice, onReload, onDeleted, onBack, event, headerExtra, headerEnd }: {
  st: AudioStatus
  proj: AudioProject
  running: Job[]
  progress: Record<string, Progress>
  paused: Job[]
  active: boolean
  mode: WsMode
  onResume: (j: Job) => void
  onDismiss: (j: Job) => void
  onInstall: (id: string) => void
  setupBusy: boolean
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
  onDeleted: () => void
  onBack: () => void
  event: { type: string; project_id?: string; client?: string; n: number } | null
  /** Prüf-App: Vermerk in der Kopfzeile (Prüfer, Speicherort) */
  headerExtra?: React.ReactNode
  /** Prüf-App: ganz rechts in der Kopfzeile, hinter „Export“ (Sprache) */
  headerEnd?: React.ReactNode
}) {
  const review = isReview()
  const sr = proj.sample_rate ?? 48000
  const duration = proj.duration ?? 0
  const origin = proj.time_origin ?? null
  const isVdr = proj.source.kind === 'vdr'
  const [mode, setMode] = useState<WsMode>(initialMode)
  const [tracks, setTracks] = useState<AudioTrack[]>(proj.tracks)
  useEffect(() => { setTracks(proj.tracks) }, [proj.tracks])
  const [view, setView] = useState<[number, number]>([0, Math.max(1, duration)])
  useEffect(() => { if (duration && view[1] <= 1) setView([0, duration]) }, [duration]) // eslint-disable-line react-hooks/exhaustive-deps
  const [selection, setSelection] = useState<[number, number] | null>(null)
  const [playhead, setPlayhead] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [loop, setLoop] = useState(false)
  const [rate, setRate] = useState(1)
  const [peaks, setPeaks] = useState<Record<string, Peaks | undefined>>({})
  const [tool, setTool] = useState<ToolTab>('transcript')
  const [monTab, setMonTab] = useState<MonitorTab>(isVdr ? (proj.video ? 'video' : 'radar') : 'video')
  const [menu, setMenu] = useState<MenuState | null>(null)
  const [noteFocus, setNoteFocus] = useState<string | null>(null)
  const [exportOpen, setExportOpen] = useState(false)
  const [exportSec, setExportSec] = useState<ExportSection | undefined>(undefined)
  const [timeText, setTimeText] = useState('')
  const [confirmDelete, setConfirmDelete] = useState(false)
  const lanesKey = `nvai.forensic.lanes.${proj.id}`
  const [lanes, setLanesState] = useState<LaneState>(() => {
    try {
      const raw = localStorage.getItem(lanesKey)
      if (raw) return { ...defaultLanes(proj), ...JSON.parse(raw) }
    } catch { /* ohne Speicher: Vorgaben */ }
    return defaultLanes(proj)
  })
  const setLanes = useCallback((fn: (l: LaneState) => LaneState) => {
    setLanesState((cur) => {
      const next = fn(cur)
      try { localStorage.setItem(lanesKey, JSON.stringify(next)) } catch { /* egal */ }
      return next
    })
  }, [lanesKey])
  const player = useRef<MultiPlayer | null>(null)
  const root = useRef<HTMLDivElement>(null)
  const upperRef = useRef<HTMLDivElement>(null)
  const [layout, setLayoutState] = useState<Layout>(loadLayout)
  const setLayout = useCallback((l: Layout) => {
    setLayoutState(l)
    try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(l)) } catch { /* egal */ }
  }, [])
  // Die Fläche reicht bis zum unteren Fensterrand; der Zeitstrahl rollt darin
  const [fitH, setFitH] = useState<number | null>(null)
  useEffect(() => {
    const fit = () => {
      const top = root.current?.getBoundingClientRect().top
      // 28 px: Innenabstand unter dem Inhaltsbereich (main.content), sonst rollt die Seite um ein paar Pixel
      if (top != null) setFitH(Math.max(420, Math.floor(window.innerHeight - top - 28)))
    }
    fit()
    window.addEventListener('resize', fit)
    return () => window.removeEventListener('resize', fit)
  }, [])
  const dragCol = (side: 'left' | 'right') => (e: React.PointerEvent) => {
    const box = upperRef.current?.getBoundingClientRect()
    if (!box) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const start = layout
    const move = (ev: PointerEvent) => {
      if (side === 'left') {
        const w = Math.round(Math.max(170, Math.min(ev.clientX - box.left, box.width - start.right - 260)))
        setLayout({ ...start, left: w })
      } else {
        const w = Math.round(Math.max(280, Math.min(box.right - ev.clientX, box.width - start.left - 260)))
        setLayout({ ...start, right: w })
      }
    }
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up) }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  const dragRow = (e: React.PointerEvent) => {
    const box = upperRef.current?.getBoundingClientRect()
    if (!box) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const start = layout
    const move = (ev: PointerEvent) => {
      const h = Math.round(Math.max(150, Math.min(ev.clientY - box.top, window.innerHeight * 0.8)))
      setLayout({ ...start, upper: h })
    }
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up) }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  const resetLayout = (part: keyof Layout) => setLayout({ ...layout, [part]: defaultLayout()[part] })

  // Daten des Schiffsschreibers
  const [series, setSeries] = useState<VdrSeries | null>(null)
  const [vdrEvents, setVdrEvents] = useState<VdrEvent[]>([])
  const [images, setImages] = useState<VdrImages | null>(null)
  const [ais, setAis] = useState<AisData | null>(null)
  useEffect(() => {
    if (!isVdr || proj.status !== 'ready') return
    let alive = true
    loadJson<VdrSeries>(audioFileUrl(proj.id, 'data', 'series.json')).then((x) => { if (alive) setSeries(x) })
    loadJson<VdrEvent[]>(audioFileUrl(proj.id, 'data', 'events.json')).then((x) => { if (alive) setVdrEvents((x ?? []).sort((a, b) => a.t - b.t)) })
    loadJson<VdrImages>(audioFileUrl(proj.id, 'data', 'images.json')).then((x) => { if (alive) setImages(x) })
    loadJson<AisData>(audioFileUrl(proj.id, 'data', 'ais.json')).then((x) => { if (alive) setAis(x) })
    return () => { alive = false }
  }, [proj.id, isVdr, proj.status])
  // Ton-Suche (Alarme, Piepser) als Ereignisse
  const events = useMemo(() => {
    const tones: VdrEvent[] = []
    for (const c of proj.scan?.clusters.slice(0, 6) ?? []) {
      for (const [a, b] of c.events) tones.push({ t: a, end: b, kind: 'tone', label: `${c.freqs.join(' + ')} Hz`, detail: t('Ton-Suche', 'tone scan'), source: 'scan' })
    }
    return [...vdrEvents, ...tones].sort((a, b) => a.t - b.t)
  }, [vdrEvents, proj.scan])

  // Übersetzer-Spur
  const [doc, setDoc] = useState<TranscriptDoc>({ source_lang: 'tl', target_lang: 'de', speakers: [], segments: [] })
  const [selSeg, setSelSeg] = useState<string | null>(null)
  const [flipped, setFlipped] = useState<Record<string, boolean>>({})
  const [showTr, setShowTr] = useState(true)
  const [blind, setBlind] = useState(false)
  const loadDoc = useCallback(() => { api.audioTranscript(proj.id).then(setDoc).catch(() => {}) }, [proj.id])
  useEffect(loadDoc, [loadDoc])
  // Meldungen anderer Fenster (oder der KI) laden neu, die eigenen nicht: sonst überschreibt das Neuladen Getipptes
  useEffect(() => {
    if (event?.type === 'audio.transcript' && event.project_id === proj.id && event.client !== CLIENT_ID) loadDoc()
  }, [event, proj.id, loadDoc])
  const saveDoc = useCallback((d: TranscriptDoc) => { api.audioTranscriptSave(proj.id, d).catch((e) => onError(String(e.message ?? e))) }, [proj.id, onError])

  // Wellenformen
  useEffect(() => {
    let alive = true
    for (const tr of tracks) {
      if (peaks[tr.id]) continue
      loadPeaks(audioFileUrl(proj.id, 'peaks', `${tr.id}.peaks`)).then((p) => { if (alive) setPeaks((cur) => ({ ...cur, [tr.id]: p })) }).catch(() => {})
    }
    return () => { alive = false }
  }, [tracks, proj.id]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => dropSpecCache(proj.id), [proj.id])

  // Abspielen
  useEffect(() => {
    const p = new MultiPlayer()
    player.current = p
    p.onEnd = () => { setPlaying(false); setPlayhead(0) }
    // Zur Fehlersuche (localStorage „nvai.debug“): window.__fxPlayer.debugState() zeigt je Spur Sprung, Puffer, Abweichung
    try {
      if (localStorage.getItem('nvai.debug')) (window as unknown as { __fxPlayer?: MultiPlayer }).__fxPlayer = p
    } catch { /* ohne Speicher */ }
    return () => { p.dispose(); player.current = null }
  }, [proj.id])
  const anySolo = tracks.some((x) => x.solo)
  useEffect(() => {
    const p = player.current
    if (!p) return
    p.duration = duration
    p.setTracks(tracks.filter((x) => x.frames > 0).map((x) => ({
      id: x.id, url: audioFileUrl(proj.id, 'proxy', `${x.id}.webm`), offset: x.offset || 0,
      gain: Math.pow(10, x.gain_db / 20), audible: anySolo ? x.solo : !x.mute, pan: lanes.pan?.[x.id] ?? 0,
    })))
  }, [tracks, anySolo, duration, proj.id, lanes.pan])
  useEffect(() => { player.current?.setRate(rate) }, [rate])
  useEffect(() => { if (player.current) player.current.loop = loop && selection ? selection : null }, [loop, selection])
  useEffect(() => {
    if (!playing) return
    let raf = 0
    const tick = () => { if (player.current) setPlayhead(player.current.position()); raf = requestAnimationFrame(tick) }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [playing])
  useEffect(() => { if (!active && player.current?.playing) { player.current.pause(); setPlaying(false) } }, [active])
  const toggle = useCallback(() => {
    const p = player.current
    if (!p) return
    if (p.playing) { p.pause(); setPlaying(false); setPlayhead(p.position()) } else {
      const from = selection && (playhead < selection[0] || playhead >= selection[1]) ? selection[0] : playhead
      void p.play(from)
      setPlaying(true)
    }
  }, [selection, playhead])
  const seek = useCallback((time: number) => {
    const x = Math.max(0, Math.min(duration, time))
    setPlayhead(x)
    player.current?.seek(x)
    // Abspielkopf im Blick behalten
    setView((v) => (x < v[0] || x > v[1] ? [Math.max(0, x - (v[1] - v[0]) * 0.2), Math.max(0, x - (v[1] - v[0]) * 0.2) + (v[1] - v[0])] : v))
  }, [duration])
  useEffect(() => {
    // Leertaste spielt immer ab bzw. hält an, außer beim Schreiben in Textfeldern und in offenen Dialogen (Nutzer 17.11.:
    // „leertaste spielt nicht immer ab“). Vorher schluckten Schieber, Häkchen und Auswahlfelder mit Fokus die Taste, und
    // ein angeklickter Knopf (▶) schaltete beim Loslassen gleich wieder zurück.
    const isTextEntry = (el: HTMLElement | null): boolean => {
      if (!el) return false
      if (el.isContentEditable || el.tagName === 'TEXTAREA') return true
      if (el.tagName !== 'INPUT') return false
      return ['text', 'search', 'number', 'email', 'url', 'password', 'tel', 'date', 'time', 'datetime-local']
        .includes(((el as HTMLInputElement).type || 'text').toLowerCase())
    }
    const onKey = (e: KeyboardEvent) => {
      if (!active) return
      const target = e.target as HTMLElement | null
      if (isTextEntry(target) || target?.closest?.('.lt-modal')) return
      if (e.code === 'Space') {
        e.preventDefault()
        if (e.repeat) return
        const focused = document.activeElement as HTMLElement | null
        if (focused && focused !== document.body && /^(BUTTON|SELECT|INPUT)$/.test(focused.tagName)) focused.blur()
        toggle()
      }
      else if (e.code === 'KeyN' && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); addNoteRef.current?.() }
      else if (e.code === 'ArrowLeft' || e.code === 'ArrowRight') {
        // Schieber und Auswahlfelder behalten ihre Pfeiltasten
        if (target?.tagName === 'SELECT' || (target?.tagName === 'INPUT' && (target as HTMLInputElement).type === 'range')) return
        e.preventDefault()
        const d = (e.shiftKey ? 10 : 2) * (e.code === 'ArrowLeft' ? -1 : 1)
        seek((player.current?.position() ?? playhead) + d)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [toggle, active, seek, playhead])

  const addNoteRef = useRef<(() => void) | null>(null)
  const setTrack = (id: string, fields: Partial<AudioTrack>) => {
    setTracks((cur) => cur.map((x) => (x.id === id ? { ...x, ...fields } : x)))
    api.audioTrack(proj.id, id, fields).catch((e) => onError(String(e.message ?? e)))
  }
  const markers = proj.markers ?? []
  const saveMarkers = (list: AudioMarker[]) => api.audioMarkers(proj.id, list).then(onReload).catch((e) => onError(String(e.message ?? e)))
  const fullTracks = tracks.filter((x) => !x.offset)
  const busyJob = running.find((j) => !['audio_export', 'audio_spectro'].includes(j.kind))
  const span = selection ? selection[1] - selection[0] : duration
  const busyTracks = useMemo(() => new Set(running.filter((j) => j.kind === 'audio_spectro').map((j) => String(j.params?.track ?? ''))), [running])
  const spectro = (tid: string) => api.audioSpectro(proj.id, tid).then(onReload).catch((e) => onError(String(e.message ?? e)))
  const seriesKeys = series ? Object.keys(series.series).filter((k) => series.series[k].values.some((v) => v != null)) : []
  const groups = useMemo(() => {
    const g = new Map<string, AudioTrack[]>()
    for (const tr of tracks) {
      const k = tr.kind === 'original' ? (tr.group || t('Original', 'Original')) : tr.kind === 'preview' ? t('Vorschau', 'Previews') : t('Bearbeitet', 'Processed')
      g.set(k, [...(g.get(k) ?? []), tr])
    }
    return [...g.entries()]
  }, [tracks])
  // Prüfsummen des Schiffsschreibers (audio_vdr: MD5 je Block gegen seine Liste, dazu MD5 der Listen)
  const ivr = (proj.vdr?.integrity ?? null) as { ok?: boolean; algorithm?: string; listed?: number; ok_count?: number; bad_count?: number;
    missing_count?: number; checkfile_ok?: boolean } | null
  const integrity = ivr ? {
    ok: ivr.ok_count ?? (ivr.ok ? ivr.listed ?? 0 : 0), files: ivr.listed ?? 0, algorithm: (ivr.algorithm ?? 'MD5').toUpperCase(),
    bad: (ivr.bad_count ?? 0) + (ivr.missing_count ?? 0) + (ivr.checkfile_ok === false ? 1 : 0) + (ivr.ok === false && !ivr.bad_count ? 1 : 0),
  } : null
  const playerMode = mode === 'player'
  const asrModel = st.models.find((m) => m.id === 'whisper_large_v3')
  const vadModel = st.models.find((m) => m.id === 'silero_vad')
  const asrReady = !st.env_ready
    ? { ok: false, why: t('Erst unter „Modelle und Einrichten“ die Audio-Umgebung einrichten.', 'Set up the audio environment under “Models and setup” first.') }
    : !asrModel?.installed || !vadModel?.installed
      ? { ok: false, why: t(`Erst die Modelle laden: Whisper large-v3 und Silero VAD (${Math.round(((asrModel?.installed ? 0 : asrModel?.size_mb ?? 0) + (vadModel?.installed ? 0 : vadModel?.size_mb ?? 0)) / 102.4) / 10} GB).`,
        `Download the models first: Whisper large-v3 and Silero VAD (${Math.round(((asrModel?.installed ? 0 : asrModel?.size_mb ?? 0) + (vadModel?.installed ? 0 : vadModel?.size_mb ?? 0)) / 102.4) / 10} GB).`), install: true }
      : { ok: true, why: '' }
  // Videoabgleich als eigener Reiter, wo ein Video dazugehört (Schiffsschreiber) oder schon zugeordnet ist
  const videoTab: [ToolTab, string][] = (proj.video || isVdr) && !review ? [['video', t('Videoabgleich', 'Video sync')]] : []
  const toolTabs: [ToolTab, string][] = playerMode
    ? [['transcript', t('Übersetzer-Spur', 'Translation')], ...videoTab, ['export', t('Export', 'Export')], ['log', t('Protokoll', 'Log')], ['notes', t('Notizen', 'Notes')]]
    : [['transcript', t('Übersetzer-Spur', 'Translation')], ['enhance', t('Verbessern', 'Enhance')], ['separate', t('Trennen', 'Separate')],
      ['learn', t('Gezielt entfernen', 'Remove a sound')], ...videoTab, ['export', t('Export', 'Export')], ['log', t('Protokoll', 'Log')], ['notes', t('Notizen', 'Notes')]]
  const notesCount = markers.filter((m) => m.kind === 'note').length

  // Notiz anlegen (Knopf, Taste N, Rechtsklick): mit Auswahl für die Auswahl, sonst an der Stelle
  const addNote = (at?: number, label = '') => {
    const inSel = selection && (at == null || (at >= selection[0] && at <= selection[1]))
    const n = inSel && selection ? newNote(selection[0], selection[1], label) : newNote(at ?? playhead, at ?? playhead, label)
    void saveMarkers([...markers, n])
    setTool('notes')
    setNoteFocus(n.id)
  }
  const play = (from: number) => {
    const p = player.current
    if (!p) return
    setPlayhead(from)
    void p.play(from)
    setPlaying(true)
  }
  const zoomAround = (at: number, factor: number) => {
    const len = Math.min(duration, Math.max(0.5, (view[1] - view[0]) * factor))
    const a = Math.max(0, Math.min(duration - len, at - len / 2))
    setView([a, a + len])
  }
  const doc2 = doc
  // Übersetzer-KI mit fester Spur für einen Bereich (Nutzer 17.11.: „ich soll auswählen welche spur der übersetzer nimmt an
  // dem markiertem abschnitt“)
  const fixedRun = (tid: string, region: [number, number]) => {
    const name = tracks.find((x) => x.id === tid)?.name ?? tid
    api.audioTranscribe(proj.id, { tracks: [tid], source_lang: doc2.source_lang || 'tl', target_lang: doc2.target_lang || 'de', region, force: true })
      .then(() => { onNotice(t(`Übersetzer-KI läuft auf ${name} für ${Math.round(region[1] - region[0])} s.`, `Translation AI running on ${name} for ${Math.round(region[1] - region[0])} s.`)); onReload() })
      .catch((err) => onError(String(err.message ?? err)))
  }
  // Rechtsklick-Menüs (Nutzer 17.11.: „rechtklick soll mir sinnvolle menüs zum steuern anbieten“)
  const openMenu = (e: React.MouseEvent, c: LaneContext) => {
    const at = c.time
    const items: MenuItem[] = []
    if (c.kind === 'segment' && c.segment) {
      const sg = c.segment
      const trn = sg.translation?.[doc2.target_lang || 'de']
      items.push(
        { label: t('Block abspielen', 'Play block'), onClick: () => { setSelection([sg.start, sg.end]); play(sg.start) } },
        { label: t('Block bearbeiten', 'Edit block'), onClick: () => { setSelSeg(sg.id); setTool('transcript') } },
        ...(!playerMode ? [{ label: sg.status === 'checked' ? t('Neu erkennen auf Spur (geprüft, gesperrt)', 'Recognise again on track (checked, locked)') : t('Neu erkennen auf Spur', 'Recognise again on track'),
          disabled: sg.status === 'checked',
          items: tracks.filter((x) => x.kind !== 'preview' && !x.offset).map((x) => ({ label: x.name, checked: x.id === sg.track,
            onClick: () => fixedRun(x.id, [Math.max(0, sg.start - 0.2), Math.min(duration, sg.end + 0.2)]) })) }] : []),
        { label: sg.status === 'checked' ? t('Wieder als Entwurf', 'Back to draft') : t('Als geprüft markieren', 'Mark as checked'),
          onClick: () => { const next = { ...doc2, segments: doc2.segments.map((x) => (x.id === sg.id ? { ...x, status: x.status === 'checked' ? 'draft' as const : 'checked' as const } : x)) }; setDoc(next); saveDoc(next) } },
        ...(trn ? [{ label: t('Original / Übersetzung umschalten', 'Toggle original / translation'), onClick: () => setFlipped((f) => ({ ...f, [sg.id]: !f[sg.id] })) }] : []),
        { label: t('Als Notiz übernehmen', 'Copy into a note'), onClick: () => addNote(undefined, `${sg.text}${trn ? `\n${trn}` : ''}`) },
        { label: t('Block löschen', 'Delete block'), danger: true, separator: true, onClick: () => { const next = { ...doc2, segments: doc2.segments.filter((x) => x.id !== sg.id) }; setDoc(next); saveDoc(next); setSelSeg(null) } },
      )
    } else if (c.kind === 'note' && c.note) {
      const m = c.note
      items.push(
        { label: t('Notiz abspielen', 'Play note'), onClick: () => { if (m.end > m.start) setSelection([m.start, m.end]); play(m.start) } },
        { label: t('Notiz bearbeiten', 'Edit note'), onClick: () => { setTool('notes'); setNoteFocus(m.id) } },
        { label: t('Notiz löschen', 'Delete note'), danger: true, separator: true, onClick: () => { void saveMarkers(markers.filter((x) => x.id !== m.id)) } },
      )
    } else if (c.kind === 'event' && c.event) {
      const ev = c.event
      items.push(
        { label: t('Zum Ereignis springen', 'Jump to the event'), onClick: () => { seek(Math.max(0, ev.t - 1)); if (ev.end != null) setSelection([ev.t, ev.end]) } },
        { label: t('Ab 5 s davor abspielen', 'Play from 5 s before'), onClick: () => play(Math.max(0, ev.t - 5)) },
        { label: t('Als Notiz übernehmen', 'Copy into a note'), onClick: () => { const n = newNote(ev.t, ev.end ?? ev.t, `${ev.label}${ev.detail ? ` · ${ev.detail}` : ''}`); void saveMarkers([...markers, n]); setTool('notes'); setNoteFocus(n.id) } },
        ...(isVdr ? [{ label: t('In der Ereignisliste zeigen', 'Show in the event list'), onClick: () => { seek(ev.t); setMonTab('events') } }] : []),
      )
    } else if ((c.kind === 'track' || c.kind === 'head') && c.track) {
      const tr = c.track
      const mode = lanes.view[tr.id] ?? 'wave'
      const pan = lanes.pan?.[tr.id] ?? 0
      items.push(
        { label: t('Stumm', 'Mute'), checked: tr.mute, onClick: () => setTrack(tr.id, { mute: !tr.mute }) },
        { label: t('Solo', 'Solo'), checked: tr.solo, onClick: () => setTrack(tr.id, { solo: !tr.solo }) },
        { label: t('Nur diese Spur hören', 'Hear only this track'), onClick: () => { for (const x of tracks) if (x.solo !== (x.id === tr.id)) setTrack(x.id, { solo: x.id === tr.id }) } },
        { label: t('Alle wieder hören', 'Hear all again'), onClick: () => { for (const x of tracks) if (x.solo || x.mute) setTrack(x.id, { solo: false, mute: false }) } },
        { label: t('Darstellung', 'Display'), separator: true, items: [
          { label: t('Welle', 'Wave'), checked: mode === 'wave', onClick: () => setLanes((l) => ({ ...l, view: { ...l.view, [tr.id]: 'wave' } })) },
          { label: t('Spektrogramm', 'Spectrogram'), checked: mode === 'spec', onClick: () => { setLanes((l) => ({ ...l, view: { ...l.view, [tr.id]: 'spec' } })); if (!tr.spec) void spectro(tr.id) } },
          { label: t('beides', 'both'), checked: mode === 'both', onClick: () => { setLanes((l) => ({ ...l, view: { ...l.view, [tr.id]: 'both' } })); if (!tr.spec) void spectro(tr.id) } },
        ] },
        { label: t('Kopfhörer', 'Headphones'), items: [
          { label: t('Mitte', 'Centre'), checked: pan === 0, onClick: () => setLanes((l) => ({ ...l, pan: { ...(l.pan ?? {}), [tr.id]: 0 } })) },
          { label: t('nur links', 'left only'), checked: pan < 0, onClick: () => setLanes((l) => ({ ...l, pan: { ...(l.pan ?? {}), [tr.id]: -1 } })) },
          { label: t('nur rechts', 'right only'), checked: pan > 0, onClick: () => setLanes((l) => ({ ...l, pan: { ...(l.pan ?? {}), [tr.id]: 1 } })) },
        ] },
        ...(selection && !playerMode ? [{ label: t('Übersetzer-KI für die Auswahl: nur diese Spur', 'Translation AI for the selection: this track only'), separator: true, onClick: () => fixedRun(tr.id, selection) }] : []),
        { label: t('Spur ausblenden', 'Hide track'), separator: !!(selection && !playerMode), onClick: () => setLanes((l) => ({ ...l, hidden: { ...l.hidden, [tr.id]: true } })) },
        ...(tr.kind !== 'original' && !review ? [{ label: t('Spur löschen', 'Delete track'), danger: true, separator: true, onClick: () => { api.audioTrackDelete(proj.id, tr.id).then(onReload).catch((err) => onError(String(err.message ?? err))) } }] : []),
      )
    }
    if (c.kind !== 'head') {
      items.push(
        { label: t(`Hier abspielen (${clockAt(at, origin)})`, `Play from here (${clockAt(at, origin)})`), separator: items.length > 0, onClick: () => play(at) },
        { label: t('Abspielkopf hierher', 'Move the playhead here'), onClick: () => seek(at) },
        { label: selection && at >= selection[0] && at <= selection[1] ? t('Notiz zur Auswahl', 'Note for the selection') : t('Notiz hier', 'Note here'), hint: 'N', onClick: () => addNote(at) },
      )
      if (selection) {
        items.push(
          { label: t('Auswahl abspielen', 'Play the selection'), separator: true, onClick: () => play(selection[0]) },
          { label: t('Auswahl in Schleife', 'Loop the selection'), checked: loop, onClick: () => setLoop(!loop) },
          { label: t('Auf Auswahl zoomen', 'Zoom to the selection'), onClick: () => setView([selection[0], selection[1]]) },
          { label: t('Auswahl exportieren …', 'Export the selection …'), onClick: () => { setExportSec(undefined); setExportOpen(true) } },
          ...(!playerMode ? [{ label: t('Übersetzer-KI für die Auswahl', 'Translation AI for the selection'), onClick: () => {
            api.audioTranscribe(proj.id, { tracks: tracks.filter((x) => x.kind === 'original').map((x) => x.id), source_lang: doc2.source_lang || 'tl', target_lang: doc2.target_lang || 'de', region: selection })
              .then(() => { onNotice(t('Übersetzer-KI läuft für die Auswahl.', 'Translation AI running for the selection.')); onReload() }).catch((err) => onError(String(err.message ?? err)))
          } }] : []),
          { label: t('Auswahl aufheben', 'Clear the selection'), onClick: () => setSelection(null) },
        )
      }
      items.push(
        { label: t('Hineinzoomen', 'Zoom in'), hint: t('Strg+Rad', 'Ctrl+wheel'), separator: true, onClick: () => zoomAround(at, 0.25) },
        { label: t('Herauszoomen', 'Zoom out'), onClick: () => zoomAround(at, 4) },
        { label: t('1 Minute um diese Stelle', '1 minute around here'), onClick: () => setView([Math.max(0, at - 30), Math.min(duration, at + 30)]) },
        { label: t('Alles zeigen', 'Show everything'), onClick: () => setView([0, duration]) },
      )
    } else if (!c.track) {
      items.push({ label: t('Notiz am Abspielkopf', 'Note at the playhead'), hint: 'N', onClick: () => addNote() })
    }
    setMenu({ x: e.clientX, y: e.clientY, items })
  }
  const curTool = toolTabs.some(([k]) => k === tool) ? tool : 'transcript'
  addNoteRef.current = () => addNote()

  if (proj.status !== 'ready') {
    const j = running[0]
    return (
      <div className="fx-ws-wait">
        <button className="btn small ghost" onClick={onBack}>← {t('Übersicht', 'Overview')}</button>
        <h3>{proj.name}</h3>
        {proj.status === 'error' ? <p className="error">{proj.error}</p> : (
          <div className="lt-progress">
            <div className="progress"><div className="bar" style={{ width: `${Math.round((j ? progress[j.id]?.progress ?? 0 : 0) * 100)}%` }} /></div>
            <span className="muted small">{(j && progress[j.id]?.stage) || t('wird eingelesen …', 'reading …')}</span>
          </div>
        )}
        <button className="btn small ghost danger-text" onClick={() => api.audioProjectDelete(proj.id).then(onDeleted).catch((e) => onError(String(e.message ?? e)))}>{t('Fall in den Papierkorb', 'Move case to the trash')}</button>
      </div>
    )
  }

  return (
    <div className={`fx-ws${playerMode ? ' player' : ''}`} ref={root} style={fitH ? { height: fitH } : undefined}>
      <div className="fx-head">
        <button className="btn small ghost" onClick={onBack} title={t('zur Übersicht', 'to the overview')}>←</button>
        <strong className="fx-title">{proj.name}</strong>
        <span className="muted small">
          {isVdr ? `${String(proj.vdr?.product ?? 'VDR')} · ${tracks.filter((x) => x.group === 'VDR').length} ${t('Kanäle', 'channels')}` : proj.source.name} · {fmtClock(duration)}
          {origin ? ` · ${new Date(origin * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC` : ''}
        </span>
        {integrity && (
          <span className={`au-chip${integrity.bad ? ' warn' : ''}`}
            title={t(`Prüfsummen des Schiffsschreibers (${integrity.algorithm}): jede Blockdatei gegen seine eigene Liste`, `Checksums of the recorder (${integrity.algorithm}): every block file against its own list`)}>
            {integrity.bad
              ? t(`${integrity.bad} Dateien abweichend oder fehlend`, `${integrity.bad} files differ or are missing`)
              : t(`✓ ${integrity.ok}/${integrity.files} Blöcke unverändert`, `✓ ${integrity.ok}/${integrity.files} blocks unchanged`)}
          </span>
        )}
        <span className="au-spacer" />
        {headerExtra}
        <button className="btn small primary" onClick={() => { setExportSec(undefined); setExportOpen(true) }} title={t('Ton, Video, Lagebild-Video, Sprache und Notizen exportieren', 'Export audio, video, situation video, speech and notes')}>⤓ {t('Export', 'Export')}</button>
        {!review && <div className="fx-mode">
          <button className={`btn small${playerMode ? ' primary' : ''}`} onClick={() => setMode('player')} title={t('Ansehen, markieren, exportieren; ohne KI', 'View, mark, export; no AI')}>{t('Player', 'Player')}</button>
          <button className={`btn small${!playerMode ? ' primary' : ''}`} onClick={() => setMode('forensic')} title={t('Alle Werkzeuge', 'All tools')}>{t('Forensik', 'Forensics')}</button>
        </div>}
        {headerEnd}
      </div>

      <div className="fx-upper" ref={upperRef}
        style={{ height: layout.upper, gridTemplateColumns: `${layout.left}px 5px minmax(0, 1fr) 5px ${layout.right}px` }}>
        <aside className="fx-left">
          <h4>{t('Spuren', 'Tracks')}</h4>
          {groups.map(([name, list]) => (
            <div key={name} className="fx-group">
              <div className="fx-group-head">{name}</div>
              {list.map((tr) => (
                <div key={tr.id} className="fx-trk">
                  <label className="check small" title={tr.channel?.position || tr.name}>
                    <input type="checkbox" checked={!lanes.hidden[tr.id]} onChange={(e) => setLanes((l) => ({ ...l, hidden: { ...l.hidden, [tr.id]: !e.target.checked } }))} />
                    <span className="au-swatch" style={{ background: tr.color }} />{tr.name}
                  </label>
                  {tr.vad ? <span className="muted small" title={t('Sprache laut Silero VAD', 'Speech according to Silero VAD')}>{fmtDur(tr.vad.speech_seconds)}</span>
                    : tr.activity && <span className="muted small" title={t('Sprachaktivität (grob)', 'Speech activity (rough)')}>{fmtDur(tr.activity.speech_seconds)}</span>}
                </div>
              ))}
            </div>
          ))}
          {!review && <><div className="lt-toolbar fx-left-actions">
            <button className="btn small" disabled={running.some((j) => j.kind === 'audio_vad') || !st.models.find((m) => m.id === 'silero_vad')?.installed}
              onClick={() => api.audioVad(proj.id, tracks.filter((x) => x.kind === 'original' && !lanes.hidden[x.id]).map((x) => x.id)).then(() => { onNotice(t('Sucht Sprache in den sichtbaren Original-Spuren (Silero VAD, Prozessor, rund 45 s je Stunde und Kanal).', 'Finding speech in the visible original tracks (Silero VAD, CPU, about 45 s per hour and channel).')); onReload() }).catch((e) => onError(String(e.message ?? e)))}
              title={t('Silero VAD: zeigt je Kanal, wo gesprochen wird; Grundlage für Übersetzer-KI und „Bester Kanal“', 'Silero VAD: shows per channel where people talk; basis for the translation AI and “Best channel”')}>
              {t('Sprache finden', 'Find speech')}</button>
            {tracks.filter((x) => x.kind === 'original' && (x.channel?.category ?? 'MIC') !== 'VHF').length >= 2 && (
              <button className="btn small" disabled={running.some((j) => j.kind === 'audio_mix')}
                onClick={() => api.audioAutomix(proj.id, tracks.filter((x) => x.kind === 'original' && (x.channel?.category ?? 'MIC') !== 'VHF').map((x) => x.id)).then(() => { onNotice(t('„Bester Kanal“ läuft: je Moment das Mikrofon mit der klarsten Sprache, als neue Spur.', '“Best channel” running: per moment the microphone with the clearest speech, as a new track.')); onReload() }).catch((e) => onError(String(e.message ?? e)))}
                title={t('Wählt je Moment das Mikrofon, auf dem gesprochen wird und das am lautesten ist; ohne Sprache alle gemittelt. Nur Auswahl und Überblendung, kein Kanal wird verändert.', 'Picks per moment the microphone with speech that is loudest; without speech all averaged. Only selection and crossfade, no channel is changed.')}>
                {t('Bester Kanal', 'Best channel')}</button>
            )}
          </div>
          <div className="lt-toolbar">
            <button className="btn small" disabled={tracks.every((x) => x.spec || busyTracks.has(x.id))}
              onClick={() => { for (const x of tracks.filter((y) => !y.spec && !y.offset && !lanes.hidden[y.id])) void spectro(x.id) }}
              title={t('Spektrogramm und Sprachaktivität für alle sichtbaren Spuren rechnen (12 h: rund 1–2 min je Spur, Prozessor)', 'Compute spectrogram and speech activity for all visible tracks (12 h: about 1–2 min per track, CPU)')}>
              {t('Spektrogramme rechnen', 'Compute spectrograms')}</button>
          </div></>}
          <h4>{t('Forensik-Spuren', 'Forensic lanes')}</h4>
          <label className="check small"><input type="checkbox" checked={lanes.notes ?? true} onChange={(e) => setLanes((l) => ({ ...l, notes: e.target.checked }))} />{t('Notizen', 'Notes')} ({notesCount})</label>
          <label className="check small"><input type="checkbox" checked={lanes.events} onChange={(e) => setLanes((l) => ({ ...l, events: e.target.checked }))} />{t('Ereignisse', 'Events')} ({events.length})</label>
          <label className="check small"><input type="checkbox" checked={lanes.transcript} onChange={(e) => setLanes((l) => ({ ...l, transcript: e.target.checked }))} />{t('Übersetzer-Spur', 'Translation track')}</label>
          <label className="check small"><input type="checkbox" checked={lanes.activity} onChange={(e) => setLanes((l) => ({ ...l, activity: e.target.checked }))} />{t('Sprachaktivität', 'Speech activity')}</label>
          {seriesKeys.length > 0 && (
            <>
              <h4>{t('Daten', 'Data')}</h4>
              <div className="fx-series">
                {seriesKeys.map((k) => (
                  <label key={k} className="check small"><input type="checkbox" checked={lanes.data.includes(k)}
                    onChange={(e) => setLanes((l) => ({ ...l, data: e.target.checked ? [...l.data, k] : l.data.filter((x) => x !== k) }))} />
                    {seriesLabel(k, series!.series[k])}</label>
                ))}
              </div>
            </>
          )}
          <h4>{t('Darstellung', 'Display')}</h4>
          <label className="lr-inline small">{t('Spurhöhe', 'Track height')}
            <input type="range" min={28} max={140} step={4} value={lanes.height} onChange={(e) => setLanes((l) => ({ ...l, height: Number(e.target.value) }))} /></label>
          <label className="lr-inline small">{t('Spektrogramm unten', 'Spectrogram floor')}
            <input type="range" min={-120} max={-40} step={1} value={lanes.specLo} onChange={(e) => setLanes((l) => ({ ...l, specLo: Math.min(Number(e.target.value), l.specHi - 10) }))} />{lanes.specLo} dB</label>
          <label className="lr-inline small">{t('oben', 'top')}
            <input type="range" min={-80} max={0} step={1} value={lanes.specHi} onChange={(e) => setLanes((l) => ({ ...l, specHi: Math.max(Number(e.target.value), l.specLo + 10) }))} />{lanes.specHi} dB</label>
          <label className="lr-inline small">{t('bis', 'up to')}
            <select value={lanes.specFmax} onChange={(e) => setLanes((l) => ({ ...l, specFmax: Number(e.target.value) }))}>
              {[2000, 4000, 6000, 8000, 12000].map((f) => <option key={f} value={f}>{f / 1000} kHz</option>)}
            </select></label>
        </aside>

        <div className="fx-vsplit" onPointerDown={dragCol('left')} onDoubleClick={() => resetLayout('left')}
          title={t('Ziehen: Breite der linken Spalte; Doppelklick: zurücksetzen', 'Drag: width of the left column; double-click: reset')} />
        <section className="fx-center">
          <ForensicMonitor proj={proj} tab={monTab} setTab={setMonTab} time={playhead} playing={playing} rate={rate}
            series={series} events={events} images={images} ais={ais} onSeek={seek} segments={doc.segments}
            targetLang={doc.target_lang || 'de'} tracks={tracks} />
        </section>
        <div className="fx-vsplit" onPointerDown={dragCol('right')} onDoubleClick={() => resetLayout('right')}
          title={t('Ziehen: Breite der Werkzeuge; Doppelklick: zurücksetzen', 'Drag: width of the tools; double-click: reset')} />

        <aside className="fx-tools">
          <div className="lr-tabs fx-tool-tabs">
            {toolTabs.map(([k, l]) => <button key={k} className={`lr-tab${curTool === k ? ' on' : ''}`} onClick={() => setTool(k)}>{l}{k === 'notes' && notesCount ? ` (${notesCount})` : ''}</button>)}
          </div>
          <div className="fx-tool-body">
            {(running.length > 0 || paused.length > 0) && (
              <div className="au-jobs">
                {running.map((j) => (
                  <div key={j.id} className="lt-progress">
                    <div className="progress"><div className="bar" style={{ width: `${Math.round((progress[j.id]?.progress ?? 0) * 100)}%` }} /></div>
                    <span className="muted small">{progress[j.id]?.stage || t('wartet', 'queued')}</span>
                    <button className="btn small ghost" onClick={() => api.cancelJob(j.id).catch(() => {})}>{j.kind === 'audio_ai' ? t('Anhalten', 'Pause') : t('Abbrechen', 'Cancel')}</button>
                  </div>
                ))}
                {paused.map((j) => (
                  <div key={j.id} className="au-paused">
                    <span className="small">{t('Angehalten', 'Paused')}: {String(j.params?.op?.model ?? '')}</span>
                    <button className="btn small primary" onClick={() => onResume(j)}>{t('Fortsetzen', 'Resume')}</button>
                    <button className="btn small ghost" onClick={() => onDismiss(j)}>✕</button>
                  </div>
                ))}
              </div>
            )}
            {curTool === 'transcript' && (
              <TranscriptTool proj={proj} tracks={fullTracks} doc={doc} setDoc={setDoc} save={saveDoc} selection={selection} selected={selSeg}
                setSelected={setSelSeg} onSeek={seek} showTranslation={showTr} setShowTranslation={setShowTr} playhead={playhead}
                blind={blind} setBlind={setBlind}
                onTranscribe={(o) => api.audioTranscribe(proj.id, o).then(() => {
                  onNotice(t('Läuft: Sprache finden, erkennen (Whisper large-v3), dann übersetzen (Qwen3.5-9B). Die Blöcke erscheinen danach als Entwurf.',
                    'Running: find speech, recognise it (Whisper large-v3), then translate (Qwen3.5-9B). The blocks then appear as drafts.'))
                  onReload()
                }).catch((e) => onError(String(e.message ?? e)))}
                canTranscribe={asrReady}
                onInstallAsr={() => onInstall(st.models.filter((m) => (m.id === 'whisper_large_v3' || m.id === 'silero_vad') && !m.installed).map((m) => m.id).join(','))}
                busy={running.some((j) => j.kind === 'audio_transcribe')} ai={!playerMode} />
            )}
            {curTool === 'enhance' && (
              <>
                <FilterTool proj={proj} tracks={fullTracks} selection={selection} onError={onError} onNotice={onNotice} onReload={onReload} />
                <h4>{t('Mit KI entrauschen', 'Denoise with AI')}</h4>
                <AiTool st={st} proj={proj} tool="denoise" tracks={fullTracks} selection={selection} span={span} busy={!!busyJob}
                  setupBusy={setupBusy} onInstall={onInstall} onError={onError} onNotice={onNotice} onReload={onReload} />
              </>
            )}
            {curTool === 'separate' && (
              <AiTool st={st} proj={proj} tool="separate" tracks={fullTracks} selection={selection} span={span} busy={!!busyJob}
                setupBusy={setupBusy} onInstall={onInstall} onError={onError} onNotice={onNotice} onReload={onReload} />
            )}
            {curTool === 'learn' && (
              <LearnTool st={st} proj={proj} tracks={fullTracks} selection={selection} busy={!!busyJob} markers={markers}
                onAddMarkers={(list) => saveMarkers([...markers, ...list])}
                onSeek={(s) => { seek(s); setSelection(null) }} onSelect={(a, b) => setSelection([a, b])}
                onDeleteMarker={(m) => saveMarkers(markers.filter((x) => x.id !== m.id))}
                onError={onError} onNotice={onNotice} onReload={onReload} />
            )}
            {curTool === 'video' && (
              <VideoLink proj={proj} busy={running.some((j) => j.kind === 'audio_align')} onError={onError} onNotice={onNotice} onReload={onReload}
                onExport={() => { setExportSec('video'); setExportOpen(true) }} />
            )}
            {curTool === 'export' && (
              <>
                <ExportPanel proj={proj} tracks={fullTracks} doc={doc} markers={markers} selection={selection} view={view} lanesView={lanes.view}
                  imageSources={images?.sources ?? []} spec={{ lo: lanes.specLo, hi: lanes.specHi, fmax: lanes.specFmax }}
                  busy={(k) => running.some((j) => j.kind === k)} onError={onError} onNotice={onNotice} onReload={onReload} compact />
              </>
            )}
            {curTool === 'notes' && (
              <NotesTool proj={proj} markers={markers} save={(list) => { void saveMarkers(list) }} onSeek={seek} onSelect={(a, b) => setSelection([a, b])}
                focus={noteFocus} onFocused={() => setNoteFocus(null)} playhead={playhead} selection={selection} onAdd={() => addNote()} />
            )}
            {curTool === 'log' && (
              <div className="au-history">
                <p className="hint small">{t('Jeder Schritt mit Zeit und Einstellungen; das Original bleibt unverändert, jede Bearbeitung ist eine neue Spur.', 'Every step with time and settings; the original stays untouched, every operation is a new track.')}</p>
                {integrity && <p className="small">{t('Prüfsummen des Schiffsschreibers', 'Checksums of the recorder')}: {integrity.ok}/{integrity.files} {t('in Ordnung', 'OK')} ({integrity.algorithm}){integrity.bad ? t(`, ${integrity.bad} abweichend`, `, ${integrity.bad} differ`) : ''}</p>}
                {!isVdr && (
                  <div className="fx-hash small">
                    <strong>{t('Quelle', 'Source')}</strong> {proj.source.name}
                    {proj.source.sha256
                      ? <><br /><span className="muted">SHA-256</span> <code>{proj.source.sha256}</code>
                        <br /><span className="muted">{t(`${((proj.source.size ?? 0) / 1024 ** 2).toFixed(1)} MB, berechnet ${new Date((proj.source.sha256_time ?? 0) * 1000).toLocaleString()}`,
                          `${((proj.source.size ?? 0) / 1024 ** 2).toFixed(1)} MB, computed ${new Date((proj.source.sha256_time ?? 0) * 1000).toLocaleString()}`)}</span></>
                      : <> · <button className="btn small" onClick={() => api.audioHash(proj.id).then(onReload).catch((e) => onError(String(e.message ?? e)))}>{t('Prüfsumme berechnen', 'Compute checksum')}</button></>}
                  </div>
                )}
                {events.length > 0 && (
                  <button className="btn small" onClick={() => {
                    const q = (v: string) => `"${String(v ?? '').replace(/"/g, '""')}"`
                    const rows = ['t_s;end_s;utc;kind;label;detail;source', ...events.map((e) => [e.t.toFixed(2), e.end == null ? '' : e.end.toFixed(2),
                      clockAt(e.t, origin, true), e.kind, q(e.label), q(e.detail), q(e.source)].join(';'))]
                    const url = URL.createObjectURL(new Blob(['\ufeff' + rows.join('\n')], { type: 'text/csv;charset=utf-8' }))
                    const a = document.createElement('a')
                    a.href = url
                    a.download = `${proj.name.replace(/[^\w\-. ]+/g, '_')}_ereignisse.csv`
                    a.click()
                    window.setTimeout(() => URL.revokeObjectURL(url), 2000)
                  }}>{t(`${events.length} Ereignisse als CSV`, `${events.length} events as CSV`)}</button>
                )}
                {[...(proj.history ?? [])].reverse().map((h, i) => (
                  <div key={i} className="small">
                    <span className="muted">{new Date(h.time * 1000).toLocaleString()}</span> · {h.op === 'export'
                      ? <>{t('Export', 'export')} {h.format}: {h.path
                        ? <><span className="fx-path">{h.path}</span> <button className="linklike small"
                          onClick={() => { api.audioReveal(proj.id, (proj.history ?? []).length - 1 - i).catch((e) => onError(String(e.message ?? e))) }}>
                          {t('im Ordner zeigen', 'show in folder')}</button></>
                        : review ? <span className="fx-path">{h.file}</span> : <a href={fileUrl(h.file)} target="_blank" rel="noreferrer">{h.file}</a>}</>
                      : <>{h.label ?? h.op}{h.region ? ` (${t('Auswahl', 'selection')})` : ''}{h.seconds ? ` · ${fmtDur(h.seconds)}` : ''}</>}
                  </div>
                ))}
                {!review && <div className="lt-toolbar lt-danger">
                  {confirmDelete ? (
                    <>
                      <button className="btn small danger-text" onClick={() => api.audioProjectDelete(proj.id).then(onDeleted).catch((e) => onError(String(e.message ?? e)))}>
                        {t(`Fall mit ${tracks.length} Spuren in den Papierkorb (wiederherstellbar, die Quelle bleibt)`, `Move the case with ${tracks.length} tracks to the trash (restorable, the source stays)`)}</button>
                      <button className="btn small ghost" onClick={() => setConfirmDelete(false)}>{t('Nein', 'No')}</button>
                    </>
                  ) : <button className="btn small ghost danger-text" onClick={() => setConfirmDelete(true)}>{t('Fall löschen …', 'Delete case …')}</button>}
                </div>}
              </div>
            )}
          </div>
        </aside>
      </div>

      <div className="fx-hsplit" onPointerDown={dragRow} onDoubleClick={() => resetLayout('upper')}
        title={t('Ziehen: nach oben mehr Platz für die Spuren; Doppelklick: zurücksetzen', 'Drag: up gives the tracks more room; double-click: reset')} />
      <div className="au-transport fx-transport">
        <button className="btn primary au-play" onClick={toggle} title={t('Leertaste', 'space')}>{playing ? '⏸' : '▶'}</button>
        <button className="btn small" onClick={() => seek(selection ? selection[0] : 0)} title={t('zum Anfang', 'to start')}>⏮</button>
        <span className="au-time">{clockAt(playhead, origin, true)}{origin ? <span className="muted small"> UTC · {fmtClock(playhead)}</span> : null}</span>
        <input className="fx-timein" value={timeText} onChange={(e) => setTimeText(e.target.value)}
          placeholder={origin ? t('Zeit (UTC) …', 'Time (UTC) …') : t('Zeit …', 'Time …')}
          title={t(origin ? 'Uhrzeit UTC eintippen (hh:mm:ss), mit + davor ab Beginn der Aufnahme; Enter springt hin' : 'Zeit eintippen (h:mm:ss); Enter springt hin',
            origin ? 'Type a UTC time (hh:mm:ss), with a leading + from the start of the recording; Enter jumps there' : 'Type a time (h:mm:ss); Enter jumps there')}
          onKeyDown={(e) => {
            if (e.key !== 'Enter') return
            const x = parseClock(timeText, origin, duration)
            if (x == null) { onError(t('Zeit nicht verstanden: hh:mm:ss eintippen.', 'Time not understood: type hh:mm:ss.')); return }
            seek(x)
            setTimeText('')
            ;(e.target as HTMLInputElement).blur()
          }} />
        <label className="lr-inline small" title={t('Tempo ohne Tonhöhenänderung, zum Mitschreiben', 'Speed without pitch change, for transcribing')}>{t('Tempo', 'Speed')}
          <select value={rate} onChange={(e) => setRate(Number(e.target.value))}>
            {RATES.map((r) => <option key={r} value={r}>{Math.round(r * 100)} %</option>)}
          </select></label>
        {selection && (
          <span className="au-selinfo">{t('Auswahl', 'selection')} {clockAt(selection[0], origin, true)} – {clockAt(selection[1], origin, true)} ({fmtClock(selection[1] - selection[0], true)})
            <button className="btn small ghost" onClick={() => setSelection(null)}>✕</button></span>
        )}
        <label className="check small"><input type="checkbox" checked={loop} onChange={(e) => setLoop(e.target.checked)} disabled={!selection} />{t('Schleife', 'loop')}</label>
        <button className="btn small" onClick={() => addNote()} title={t('Notiz am Abspielkopf oder zur Auswahl (Taste N)', 'Note at the playhead or for the selection (N key)')}>+ {t('Notiz', 'Note')}</button>
        <span className="au-spacer" />
        <span className="muted small fx-keys">{t('Leertaste ▶ · ←/→ 2 s (⇧ 10 s) · N Notiz · Strg+Rad zoomt · Rechtsklick: Menü', 'Space ▶ · ←/→ 2 s (⇧ 10 s) · N note · Ctrl+wheel zooms · right-click: menu')}</span>
        <button className="btn small" onClick={() => setView([0, duration])}>{t('Alles', 'All')}</button>
        <button className="btn small" disabled={!selection} onClick={() => selection && setView([selection[0], selection[1]])}>{t('Auswahl', 'Selection')}</button>
        <button className="btn small" onClick={() => { const c = playhead, h = 30; setView([Math.max(0, c - h), Math.min(duration, c + h)]) }} title={t('1 Minute um den Abspielkopf', '1 minute around the playhead')}>1 min</button>
        <button className="btn small" onClick={() => { const c = (view[0] + view[1]) / 2, h = (view[1] - view[0]) / 4; setView([Math.max(0, c - h), Math.min(duration, c + h)]) }}>＋</button>
        <button className="btn small" onClick={() => { const c = (view[0] + view[1]) / 2, h = (view[1] - view[0]); setView([Math.max(0, c - h), Math.min(duration, c + h)]) }}>－</button>
      </div>

      <div className="fx-lanes-wrap">
        <ForensicLanes pid={proj.id} tracks={tracks} peaks={peaks} sr={sr} duration={duration} view={view} setView={setView}
          selection={selection} setSelection={setSelection} playhead={playhead} onSeek={seek} markers={markers}
          onMarkerSelect={(m) => { if (m.end > m.start) setSelection([m.start, m.end]); seek(m.start) }} onMarkerDelete={(m) => saveMarkers(markers.filter((x) => x.id !== m.id))}
          onTrack={setTrack} onTrackDelete={(id) => api.audioTrackDelete(proj.id, id).then(onReload).catch((e) => onError(String(e.message ?? e)))}
          onSpectro={(id) => void spectro(id)} lanes={lanes} setLanes={setLanes} origin={origin}
          segments={doc.segments} showTranslation={showTr} targetLang={doc.target_lang || 'de'} flipped={flipped} blind={blind}
          onFlip={(id) => setFlipped((f) => ({ ...f, [id]: !f[id] }))}
          onSegment={(s: TranscriptSegment) => { setSelSeg(s.id); setTool('transcript'); seek(s.start) }} selectedSegment={selSeg}
          events={lanes.events ? events.filter((e) => e.kind !== 'system') : []} onEvent={(e) => { seek(Math.max(0, e.t - 1)); if (e.end != null) setSelection([e.t, e.end]); setMonTab(isVdr ? 'events' : monTab) }}
          series={series} busyTracks={busyTracks} headWidth={layout.head ?? HEAD_WIDTH} onHeadWidth={(w) => setLayout({ ...layout, head: w })}
          onContext={openMenu} onNoteEdit={(m) => { setTool('notes'); setNoteFocus(m.id) }} />
      </div>
      <ContextMenu menu={menu} onClose={() => setMenu(null)} />
      {exportOpen && (
        <ExportDialog initial={exportSec} proj={proj} tracks={fullTracks} doc={doc} markers={markers} selection={selection} view={view} lanesView={lanes.view}
          imageSources={images?.sources ?? []} spec={{ lo: lanes.specLo, hi: lanes.specHi, fmax: lanes.specFmax }}
          busy={(k) => running.some((j) => j.kind === k)} onError={onError} onNotice={(m) => { onNotice(m) }} onReload={onReload}
          onClose={() => setExportOpen(false)} />
      )}
      <div className="fx-legend small muted">
        {Object.entries(EVENT_COLOR).filter(([k]) => events.some((e) => e.kind === k)).map(([k, c]) => (
          <span key={k}><span className="fx-dot" style={{ background: c }} />{k}</span>
        ))}
      </div>
    </div>
  )
}

