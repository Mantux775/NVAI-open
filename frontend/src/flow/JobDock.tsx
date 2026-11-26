// Eine Auftragsleiste über alle Reiter (seit 0.5.42, Konzept „NVAI im Fluss“, Bildschirm F): was läuft, was wartet
// (auch Anschluss-Szenen, die auf ihre Vorlage warten), mit Restzeit und Ziel; „Zeigen“ führt direkt zum Ergebnis,
// auch aus einem anderen Reiter. Vorher zeigte jeder Reiter den Fortschritt an anderer Stelle.
import { useEffect, useMemo, useRef, useState } from 'react'
import { api, type StudioChangedEvent, type StudioProject } from '../api'
import { t } from '../i18n'
import { estimateApi, type Estimate } from './estimate'
import { sceneRef } from './studio/logic'
import { currentPhase, isActive, noteEstimate, remainingSeconds, useJobs, useNow, type TrackedJob } from './jobs'
import { fmtClock, fmtEta, fmtLeft } from './time'

export type JobTab = 'generate' | 'studio' | 'vhs' | 'history' | 'models' | 'loras' | 'audio'

/** Wo ein Auftrag hingehört (für „Zeigen“ und ob ein Hinweis nötig ist) */
export function originTab(j: { kind: string; params: Record<string, any> }): JobTab {
  if (j.kind === 'studio_export' || j.params?.studio_project) return 'studio'
  if (j.kind.startsWith('lora_')) return 'loras'
  if (j.kind.startsWith('audio_')) return 'audio'
  if (j.kind.startsWith('vhs')) return 'vhs'
  return 'generate'
}

/** Rechnen auf der Grafikkarte (für „GPU frei in …“); Export und Ton-Forensik laufen in eigenen Schlangen */
const GPU_KINDS = new Set(['txt2img', 'txt2video', 'txt2audio', 'tts', 'img23d', 'restore', 'video_upscale',
  'expand_prompt', 'vhs', 'lora_train', 'lora_test', 'lora_dataset'])

const KIND_LABEL: Record<string, [string, string]> = {
  txt2img: ['Bild', 'Image'],
  txt2video: ['Video', 'Video'],
  txt2audio: ['Ton', 'Sound'],
  tts: ['Stimme', 'Voice'],
  img23d: ['3D-Modell', '3D model'],
  restore: ['Foto restaurieren', 'Restore photo'],
  video_upscale: ['Video hochskalieren', 'Upscale video'],
  expand_prompt: ['Prompt ausbauen', 'Expand prompt'],
  studio_export: ['Export', 'Export'],
  vhs: ['VHS', 'VHS'],
  lora_train: ['LoRA-Training', 'LoRA training'],
  lora_test: ['LoRA-Probebilder', 'LoRA test images'],
  lora_dataset: ['LoRA-Datensatz', 'LoRA dataset'],
}

function kindLabel(kind: string): string {
  const l = KIND_LABEL[kind]
  if (l) return t(l[0], l[1])
  return kind.startsWith('audio_') ? t('Ton-Forensik', 'Audio forensics') : kind
}

/** Kurz, was entsteht: „Video · 5 s“, „Ton · 60 s“, „Bild · Holzfass mit Eisenbändern“ */
function detail(j: TrackedJob): string {
  const p = j.params || {}
  if (j.kind === 'txt2video' && p.frames) return `${Math.round(Number(p.frames) / Number(p.fps || 24))} s`
  if (j.kind === 'txt2audio' && p.seconds) return `${Math.round(Number(p.seconds))} s`
  const prompt = String(p.prompt ?? p.text ?? '').trim()
  if (!prompt) return ''
  const words = prompt.split(/\s+/).slice(0, 5).join(' ')
  return words.length > 34 ? `${words.slice(0, 33)}…` : words
}

function sceneOf(p: StudioProject | undefined, j: TrackedJob) {
  if (!p) return null
  return p.scenes.find((s) => s.jobs.includes(j.id) || (j.asset_ids.length > 0 && j.asset_ids.some((a) => s.takes.includes(a)))) ?? null
}

