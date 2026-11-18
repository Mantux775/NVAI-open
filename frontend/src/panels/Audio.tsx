import { useCallback, useEffect, useRef, useState } from 'react'
import { api, type Asset, type AudioOp, type AudioProject, type AudioProjectSummary, type AudioStatus, type AudioTrashEntry, type Job, type ServerEvent } from '../api'
import { fmtClock } from '../audio/Timeline'
import { Recommendations } from '../components/Recommendations'
import { LicenseBadge, fmtMb } from '../forensic/tools'
import { Workspace, type WsMode } from '../forensic/Workspace'
import { t } from '../i18n'
import { ContextMenu, type MenuState } from '../studio/ContextMenu'

// Bereich „Ton-Forensik“ (bis 17.11.2026 abends „Audio“; Nutzer: „Ton wird zum Ton Forensik Tool, es braucht ähnlich
// wie in dem Studio unterschiedliche tracks … dann spuren für die Forensik, und tools die mann braucht“, dazu die
// Übersetzer-Spur und die Sektion „Forensik Player MaintenanceViewer“ für die Daten eines Schiffsschreibers).
// Server: audio_lab.py (Projekte, Spuren, Aufträge), audio_forensic.py (Spektrogramm, Sprache, Transkript),
// audio_vdr.py (Schiffsschreiber); Rechnen in audio_tools.py, forensic_tools.py, vdr.py. Arbeitsfläche: forensic/.

type Progress = { progress: number; stage: string }
type Main = 'home' | 'vdr' | 'models' | 'project'
const AUDIO_KINDS = ['audio_prepare', 'audio_dsp', 'audio_ai', 'audio_export', 'audio_setup', 'audio_learn', 'audio_scan',
  'audio_spectro', 'audio_vad', 'audio_transcribe', 'audio_align', 'audio_vdr_import', 'audio_vdr_verify', 'audio_hash',
  'audio_mix', 'audio_vexport', 'audio_render', 'audio_package']

function fmtBytes(b: number): string {
  return b >= 1024 ** 3 ? `${(b / 1024 ** 3).toLocaleString(undefined, { maximumFractionDigits: 1 })} GB` : `${Math.max(1, Math.round(b / 1024 ** 2))} MB`
}

/** Rückfrage vor dem Löschen eines Falls: er kommt in den Papierkorb */
function DeleteCaseDialog({ p, busyJob, onConfirm, onClose }: { p: AudioProjectSummary; busyJob: boolean; onConfirm: () => void; onClose: () => void }) {
  return (
    <div className="lt-modal" onClick={onClose}>
      <div className="lt-modal-box panel au-del-dialog" onClick={(e) => e.stopPropagation()}>
        <div className="lt-modal-head"><strong>{t(`Fall „${p.name}“ löschen?`, `Delete case “${p.name}”?`)}</strong></div>
        <p className="small">{t('Der Fall kommt in den Papierkorb (unter „Übersicht“). Dort lässt er sich wiederherstellen oder endgültig löschen.',
          'The case goes to the trash (under “Overview”). There it can be restored or deleted for good.')}</p>
        <ul className="small">
          <li>{t('Mit dem Fall gehen: Arbeitsspuren und Spektrogramme, Übersetzer-Spur, Notizen und Marken, Protokoll.', 'Going with the case: working tracks and spectrograms, translation track, notes and markers, log.')}</li>
          <li>{t('Es bleiben: die Originaldateien der Quelle (sie liegen nie im Fall) und alle Exporte im Verlauf.', 'Staying: the original source files (they never live inside the case) and all exports in the History.')}</li>
        </ul>
        {busyJob && <p className="hint warn small">{t('In diesem Fall läuft gerade ein Auftrag; erst abbrechen oder abwarten.', 'A job is running in this case; cancel it or wait first.')}</p>}
        <div className="lt-toolbar">
          <button className="btn danger" disabled={busyJob} onClick={onConfirm}>{t('In den Papierkorb', 'Move to the trash')}</button>
          <button className="btn ghost" onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
        </div>
      </div>
    </div>
  )
}

