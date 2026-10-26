// Studio (Nutzer 26.10.2026): eigener Bereich über den ganzen Bildschirm. Oben Medienleiste, Programmmonitor und
// Eigenschaften, unten die Komposition (Szenen mit Prompts, Marker) über dem Schnitt (echte Clips auf Spuren).
// Jede Änderung ist ein Befehl an den Server (/api/studio/projects/{id}/command), die gleichen nutzt Claude per MCP.

import { useCallback, useEffect, useRef, useState, type PointerEvent as RPointerEvent } from 'react'
import {
  api,
  TPS,
  type Asset,
  type ModelInfo,
  type ServerEvent,
  type StudioChangedEvent,
  type StudioMarkerKind,
  type StudioProject,
  type StudioProjectInfo,
} from '../api'
import { t } from '../i18n'
import { Bin } from '../studio/Bin'
import { Inspector, MARKER_LABEL } from '../studio/Inspector'
import { Monitor } from '../studio/Monitor'
import { Timelines, type Selection } from '../studio/Timelines'
import { frameTicks, snapFrame } from '../studio/time'

const KEY_PROJECT = 'nvai-studio-project'
const KEY_ZOOM = 'nvai-studio-zoom'
const KEY_SPLIT = 'nvai-studio-split'

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
}

export function StudioPanel({ event, studioEvent, assetsVersion }: {
  event: ServerEvent | null
  studioEvent: StudioChangedEvent | null
  assetsVersion: number
}) {
  const [projects, setProjects] = useState<StudioProjectInfo[]>([])
  const [project, setProject] = useState<StudioProject | null>(null)
  const [selection, setSelection] = useState<Selection>(null)
  const [playhead, setPlayhead] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [zoom, setZoomState] = useState(() => Number(stored(KEY_ZOOM)) || 40)
  const [split, setSplit] = useState(() => Number(stored(KEY_SPLIT)) || 44)
  const [notice, setNotice] = useState<string | null>(null)
  const [models, setModels] = useState<ModelInfo[]>([])
  const [presets, setPresets] = useState<{ id: string; label: string; ext: string }[]>([])
  const [preset, setPreset] = useState('youtube-1080p')
  const [exporting, setExporting] = useState<ExportState | null>(null)
  const [binKey, setBinKey] = useState(0)
  const [source, setSource] = useState<Asset | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [fullscreen, setFullscreen] = useState(!!document.fullscreenElement)
  const root = useRef<HTMLDivElement>(null)
  const pid = project?.id

  const setZoom = useCallback((z: number) => {
    setZoomState(z)
    store(KEY_ZOOM, String(z))
  }, [])

  const open = useCallback(async (id: string) => {
    try {
      const p = await api.studioProject(id)
      setProject(p)
      setSelection(null)
      setPlayhead(0)
      setPlaying(false)
      store(KEY_PROJECT, id)
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }, [])

  useEffect(() => {
    api.studioProjects().then((list) => {
      setProjects(list)
      const last = stored(KEY_PROJECT)
      const pick = list.find((x) => x.id === last) ?? list[0]
      if (pick) open(pick.id)
    })
    Promise.all([api.models('image'), api.models('video'), api.models('audio')])
      .then((lists) => setModels(lists.flat()))
      .catch(() => {})
    api.studioPresets().then(setPresets).catch(() => {})
  }, [open])

  const reload = useCallback(async () => {
    if (!pid) return
    try {
      setProject(await api.studioProject(pid))
    } catch {
      /* bleibt beim alten Stand */
    }
  }, [pid])

  const run = useCallback(
    async (command: string, params: Record<string, unknown> = {}) => {
      if (!pid) return undefined
      try {
        const r = await api.studioCommand(pid, command, params)
        setProject(r.project)
        setNotice(null)
        return r.result
      } catch (e: any) {
        setNotice(String(e.message ?? e))
        return undefined
      }
    },
    [pid],
  )

  // Projekt anderswo geändert (Claude per MCP, ein fertiger Auftrag, ein Anschluss, der jetzt startet)
  useEffect(() => {
    if (studioEvent && studioEvent.project_id === pid && studioEvent.updated_at !== project?.updated_at) reload()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [studioEvent])

  // Live-Feed: fertige Szenen neu laden, Export-Fortschritt anzeigen, Medienleiste auffrischen
  useEffect(() => {
    if (!event || !('job_id' in event)) return
    if (exporting && event.job_id === exporting.id) {
      if (event.type === 'job.progress') setExporting({ ...exporting, progress: event.progress, stage: event.stage })
      if (event.type === 'job.error') setExporting({ ...exporting, status: 'error', error: event.error })
      if (event.type === 'job.done') {
        api.jobAssets(event.job_id).then((a) => setExporting({ ...exporting, status: 'done', progress: 1, url: a[0]?.url }))
        setBinKey((k) => k + 1)
      }
      return
    }
    if (event.type === 'job.done') setBinKey((k) => k + 1)
    if (['job.done', 'job.error', 'job.cancelled'].includes(event.type) && project?.scenes.some((s) => s.jobs.includes(event.job_id))) {
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
              : t('Alle Szenen haben schon einen Take. Zum Neuerzeugen eine Szene wählen.', 'Every scene already has a take. Select a scene to generate it again.'),
        )
      } catch (e: any) {
        setNotice(String(e.message ?? e))
      }
    },
    [pid, reload],
  )

  const conform = async () => {
    const r = await run('edit.conform')
    if (r) {
      setNotice(t(`Übernommen: ${r.created} neu, ${r.updated} ausgetauscht, ${r.transitions} Überblendung(en).`,
        `Conformed: ${r.created} new, ${r.updated} replaced, ${r.transitions} dissolve(s).`))
    }
  }

  const addMarker = async (kind: StudioMarkerKind) => {
    const r = await run('marker.add', { at: playhead, kind })
    if (r?.id) setSelection({ type: 'marker', id: r.id })
  }

  const undo = async () => {
    if (!pid) return
    try {
      setProject(await api.studioUndo(pid))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }
  const redo = async () => {
    if (!pid) return
    try {
      setProject(await api.studioRedo(pid))
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
  }

  const startExport = async () => {
    if (!pid) return
    try {
      const job = await api.studioExport(pid, preset)
      setExporting({ id: job.id, progress: 0, stage: t('wartet', 'waiting'), status: 'running' })
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
    } catch (e: any) {
      setNotice(String(e.message ?? e))
    }
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

  const remove = async () => {
    if (!pid) return
    if (!confirmDelete) {
      setConfirmDelete(true)
      setTimeout(() => setConfirmDelete(false), 4000)
      return
    }
    setConfirmDelete(false)
    await api.studioDelete(pid)
    const list = await api.studioProjects()
    setProjects(list)
    setProject(null)
    if (list[0]) open(list[0].id)
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

  // Tastatur wie in Schnittprogrammen; nicht während der Eingabe in Feldern
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || !project) return
      const ctrl = e.ctrlKey || e.metaKey
      if (e.key === 'Escape') {
        if (selection?.type === 'asset') setSelection(null)
        return
      }
      if (selection?.type === 'asset' && (e.key === 'Delete' || e.key === 'Backspace')) return // nur per Knopf
      if (e.code === 'Space') {
        if (selection?.type === 'asset') return // die Quelle hat ihre eigenen Bedienelemente
        e.preventDefault()
        setPlaying((x) => !x)
      } else if (ctrl && e.key.toLowerCase() === 'z' && !e.shiftKey) {
        e.preventDefault()
        undo()
      } else if (ctrl && (e.key.toLowerCase() === 'y' || (e.key.toLowerCase() === 'z' && e.shiftKey))) {
        e.preventDefault()
        redo()
      } else if (e.key === 'Delete' || e.key === 'Backspace') {
        if (!selection) return
        e.preventDefault()
        if (selection.type === 'scene') run('scene.delete', { id: selection.id })
        if (selection.type === 'clip') run('clip.delete', { ids: [selection.id], ripple: e.shiftKey })
        if (selection.type === 'marker') run('marker.delete', { id: selection.id })
        setSelection(null)
      } else if (e.key.toLowerCase() === 'c' && !ctrl) {
        const track = selection?.type === 'clip' ? project.clips.find((c) => c.id === selection.id)?.track : undefined
        run('clip.razor', track ? { at: playhead, track } : { at: playhead })
      } else if (e.key.toLowerCase() === 'm' && !ctrl) {
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

  const running = project?.scenes.filter((s) => s.status === 'running' || s.status === 'waiting').length ?? 0

  return (
    <div className="studio" ref={root} style={{ gridTemplateRows: `auto 1fr 6px ${split}%` }}>
      <div className="st-toolbar">
        <select value={pid ?? ''} onChange={(e) => e.target.value && open(e.target.value)} title={t('Projekt', 'Project')}>
          {!pid && <option value="">{t('— Projekt —', '— project —')}</option>}
          {projects.map((x) => (
            <option key={x.id} value={x.id}>{x.id === pid && project ? project.name : x.name}</option>
          ))}
        </select>
        <button className="btn small" onClick={create} title={t('Neues Projekt', 'New project')}>+</button>
        {project && (
          <button className="btn small ghost" onClick={remove} title={t('In den Papierkorb des Studios', 'To the studio trash')}>
            {confirmDelete ? t('Wirklich löschen?', 'Really delete?') : t('Löschen', 'Delete')}
          </button>
        )}
        <span className="st-sep" />
        <button className="btn small" disabled={!project?.history.undo} onClick={undo} title={t('Rückgängig (Strg+Z)', 'Undo (Ctrl+Z)')}>↶</button>
        <button className="btn small" disabled={!project?.history.redo} onClick={redo} title={t('Wiederholen (Strg+Y)', 'Redo (Ctrl+Y)')}>↷</button>
        <span className="st-sep" />
        <button className="btn small primary" disabled={!project} onClick={() => generate()} title={t('Alle Szenen ohne Take erzeugen', 'Generate every scene without a take')}>
          {t('Szenen erzeugen', 'Generate scenes')}{running ? ` (${running})` : ''}
        </button>
        <button className="btn small" disabled={!project} onClick={conform} title={t('Gewählte Takes in den Schnitt legen, Marker auswerten', 'Put the chosen takes into the edit, apply the markers')}>
          {t('Übernehmen', 'Conform')} ↓
        </button>
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
        <select value={preset} onChange={(e) => setPreset(e.target.value)} title={t('Exportformat', 'Export format')}>
          {presets.map((x) => (
            <option key={x.id} value={x.id}>{x.label}</option>
          ))}
        </select>
        <button className="btn small primary" disabled={!project?.clips.length || exporting?.status === 'running'} onClick={startExport}>
          {t('Exportieren', 'Export')}
        </button>
        {exporting && (
          <span className={`st-export ${exporting.status}`}>
            {exporting.status === 'running' && <>{Math.round(exporting.progress * 100)} % · {exporting.stage}</>}
            {exporting.status === 'done' && (
              /\.(mkv|mov)$/i.test(exporting.url ?? '') ? (
                <a href={exporting.url} download>{t('Fertig – herunterladen (auch im Verlauf)', 'Done – download (also in History)')}</a>
              ) : (
                <a href={exporting.url} target="_blank" rel="noreferrer">{t('Fertig – ansehen (auch im Verlauf)', 'Done – view (also in History)')}</a>
              )
            )}
            {exporting.status === 'error' && <span className="warn-text">{exporting.error}</span>}
          </span>
        )}
        <span className="st-spacer" />
        <button className="btn small ghost" onClick={toggleFullscreen} title={t('Vollbild', 'Full screen')}>
          {fullscreen ? t('Vollbild beenden', 'Exit full screen') : t('⛶ Vollbild', '⛶ Full screen')}
        </button>
      </div>

      {notice && (
        <div className="st-notice" onClick={() => setNotice(null)}>
          {notice}
        </div>
      )}

      {!project ? (
        <div className="st-start">
          <div className="panel">
            <h2>{t('Studio', 'Studio')}</h2>
            <p className="muted">
              {t('Oben komponierst du Szenen mit Prompts und steuerst mit Markern, was wohin kommt; unten schneidest du das fertige Material. Export mit Hardware-Encoder.',
                'At the top you compose scenes with prompts and use markers to say what goes where; below you cut the finished material. Export with a hardware encoder.')}
            </p>
            <button className="btn primary" onClick={create}>+ {t('Neues Projekt', 'New project')}</button>
          </div>
        </div>
      ) : (
        <>
          <div className="st-upper">
            <Bin
              refreshKey={binKey + assetsVersion}
              selectedId={selection?.type === 'asset' ? selection.id : null}
              usedIds={new Set(project.clips.map((c) => c.asset_id))}
              onOpen={openSource}
              onDeleted={assetGone}
            />
            <Monitor
              project={project}
              playhead={playhead}
              playing={playing}
              onPlayhead={setPlayhead}
              onStop={() => setPlaying(false)}
              source={selection?.type === 'asset' ? source : null}
              onCloseSource={() => setSelection(null)}
            />
            <div className="st-side">
              <Inspector
                project={project}
                selection={selection}
                models={models}
                onCommand={run}
                onGenerate={generate}
                onSelect={setSelection}
                asset={selection?.type === 'asset' ? source : null}
                playhead={playhead}
                onDeleteAsset={deleteAsset}
              />
            </div>
          </div>
          <div className="st-splitter" onPointerDown={dragSplit} title={t('Ziehen: Höhe der Zeitleisten', 'Drag: height of the timelines')} />
          <Timelines
            project={project}
            playhead={playhead}
            zoom={zoom}
            selection={selection}
            onSelect={setSelection}
            onPlayhead={(x) => {
              setPlaying(false)
              setPlayhead(x)
            }}
            onCommand={run}
            onZoom={setZoom}
          />
        </>
      )}
    </div>
  )
}
