// Studio (Nutzer 26.10.2026): eigener Bereich über den ganzen Bildschirm. Oben Medienleiste, Programmmonitor und
// Eigenschaften, unten die Komposition (Szenen mit Prompts, Marker) über dem Schnitt (echte Clips auf Spuren).
// Jede Änderung ist ein Befehl an den Server (/api/studio/projects/{id}/command), die gleichen nutzt Claude per MCP.
//
// Schnittwerkzeuge (Nutzer 27.10.2026, Vorbild FilmCraft, „simpel und überschaubar“): Werkzeuge und Magnet in der
// Zeitleiste, Rechtsklick-Menüs überall (hier gebaut, weil sie Zwischenablage, Erzeugen und Export brauchen),
// Kopieren/Ausschneiden/Einfügen, Spuren hinzufügen und schalten, Geschwindigkeit mit Rückfrage bei Kollision,
// „Übernehmen“ mit Rückfrage, Projekte als Paket exportieren und importieren.
//
// Konzept „NVAI im Fluss“ (seit 0.5.42): unter der Werkzeugleiste eine Schrittleiste mit einem Knopf für den nächsten
// Schritt samt Zeit und die Szenen als Karten mit ihrem Zustand (Bildschirm D, flow/studio/FlowBar.tsx); die
// Eigenschaften einer Szene zeigen oben ihren Zustand mit dem passenden Knopf (Bildschirm E). Die Knöpfe der Leiste
// bleiben, treten aber hinter den einen Knopf zurück.

import { useCallback, useEffect, useMemo, useRef, useState, type MouseEvent as RMouseEvent, type PointerEvent as RPointerEvent } from 'react'
import {
  api,
  TPS,
  type Asset,
  type ModelInfo,
  type ServerEvent,
  type StudioChangedEvent,
  type StudioClip,
  type StudioMarker,
  type StudioMarkerKind,
  type StudioProject,
  type StudioProjectInfo,
  type StudioScene,
  type StudioTransitionKind,
} from '../api'
import type { Downloads } from '../downloads'
import '../flow/studio.css'
import { FlowBar } from '../flow/studio/FlowBar'
import { trackJob } from '../flow/jobs'
import { presetShort, reorderStarts, sceneOrder, type ExportInfo, type FocusField, type Next, type SceneFlow, type StartRun } from '../flow/studio/logic'
import { t } from '../i18n'
import { Bin, mediaKind } from '../studio/Bin'
import { ConformDialog, type ConformPlan } from '../studio/ConformDialog'
import { ContextMenu, type MenuItem, type MenuState } from '../studio/ContextMenu'
import { Inspector, MARKER_LABEL } from '../studio/Inspector'
import { Monitor } from '../studio/Monitor'
import { selIds, Timelines, TRANSITION_LABEL, type MenuTarget, type Selection, type Tool } from '../studio/Timelines'
import { Wizard, WizardAsk, WizardCoach, wizardAskWanted } from '../studio/Wizard'
import { clipEnd, clipSpeed, decimal, frameTicks, sec, snapFrame, trackKind, trackLabel, trackOrHighest, tracksOf } from '../studio/time'

const KEY_PROJECT = 'nvai-studio-project'
const KEY_ZOOM = 'nvai-studio-zoom'
const KEY_SPLIT = 'nvai-studio-split'
const KEY_MAGNET = 'nvai-studio-magnet'
const KEY_BIN = 'nvai-studio-bin-width'
const BIN_WIDTH = 240
// Eigenschaftenspalte rechts, verstellbar wie die Materialspalte (Nutzer 31.10.2026: „die rechte panele mit promts und
// einstellungen soll auch wie die linke panelle mit medien breiten verstellbar sein“)
const KEY_SIDE = 'nvai-studio-side-width'
const SIDE_WIDTH = 330
const SIDE_MIN = 260
const BIN_MIN = 180
// Beide Seitenspalten lassen sich so breit ziehen, bis die Vorschau nur noch diese Breite hat (Nutzer 25.11.2026:
// „‚Project‘ bereich im studio soll sich noch viel weiter breiter machen lassen“; bis 0.5.39 höchstens 640 px)
const MONITOR_MIN = 200
const SPLITTERS = 10

function stored(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}
function store(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* privates Fenster: dann eben nicht merken */
  }
}

interface ExportState {
  id: string
  progress: number
  stage: string
  status: 'running' | 'done' | 'error'
  url?: string
  error?: string
  /** Stand des Schnitts beim Start: Ändert er sich danach, schlägt die Leiste wieder „Exportieren“ vor */
  sig?: string
}

/** Fingerabdruck des Schnitts (Clips, Spuren, Format) für „ist der Export noch aktuell?“ */
function editSig(p: StudioProject): string {
  return JSON.stringify([p.clips.map((c) => [c.id, c.track, c.asset_id, c.start, c.in, c.out, c.speed, c.gain_db, c.muted,
    c.transition?.kind, c.transition?.duration, c.scale, c.anchor, c.scale_keys]), p.tracks, p.settings.width, p.settings.height, p.settings.fps])
}

// Leiste mit dem nächsten Schritt auf (1) oder zu (0), Vorgabe auf; ihre Kartenreihe der Szenen auf (1) oder zu (0),
// Vorgabe zu (Nutzer 26.11.2026: „standard ausgeklappt (unterelemente zugeklappt)“)
const KEY_FLOW = 'nvai-studio-flow'
const KEY_CARDS = 'nvai-studio-cards'

/** Zwischenablage des Studios: Clips, Szenen oder Marker samt Abstand zum frühesten (anchor). */
type Clipboard =
  | { type: 'clip'; anchor: number; items: StudioClip[] }
  | { type: 'scene'; anchor: number; items: StudioScene[] }
  | { type: 'marker'; anchor: number; items: StudioMarker[] }

/** Rückfrage, wenn ein langsamerer Clip an den nächsten stößt */
interface SpeedAsk {
  clip: StudioClip
  speed: number
  hits: StudioClip[]
  longer: number
}

const SPEEDS = [25, 50, 75, 100, 150, 200, 400]

function megabytes(bytes: number): string {
  return bytes >= 1e9 ? `${decimal((bytes / 1e9).toFixed(1))} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`
}

/** Exportvorlage nach dem Projektformat (Nutzertest 26.11.2026: ein Hochkant-Projekt ging sonst als 1920 × 1080 hinaus):
 *  hochkant die Shorts-Vorlage, 4K YouTube 4K, 1920 × 1080 YouTube 1080p, andere Größen im Projektformat */
function presetForFormat(w: number, h: number): string {
  if (h > w) return 'shorts-1080x1920'
  if (w >= 3840 && h >= 2160) return 'youtube-2160p'
  return w === 1920 && h === 1080 ? 'youtube-1080p' : 'project'
}

/** Schmales Fenster (bis 900 px): ohne Materialspalte (wie styles.css) */
const NARROW = '(max-width: 900px)'