/** Rückfrage vor dem endgültigen Löschen (ein Fall oder der ganze Papierkorb) */
function PurgeDialog({ what, list, onConfirm, onClose }: { what: AudioTrashEntry | 'all'; list: AudioTrashEntry[]; onConfirm: () => void; onClose: () => void }) {
  const items = what === 'all' ? list : [what]
  const size = items.reduce((a, x) => a + x.size, 0)
  return (
    <div className="lt-modal" onClick={onClose}>
      <div className="lt-modal-box panel au-del-dialog" onClick={(e) => e.stopPropagation()}>
        <div className="lt-modal-head"><strong>{what === 'all'
          ? t(`Papierkorb leeren (${items.length} ${items.length === 1 ? 'Fall' : 'Fälle'})?`, `Empty the trash (${items.length} ${items.length === 1 ? 'case' : 'cases'})?`)
          : t(`„${what.name}“ endgültig löschen?`, `Delete “${what.name}” for good?`)}</strong></div>
        <p className="small">{t(`Das lässt sich nicht rückgängig machen und gibt ${fmtBytes(size)} frei. Die Originaldateien der Quelle und die Exporte im Verlauf bleiben.`,
          `This cannot be undone and frees ${fmtBytes(size)}. The original source files and the exports in the History stay.`)}</p>
        <div className="lt-toolbar">
          <button className="btn danger" onClick={onConfirm}>{t('Endgültig löschen', 'Delete for good')}</button>
          <button className="btn ghost" onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
        </div>
      </div>
    </div>
  )
}

/** Auswahl einer Datei aus dem Verlauf: Audio und Video */
function MediaPicker({ onPick, onClose }: { onPick: (a: Asset) => void; onClose: () => void }) {
  const [media, setMedia] = useState<'audio' | 'video'>('audio')
  const [q, setQ] = useState('')
  const [assets, setAssets] = useState<Asset[]>([])
  useEffect(() => {
    const timer = window.setTimeout(() => {
      api.assetPage({ media, q: q.trim() || undefined, limit: 120, offset: 0 }).then(setAssets).catch(() => setAssets([]))
    }, 200)
    return () => window.clearTimeout(timer)
  }, [media, q])
  return (
    <div className="lt-modal" onClick={onClose}>
      <div className="lt-modal-box panel" onClick={(e) => e.stopPropagation()}>
        <div className="lt-modal-head">
          <strong>{t('Aus dem Verlauf', 'From the history')}</strong>
          <select value={media} onChange={(e) => setMedia(e.target.value as 'audio' | 'video')}>
            <option value="audio">{t('Audio', 'Audio')}</option>
            <option value="video">{t('Video', 'Video')}</option>
          </select>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('Suchen …', 'Search …')} />
          <button className="btn small ghost" onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
        </div>
        <div className="au-pick-list">
          {assets.map((a) => (
            <button key={a.id} className="au-pick" onClick={() => onPick(a)}>
              {a.thumb_url ? <img src={a.thumb_url} alt="" /> : <span className="au-pick-icon">{a.kind === 'video' ? '🎬' : '♪'}</span>}
              <span><strong>{(a.meta?.original_name as string) || a.filename.split('/').pop()}</strong><br />
                <span className="muted small">{a.prompt?.slice(0, 90)}</span></span>
            </button>
          ))}
          {assets.length === 0 && <p className="muted small">{t('Nichts gefunden.', 'Nothing found.')}</p>}
        </div>
      </div>
    </div>
  )
}