/** Wie im Studio benannt: „Szene 3 · Video“, „Sprecher 2 · Stimme“ (Titel im Tooltip) */
function sceneLabel(p: StudioProject, sceneId: string, kind: string): string {
  return kind ? `${sceneRef(p, sceneId)} · ${kind}` : sceneRef(p, sceneId)
}

interface Row {
  key: string
  state: 'run' | 'queue' | 'wait' | 'done' | 'err' | 'off'
  label: string
  title?: string
  sub: string
  job?: TrackedJob
  cancel?: boolean
}

export function JobsChip({ open, pinned, onToggle }: { open: boolean; pinned: boolean; onToggle: (shown: boolean) => void }) {
  const jobs = useJobs()
  const recent = jobs.filter((j) => isActive(j) || (j.finished_at ?? 0) > Date.now() / 1000 - 600)
  if (!recent.length) return null
  const active = recent.filter(isActive).length
  // Sichtbar ist die Leiste, solange etwas läuft, oder wenn der Nutzer sie geöffnet hat (wie in JobDock)
  const shown = open && (pinned || active > 0)
  return (
    <button type="button" className={active ? 'flow-chip ok' : 'flow-chip'} onClick={() => onToggle(shown)} aria-expanded={shown}
      title={t('Alle Aufträge mit Restzeit', 'All jobs with time left')}>
      {active ? t(`Aufträge ${active}`, `Jobs ${active}`) : t('Aufträge ✓', 'Jobs ✓')} {shown ? '▾' : '▴'}
    </button>
  )
}