export function StudioPanel({ event, studioEvent, assetsVersion, modelsVersion = 0, visible = true, onShowModels, downloads, focus, wizard = 0 }: {
  event: ServerEvent | null
  studioEvent: StudioChangedEvent | null
  assetsVersion: number
  /** zählt hoch, wenn eine LoRA hinzukam, zugeordnet oder gelöscht wurde: Modellliste (Figuren) neu laden */
  modelsVersion?: number
  /** Das Studio bleibt beim Reiterwechsel bestehen (seit 26.11.2026) und ist dann nur ausgeblendet */
  visible?: boolean
  /** Reiter „Modelle“ öffnen (fehlendes Modell einer Szene) */
  onShowModels?: () => void
  /** Downloads der App: Ein fehlendes Modell einer Szene lädt an Ort und Stelle (seit 0.5.42, ModelNeed) */
  downloads?: Downloads
  /** Projekt öffnen und Szene wählen (Auftragsleiste, „Ins Studio“ im Reiter Generieren); n zählt je Klick hoch */
  focus?: { projectId: string; sceneId?: string | null; n: number } | null
  /** zählt hoch, wenn der Willkommen-Bildschirm „Ein Video mit Ton“ startet: Assistenten öffnen */
  wizard?: number
}) {
  const [projects, setProjects] = useState<StudioProjectInfo[]>([])
  const [project, setProject] = useState<StudioProject | null>(null)
  const [selection, setSelection] = useState<Selection>(null)
  const [playhead, setPlayhead] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [zoom, setZoomState] = useState(() => Number(stored(KEY_ZOOM)) || 40)
  // Niedrige Fenster (14-Zoll-Notebook): anfangs etwas weniger Zeitleiste, damit Vorschau und Eigenschaften Platz haben
  const [split, setSplit] = useState(() => Number(stored(KEY_SPLIT)) || (window.innerHeight < 800 ? 38 : 44))
  const [binWidth, setBinWidth] = useState(() => Number(stored(KEY_BIN)) || BIN_WIDTH)
  const [sideWidth, setSideWidth] = useState(() => Number(stored(KEY_SIDE)) || SIDE_WIDTH)
  // Erzeugen: Fortschritt je Auftrag aus dem Live-Feed, Anzahl der Szenen dieses Laufs, Rückfrage beim Abbrechen
  const [jobProgress, setJobProgress] = useState<Record<string, { progress: number; stage: string }>>({})
  const [runTotal, setRunTotal] = useState(0)
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [models, setModels] = useState<ModelInfo[]>([])
  const [active, setActive] = useState<Partial<Record<string, string | null>>>({})
  const [presets, setPresets] = useState<{ id: string; label: string; ext: string }[]>([])
  const [preset, setPreset] = useState('youtube-1080p')
  const [exporting, setExporting] = useState<ExportState | null>(null)
  const [binKey, setBinKey] = useState(0)
  const [source, setSource] = useState<Asset | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [fullscreen, setFullscreen] = useState(!!document.fullscreenElement)
  const [tool, setTool] = useState<Tool>('select')
  const [magnet, setMagnetState] = useState(() => stored(KEY_MAGNET) === '1')
  const [menu, setMenu] = useState<MenuState | null>(null)
  const [clipboard, setClipboard] = useState<Clipboard | null>(null)
  const [conformPlan, setConformPlan] = useState<ConformPlan | null>(null)
  const [speedAsk, setSpeedAsk] = useState<SpeedAsk | null>(null)
  // Assistent (seit 0.5.28): Frage beim Start und bei neuen Projekten, der Assistent selbst, Hinweise danach
  const [askWizard, setAskWizard] = useState(false)
  const [wizardOpen, setWizardOpen] = useState(false)
  const [coach, setCoach] = useState(false)
  // Konzept „NVAI im Fluss“ (seit 0.5.42): „Startbild erzeugen“ je Szene, Kartenreihe auf/zu, Feld für den Blick nach
  // einem Klick auf den großen Knopf
  const [startRuns, setStartRuns] = useState<Record<string, StartRun>>({})
  const [flowOpen, setFlowOpen] = useState(() => stored(KEY_FLOW) !== '0')
  const [cardsOpen, setCardsOpen] = useState(() => stored(KEY_CARDS) === '1')
  const [focusField, setFocusField] = useState<{ scene: string; field: FocusField; n: number } | null>(null)
  const root = useRef<HTMLDivElement>(null)
  const upper = useRef<HTMLDivElement>(null)
  const importInput = useRef<HTMLInputElement>(null)
  const pid = project?.id

  const setZoom = useCallback((z: number) => {
    setZoomState(z)
    store(KEY_ZOOM, String(z))
  }, [])
  const setMagnet = useCallback((on: boolean) => {
    setMagnetState(on)
    store(KEY_MAGNET, on ? '1' : '0')
  }, [])
  const closeMenu = useCallback(() => setMenu(null), [])

  const openSeq = useRef(0)
  const open = useCallback(async (id: string) => {
    const seq = ++openSeq.current
    try {
      const p = await api.studioProject(id)
      if (seq !== openSeq.current) return  // inzwischen ein anderes Projekt gewählt: dessen Antwort gilt
      setProject(p)
      setExporting(null)  // die Anzeige gehörte zum vorigen Projekt
      setSelection(null)
      setPlayhead(0)
      setPlaying(false)
      store(KEY_PROJECT, id)
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }, [])

  // Wunsch von außen (focus): gilt vor dem zuletzt offenen Projekt, auch wenn die Liste erst danach ankommt
  const focusTaken = useRef(0)
  useEffect(() => {
    api.studioProjects().then((list) => {
      setProjects(list)
      if (focusTaken.current) return
      const last = stored(KEY_PROJECT)
      const pick = list.find((x) => x.id === last) ?? list[0]
      if (pick) open(pick.id)
    }).catch((e) => setNotice(String((e as Error).message ?? e)))
    api.health().then((h) => setActive(h.active_models)).catch(() => {})
    api.studioPresets().then(setPresets).catch(() => {})
  }, [open])

  // Beim Start des Studios fragen, ob der Assistent führen soll (einmal je Sitzung; Nutzer 14.11.2026: „beim start von
  // dem studio oder neuen Projekt soll es mich fragen ob ich geführt werden will, mit dem kästchen nicht mehr anzeigen“)
  useEffect(() => {
    if (!wizardAskWanted()) return
    try {
      if (sessionStorage.getItem('nvai-wizard-asked')) return
      sessionStorage.setItem('nvai-wizard-asked', '1')
    } catch {
      /* ohne Sitzungsspeicher: trotzdem einmal fragen */
    }
    setAskWizard(true)
  }, [])

  // Willkommen-Bildschirm „Ein Video mit Ton“ (seit 0.5.42): den Assistenten öffnen; wizard zählt je Start hoch
  const wizardSeen = useRef(0)
  useEffect(() => {
    if (!wizard || wizard === wizardSeen.current) return
    wizardSeen.current = wizard
    setAskWizard(false)
    setWizardOpen(true)
  }, [wizard])

  // Sprachmodelle gehören dazu (Sprecher-Bahn), sonst bot die Auswahl dort nur „aktives Modell“ (bis 0.5.21); LoRAs für
  // die Figuren (seit 0.5.24), neu geladen, wenn eine hinzukommt oder sich ihre Zuordnung ändert
  const loadModels = useCallback(() => {
    Promise.all([api.models('image'), api.models('video'), api.models('audio'), api.models('speech'), api.models('lora')])
      .then((lists) => setModels(lists.flat()))
      .catch(() => {})
  }, [])
  useEffect(() => {
    loadModels()
  }, [modelsVersion, loadModels])
  // Ein Modell, das eine Szene an Ort und Stelle geladen hat (ModelNeed): Liste neu lesen, die Szene ist dann bereit
  useEffect(() => {
    if (downloads?.finished) {
      loadModels()
      api.health().then((h) => setActive(h.active_models)).catch(() => {})
    }
  }, [downloads?.finished, loadModels])

  // Ausgeblendet (anderer Reiter): Wiedergabe und Medien anhalten, Menü zu. Wieder sichtbar: aktive und geladene Modelle
  // neu lesen, sie können sich unter „Modelle“ geändert haben (vorher kam das Studio jedes Mal frisch)
  const wasHidden = useRef(false)
  useEffect(() => {
    if (!visible) {
      wasHidden.current = true
      setPlaying(false)
      setMenu(null)
      root.current?.querySelectorAll('video, audio').forEach((el) => (el as HTMLMediaElement).pause())
    } else if (wasHidden.current) {
      api.health().then((h) => setActive(h.active_models)).catch(() => {})
      loadModels()
    }
  }, [visible, loadModels])

  // Schmale Fenster: Vorschau und Eigenschaften ohne die Materialspalte. Vorher blendete styles.css sie aus, die fünf
  // Spalten im style blieben aber, und Vorschau und Eigenschaften rutschten in die 5-px-Spalten der Trennlinien.
  const [narrow, setNarrow] = useState(() => window.matchMedia(NARROW).matches)
  useEffect(() => {
    const mq = window.matchMedia(NARROW)
    const on = () => setNarrow(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])

  // Exportvorlage passend zum Format des Projekts, bis man selbst eine wählt (je Projekt)
  const presetTouched = useRef(false)
  const formatW = project?.settings.width
  const formatH = project?.settings.height
  useEffect(() => {
    presetTouched.current = false
  }, [pid])
  useEffect(() => {
    if (formatW && formatH && !presetTouched.current) setPreset(presetForFormat(formatW, formatH))
  }, [pid, formatW, formatH])

  // Eine Antwort nur übernehmen, wenn sie nicht älter ist als der Stand, den die Ansicht schon hat: GET und Befehle laufen
  // im Server nebeneinander, ein spätes GET setzte sonst einen überholten Stand (etwa ein eben Rückgängig-gemachtes)
  const accept = useCallback((next: StudioProject) => {
    // auch keine Antwort eines anderen Projekts (ein Befehl an das vorige, der nach dem Wechsel ankommt)
    setProject((cur) => (cur && (cur.id !== next.id || (next.updated_at ?? 0) < (cur.updated_at ?? 0)) ? cur : next))
  }, [])

  const reload = useCallback(async () => {
    if (!pid) return
    try {
      accept(await api.studioProject(pid))
    } catch {
      /* bleibt beim alten Stand */
    }
  }, [pid])

  const run = useCallback(
    async (command: string, params: Record<string, unknown> = {}) => {
      if (!pid) return undefined
      try {
        const r = await api.studioCommand(pid, command, params)
        accept(r.project)
        setNotice(null)
        return r.result
      } catch (e: any) {
        setNotice(String(e.message ?? e))
        return undefined
      }
    },
    [pid],
  )

  // Von außen (seit 0.5.42): Projekt öffnen und Szene wählen, aus der Auftragsleiste („Zeigen“) oder nach „Ins Studio“
  // im Reiter Generieren. n zählt je Klick hoch, derselbe Wunsch kommt also nur einmal an.
  const focusScene = useRef<string | null>(null)
  useEffect(() => {
    if (!focus || !focus.n || focus.n === focusTaken.current) return
    focusTaken.current = focus.n
    setAskWizard(false)
    const go = async () => {
      if (focus.projectId !== pid) {
        // ein eben angelegtes Projekt kennt die Liste vielleicht noch nicht
        await api.studioProjects().then(setProjects).catch(() => {})
        await open(focus.projectId)
      } else {
        await reload()
      }
      if (focus.sceneId) {
        focusScene.current = focus.sceneId
        setSelection({ type: 'scene', id: focus.sceneId })
      }
    }
    void go()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focus?.n])
  // Die gewählte Szene in der Kartenreihe zeigen (nur nach einem Wunsch von außen, sonst springt nichts)
  useEffect(() => {
    if (!focusScene.current || selection?.type !== 'scene' || selection.id !== focusScene.current) return
    const id = focusScene.current
    focusScene.current = null
    window.requestAnimationFrame(() => {
      root.current?.querySelector(`[data-scene-card="${CSS.escape(id)}"]`)?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
    })
  }, [selection, project])

  // Projekt anderswo geändert (Claude per MCP, ein fertiger Auftrag, ein Anschluss, der jetzt startet)
  useEffect(() => {
    if (!studioEvent) return
    if (studioEvent.project_id === pid) {
      if (studioEvent.updated_at !== project?.updated_at) reload()
      return
    }
    // Ein Projekt, das die Liste noch nicht kennt (Claude legt per MCP eins an): Liste auffrischen und, wenn gerade
    // keins offen ist, gleich öffnen
    if (!projects.some((x) => x.id === studioEvent.project_id)) {
      api.studioProjects().then((list) => {
        setProjects(list)
        if (!pid && list.some((x) => x.id === studioEvent.project_id)) open(studioEvent.project_id)
      }).catch(() => {})
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [studioEvent])

  // Live-Feed: fertige Szenen neu laden, Export-Fortschritt anzeigen, Medienleiste auffrischen
  // Solange ein Export läuft, alle 5 s beim Server nachfragen: Kommen zwei Ereignisse vor dem nächsten Rendern an, sieht
  // die Ansicht nur das letzte, und ein Serverneustart meldet abgebrochene Aufträge gar nicht. Vorher blieb die Anzeige
  // dann auf „läuft“ und „Exportieren“ gesperrt
  const exportId = exporting?.status === 'running' ? exporting.id : null
  useEffect(() => {
    if (!exportId) return
    const timer = window.setInterval(() => {
      api.job(exportId).then((j) => {
        if (j.status === 'running' || j.status === 'queued') return
        if (j.status === 'done') {
          api.jobAssets(j.id).then((a) => setExporting((x) => (x && x.id === j.id ? { ...x, status: 'done', progress: 1, url: a[0]?.url } : x)))
          setBinKey((k) => k + 1)
        } else {
          setExporting((x) => (x && x.id === j.id ? { ...x, status: 'error', error: j.error || t('Export abgebrochen.', 'Export cancelled.') } : x))
        }
      }).catch(() => {})
    }, 5000)
    return () => window.clearInterval(timer)
  }, [exportId])

  useEffect(() => {
    if (!event || !('job_id' in event)) return
    if (exporting && event.job_id === exporting.id) {
      if (event.type === 'job.progress') setExporting({ ...exporting, progress: event.progress, stage: event.stage })
      if (event.type === 'job.error') setExporting({ ...exporting, status: 'error', error: event.error })
      if (event.type === 'job.cancelled') setExporting({ ...exporting, status: 'error', error: t('Export abgebrochen.', 'Export cancelled.') })
      if (event.type === 'job.done') {
        api.jobAssets(event.job_id).then((a) => setExporting({ ...exporting, status: 'done', progress: 1, url: a[0]?.url }))
        setBinKey((k) => k + 1)
      }
      return
    }
    // Export, den Claude per MCP gestartet hat: Fortschritt genauso zeigen wie bei einem Klick auf „Exportieren“
    if (event.type === 'job.started' && pid && exporting?.status !== 'running') {
      api.job(event.job_id).then((j) => {
        if (j.kind === 'studio_export' && j.params?.project_id === pid) {
          setExporting({ id: j.id, progress: j.progress ?? 0, stage: j.stage || t('läuft', 'running'), status: 'running', sig: project ? editSig(project) : undefined })
        }
      }).catch(() => {})
    }
    if (event.type === 'job.done') setBinKey((k) => k + 1)
    const ofScene = project?.scenes.some((s) => s.jobs.includes(event.job_id))
    if (ofScene && (event.type === 'job.progress' || event.type === 'job.started')) {
      const progress = event.type === 'job.progress' ? event.progress : 0
      const stage = event.type === 'job.progress' ? event.stage : t('startet', 'starting')
      setJobProgress((m) => ({ ...m, [event.job_id]: { progress, stage } }))
    }
    if (['job.done', 'job.error', 'job.cancelled'].includes(event.type) && ofScene) {
      setJobProgress((m) => {
        const next = { ...m }
        delete next[event.job_id]
        return next
      })
      reload()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [event])

  const generate = useCallback(
    async (ids?: string[]) => {
      if (!pid) return
      try {
        const r = await api.studioGenerate(pid, ids)
        await reload()
        const errors = Object.values(r.errors)
        const n = Object.keys(r.jobs).length
        const w = Object.keys(r.waiting ?? {}).length
        const later = w ? t(` ${w} Anschluss-Szene(n) folgen, sobald ihre Vorlage fertig ist.`, ` ${w} chained scene(s) follow once the scene before is done.`) : ''
        setNotice(
          errors.length
            ? t(`${n} Szene(n) in Arbeit, ${errors.length} nicht: ${errors[0]}`, `${n} scene(s) queued, ${errors.length} not: ${errors[0]}`) + later
            : n || w
              ? t(`${n} Szene(n) in Arbeit. Fertige erscheinen als Take.`, `${n} scene(s) queued. Finished ones appear as takes.`) + later
              : t('Alle Szenen haben schon einen Take. Eine Szene wählen, dann erzeugt „Gewählte erzeugen“ sie neu (auch eine kopierte Szene, die den Take ihrer Vorlage mitbringt).',
                'Every scene already has a take. Select a scene, and "Generate selected" makes it again (also a copied scene that brought the take of its original).'),
        )
      } catch (e: any) {
        setNotice(String(e.message ?? e))
      }
    },
    [pid, reload],
  )

  // Erzeugen abbrechen: alle laufenden und wartenden Aufträge der Szenen; erster Klick fragt nach (lange Läufe)
  const cancelGenerate = async () => {
    if (!pid) return
    if (!confirmCancel) {
      setConfirmCancel(true)
      setTimeout(() => setConfirmCancel(false), 4000)
      return
    }
    setConfirmCancel(false)
    try {
      const r = await api.studioCancel(pid)
      setJobProgress({})
      await reload()
      setNotice(t(`Erzeugen abgebrochen (${r.cancelled.length} Auftrag/Aufträge). Fertige Takes bleiben.`,
        `Generation cancelled (${r.cancelled.length} job(s)). Finished takes stay.`))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  // Wie viele Szenen dieser Lauf hat (für „fertig/gesamt“); nach dem Öffnen den Stand laufender Aufträge einmal holen,
  // bis der Live-Feed die nächste Meldung bringt
  const busyScenes = project?.scenes.filter((s) => s.status === 'running' || s.status === 'waiting') ?? []
  useEffect(() => {
    if (!busyScenes.length) {
      setRunTotal(0)
      return
    }
    setRunTotal((n) => Math.max(n, busyScenes.length))
    for (const s of busyScenes) {
      for (const j of s.jobs) {
        if (jobProgress[j]) continue
        api.job(j).then((job) => {
          if (job.status === 'running') {
            setJobProgress((m) => (m[j] ? m : { ...m, [j]: { progress: job.progress ?? 0, stage: job.stage ?? '' } }))
          }
        }).catch(() => {})
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project])

  // „Übernehmen“: erst der Plan; Rückfrage nur, wenn etwas Vorhandenes betroffen ist (Nutzer 27.10.2026)
  const runConform = async (params: Record<string, unknown>) => {
    setConformPlan(null)
    const r = await run('edit.conform', params)
    if (r) {
      const skipped = r.skipped?.length ? t(` ${r.skipped.length} übersprungen.`, ` ${r.skipped.length} skipped.`) : ''
      setNotice(t(`Übernommen: ${r.created} neu, ${r.updated} ausgetauscht, ${r.transitions} Übergang/Übergänge.`,
        `Conformed: ${r.created} new, ${r.updated} replaced, ${r.transitions} transition(s).`) + skipped)
    }
  }
  /** Mit `sceneIds` nur diese Szenen („In den Schnitt“ einer Szene, seit 0.5.42); der Plan zeigt dann nur sie */
  const conform = async (sceneIds?: string[]) => {
    if (!pid) return
    try {
      const full = await api.studioConformPlan(pid)
      const plan = sceneIds ? { ...full, items: full.items.filter((i) => sceneIds.includes(i.scene_id)) } : full
      const attention = plan.items.some((i) =>
        i.action === 'replace' || i.action === 'error' || (i.action === 'create' && (i.overlaps?.length || i.in_edit)))
      if (attention) setConformPlan(plan)
      else await runConform(sceneIds ? { scenes: sceneIds } : {})
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  // „Startbild erzeugen“ (seit 0.5.42 hier statt in den Eigenschaften): zwei Varianten je Szene; die erste wird das
  // Startbild, wenn inzwischen kein anderes gewählt wurde. Der Auftrag gehört dem Studio, er läuft weiter, wenn man eine
  // andere Szene oder ein anderes Projekt wählt.
  const projectRef = useRef(project)
  projectRef.current = project
  const startRunsRef = useRef(startRuns)
  startRunsRef.current = startRuns
  const settling = useRef(new Set<string>())
  const startImages = async (ids: string[]) => {
    if (!pid || !project) return
    for (const id of ids) {
      const s = project.scenes.find((x) => x.id === id)
      if (!s || startRunsRef.current[id]?.status === 'running') continue
      try {
        const job = await api.studioStartImage(pid, id)
        trackJob(job)
        setStartRuns((m) => ({ ...m, [id]: { pid, job: job.id, before: s.params?.image_asset_id ?? null, status: 'running', variants: [] } }))
      } catch (e: any) {
        setNotice(String(e.message ?? e))
      }
    }
  }
  const settleStart = useCallback(async (sceneId: string) => {
    const r = startRunsRef.current[sceneId]
    if (!r || r.status !== 'running' || settling.current.has(r.job)) return
    settling.current.add(r.job)
    try {
      const j = await api.job(r.job)
      if (j.status === 'queued' || j.status === 'running') return
      if (j.status === 'done') {
        const variants = await api.jobAssets(r.job)
        const cur = projectRef.current
        const now = cur?.id === r.pid ? cur.scenes.find((x) => x.id === sceneId) : undefined
        if (variants[0] && (!now || (now.params?.image_asset_id ?? null) === r.before)) {
          const res = await api.studioCommand(r.pid, 'scene.update', { id: sceneId, params: { image_asset_id: variants[0].id } })
          accept(res.project)
        }
        setStartRuns((m) => (m[sceneId]?.job === r.job ? { ...m, [sceneId]: { ...r, status: 'done', variants } } : m))
      } else {
        setStartRuns((m) => (m[sceneId]?.job === r.job
          ? { ...m, [sceneId]: { ...r, status: 'error', error: j.error || t('Abgebrochen.', 'Cancelled.') } } : m))
      }
    } catch {
      /* Server kurz weg: beim nächsten Takt */
    } finally {
      settling.current.delete(r.job)
    }
  }, [accept])
  // Fertig melden die Ereignisse; dazu alle 3 s nachfragen, falls eins verloren ging (zwei in einem Takt)
  const startBusy = Object.values(startRuns).some((r) => r.status === 'running')
  useEffect(() => {
    if (!startBusy) return
    const timer = window.setInterval(() => {
      for (const [id, r] of Object.entries(startRunsRef.current)) if (r.status === 'running') void settleStart(id)
    }, 3000)
    return () => window.clearInterval(timer)
  }, [startBusy, settleStart])
  useEffect(() => {
    if (!event || !('job_id' in event) || !['job.done', 'job.error', 'job.cancelled'].includes(event.type)) return
    const hit = Object.entries(startRunsRef.current).find(([, r]) => r.job === event.job_id)
    if (hit) void settleStart(hit[0])
  }, [event, settleStart])

  // Neue Videoszene hinten an der Bildbahn (Karte „+ Szene“; ohne Länge nähme der Server 5 s)
  const addScene = async () => {
    const r = await run('scene.add', { lane: 'video', kind: 'video', duration_s: 5 })
    if (r?.id) {
      setSelection({ type: 'scene', id: r.id })
      setFocusField((f) => ({ scene: r.id, field: 'prompt', n: (f?.n ?? 0) + 1 }))
    }
  }

  // Kartenreihe (Nutzer 26.11.2026: „mit rechtsklick entfernen oder mit x icon rechts oben (bei mouse over) löschen …
  // dann via drag and drop schieben“). Löschen wie in der Zeitleiste ohne Rückfrage, Strg+Z holt die Szene zurück; eine
  // laufende Szene rechnet dann weiter, und mit Strg+Z kommt ihr Ergebnis wieder an die Szene.
  const deleteScene = async (id: string) => {
    await run('scene.delete', { id })
    setSelection((sel) => (selIds(sel, 'scene').includes(id) ? null : sel))
  }
  /** Szenen einer Bahn in neuer Reihenfolge: lückenlos ab dem Start der bisher ersten, Längen bleiben, andere Bahnen
   *  und Marker bleiben stehen; ein Schritt zum Rückgängigmachen. Ein Anschluss bleibt bestehen, grenzt er nicht mehr
   *  an seine Vorlage, zeigt die Karte „Anschluss getrennt“. */
  const reorder = async (lane: string, ids: string[]) => {
    if (!project) return
    const moves = reorderStarts(project, lane, ids)
    if (!moves.length) return
    await run('batch', { commands: moves.map((m) => ({ command: 'scene.update', params: { id: m.id, start: m.start } })) })
  }
  /** Rechtsklick auf eine Karte: dasselbe Menü wie auf der Szene in der Zeitleiste, davor Schieben innerhalb der Bahn */
  const cardMenu = (e: { clientX: number; clientY: number }, id: string) => {
    if (!project) return
    const s = project.scenes.find((x) => x.id === id)
    if (!s) return
    if (!selIds(selection, 'scene').includes(id)) setSelection({ type: 'scene', id })
    const lane = sceneOrder(project).filter((x) => x.lane === s.lane).map((x) => x.id)
    const i = lane.indexOf(id)
    const move = (to: number) => {
      const ids = lane.filter((x) => x !== id)
      ids.splice(to, 0, id)
      void reorder(s.lane, ids)
    }
    const items: MenuItem[] = [
      { label: t('Nach vorn schieben', 'Move earlier'), disabled: i <= 0, onClick: () => move(i - 1) },
      { label: t('Nach hinten schieben', 'Move later'), disabled: i < 0 || i >= lane.length - 1, onClick: () => move(i + 1) },
      ...menuFor({ kind: 'scene', id, at: s.start }).map((it, k) => (k === 0 ? { ...it, separator: true } : it)),
    ]
    setMenu({ x: e.clientX, y: e.clientY, items })
  }

  /** Der große Knopf (Bildschirm D): tut den nächsten Schritt oder holt die Szene, um die es geht, in die Eigenschaften.
   *  Nichts landet ohne Klick im Schnitt oder im Export. */
  const doNext = (next: Next) => {
    const scene = next.scenes[0]
    const show = (field?: FocusField) => {
      if (!scene) return
      setPlaying(false)
      setSelection({ type: 'scene', id: scene.id })
      if (field) setFocusField((f) => ({ scene: scene.id, field, n: (f?.n ?? 0) + 1 }))
    }
    switch (next.kind) {
      case 'wizard': setWizardOpen(true); return
      case 'start': void startImages(next.scenes.map((s) => s.id)); return
      case 'generate': void generate(next.scenes.map((s) => s.id)); return
      case 'conform': void conform(); return
      case 'export': void startExport(); return
      case 'done': {
        // wie „Fertig – ansehen“: MKV und MOV spielt kein Browser, die werden heruntergeladen
        const url = exporting?.url
        if (!url) return
        if (/\.(mkv|mov)$/i.test(url)) {
          const a = document.createElement('a')
          a.href = url
          a.download = ''
          document.body.appendChild(a)
          a.click()
          a.remove()
        } else window.open(url, '_blank', 'noopener')
        return
      }
      case 'exporting': case 'idle': return
      default: show(next.field)
    }
  }

  const addMarkerAt = async (at: number, kind: StudioMarkerKind) => {
    const r = await run('marker.add', { at, kind })
    if (r?.id) setSelection({ type: 'marker', id: r.id })
  }
  const addMarker = (kind: StudioMarkerKind) => addMarkerAt(playhead, kind)

  const undo = async () => {
    if (!pid) return
    try {
      accept(await api.studioUndo(pid))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }
  const redo = async () => {
    if (!pid) return
    try {
      accept(await api.studioRedo(pid))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  const startExport = async () => {
    if (!pid) return
    try {
      const job = await api.studioExport(pid, preset)
      setExporting({ id: job.id, progress: 0, stage: t('wartet', 'waiting'), status: 'running', sig: project ? editSig(project) : undefined })
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  // „+“ neben der Projektauswahl (Nutzer 26.10.2026): sofort ein Projekt „New 1“, „New 2“ … in 1920 × 1080,
  // Format und Bildrate stehen in den Eigenschaften
  const create = async () => {
    try {
      const p = await api.studioCreate('')
      setProjects(await api.studioProjects())
      open(p.id)
      if (wizardAskWanted()) setAskWizard(true)
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  // Paket herunterladen: der Server packt das ZIP, der Browser lädt es über einen Link
  const download = (masters: boolean) => {
    if (!pid) return
    const a = document.createElement('a')
    a.href = api.studioPackageUrl(pid, masters)
    a.download = ''
    document.body.appendChild(a)
    a.click()
    a.remove()
    setNotice(t('Das Paket wird gepackt; der Download beginnt gleich (große Projekte brauchen einen Moment).',
      'The package is being built; the download starts shortly (large projects take a moment).'))
  }
  const importProject = async (file: File | undefined) => {
    if (!file) return
    setNotice(t(`„${file.name}“ wird importiert …`, `Importing "${file.name}" …`))
    try {
      const p = await api.studioImport(file)
      setProjects(await api.studioProjects())
      setBinKey((k) => k + 1)
      await open(p.id)
      setNotice(t(`Importiert als „${p.name}“.`, `Imported as "${p.name}".`))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  // „+“ (Nutzer 27.10.2026: „beim Klick auf + ein Dropdown-Menü mit Optionen New, Export, Import“)
  const projectMenu = async (e: RMouseEvent<HTMLButtonElement>) => {
    const box = e.currentTarget.getBoundingClientRect()
    const info = pid ? await api.studioPackageInfo(pid).catch(() => null) : null
    const items: MenuItem[] = [
      { label: t('Neues Projekt', 'New project'), onClick: create },
      {
        label: t('Projekt exportieren', 'Export project'),
        disabled: !project,
        items: [
          { label: t(`Mit Material (.zip${info ? `, ${megabytes(info.bytes)}` : ''})`, `With media (.zip${info ? `, ${megabytes(info.bytes)}` : ''})`), onClick: () => download(false) },
          {
            label: t(`Mit verlustfreien Kopien${info ? ` (${megabytes(info.bytes + info.master_bytes)})` : ''}`,
              `With lossless copies${info ? ` (${megabytes(info.bytes + info.master_bytes)})` : ''}`),
            disabled: !info?.master_bytes,
            onClick: () => download(true),
          },
        ],
      },
      { label: t('Projekt importieren …', 'Import project …'), onClick: () => importInput.current?.click() },
    ]
    setMenu({ x: box.left, y: box.bottom + 4, items })
  }

  // Material: anklicken zeigt es im Monitor (Quelle) und die Angaben in den Eigenschaften
  const openSource = (a: Asset) => {
    setPlaying(false)
    setSource(a)
    setSelection({ type: 'asset', id: a.id })
  }
  const assetGone = (id: string) => {
    if (source?.id === id) {
      setSource(null)
      setSelection(null)
    }
    reload() // Takes dieser Datei fallen aus den Szenen
  }
  const deleteAsset = async (a: Asset) => {
    try {
      await api.deleteAsset(a.id)
      assetGone(a.id)
      setBinKey((k) => k + 1)
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }
  const reveal = async (assetId: string) => {
    try {
      await api.revealAsset(assetId)
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  const remove = async () => {
    if (!pid) return
    if (!confirmDelete) {
      setConfirmDelete(true)
      setTimeout(() => setConfirmDelete(false), 4000)
      return
    }
    setConfirmDelete(false)
    try {
      await api.studioDelete(pid)
      const list = await api.studioProjects()
      setProjects(list)
      setProject(null)
      if (list[0]) open(list[0].id)
    } catch (e) {
      setNotice(String((e as Error).message ?? e))  // etwa eine Datei, die Windows noch sperrt
    }
  }

  const toggleFullscreen = () => {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    else document.documentElement.requestFullscreen().catch(() => {})
  }
  useEffect(() => {
    const on = () => setFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', on)
    return () => document.removeEventListener('fullscreenchange', on)
  }, [])

  // ------------------------------------------------------------------------- Bearbeiten (auch per Menü)

  const many = (command: string, items: Record<string, unknown>[]) =>
    items.length === 1 ? run(command, items[0]) : run('batch', { commands: items.map((params) => ({ command, params })) })

  /** Kopieren wie bei FilmCraft: merkt die Objekte samt Abstand; Einfügen legt sie am Abspielkopf ab. */
  const copy = (sel: Selection = selection): boolean => {
    if (!project || !sel) return false
    const ids = selIds(sel, sel.type)
    if (sel.type === 'clip') {
      const items = project.clips.filter((c) => ids.includes(c.id))
      if (items.length) setClipboard({ type: 'clip', anchor: Math.min(...items.map((c) => c.start)), items: structuredClone(items) })
      return items.length > 0
    }
    if (sel.type === 'scene') {
      const items = project.scenes.filter((s) => ids.includes(s.id))
      if (items.length) setClipboard({ type: 'scene', anchor: Math.min(...items.map((s) => s.start)), items: structuredClone(items) })
      return items.length > 0
    }
    if (sel.type === 'marker') {
      const items = project.markers.filter((m) => ids.includes(m.id))
      if (items.length) setClipboard({ type: 'marker', anchor: Math.min(...items.map((m) => m.at)), items: structuredClone(items) })
      return items.length > 0
    }
    return false
  }

  const removeSelection = async (sel: Selection = selection, ripple = false) => {
    if (!sel) return
    const ids = selIds(sel, sel.type)
    if (sel.type === 'clip') await run('clip.delete', { ids, ripple })
    if (sel.type === 'scene') await many('scene.delete', ids.map((id) => ({ id })))
    if (sel.type === 'marker') await many('marker.delete', ids.map((id) => ({ id })))
    if (sel.type === 'transition') await run('clip.update', { id: sel.id, transition: null })
    setSelection(null)
  }

  /** Ausschneiden lässt eine Lücke (wie FilmCraft); ein ausgeschnittener Clip behält beim Einfügen seine Szene. */
  const cut = async (sel: Selection = selection) => {
    if (copy(sel)) await removeSelection(sel)
  }

  /** Einfügen bei `at` (Abspielkopf oder Rechtsklick); Clips auf ihre alte Spur, bei einer Spur auf `track`. */
  const paste = async (at: number = playhead, track?: string) => {
    if (!project || !clipboard) return
    const p = project
    const cb = clipboard
    let results: any
    if (cb.type === 'clip') {
      const alive = new Set(p.clips.map((c) => c.id))
      const single = new Set(cb.items.map((c) => c.track)).size === 1
      results = await run('batch', {
        commands: cb.items.map((c) => {
          const kind = trackKind(p, c.track) ?? (c.track.startsWith('A') ? 'audio' : 'video')
          const target = track && single && trackKind(p, track) === kind ? track : trackOrHighest(p, c.track, kind)
          return {
            command: 'clip.add',
            params: {
              track: target, asset_id: c.asset_id, start: at + (c.start - cb.anchor), in: c.in, out: c.out, speed: clipSpeed(c),
              gain_db: c.gain_db, muted: c.muted, scene_id: alive.has(c.id) ? null : c.scene_id,
              transition: c.transition ? { kind: c.transition.kind, duration: c.transition.duration } : null,
              // Skalieren nur auf Videospuren (der Server lehnt es auf Tonspuren ab)
              ...(kind === 'video' && (c.scale !== undefined || c.anchor || c.scale_keys?.length)
                ? { scale: c.scale ?? 1, anchor: c.anchor ?? [0.5, 0.5], scale_keys: c.scale_keys ?? [] } : {}),
            },
          }
        }),
      })
      const ids: string[] = results?.results?.map((r: any) => r?.id).filter(Boolean) ?? []
      if (ids.length) setSelection({ type: 'clip', id: ids[0], ids: ids.length > 1 ? ids : undefined })
      const end = Math.max(...cb.items.map((c) => at + (clipEnd(c) - cb.anchor)))
      if (Number.isFinite(end)) setPlayhead(snapFrame(p, end))
    } else if (cb.type === 'scene') {
      results = await run('batch', {
        commands: cb.items.map((s) => ({
          command: 'scene.add',
          params: { lane: s.lane, kind: s.kind, title: s.title, prompt: s.prompt, model_id: s.model_id, params: s.params, lyrics: s.lyrics,
            start: at + (s.start - cb.anchor), duration: s.duration, takes: s.takes, take: s.take },
        })),
      })
      const ids: string[] = results?.results?.map((r: any) => r?.id).filter(Boolean) ?? []
      if (ids.length) setSelection({ type: 'scene', id: ids[0], ids: ids.length > 1 ? ids : undefined })
    } else {
      results = await run('batch', {
        commands: cb.items.map((m) => ({
          command: 'marker.add',
          params: { kind: m.kind, name: m.name, comment: m.comment, color: m.color, params: m.params, duration: m.duration, at: at + (m.at - cb.anchor) },
        })),
      })
      const ids: string[] = results?.results?.map((r: any) => r?.id).filter(Boolean) ?? []
      if (ids.length) setSelection({ type: 'marker', id: ids[0], ids: ids.length > 1 ? ids : undefined })
    }
  }

  /** Geschwindigkeit; stößt der längere Clip an den nächsten, fragt das Studio nach (Nutzer 27.10.2026: „es soll mich
   * warnen, wenn es beim Verlängern mit anderen Clips kollidiert“). */
  const requestSpeed = (c: StudioClip, speed: number) => {
    if (!project) return
    const oldEnd = clipEnd(c)
    const newEnd = c.start + Math.round((c.out - c.in) / speed)
    const hits = newEnd > oldEnd ? project.clips.filter((o) => o.id !== c.id && o.track === c.track && o.start >= c.start && o.start < newEnd) : []
    if (hits.length) setSpeedAsk({ clip: c, speed, hits, longer: newEnd - oldEnd })
    else run('clip.update', { id: c.id, speed })
  }

  /** Schnitt nahe `at` (± eine halbe Sekunde): auf `track`, sonst auf den Videospuren von unten, dann Ton. */
  const cutNear = (at: number, track?: string): StudioClip | undefined => {
    if (!project) return undefined
    const p = project
    const order = (c: StudioClip) => {
      if (c.track === track) return -1
      const video = [...tracksOf(p, 'video')].reverse().map((tr) => tr.id)
      return video.includes(c.track) ? video.indexOf(c.track) : 100 + tracksOf(p, 'audio').findIndex((tr) => tr.id === c.track)
    }
    return p.clips
      .filter((c) => c.start > 0 && Math.abs(c.start - at) <= TPS / 2)
      .sort((a, b) => order(a) - order(b) || Math.abs(a.start - at) - Math.abs(b.start - at))[0]
  }

  const setTransition = (c: StudioClip, kind: StudioTransitionKind) =>
    run('clip.update', { id: c.id, transition: { kind, duration: c.transition?.duration ?? TPS / 2 } })

  /** Strg+D: Überblendung an die gewählten Clips, sonst an den Schnitt am Abspielkopf (wie FilmCraft). */
  const addDefaultTransition = async () => {
    if (!project) return
    const ids = selIds(selection, 'clip')
    if (ids.length) {
      await many('clip.update', ids.map((id) => ({ id, transition: { kind: 'dissolve', duration_s: 0.5 } })))
      return
    }
    const c = cutNear(playhead)
    if (c) await setTransition(c, 'dissolve')
    else setNotice(t('Am Abspielkopf ist kein Schnitt (± eine halbe Sekunde).', 'There is no cut at the playhead (± half a second).'))
  }

  const razorAtPlayhead = () => {
    if (!project) return
    const tracks = new Set(project.clips.filter((c) => selIds(selection, 'clip').includes(c.id)).map((c) => c.track))
    if (tracks.size) many('clip.razor', [...tracks].map((track) => ({ at: playhead, track })))
    else run('clip.razor', { at: playhead })
  }

  // ------------------------------------------------------------------------------- Rechtsklick-Menüs

  const markerKinds = (at: number): MenuItem[] =>
    Object.entries(MARKER_LABEL).map(([kind, label]) => ({ label, onClick: () => addMarkerAt(at, kind as StudioMarkerKind) }))
  const transitionKinds = (apply: (k: StudioTransitionKind) => void, current?: string): MenuItem[] =>
    Object.entries(TRANSITION_LABEL).map(([k, label]) => ({ label, checked: current === k, onClick: () => apply(k as StudioTransitionKind) }))
  const addTracks = (separator = false): MenuItem[] => [
    { label: t('Videospur hinzufügen', 'Add video track'), separator, onClick: () => run('track.add', { kind: 'video' }) },
    { label: t('Tonspur hinzufügen', 'Add audio track'), onClick: () => run('track.add', { kind: 'audio' }) },
  ]
  const clipboardLabel = (type: Clipboard['type']) =>
    !clipboard || clipboard.type !== type
      ? t('Einfügen', 'Paste')
      : t(`Einfügen (${clipboard.items.length})`, `Paste (${clipboard.items.length})`)

  const menuFor = (target: MenuTarget): MenuItem[] => {
    const p = project!
    switch (target.kind) {
      case 'clip': {
        const c = p.clips.find((x) => x.id === target.id)
        if (!c) return []
        const sel: Selection = selIds(selection, 'clip').includes(c.id) ? selection : { type: 'clip', id: c.id }
        const multi = selIds(sel, 'clip').length > 1
        const image = p.media[c.asset_id]?.kind === 'image'
        return [
          { label: t('Ausschneiden', 'Cut'), hint: t('Strg+X', 'Ctrl+X'), onClick: () => cut(sel) },
          { label: t('Kopieren', 'Copy'), hint: t('Strg+C', 'Ctrl+C'), onClick: () => copy(sel) },
          { label: clipboardLabel('clip'), hint: t('Strg+V', 'Ctrl+V'), disabled: clipboard?.type !== 'clip', onClick: () => paste(playhead) },
          { label: t('Hier schneiden', 'Cut here'), separator: true, disabled: !(c.start < target.at && target.at < clipEnd(c)), onClick: () => run('clip.razor', { at: target.at, track: c.track }) },
          {
            label: t('Übergang am Anfang', 'Transition at the start'),
            items: [
              ...transitionKinds((k) => setTransition(c, k), c.transition?.kind),
              { label: t('Entfernen', 'Remove'), separator: true, disabled: !c.transition, onClick: () => run('clip.update', { id: c.id, transition: null }) },
            ],
          },
          {
            label: t('Geschwindigkeit', 'Speed'),
            disabled: image || multi,
            items: SPEEDS.map((pct) => ({ label: `${pct} %`, checked: Math.round(clipSpeed(c) * 100) === pct, onClick: () => requestSpeed(c, pct / 100) })),
          },
          {
            label: c.muted ? t('Ton an', 'Unmute') : t('Stumm schalten', 'Mute'),
            disabled: image,
            onClick: () => multi ? run('batch', { commands: selIds(sel, 'clip').map((id) => ({ command: 'clip.update', params: { id, muted: !c.muted } })) }) : run('clip.update', { id: c.id, muted: !c.muted }),
          },
          { label: t('Marker hier', 'Marker here'), hint: 'M', onClick: () => addMarkerAt(target.at, 'note') },
          { label: t('Speicherort öffnen', 'Show in folder'), separator: true, onClick: () => reveal(c.asset_id) },
          { label: t('Löschen', 'Delete'), hint: t('Entf', 'Del'), danger: true, separator: true, onClick: () => removeSelection(sel) },
          { label: t('Löschen, Lücke schließen', 'Delete, close gap'), hint: t('Umschalt+Entf', 'Shift+Del'), danger: true, onClick: () => removeSelection(sel, true) },
        ]
      }
      case 'transition': {
        const c = p.clips.find((x) => x.id === target.id)
        const tr = c?.transition
        if (!c || !tr) return []
        return [
          ...transitionKinds((k) => setTransition(c, k), tr.kind),
          {
            label: t('Dauer', 'Duration'),
            separator: true,
            items: [0.25, 0.5, 1, 2].map((s) => ({
              label: `${decimal(String(s))} s`,
              checked: Math.abs(sec(tr.duration) - s) < 1e-3,
              onClick: () => run('clip.update', { id: c.id, transition: { kind: tr.kind, duration_s: s } }),
            })),
          },
          { label: t('Entfernen', 'Remove'), hint: t('Entf', 'Del'), danger: true, separator: true, onClick: () => run('clip.update', { id: c.id, transition: null }) },
        ]
      }
      case 'scene': {
        const s = p.scenes.find((x) => x.id === target.id)
        if (!s) return []
        const sel: Selection = selIds(selection, 'scene').includes(s.id) ? selection : { type: 'scene', id: s.id }
        const ids = selIds(sel, 'scene')
        const busy = s.status === 'running' || s.status === 'waiting'
        return [
          { label: s.take ? t('Neu erzeugen', 'Generate again') : t('Erzeugen', 'Generate'), disabled: busy, onClick: () => generate(ids) },
          { label: t('Ausschneiden', 'Cut'), hint: t('Strg+X', 'Ctrl+X'), separator: true, onClick: () => cut(sel) },
          { label: t('Kopieren', 'Copy'), hint: t('Strg+C', 'Ctrl+C'), onClick: () => copy(sel) },
          { label: clipboardLabel('scene'), hint: t('Strg+V', 'Ctrl+V'), disabled: clipboard?.type !== 'scene', onClick: () => paste(playhead) },
          { label: t('Marker hier', 'Marker here'), hint: 'M', separator: true, onClick: () => addMarkerAt(target.at, 'note') },
          { label: t('Löschen', 'Delete'), hint: t('Entf', 'Del'), danger: true, separator: true, onClick: () => removeSelection(sel) },
        ]
      }
      case 'marker': {
        const m = p.markers.find((x) => x.id === target.id)
        if (!m) return []
        const sel: Selection = selIds(selection, 'marker').includes(m.id) ? selection : { type: 'marker', id: m.id }
        return [
          { label: m.done ? t('Wieder offen', 'Reopen') : t('Erledigt', 'Done'), onClick: () => run('marker.update', { id: m.id, done: !m.done }) },
          {
            label: t('Art', 'Kind'),
            items: Object.entries(MARKER_LABEL).map(([kind, label]) => ({ label, checked: m.kind === kind, onClick: () => run('marker.update', { id: m.id, kind, color: null }) })),
          },
          { label: t('Ausschneiden', 'Cut'), hint: t('Strg+X', 'Ctrl+X'), separator: true, onClick: () => cut(sel) },
          { label: t('Kopieren', 'Copy'), hint: t('Strg+C', 'Ctrl+C'), onClick: () => copy(sel) },
          { label: t('Löschen', 'Delete'), hint: t('Entf', 'Del'), danger: true, separator: true, onClick: () => removeSelection(sel) },
        ]
      }
      case 'track-head': {
        const tr = p.tracks.find((x) => x.id === target.track)
        if (!tr) return []
        const n = p.clips.filter((c) => c.track === tr.id).length
        const first = tr.id.endsWith('1') && tr.id.length === 2
        return [
          ...addTracks(),
          ...(tr.kind === 'video'
            ? [{ label: tr.hidden ? t(`${tr.id} einblenden`, `Show ${tr.id}`) : t(`${tr.id} ausblenden`, `Hide ${tr.id}`), separator: true, onClick: () => run('track.update', { id: tr.id, hidden: !tr.hidden }) }]
            : []),
          { label: tr.muted ? t(`Ton von ${tr.id} an`, `Unmute ${tr.id}`) : t(`${tr.id} stumm schalten`, `Mute ${tr.id}`), separator: tr.kind !== 'video', onClick: () => run('track.update', { id: tr.id, muted: !tr.muted }) },
          {
            label: first
              ? t(`${tr.id} bleibt immer`, `${tr.id} always stays`)
              : t(`Spur ${trackLabel(tr)} entfernen${n ? ` (${n} Clip${n > 1 ? 's' : ''})` : ''}`, `Remove track ${trackLabel(tr)}${n === 1 ? t(' (1 Clip)', ' (1 clip)') : n ? t(` (${n} Clips)`, ` (${n} clips)`) : ''}`),
            separator: true,
            danger: true,
            disabled: first,
            onClick: () => run('track.delete', { id: tr.id }),
          },
        ]
      }
      case 'track': {
        const c = cutNear(target.at, target.track)
        return [
          { label: clipboardLabel('clip') + t(' (hier)', ' (here)'), hint: t('Strg+V', 'Ctrl+V'), disabled: clipboard?.type !== 'clip', onClick: () => paste(target.at, target.track) },
          {
            label: c ? t(`Übergang hier (${c.track})`, `Transition here (${c.track})`) : t('Übergang hier (kein Schnitt in der Nähe)', 'Transition here (no cut nearby)'),
            disabled: !c,
            items: c ? transitionKinds((k) => setTransition(c, k), c.transition?.kind) : undefined,
          },
          { label: t('Marker hier', 'Marker here'), items: markerKinds(target.at) },
          ...addTracks(true),
        ]
      }
      case 'lane': {
        const add = async (kind: 'video' | 'image' | 'audio') => {
          // Musik und Geräusche ohne Länge: Der Server nimmt die Filmlänge bzw. 4 s (seit 0.5.30)
          const duration_s = target.lane === 'video' ? 5 : target.lane === 'voice' ? 10 : undefined
          const r = await run('scene.add', { lane: target.lane, kind, start: target.at, duration_s })
          if (r?.id) setSelection({ type: 'scene', id: r.id })
        }
        return [
          ...(target.lane === 'video'
            ? [
              { label: t('Neue Videoszene hier', 'New video scene here'), onClick: () => add('video') },
              { label: t('Neues Standbild hier', 'New still image here'), onClick: () => add('image') },
            ]
            : [{ label: t('Neue Szene hier', 'New scene here'), onClick: () => add('audio') }]),
          { label: clipboardLabel('scene') + t(' (hier)', ' (here)'), hint: t('Strg+V', 'Ctrl+V'), disabled: clipboard?.type !== 'scene', onClick: () => paste(target.at) },
          { label: t('Marker hier', 'Marker here'), separator: true, items: markerKinds(target.at) },
        ]
      }
      case 'markers':
        return [
          { label: t('Marker hier', 'Marker here'), items: markerKinds(target.at) },
          { label: clipboardLabel('marker') + t(' (hier)', ' (here)'), hint: t('Strg+V', 'Ctrl+V'), disabled: clipboard?.type !== 'marker', onClick: () => paste(target.at) },
        ]
    }
  }

  const onMenu = (e: { clientX: number; clientY: number }, target: MenuTarget) => {
    if (!project) return
    const items = menuFor(target)
    if (items.length) setMenu({ x: e.clientX, y: e.clientY, items })
  }

  /** Material: an eine Spur senden (am Abspielkopf), Speicherort, Datei (das Löschen hängt die Medienleiste an). */
  const binMenu = (a: Asset): MenuItem[] => {
    if (!project) return []
    const kind = mediaKind(a) === 'audio' ? 'audio' : 'video'
    return [
      { label: t('Im Monitor zeigen', 'Show in the monitor'), onClick: () => openSource(a) },
      {
        label: t('An Spur senden (am Abspielkopf)', 'Send to track (at the playhead)'),
        items: tracksOf(project, kind).map((tr) => ({
          label: tr.id,
          onClick: async () => {
            const r = await run('clip.add', { track: tr.id, asset_id: a.id, start: playhead })
            if (r?.id) setSelection({ type: 'clip', id: r.id })
          },
        })),
      },
      { label: t('Speicherort öffnen', 'Show in folder'), separator: true, onClick: () => reveal(a.id) },
      { label: t('Datei öffnen', 'Open file'), onClick: () => window.open(a.url, '_blank', 'noopener') },
    ]
  }

  // Tastatur wie in Schnittprogrammen; nicht während der Eingabe in Feldern
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName
      // !visible: Das Studio bleibt auf anderen Reitern bestehen; Entf, Leertaste und Strg+Z gehören dann nicht ihm
      if (!visible || tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || !project || menu || conformPlan
        || speedAsk || wizardOpen || askWizard) return
      const ctrl = e.ctrlKey || e.metaKey
      const key = e.key.toLowerCase()
      if (e.key === 'Escape') {
        if (tool !== 'select') setTool('select')
        else if (selection) setSelection(null)
        return
      }
      if (selection?.type === 'asset' && (e.key === 'Delete' || e.key === 'Backspace')) return // nur per Knopf
      if (e.code === 'Space') {
        if (selection?.type === 'asset') return // die Quelle hat ihre eigenen Bedienelemente
        e.preventDefault()
        setPlaying((x) => !x)
      } else if (ctrl && key === 'z' && !e.shiftKey) {
        e.preventDefault()
        undo()
      } else if (ctrl && (key === 'y' || (key === 'z' && e.shiftKey))) {
        e.preventDefault()
        redo()
      } else if (ctrl && key === 'c') {
        if (copy()) e.preventDefault()
      } else if (ctrl && key === 'x') {
        e.preventDefault()
        cut()
      } else if (ctrl && key === 'v') {
        e.preventDefault()
        paste(playhead)
      } else if (ctrl && key === 'k') {
        e.preventDefault()
        razorAtPlayhead()
      } else if (ctrl && key === 'd') {
        e.preventDefault()
        addDefaultTransition()
      } else if (ctrl && key === 'a') {
        e.preventDefault()
        const ids = project.clips.map((c) => c.id)
        if (ids.length) setSelection({ type: 'clip', id: ids[0], ids: ids.length > 1 ? ids : undefined })
      } else if (e.key === 'Delete' || e.key === 'Backspace') {
        if (!selection) return
        e.preventDefault()
        removeSelection(selection, e.shiftKey)
      } else if (ctrl || e.altKey) {
        return
      } else if (key === 'v') {
        setTool('select')
      } else if (key === 'c') {
        setTool('razor')
      } else if (key === 'z') {
        setTool('scale')
      } else if (key === 's') {
        setMagnet(!magnet)
      } else if (key === 'm') {
        addMarker('note')
      } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault()
        const step = e.shiftKey ? TPS : frameTicks(project)
        setPlayhead((x) => snapFrame(project, Math.max(0, x + (e.key === 'ArrowLeft' ? -step : step))))
      } else if (e.key === 'Home') {
        setPlayhead(0)
      } else if (e.key === 'End') {
        setPlayhead(project.edit_duration)
      } else if (e.key === '+' || e.key === '=') {
        setZoom(Math.min(400, zoom * 1.25))
      } else if (e.key === '-') {
        setZoom(Math.max(4, zoom * 0.8))
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  // Trennlinie zwischen oben und Zeitleisten ziehen
  const dragSplit = (e: RPointerEvent) => {
    const box = root.current?.getBoundingClientRect()
    if (!box) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const move = (ev: PointerEvent) => {
      const pct = Math.min(75, Math.max(20, ((box.bottom - ev.clientY) / box.height) * 100))
      setSplit(pct)
      store(KEY_SPLIT, String(Math.round(pct)))
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  // Breite der Materialspalte ziehen (Nutzer 27.10.2026: „dann soll Material-Spalte breiter gemacht werden können“);
  // Doppelklick stellt sie zurück
  const dragBin = (e: RPointerEvent) => {
    const box = upper.current?.getBoundingClientRect()
    if (!box) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const side = sideWidth  // wird es eng, weicht die andere Spalte bis zu ihrer Mindestbreite, beim Zurückziehen zurück
    const move = (ev: PointerEvent) => {
      const free = box.width - MONITOR_MIN - SPLITTERS
      const w = Math.round(Math.max(BIN_MIN, Math.min(ev.clientX - box.left, free - SIDE_MIN)))
      const other = Math.round(Math.max(SIDE_MIN, Math.min(side, free - w)))
      setBinWidth(w)
      store(KEY_BIN, String(w))
      setSideWidth(other)
      store(KEY_SIDE, String(other))
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  const resetBin = () => {
    setBinWidth(BIN_WIDTH)
    store(KEY_BIN, String(BIN_WIDTH))
  }

  // Breite der Eigenschaftenspalte rechts ziehen, wie die Materialspalte; Doppelklick stellt sie zurück
  const dragSide = (e: RPointerEvent) => {
    const box = upper.current?.getBoundingClientRect()
    if (!box) return
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const bin = binWidth
    const move = (ev: PointerEvent) => {
      const free = box.width - MONITOR_MIN - SPLITTERS
      const w = Math.round(Math.max(SIDE_MIN, Math.min(box.right - ev.clientX, free - BIN_MIN)))
      const other = Math.round(Math.max(BIN_MIN, Math.min(bin, free - w)))
      setSideWidth(w)
      store(KEY_SIDE, String(w))
      setBinWidth(other)
      store(KEY_BIN, String(other))
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  const resetSide = () => {
    setSideWidth(SIDE_WIDTH)
    store(KEY_SIDE, String(SIDE_WIDTH))
  }

  const running = project?.scenes.filter((s) => s.status === 'running' || s.status === 'waiting').length ?? 0
  // Stand des Erzeugens neben „Übernehmen“: die Szene, die gerade rechnet, mit Prozent, dazu fertig/gesamt dieses Laufs
  const current = project?.scenes.find((s) => s.jobs.some((j) => jobProgress[j]))
  const currentJob = current?.jobs.find((j) => jobProgress[j])
  const currentPct = currentJob ? Math.round((jobProgress[currentJob]?.progress ?? 0) * 100) : 0
  const runDone = Math.max(0, runTotal - running)
  const askNames = speedAsk ? speedAsk.hits.map((c) => project?.scenes.find((s) => s.id === c.scene_id)?.title || project?.assets[c.asset_id]?.prompt?.slice(0, 30) || c.asset_id) : []

  // Konzept „NVAI im Fluss“ (seit 0.5.42): Stand des Exports für Leiste und Knopf, gemeinsamer Stand für die Eigenschaften
  const sigNow = useMemo(() => (project ? editSig(project) : ''), [project])
  const exportInfo: ExportInfo | null = project ? {
    status: exporting ? exporting.status : 'none',
    progress: exporting?.progress ?? 0,
    file: exporting?.url ? decodeURIComponent(exporting.url.split('/').pop() ?? '') : undefined,
    fresh: !!exporting && exporting.sig === sigNow,
    preset: presetShort(preset, presets.find((x) => x.id === preset)?.label ?? preset, project),
  } : null
  const sceneFlow: SceneFlow = {
    startRuns,
    onStartImages: (ids) => void startImages(ids),
    onConform: (ids) => void conform(ids),
    progressOf: (s) => {
      for (const j of s.jobs) if (jobProgress[j]) return jobProgress[j].progress
      return null
    },
    downloads,
    focus: focusField,
  }
  const toggleCards = () => {
    store(KEY_CARDS, cardsOpen ? '0' : '1')
    setCardsOpen(!cardsOpen)
  }
  const toggleFlow = () => {
    store(KEY_FLOW, flowOpen ? '0' : '1')
    setFlowOpen(!flowOpen)
  }
  const showFlow = !!project && !!exportInfo && flowOpen

  return (
    <div className="studio" ref={root}
      style={{ gridTemplateRows: showFlow ? `auto auto 1fr 6px ${split}%` : `auto 1fr 6px ${split}%`, ...(visible ? {} : { display: 'none' }) }}>
      <div className="st-toolbar">
        <select
          value={pid ?? ''}
          onChange={(e) => e.target.value && open(e.target.value)}
          // Klick auf die Projektauswahl zeigt rechts die Projekteinstellungen (Nutzer 27.10.2026: „sonst komme ich
          // nirgendwo auf die Projekteinstellungen“)
          onPointerDown={() => setSelection(null)}
          title={t('Projekt wählen; rechts erscheinen seine Einstellungen', 'Choose a project; its settings show on the right')}
        >
          {!pid && <option value="">{t('– Projekt –', '– project –')}</option>}
          {projects.map((x) => (
            <option key={x.id} value={x.id}>{x.id === pid && project ? project.name : x.name}</option>
          ))}
        </select>
        <button className="btn small" onClick={projectMenu} title={t('Neu, Exportieren, Importieren', 'New, export, import')}>+ ▾</button>
        <input ref={importInput} type="file" accept=".zip,.json" hidden onChange={(e) => { importProject(e.target.files?.[0]); e.target.value = '' }} />
        {project && (
          <button className="btn small ghost" onClick={remove} title={t('In den Papierkorb des Studios', 'To the studio trash')}>
            {confirmDelete ? t('Wirklich löschen?', 'Really delete?') : t('Löschen', 'Delete')}
          </button>
        )}
        <span className="st-sep" />
        <button className="btn small" disabled={!project?.history.undo} onClick={undo} title={t('Rückgängig (Strg+Z)', 'Undo (Ctrl+Z)')}>↶</button>
        <button className="btn small" disabled={!project?.history.redo} onClick={redo} title={t('Wiederholen (Strg+Y)', 'Redo (Ctrl+Y)')}>↷</button>
        <span className="st-sep" />
        {/* Mit gewählten Szenen erzeugt der Knopf genau diese neu, sonst alle ohne Take (Nutzer 18.11. am Mac: „ich kann
            keine neue szene erzeugen, es sagt mir alle szenen haben schon einen Take“; eine kopierte Szene bringt den Take
            ihrer Vorlage mit). Eine leere Liste hieße beim Server „alle ohne Take“: beschäftigte Szenen gar nicht senden. */}
        <button className="btn small" disabled={!project}
          onClick={() => {
            const picked = selIds(selection, 'scene')
            if (!picked.length) { void generate(); return }
            const free = picked.filter((id) => project?.scenes.some((s) => s.id === id && !s.jobs?.length && !s.waiting_for))
            if (!free.length) {
              setNotice(t('Die gewählten Szenen laufen schon oder warten auf die Szene, an die sie anschließen.', 'The selected scenes are already running or waiting for the scene they continue.'))
              return
            }
            void generate(free)
          }}
          title={selIds(selection, 'scene').length
            ? t('Die gewählten Szenen neu erzeugen, auch wenn sie schon einen Take haben', 'Generate the selected scenes again, even if they already have a take')
            : t('Alle Szenen ohne Take erzeugen; mit gewählten Szenen genau diese', 'Generate every scene without a take; with selected scenes exactly those')}>
          {selIds(selection, 'scene').length ? t('Gewählte erzeugen', 'Generate selected') : t('Szenen erzeugen', 'Generate scenes')}{running ? ` (${running})` : ''}
        </button>
        <button className="btn small" disabled={!project} onClick={() => void conform()} title={t('Gewählte Takes in den Schnitt legen, Marker auswerten; fragt nach, bevor Vorhandenes überschrieben wird', 'Put the chosen takes into the edit, apply the markers; asks before anything in the edit is overwritten')}>
          {t('Übernehmen', 'Conform')} ↓
        </button>
        <button className="btn small wz-open" onClick={() => setWizardOpen(true)} title={t('Der Assistent führt Schritt für Schritt durch ein ganzes Video', 'The assistant guides you step by step through a whole video')}>
          ✨ {t('Assistent', 'Assistant')}
        </button>
        {running > 0 && (
          <span className="st-gen" title={current ? `${current.title || current.prompt.slice(0, 40)} · ${jobProgress[currentJob!]?.stage ?? ''}` : t('Wartet auf die Grafikkarte', 'Waiting for the GPU')}>
            <span className="st-gen-bar"><span style={{ width: `${current ? Math.max(2, currentPct) : 0}%` }} /></span>
            {/* bei wenig Platz kürzt sich nur der Name; Prozent und fertig/gesamt bleiben sichtbar */}
            <span className="st-gen-text">
              <span className="st-gen-name">{current ? current.title || t('Szene', 'Scene') : t('wartet …', 'queued …')}</span>
              {current && <span className="st-gen-num">&nbsp;{currentPct} %</span>}
              {runTotal > 1 && <span className="st-gen-num">&nbsp;· {runDone}/{runTotal}</span>}
            </span>
            <button className={`btn small ghost st-gen-cancel${confirmCancel ? ' armed' : ''}`} onClick={cancelGenerate}
              title={t('Alle laufenden und wartenden Aufträge dieses Projekts abbrechen', 'Cancel all running and queued jobs of this project')}>
              {confirmCancel ? t('Wirklich abbrechen?', 'Really cancel?') : t('✕ Abbrechen', '✕ Cancel')}
            </button>
          </span>
        )}
        <select
          value=""
          disabled={!project}
          onChange={(e) => e.target.value && addMarker(e.target.value as StudioMarkerKind)}
          title={t('Marker am Abspielkopf setzen (M)', 'Add a marker at the playhead (M)')}
        >
          <option value="">{t('+ Marker', '+ Marker')}</option>
          {Object.entries(MARKER_LABEL).map(([id, label]) => (
            <option key={id} value={id}>{label}</option>
          ))}
        </select>
        <span className="st-sep" />
        <button className="btn small" disabled={!project} onClick={() => setPlaying((x) => !x)} title={t('Abspielen (Leertaste)', 'Play (Space)')}>
          {playing ? '❚❚' : '▶'}
        </button>
        <button className="btn small ghost" onClick={() => setZoom(Math.max(4, zoom * 0.8))} title={t('Verkleinern (-)', 'Zoom out (-)')}>−</button>
        <button className="btn small ghost" onClick={() => setZoom(Math.min(400, zoom * 1.25))} title={t('Vergrößern (+)', 'Zoom in (+)')}>+</button>
        <span className="st-sep" />
        <select value={preset} onChange={(e) => { presetTouched.current = true; setPreset(e.target.value) }}
          title={t('Exportformat', 'Export format')}>
          {presets.map((x) => (
            <option key={x.id} value={x.id}>{x.label}</option>
          ))}
        </select>
        <button className="btn small" disabled={!project?.clips.length || exporting?.status === 'running'} onClick={startExport}>
          {t('Exportieren', 'Export')}
        </button>
        {/* Die ganze Leiste mit dem nächsten Schritt ein- und ausklappen, mit demselben Zeichen wie ihre Kartenreihe;
            eingeklappt nimmt sie keinen Platz (Nutzer 26.11.2026: „es soll hinter dem export button sein“) */}
        <button type="button" className="sf-fold st-flow-fold" onClick={toggleFlow} aria-expanded={flowOpen}
          title={flowOpen ? t('Leiste mit dem nächsten Schritt einklappen', 'Collapse the bar with the next step')
            : t('Leiste mit dem nächsten Schritt zeigen', 'Show the bar with the next step')}>
          {flowOpen ? '▾' : '▸'}
        </button>
        {exporting && (
          <span className={`st-export ${exporting.status}`}>
            {exporting.status === 'running' && <>{Math.round(exporting.progress * 100)} % · {exporting.stage}</>}
            {exporting.status === 'done' && (
              /\.(mkv|mov)$/i.test(exporting.url ?? '') ? (
                <a href={exporting.url} download>{t('Fertig – herunterladen (auch im Projektordner)', 'Done – download (also in the project folder)')}</a>
              ) : (
                <a href={exporting.url} target="_blank" rel="noreferrer">{t('Fertig – ansehen (auch im Projektordner)', 'Done – view (also in the project folder)')}</a>
              )
            )}
            {exporting.status === 'error' && <span className="warn-text">{exporting.error}</span>}
          </span>
        )}
        <span className="st-spacer" />
        <button className="btn small ghost" onClick={toggleFullscreen} title={t('Vollbild', 'Full screen')}>
          {fullscreen ? t('Vollbild beenden', 'Exit full screen') : <>⛶<span className="st-wide"> {t('Vollbild', 'Full screen')}</span></>}
        </button>
      </div>

      {askWizard && (
        <WizardAsk
          onStart={() => setWizardOpen(true)}
          onClose={(never) => {
            setAskWizard(false)
            if (never) setNotice(t('Den Assistenten startest du jederzeit oben über „✨ Assistent“ neben „Übernehmen“.', 'You can start the assistant any time with "✨ Assistant" at the top, next to "Conform".'))
          }}
        />
      )}
      {wizardOpen && (
        <Wizard
          project={project}
          onClose={() => setWizardOpen(false)}
          onOpenProject={async (id) => {
            setProjects(await api.studioProjects())
            open(id)
          }}
          onDone={() => {
            setWizardOpen(false)
            setCoach(true)
          }}
        />
      )}
      {coach && <WizardCoach running={running} onClose={() => setCoach(false)} />}
      {notice && (
        <div className="st-notice" onClick={() => setNotice(null)}>
          {notice}
        </div>
      )}

      {showFlow && project && exportInfo && (
        <FlowBar
          p={project}
          models={models}
          active={active}
          selectedId={selection?.type === 'scene' ? selection.id : null}
          startRuns={startRuns}
          jobProgress={jobProgress}
          exportInfo={exportInfo}
          open={cardsOpen}
          onToggle={toggleCards}
          onSelect={(id) => {
            setPlaying(false)
            setSelection({ type: 'scene', id })
          }}
          onNext={doNext}
          onAddScene={() => void addScene()}
          onMenu={cardMenu}
          onDelete={(id) => void deleteScene(id)}
          onReorder={(lane, ids) => void reorder(lane, ids)}
        />
      )}
      {!project ? (
        <div className="st-start">
          <div className="panel">
            <h2>{t('Studio', 'Studio')}</h2>
            <p className="muted">
              {t('Oben komponierst du Szenen mit Prompts und steuerst mit Markern, was wohin kommt; unten schneidest du das fertige Material. Export mit Hardware-Encoder.',
                'At the top you compose scenes with prompts and use markers to say what goes where; below you cut the finished material. Export with a hardware encoder.')}
            </p>
            <div className="st-actions">
              <button className="btn primary" onClick={create}>+ {t('Neues Projekt', 'New project')}</button>
              <button className="btn" onClick={() => importInput.current?.click()}>{t('Projekt importieren …', 'Import project …')}</button>
            </div>
          </div>
        </div>
      ) : (
        <>
          <div className="st-upper" ref={upper} style={{ gridTemplateColumns: narrow
            ? `minmax(${MONITOR_MIN}px, 1fr) 5px minmax(${SIDE_MIN}px, ${sideWidth}px)`
            : `minmax(${BIN_MIN}px, ${binWidth}px) 5px minmax(${MONITOR_MIN}px, 1fr) 5px minmax(${SIDE_MIN}px, ${sideWidth}px)` }}>
            {!narrow && (
              <Bin
                refreshKey={binKey + assetsVersion}
                selectedId={selection?.type === 'asset' ? selection.id : null}
                usedIds={new Set(project.clips.map((c) => c.asset_id))}
                projectId={project.id}
                home={project.folder}
                onOpen={openSource}
                onDeleted={assetGone}
                menuItems={binMenu}
                onMenu={(e, items) => setMenu({ x: e.clientX, y: e.clientY, items })}
              />
            )}
            {!narrow && (
              <div className="st-vsplit" onPointerDown={dragBin} onDoubleClick={resetBin}
                title={t('Ziehen: Breite der Materialspalte; Doppelklick: zurücksetzen', 'Drag: width of the media column; double-click: reset')} />
            )}
            <Monitor
              project={project}
              playhead={playhead}
              playing={playing}
              onPlayhead={setPlayhead}
              onStop={() => setPlaying(false)}
              source={selection?.type === 'asset' ? source : null}
              onCloseSource={() => setSelection(null)}
              tool={tool}
              selectedClip={selection?.type === 'clip' ? selection.id : null}
              onCommand={run}
            />
            <div className="st-vsplit" onPointerDown={dragSide} onDoubleClick={resetSide}
              title={t('Ziehen: Breite der Eigenschaften; Doppelklick: zurücksetzen', 'Drag: width of the properties; double-click: reset')} />
            <div className="st-side">
              <Inspector
                project={project}
                selection={selection}
                models={models}
                active={active}
                onCommand={run}
                onGenerate={generate}
                onSelect={setSelection}
                asset={selection?.type === 'asset' ? source : null}
                playhead={playhead}
                onDeleteAsset={deleteAsset}
                onSpeed={requestSpeed}
                onPlayhead={(x) => {
                  setPlaying(false)
                  setPlayhead(x)
                }}
                onShowModels={onShowModels}
                flow={sceneFlow}
              />
            </div>
          </div>
          <div className="st-splitter" onPointerDown={dragSplit} title={t('Ziehen: Höhe der Zeitleisten', 'Drag: height of the timelines')} />
          <Timelines
            project={project}
            playhead={playhead}
            zoom={zoom}
            selection={selection}
            tool={tool}
            magnet={magnet}
            onTool={setTool}
            onMagnet={setMagnet}
            onSelect={setSelection}
            onPlayhead={(x) => {
              setPlaying(false)
              setPlayhead(x)
              // Klick ins Lineal holt den Monitor auf den Schnitt zurück (Nutzer 27.10.2026)
              if (selection?.type === 'asset') setSelection(null)
            }}
            onCommand={run}
            onZoom={setZoom}
            onMenu={onMenu}
          />
        </>
      )}

      <ContextMenu menu={menu} onClose={closeMenu} />
      {conformPlan && <ConformDialog plan={conformPlan} onRun={runConform} onClose={() => setConformPlan(null)} />}
      {speedAsk && (
        <div className="st-dialog-layer" onPointerDown={(e) => e.target === e.currentTarget && setSpeedAsk(null)}>
          <div className="st-dialog st-dialog-small" role="dialog">
            <h3>{t('Clip wird länger', 'The clip gets longer')}</h3>
            <p className="small">
              {t(`Mit ${Math.round(speedAsk.speed * 100)} % wird der Clip ${decimal(sec(speedAsk.longer).toFixed(2))} s länger und stößt an ${askNames.map((x) => `„${x}“`).join(', ')}.`,
                `At ${Math.round(speedAsk.speed * 100)} % the clip becomes ${decimal(sec(speedAsk.longer).toFixed(2))} s longer and runs into ${askNames.map((x) => `"${x}"`).join(', ')}.`)}
            </p>
            <div className="st-dialog-choices">
              {([
                ['clamp', t('Bis zum nächsten Clip', 'Up to the next clip'), t('Der Clip endet, wo der nächste beginnt, und zeigt dafür weniger Material.', 'The clip ends where the next one starts and shows less material.')],
                ['ripple', t('Nachfolgende verschieben', 'Push the later clips'), t('Alle späteren Clips dieser Spur rücken nach hinten.', 'All later clips on this track move back.')],
                ['overwrite', t('Überdecken', 'Cover them'), t('Der Clip überschreibt, was dahinter liegt.', 'The clip overwrites what lies behind it.')],
              ] as const).map(([overlap, label, hint]) => (
                <button key={overlap} className="btn small" title={hint} onClick={() => {
                  const a = speedAsk
                  setSpeedAsk(null)
                  run('clip.update', { id: a.clip.id, speed: a.speed, overlap })
                }}>
                  {label}
                </button>
              ))}
              <button className="btn small ghost" onClick={() => setSpeedAsk(null)}>{t('Abbrechen', 'Cancel')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