export function AudioPanel({ event, active }: { event: ServerEvent | null; active: boolean }) {
  const [st, setSt] = useState<AudioStatus | null>(null)
  const [main, setMain] = useState<Main>('home')
  const [pid, setPid] = useState<string | null>(null)
  const [wsMode, setWsMode] = useState<WsMode>('forensic')
  const [proj, setProj] = useState<AudioProject | null>(null)
  const [running, setRunning] = useState<Job[]>([])
  const [progress, setProgress] = useState<Record<string, Progress>>({})
  const [paused, setPaused] = useState<Record<string, Job[]>>({})
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [picker, setPicker] = useState(false)
  const [path, setPath] = useState('')
  const [lastEvent, setLastEvent] = useState<{ type: string; project_id?: string; client?: string; n: number } | null>(null)
  const upload = useRef<HTMLInputElement>(null)
  // Fälle löschen (Nutzer 17.11.: „ich soll die fälle auch löschen können“): Papierkorb, Rückfragen, Rechtsklick
  const [trash, setTrash] = useState<AudioTrashEntry[]>([])
  const [askDelete, setAskDelete] = useState<AudioProjectSummary | null>(null)
  const [askPurge, setAskPurge] = useState<AudioTrashEntry | 'all' | null>(null)
  const [caseMenu, setCaseMenu] = useState<MenuState | null>(null)
  const loadTrash = useCallback(() => { api.audioTrash().then(setTrash).catch(() => setTrash([])) }, [])
  useEffect(() => { if (main === 'home') loadTrash() }, [main, loadTrash])

  const loadStatus = useCallback(() => { api.audioStatus().then(setSt).catch((e) => setError(String(e.message ?? e))) }, [])
  const loadProject = useCallback(() => {
    if (pid) api.audioProject(pid).then(setProj).catch(() => { setProj(null); setPid(null) })
    else setProj(null)
  }, [pid])
  const loadJobs = useCallback(() => {
    Promise.all(AUDIO_KINDS.map((k) => api.activeJobs(k).catch(() => [] as Job[]))).then((all) => setRunning(all.flat()))
  }, [])
  useEffect(loadStatus, [loadStatus])
  useEffect(loadProject, [loadProject])
  useEffect(loadJobs, [loadJobs])

  const timer = useRef<number | null>(null)
  const soon = useCallback(() => {
    if (timer.current) window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => { loadStatus(); loadProject(); loadJobs() }, 350)
  }, [loadStatus, loadProject, loadJobs])
  useEffect(() => {
    if (!event) return
    if (event.type === 'job.progress') {
      if (running.some((j) => j.id === event.job_id)) setProgress((p) => ({ ...p, [event.job_id]: { progress: event.progress, stage: event.stage } }))
    } else if (event.type === 'job.queued') {
      if (event.kind.startsWith('audio_')) soon()
    } else if (event.type === 'job.done' || event.type === 'job.error' || event.type === 'job.cancelled') {
      const j = running.find((x) => x.id === event.job_id)
      if (j) {
        if (event.type === 'job.error') setError(event.error)
        if (event.type === 'job.cancelled' && j.kind === 'audio_ai' && j.params?.project_id) {
          const key = String(j.params.project_id)
          setPaused((p) => ({ ...p, [key]: [...(p[key] ?? []).filter((x) => x.id !== j.id), j] }))
        }
        if (event.type === 'job.done' && ['audio_export', 'audio_render', 'audio_vexport', 'audio_package'].includes(j.kind)) {
          const dir = (j.params?.dest_dir as string | undefined) ?? ''
          setNotice(dir ? t(`Export fertig: gespeichert in ${dir} (Pfad unter „Protokoll“).`, `Export done: saved in ${dir} (path under “Log”).`)
            : t('Export fertig: Er liegt im Verlauf und unter „Protokoll“.', 'Export done: it is in the History and under “Log”.'))
        }
        soon()
      }
    } else if (event.type === 'audio.changed') {
      soon()
    } else if (event.type === 'audio.transcript') {
      setLastEvent((e) => ({ type: event.type, project_id: event.project_id, client: event.client, n: (e?.n ?? 0) + 1 }))
    }
  }, [event]) // eslint-disable-line react-hooks/exhaustive-deps

  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    setError('')
    setNotice('')
    setBusy(true)
    try {
      await fn()
      if (ok) setNotice(ok)
      soon()
    } catch (e) {
      setError(String((e as Error).message ?? e))
    } finally {
      setBusy(false)
    }
  }
  const openProject = (id: string, mode?: WsMode) => {
    const summary = st?.projects.find((x) => x.id === id)
    setWsMode(mode ?? ((summary?.kind ?? summary?.source_kind) === 'vdr' ? 'player' : 'forensic'))
    setPid(id)
    setMain('project')
  }
  const create = (o: { asset_id?: string; path?: string }) => act(async () => { const p = await api.audioCreate(o); openProject(p.id, 'forensic') })
  const install = (id: string) => act(() => api.audioSetup({ env: !st?.env_ready, models: id.split(',').filter(Boolean) }),
    t('Lädt im Hintergrund; der Fortschritt steht links.', 'Downloading in the background; progress is shown on the left.'))
  const setupRunning = running.find((j) => j.kind === 'audio_setup')
  const deleteCase = (p: AudioProjectSummary) => act(async () => {
    await api.audioProjectDelete(p.id)
    setAskDelete(null)
    if (pid === p.id) { setPid(null); setMain('home') }
    loadTrash()
  }, t(`„${p.name}“ liegt im Papierkorb (unter „Übersicht“).`, `“${p.name}” is in the trash (under “Overview”).`))
  const restoreCase = (x: AudioTrashEntry) => act(async () => { await api.audioTrashRestore(x.entry); loadTrash() },
    t(`„${x.name}“ ist wieder da.`, `“${x.name}” is back.`))
  const purge = (what: AudioTrashEntry | 'all') => act(async () => {
    const r = what === 'all' ? await api.audioTrashEmpty() : await api.audioTrashPurge(what.entry)
    setAskPurge(null)
    loadTrash()
    setNotice(t(`Endgültig gelöscht, ${fmtBytes(r.freed)} frei.`, `Deleted for good, ${fmtBytes(r.freed)} freed.`))
  })

  if (!st) return <div className="lt-panel"><p className="muted">{error || t('Lädt …', 'Loading …')}</p></div>
  const show: Main = main === 'project' && !proj ? 'home' : main

  if (show === 'project' && proj) {
    return (
      <div className="lt-panel fx-panel">
        {error && <p className="error fx-msg" onClick={() => setError('')}>{error}</p>}
        {notice && <p className="hint fx-msg" onClick={() => setNotice('')}>{notice}</p>}
        <Workspace key={proj.id} st={st} proj={proj} running={running.filter((j) => j.params?.project_id === proj.id)}
          progress={progress} paused={paused[proj.id] ?? []} active={active} mode={wsMode} event={lastEvent}
          onResume={(j) => act(async () => { await api.audioOp(proj.id, j.params.request as AudioOp); setPaused((p) => ({ ...p, [proj.id]: (p[proj.id] ?? []).filter((x) => x.id !== j.id) })) })}
          onDismiss={(j) => setPaused((p) => ({ ...p, [proj.id]: (p[proj.id] ?? []).filter((x) => x.id !== j.id) }))}
          onInstall={install} setupBusy={!!setupRunning} onError={setError} onNotice={setNotice} onReload={soon}
          onDeleted={() => { setPid(null); setMain('home'); loadStatus(); loadTrash(); setNotice(t('Der Fall liegt im Papierkorb (unter „Übersicht“).', 'The case is in the trash (under “Overview”).')) }}
          onBack={() => { setMain(proj.source.kind === 'vdr' ? 'vdr' : 'home') }} />
      </div>
    )
  }

  const caseIcon = (k?: string, video?: boolean) => (k === 'vdr' ? '🚢 ' : video ? '🎬 ' : '♪ ')
  return (
    <div className="lt-panel lt-studio au-panel">
      <aside className="lt-side">
        <div className="lt-side-head">
          <h2>{t('Ton-Forensik', 'Audio forensics')}</h2>
          <button className="btn small primary" onClick={() => upload.current?.click()} disabled={busy}>+ {t('Aufnahme', 'Recording')}</button>
          <input ref={upload} type="file" accept="audio/*,video/*,.mkv,.flac,.wav,.mp3,.m4a,.ogg,.opus" hidden
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) act(async () => { setNotice(t('Lädt hoch …', 'Uploading …')); const a = await api.upload(f); const p = await api.audioCreate({ asset_id: a.id }); openProject(p.id, 'forensic') }) }} />
        </div>
        <button className={`lt-side-item${show === 'home' ? ' on' : ''}`} onClick={() => setMain('home')}><span>{t('Übersicht', 'Overview')}</span></button>
        <button className={`lt-side-item${show === 'vdr' ? ' on' : ''}`} onClick={() => setMain('vdr')}>
          <span>🚢 {t('Forensik Player · MaintenanceViewer', 'Forensic player · MaintenanceViewer')}</span>
        </button>
        <button className={`lt-side-item${show === 'models' ? ' on' : ''}`} onClick={() => setMain('models')}>
          <span>{t('Modelle und Einrichten', 'Models and setup')}</span>
          <span className={`lt-dot ${st.env_ready && st.models.some((m) => m.installed) ? 'ok' : st.env_ready ? 'part' : 'no'}`} />
        </button>
        {setupRunning && (
          <div className="au-side-job">
            <span className="muted small">{progress[setupRunning.id]?.stage || t('lädt …', 'downloading …')}</span>
            <span className="lt-mini"><span style={{ width: `${Math.round((progress[setupRunning.id]?.progress ?? 0) * 100)}%` }} /></span>
          </div>
        )}
        <h4>{t('Fälle', 'Cases')}</h4>
        {st.projects.length === 0 && <p className="muted small">{t('Noch keine.', 'None yet.')}</p>}
        {st.projects.map((p) => {
          const job = running.find((j) => j.params?.project_id === p.id)
          const menu = (e: React.MouseEvent) => {
            e.preventDefault()
            setCaseMenu({ x: e.clientX, y: e.clientY, items: [
              { label: t('Öffnen', 'Open'), onClick: () => openProject(p.id) },
              { label: t('Im Player öffnen (ohne KI)', 'Open in the player (no AI)'), onClick: () => openProject(p.id, 'player') },
              { label: t('Fall löschen …', 'Delete case …'), danger: true, separator: true, onClick: () => setAskDelete(p) },
            ] })
          }
          return (
            <div key={p.id} className="au-case" onContextMenu={menu}>
              <button className="lt-side-run" onClick={() => openProject(p.id)}>
                <span className="lt-side-run-top"><strong>{caseIcon(p.kind ?? p.source_kind, p.has_video)}{p.name}</strong>
                  {job && <span className="lt-dot busy" />}</span>
                <span className="muted small">{p.duration ? fmtClock(p.duration) : p.status === 'error' ? t('Fehler', 'error') : t('wird eingelesen …', 'reading …')} · {p.tracks} {t('Spuren', 'tracks')}</span>
                {job && progress[job.id] && <span className="lt-mini"><span style={{ width: `${Math.round(progress[job.id].progress * 100)}%` }} /></span>}
              </button>
              <button className="au-case-del" title={t('Fall löschen …', 'Delete case …')} aria-label={t('Fall löschen', 'Delete case')}
                onClick={() => setAskDelete(p)}>🗑</button>
            </div>
          )
        })}
      </aside>

      <section className="lt-main panel">
        {error && <p className="error" onClick={() => setError('')}>{error}</p>}
        {notice && <p className="hint" onClick={() => setNotice('')}>{notice}</p>}
        {show === 'home' && (
          <div className="lt-home">
            <h3>{t('Aufnahmen prüfen, verstehen, belegen', 'Examine, understand and document recordings')}</h3>
            <p className="hint">{t('Arbeitsweise wie in der Forensik üblich: Das Original bleibt unverändert und jede Bearbeitung wird eine neue Spur daneben, jeder Schritt steht im Protokoll. Aufnahmen jeder Länge, auch viele Stunden; alles bleibt auf diesem Rechner.',
              'Working the forensic way: the original stays untouched and every operation becomes a new track next to it, every step is logged. Recordings of any length, also many hours; everything stays on this computer.')}</p>
            <div className="au-new">
              <button className="btn primary" disabled={busy} onClick={() => upload.current?.click()}>{t('Datei hochladen …', 'Upload a file …')}</button>
              <button className="btn" disabled={busy} onClick={() => setPicker(true)}>{t('Aus dem Verlauf …', 'From the history …')}</button>
              <input className="au-path" value={path} onChange={(e) => setPath(e.target.value)} placeholder={t('oder Pfad einer großen Datei auf diesem Rechner (wird nicht kopiert)', 'or the path of a large file on this computer (not copied)')} />
              <button className="btn" disabled={busy || !path.trim()} onClick={() => create({ path })}>{t('Öffnen', 'Open')}</button>
              <button className="btn" onClick={() => setMain('vdr')}>🚢 {t('Schiffsschreiber laden …', 'Load a voyage data recorder …')}</button>
            </div>
            <ol className="lt-home-steps">
              <li>{t('Sehen und hören: Wellenform und Spektrogramm je Spur, die Sprachaktivität zeigt, wo gesprochen wird; Tempo ohne Tonhöhenänderung, Schleife, Kanal solo.', 'See and hear: waveform and spectrogram per track, speech activity shows where people talk; speed without pitch change, loop, channel solo.')}</li>
              <li>{t('Verbessern: Filter, Entrauschen, Trennen und „Gezielt entfernen“ (Alarm lernen) erzeugen neue Spuren; erst an einer Auswahl probieren.', 'Enhance: filters, denoising, separation and “Remove a sound” (learn an alarm) create new tracks; try on a selection first.')}</li>
              <li>{t('Übersetzer-Spur: Gesprochenes als Satzblöcke im Original und übersetzt, je Block umschaltbar; KI-Text bleibt Entwurf, bis du ihn prüfst.', 'Translation track: speech as sentence blocks in the original and translated, switchable per block; AI text stays a draft until you check it.')}</li>
              <li>{t('Belegen: Marken mit Notizen, Export als Ton oder Video mit Ton, Transkript als Text oder Untertitel; das Protokoll hält jeden Schritt fest.', 'Document: markers with notes, export as audio or video with sound, transcript as text or subtitles; the log records every step.')}</li>
            </ol>
            {!st.env_ready && <button className="btn" onClick={() => setMain('models')}>{t('Zuerst die Modelle einrichten', 'Set up the models first')}</button>}
            <Recommendations mode="audiolab" />
          </div>
        )}
        {show === 'home' && trash.length > 0 && (
          <div className="au-trash">
            <h4>{t(`Papierkorb (${trash.length})`, `Trash (${trash.length})`)} <span className="muted small">{fmtBytes(trash.reduce((a, x) => a + x.size, 0))}</span></h4>
            {trash.map((x) => (
              <div key={x.entry} className="au-trash-row">
                <span>{caseIcon(x.kind)}<strong>{x.name}</strong> <span className="muted small">{x.duration ? `${fmtClock(x.duration)} · ` : ''}{x.tracks} {t('Spuren', 'tracks')} · {fmtBytes(x.size)} · {t('gelöscht', 'deleted')} {new Date(x.deleted * 1000).toLocaleString()}</span></span>
                <button className="btn small" disabled={busy || x.exists} title={x.exists ? t('Ein Fall mit dieser Kennung ist schon da', 'A case with this id already exists') : ''}
                  onClick={() => restoreCase(x)}>{t('Wiederherstellen', 'Restore')}</button>
                <button className="btn small ghost danger-text" disabled={busy} onClick={() => setAskPurge(x)}>{t('Endgültig löschen …', 'Delete for good …')}</button>
              </div>
            ))}
            {trash.length > 1 && <button className="btn small ghost danger-text" disabled={busy} onClick={() => setAskPurge('all')}>{t('Papierkorb leeren …', 'Empty the trash …')}</button>}
          </div>
        )}
        {show === 'vdr' && <VdrView st={st} busy={busy} running={running} progress={progress} onOpen={(id) => openProject(id, 'player')}
          onCreate={(p, name) => act(async () => { const x = await api.vdrCreate({ path: p, name }); openProject(x.id, 'player') })} onError={setError} />}
        {show === 'models' && <ModelsView st={st} busy={busy || !!setupRunning} onInstall={install}
          onEnv={() => act(() => api.audioSetup({ env: true, models: [] }))}
          onDelete={(id) => act(() => api.audioModelDelete(id))} />}
      </section>
      <ContextMenu menu={caseMenu} onClose={() => setCaseMenu(null)} />
      {askDelete && <DeleteCaseDialog p={askDelete} busyJob={running.some((j) => j.params?.project_id === askDelete.id)}
        onConfirm={() => deleteCase(askDelete)} onClose={() => setAskDelete(null)} />}
      {askPurge && <PurgeDialog what={askPurge} list={trash} onConfirm={() => purge(askPurge)} onClose={() => setAskPurge(null)} />}
      {picker && <MediaPicker onClose={() => setPicker(false)} onPick={(a) => { setPicker(false); create({ asset_id: a.id }) }} />}
    </div>
  )
}