export function JobDock({ open, pinned = false, onClose, onShow, tab, studioEvent }: {
  open: boolean
  /** vom Nutzer geöffnet: auch ohne laufende Aufträge zeigen */
  pinned?: boolean
  onClose: () => void
  /** „Zeigen“/„Ansehen“: zum Ergebnis, auch in einem anderen Reiter */
  onShow: (job: TrackedJob, sceneId: string | null) => void
  tab: JobTab
  studioEvent: StudioChangedEvent | null
}) {
  const jobs = useJobs()
  const active = jobs.filter(isActive)
  const now = useNow(active.length > 0)
  const [projects, setProjects] = useState<Record<string, StudioProject>>({})
  const [estimates, setEstimates] = useState<Record<string, Estimate>>({})
  const [toast, setToast] = useState<{ job: TrackedJob; text: string; err: boolean } | null>(null)
  const prevStatus = useRef<Record<string, string>>({})

  // Projekte der Studio-Aufträge: Szenennamen und wartende Anschlüsse (neu bei jeder Änderung des Projekts)
  const pids = useMemo(() => [...new Set(jobs
    .filter((j) => isActive(j) || (j.finished_at ?? 0) > now / 1000 - 600)
    .map((j) => String(j.params?.studio_project ?? (j.kind === 'studio_export' ? j.params?.project_id ?? '' : '')))
    .filter(Boolean))].sort(), [jobs, now])
  const pidKey = pids.join(',')
  useEffect(() => {
    for (const pid of pids) {
      api.studioProject(pid).then((p) => setProjects((m) => ({ ...m, [pid]: p }))).catch(() => { /* gelöscht */ })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pidKey])
  useEffect(() => {
    if (studioEvent && pids.includes(studioEvent.project_id)) {
      api.studioProject(studioEvent.project_id).then((p) => setProjects((m) => ({ ...m, [p.id]: p }))).catch(() => {})
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [studioEvent])

  // Erwartete Rechenzeit je offenem Auftrag (einmal je Auftrag)
  const missingEst = active.filter((j) => !estimates[j.id] && Object.keys(j.params || {}).length > 0 && GPU_KINDS.has(j.kind))
  const estKey = missingEst.map((j) => j.id).join(',')
  useEffect(() => {
    if (!missingEst.length) return
    estimateApi.many(missingEst.map((j) => ({ kind: j.kind, params: j.params })))
      .then((r) => setEstimates((m) => {
        const next = { ...m }
        missingEst.forEach((j, i) => {
          if (!r.items[i]) return
          next[j.id] = r.items[i]
          noteEstimate(j.id, r.items[i])
        })
        return next
      }))
      .catch(() => { /* ohne Zeit */ })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [estKey])

  // Hinweis, wenn etwas fertig wird, das nicht im offenen Reiter liegt
  useEffect(() => {
    const prev = prevStatus.current
    for (const j of jobs) {
      const was = prev[j.id]
      if (was && (was === 'queued' || was === 'running') && (j.status === 'done' || j.status === 'error')
        && j.kind !== 'expand_prompt' && originTab(j) !== tab) {
        const p = projects[String(j.params?.studio_project ?? '')]
        const s = sceneOf(p, j)
        const what = s && p ? sceneLabel(p, s.id, kindLabel(j.kind)) : kindLabel(j.kind)
        setToast({
          job: j,
          err: j.status === 'error',
          text: j.status === 'error'
            ? t(`${what}: Fehler`, `${what}: error`)
            : s ? t(`${what} ist fertig, ein neuer Take liegt bereit.`, `${what} is done, a new take is ready.`)
              : t(`${what} ist fertig.`, `${what} is done.`),
        })
      }
      prev[j.id] = j.status
    }
  }, [jobs, tab, projects])
  useEffect(() => {
    if (!toast) return
    const timer = window.setTimeout(() => setToast(null), 10000)
    return () => window.clearTimeout(timer)
  }, [toast])

  const rows: Row[] = []
  const running = active.filter((j) => j.status === 'running')
  const queued = active.filter((j) => j.status === 'queued').sort((a, b) => a.created_at - b.created_at)
  const label = (j: TrackedJob): { label: string; title?: string; scene: string | null } => {
    const p = projects[String(j.params?.studio_project ?? '')]
    const s = sceneOf(p, j)
    if (p && s) return { label: sceneLabel(p, s.id, kindLabel(j.kind)), title: [s.title, p.name].filter(Boolean).join(' · '), scene: s.id }
    if (j.kind === 'studio_export') {
      const ep = projects[String(j.params?.project_id ?? '')]
      return { label: `${kindLabel(j.kind)}${ep ? ` · ${ep.name}` : ''}`, scene: null }
    }
    const d = detail(j)
    return { label: d ? `${kindLabel(j.kind)} · ${d}` : kindLabel(j.kind), title: String(j.params?.prompt ?? ''), scene: null }
  }
  const phaseText = (j: TrackedJob) => ({
    queue: t('wartet', 'queued'), prepare: t('bereitet vor', 'preparing'), start: t('Rechner startet', 'engine starts'),
    load: t('Modell lädt', 'model loads'), run: t('rechnet', 'computing'), save: t('speichert', 'saving'),
  }[currentPhase(j) ?? 'run'])
  let gpuLeft = 0
  let gpuAny = false
  for (const j of running) {
    const l = label(j)
    const est = estimates[j.id]
    const left = remainingSeconds(j, est?.seconds ?? null, now)
    if (GPU_KINDS.has(j.kind)) { gpuAny = true; gpuLeft += left ?? est?.seconds ?? 0 }
    const pct = Math.round(j.progress * 100)
    const ph = currentPhase(j)
    rows.push({
      key: j.id, state: 'run', label: l.label, title: l.title, job: j, cancel: true,
      sub: ph === 'run' && pct > 2 ? [`${pct} %`, fmtLeft(left)].filter(Boolean).join(' · ') : [phaseText(j), fmtLeft(left)].filter(Boolean).join(' · '),
    })
  }
  for (const j of queued) {
    const l = label(j)
    const est = estimates[j.id]
    if (GPU_KINDS.has(j.kind)) { gpuAny = true; gpuLeft += est?.seconds ?? 0 }
    rows.push({ key: j.id, state: 'queue', label: l.label, title: l.title, job: j, cancel: true,
      sub: [t('wartet', 'queued'), fmtEta(est?.seconds)].filter(Boolean).join(' · ') })
  }
  for (const p of Object.values(projects)) {
    for (const s of p.scenes) {
      if (!s.waiting_for) continue
      const src = p.scenes.find((x) => x.id === s.waiting_for)
      rows.push({
        key: `wait-${s.id}`, state: 'wait', label: sceneLabel(p, s.id, kindLabel(s.kind === 'image' ? 'txt2img' : 'txt2video')),
        title: p.name,
        sub: src ? t(`wartet auf ${sceneLabel(p, src.id, '')}`, `waits for ${sceneLabel(p, src.id, '')}`) : t('wartet auf die Vorlage', 'waits for its source'),
      })
    }
  }
  const finished = jobs
    .filter((j) => !isActive(j) && (j.finished_at ?? 0) > now / 1000 - 600 && j.kind !== 'expand_prompt')
    .slice(0, 6)
  for (const j of finished) {
    const l = label(j)
    const p = projects[String(j.params?.studio_project ?? '')]
    const took = j.started_at && j.finished_at ? fmtClock(j.finished_at - j.started_at) : ''
    rows.push({
      key: j.id, job: j, label: l.label, title: l.title,
      state: j.status === 'done' ? 'done' : j.status === 'error' ? 'err' : 'off',
      sub: j.status === 'error' ? (j.error ?? t('Fehler', 'Error'))
        : j.status === 'cancelled' ? t('abgebrochen', 'cancelled')
        : p ? t(`fertig · im Projekt „${p.name}“`, `done · in the project “${p.name}”`)
        : took ? t(`fertig nach ${took}`, `done after ${took}`) : t('fertig', 'done'),
    })
  }

  const show = (j: TrackedJob) => {
    const p = projects[String(j.params?.studio_project ?? '')]
    onShow(j, sceneOf(p, j)?.id ?? null)
  }

  return (
    <>
      {/* Von selbst nur, solange etwas läuft oder wartet: danach verdeckte sie zehn Minuten lang die Zeitleiste */}
      {open && rows.length > 0 && (pinned || rows.some((r) => r.state === 'run' || r.state === 'queue' || r.state === 'wait')) && (
        <div className="flow-dock" role="region" aria-label={t('Aufträge', 'Jobs')}>
          <div className="flow-dock-head">
            <b>{t('Aufträge', 'Jobs')}</b>
            <span className="flow-row">
              {gpuAny && gpuLeft > 0 && <span className="muted small">{t(`GPU frei in ${fmtEta(gpuLeft)}`, `GPU free in ${fmtEta(gpuLeft)}`)}</span>}
              <button type="button" className="btn small ghost" onClick={onClose} aria-label={t('Auftragsleiste schließen', 'Close the job list')}>✕</button>
            </span>
          </div>
          <ul>
            {rows.map((r) => (
              <li key={r.key}>
                <span className={`flow-dot ${r.state === 'run' ? 'run' : r.state === 'done' ? 'done' : r.state === 'err' ? 'err' : ''}`} aria-hidden="true" />
                <span title={r.title || undefined} style={{ minWidth: 0 }}>
                  <span className="label">{r.label}</span>
                  <span className="sub">{r.sub}</span>
                </span>
                {r.cancel && r.job ? (
                  <button type="button" className="btn small ghost" aria-label={t(`${r.label}: abbrechen`, `${r.label}: cancel`)}
                    title={t('Abbrechen', 'Cancel')} onClick={() => api.cancelJob(r.job!.id).catch(() => { /* schon fertig */ })}>✕</button>
                ) : r.job && (r.state === 'done' || r.state === 'err') ? (
                  <button type="button" className="btn small" onClick={() => show(r.job!)}>{t('Zeigen', 'Show')}</button>
                ) : <span />}
              </li>
            ))}
          </ul>
        </div>
      )}
      {toast && (
        <div className={toast.err ? 'flow-toast err' : 'flow-toast'} role="status">
          <span>{toast.text}</span>
          <button type="button" className="btn small" onClick={() => { show(toast.job); setToast(null) }}>{t('Ansehen', 'View')}</button>
          <button type="button" className="btn small ghost" onClick={() => setToast(null)} aria-label={t('Schließen', 'Close')}>✕</button>
        </div>
      )}
    </>
  )
}