function VdrView({ st, busy, running, progress, onOpen, onCreate, onError }: {
  st: AudioStatus
  busy: boolean
  running: Job[]
  progress: Record<string, Progress>
  onOpen: (id: string) => void
  onCreate: (path: string, name: string) => void
  onError: (e: string) => void
}) {
  const [path, setPath] = useState(() => { try { return localStorage.getItem('nvai.forensic.vdrpath') ?? '' } catch { return '' } })
  const [name, setName] = useState('')
  const [info, setInfo] = useState<Record<string, any> | null>(null)
  const [checking, setChecking] = useState(false)
  const clean = (p: string) => p.trim().replace(/^"|"$/g, '')
  const inspect = async () => {
    setChecking(true)
    setInfo(null)
    try {
      setInfo(await api.vdrInspect(clean(path)))
      try { localStorage.setItem('nvai.forensic.vdrpath', path.trim()) } catch { /* ohne Speicher */ }
    } catch (e) { onError(String((e as Error).message ?? e)) } finally { setChecking(false) }
  }
  const list = st.projects.filter((p) => (p.kind ?? p.source_kind) === 'vdr')
  const chans = (info?.audio ?? info?.channels ?? []) as { id?: string; input?: string; position?: string; category?: string }[]
  const utc = (x: unknown) => (typeof x === 'number' ? `${new Date(x * 1000).toISOString().slice(0, 19).replace('T', ' ')} UTC` : String(x ?? '–'))
  const count = (x: unknown) => (Array.isArray(x) ? x.length : 0)
  return (
    <div className="lt-home fx-vdr">
      <h3>🚢 {t('Forensik Player · MaintenanceViewer', 'Forensic player · MaintenanceViewer')}</h3>
      <p className="hint">{t('Lädt die Daten eines Schiffsdatenschreibers (VDR, zuerst Furuno VR-7000) mit allem, was er aufzeichnet: jeden Mikrofon- und Funkkanal als eigene Spur, Kurs, Geschwindigkeit, Ruder, Maschine, Wind, Tiefe, Alarme, Türen und Rampen, AIS, Radar- und ECDIS-Bilder sowie die Prüfsummen. Die Quelldateien werden nur gelesen, nie verändert.',
        'Loads the data of a voyage data recorder (VDR, Furuno VR-7000 first) with everything it records: every microphone and radio channel as its own track, heading, speed, rudder, engine, wind, depth, alarms, doors and ramps, AIS, radar and ECDIS pictures and the checksums. The source files are only read, never changed.')}</p>
      <div className="au-new">
        <input className="au-path" value={path} onChange={(e) => setPath(e.target.value)} placeholder={t('Ordner der VDR-Daten (mit block.1.….gz und Track.txt)', 'Folder of the VDR data (with block.1.….gz and Track.txt)')} />
        <button className="btn" disabled={!path.trim() || checking} onClick={inspect}>{checking ? t('prüft …', 'checking …') : t('Prüfen', 'Check')}</button>
      </div>
      {info && (
        <div className="fx-vdr-info">
          <div className="fx-ro-grid">
            <div className="fx-ro"><span className="fx-ro-label">{t('Gerät', 'Device')}</span><span className="fx-ro-value">{String(info.product ?? '–')}</span></div>
            <div className="fx-ro"><span className="fx-ro-label">{t('Beginn', 'Start')}</span><span className="fx-ro-value">{utc(info.start_utc)}</span></div>
            <div className="fx-ro"><span className="fx-ro-label">{t('Ende', 'End')}</span><span className="fx-ro-value">{utc(info.end_utc)}</span></div>
            <div className="fx-ro"><span className="fx-ro-label">{t('Dauer', 'Duration')}</span><span className="fx-ro-value">{typeof info.duration === 'number' ? fmtClock(info.duration) : '–'}</span></div>
            <div className="fx-ro"><span className="fx-ro-label">{t('Blöcke', 'Blocks')}</span><span className="fx-ro-value">{String(info.blocks ?? '–')}{count(info.gaps) ? ` · ${count(info.gaps)} ${t('Lücken', 'gaps')}` : ''}</span></div>
            <div className="fx-ro"><span className="fx-ro-label">{t('Größe', 'Size')}</span><span className="fx-ro-value">{typeof info.size_bytes === 'number' ? fmtMb(info.size_bytes / 1024 ** 2) : '–'}</span></div>
          </div>
          {chans.length > 0 && (
            <>
              <h4>{t(`${chans.length} Tonkanäle`, `${chans.length} audio channels`)}</h4>
              <ul className="fx-vdr-ch">{chans.map((c, i) => <li key={i}><strong>{c.input ?? c.id}</strong> {c.position ? `· ${c.position}` : ''} <span className="muted small">{c.category ?? ''}</span></li>)}</ul>
            </>
          )}
          <p className="muted small">
            {t(`${count(info.serial)} serielle Geräte · ${count(info.digital)} digitale und ${count(info.analog)} analoge Eingänge · ${count(info.images)} Bildquellen`,
              `${count(info.serial)} serial devices · ${count(info.digital)} digital and ${count(info.analog)} analog inputs · ${count(info.images)} picture sources`)}
          </p>
          <div className="au-new">
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Name des Falls (optional)', 'Case name (optional)')} />
            <button className="btn primary" disabled={busy} onClick={() => onCreate(clean(path), name)}>{t('Einlesen', 'Import')}</button>
            <span className="muted small">{t('Läuft im Hintergrund auf dem Prozessor.', 'Runs in the background on the CPU.')}</span>
          </div>
        </div>
      )}
      <h4>{t('Eingelesene Schiffsschreiber', 'Imported recorders')}</h4>
      {list.length === 0 && <p className="muted small">{t('Noch keine.', 'None yet.')}</p>}
      {list.map((p) => {
        const job = running.find((j) => j.params?.project_id === p.id)
        return (
          <div key={p.id} className="lt-own-row">
            <div className="lt-own-main">
              <strong>🚢 {p.name}</strong>
              <span className="muted small">{p.duration ? fmtClock(p.duration) : p.status === 'error' ? t('Fehler', 'error') : t('wird eingelesen …', 'reading …')} · {p.tracks} {t('Spuren', 'tracks')}</span>
              {job && <span className="lt-mini"><span style={{ width: `${Math.round((progress[job.id]?.progress ?? 0) * 100)}%` }} /></span>}
            </div>
            <button className="btn small primary" onClick={() => onOpen(p.id)}>{t('Öffnen', 'Open')}</button>
          </div>
        )
      })}
    </div>
  )
}

function ModelsView({ st, busy, onInstall, onEnv, onDelete }: {
  st: AudioStatus
  busy: boolean
  onInstall: (id: string) => void
  onEnv: () => void
  onDelete: (id: string) => void
}) {
  const groups: [string, string][] = [
    ['voice', t('Stimme von Musik trennen', 'Separate voice from music')],
    ['dialogue', t('Sprache, Musik und Geräusche trennen (Filme, Mitschnitte)', 'Separate speech, music and effects (films, recordings)')],
    ['denoise', t('Rauschen aus Sprache entfernen', 'Remove noise from speech')],
    ['asr', t('Sprache erkennen und übersetzen', 'Recognise and translate speech')],
    ['vad', t('Sprache finden', 'Find speech')],
  ]
  return (
    <div className="au-models">
      <h3>{t('Modelle und Einrichten', 'Models and setup')}</h3>
      <div className="lr-fix-box">
        <strong>{st.env_ready ? '✓ ' : '○ '}{t('Audio-Umgebung', 'Audio environment')}</strong>
        <p className="hint small">{t('Eine kleine eigene Umgebung (rund 30 MB); PyTorch kommt aus ComfyUI, es wird nichts doppelt geladen. Einlesen, Filter und Export laufen auch ohne sie.',
          'A small environment of its own (about 30 MB); PyTorch comes from ComfyUI, nothing is downloaded twice. Reading, filters and export work without it too.')}</p>
        {!st.env_ready && <button className="btn small" disabled={busy} onClick={onEnv}>{t('Einrichten', 'Set up')}</button>}
      </div>
      <p className="hint small">{t('Vorgeschlagen ist je Aufgabe das beste Modell, dessen Lizenz auch den Verkauf der Ergebnisse erlaubt (Recherche November 2026). Modelle, die nur Ausgänge leiser machen (Masken), erfinden nichts dazu.',
        'For each task the best model whose license also allows selling the results is suggested (research November 2026). Mask-based models only attenuate; they invent nothing.')}</p>
      {groups.map(([task, label]) => {
        const list = st.models.filter((m) => m.task === task)
        if (!list.length) return null
        return (
          <div key={task} className="au-model-group">
            <h4>{label}</h4>
            {list.map((m) => (
              <div key={m.id} className="lt-own-row">
                <div className="lt-own-main">
                  <strong>{m.label} {m.recommended_for.length > 0 && <span className="au-rec">★ {t('empfohlen', 'recommended')}</span>}</strong>
                  <span className="muted small">
                    <LicenseBadge m={m} /> {m.device === 'cpu' ? t('Prozessor', 'CPU') : t('Grafikkarte', 'GPU')}
                    {m.vram_gb ? ` · ${m.vram_gb} GB` : ''}{m.seconds_per_minute ? ` · ${t(`${m.seconds_per_minute} s je Minute Ton`, `${m.seconds_per_minute} s per minute of audio`)}` : ''} · {fmtMb(m.size_mb)}
                  </span>
                  {m.notes && <span className="hint small">{m.notes}</span>}
                </div>
                {m.installed
                  ? <button className="btn small ghost danger-text" disabled={busy} onClick={() => onDelete(m.id)}>{t('Löschen', 'Delete')}</button>
                  : <button className="btn small primary" disabled={busy} onClick={() => onInstall(m.id)}>{t('Laden', 'Download')} ({fmtMb(m.size_mb)})</button>}
              </div>
            ))}
          </div>
        )
      })}
      <p className="muted small">{t('Ablage', 'Location')}: {st.models_dir} · {t(`${st.free_gb} GB frei`, `${st.free_gb} GB free`)}</p>
    </div>
  )
}
