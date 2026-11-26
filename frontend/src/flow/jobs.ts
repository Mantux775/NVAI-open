// Alle Aufträge der App an einer Stelle (seit 0.5.42, Konzept „NVAI im Fluss“: Phasen mit Restzeit, eine
// Auftragsleiste über alle Reiter). Gespeist aus jedem Ereignis des WebSockets (App reicht sie einzeln durch, nichts
// geht in einer gebündelten React-Aktualisierung verloren) und regelmäßig aus der Auftragsliste des Servers.
import { useEffect, useState, useSyncExternalStore } from 'react'
import { api, type Job, type ServerEvent } from '../api'
import type { Estimate } from './estimate'

/** queue: wartet auf die GPU · prepare: bereitet vor (Prompt ausbauen, Worker entladen) · start: GPU-Backend startet ·
 *  load: Modell lädt · run: rechnet · save: speichert */
export type PhaseKey = 'queue' | 'prepare' | 'start' | 'load' | 'run' | 'save'

export interface PhaseMark {
  key: PhaseKey
  /** Zeitpunkt des Wechsels (ms); bei Aufträgen, die erst mitten im Lauf gesehen wurden, der Zeitpunkt des Sehens */
  at: number
  stage: string
}

export interface TrackedJob extends Job {
  /** Phasen, wie diese Oberfläche sie gesehen hat */
  marks: PhaseMark[]
  /** Schritt x von y aus „Schritt 34/50“; bei mehreren Stufen dazu der Durchgang („Durchgang 1/2 · Schritt 3/8“) */
  step: { n: number; of: number; pass?: { n: number; of: number } } | null
  /** Ab hier wird gerechnet (Zeitpunkt und Fortschritt): Grundlage der Restzeit */
  runFrom: { at: number; progress: number } | null
  /** Auftrag erst über die Liste gesehen (Zeiten der früheren Phasen unbekannt) */
  partial: boolean
}

const ACTIVE = new Set(['queued', 'running'])
const KEEP = 60

let jobs: Record<string, TrackedJob> = {}
let snapshot: TrackedJob[] = []
const listeners = new Set<() => void>()
const fetching = new Set<string>()
// Schätzung je Auftrag (Rechenzeit, Start und Laden), sobald sie jemand kennt: Restzeit auch vor dem Rechnen ehrlich
const expectations: Record<string, Estimate> = {}

/** Schätzung eines Auftrags merken (Generieren beim Abschicken, Auftragsleiste für alle offenen) */
export function noteEstimate(jobId: string, est: Estimate | null | undefined): void {
  if (est && est.seconds != null) expectations[jobId] = est
}

function publish() {
  snapshot = Object.values(jobs).sort((a, b) => b.created_at - a.created_at)
  if (snapshot.length > KEEP) {
    // Ältere fertige zuerst vergessen, laufende und wartende nie
    const drop = snapshot.filter((j) => !ACTIVE.has(j.status)).slice(KEEP - snapshot.filter((j) => ACTIVE.has(j.status)).length)
    for (const j of drop) delete jobs[j.id]
    snapshot = Object.values(jobs).sort((a, b) => b.created_at - a.created_at)
  }
  for (const f of listeners) f()
}

/** „Schritt 34/50“, „Step 3/8“, „Durchgang 1/2 · Schritt 5/16“: der letzte Bruch ist der Schritt, ein Bruch davor der
 *  Durchgang (seit 0.5.42 zählt der Server die zwei Stufen von LTX-2.5) */
export function stepOf(stage: string): { n: number; of: number; pass?: { n: number; of: number } } | null {
  const all = [...(stage || '').matchAll(/(\d+)\s*\/\s*(\d+)/g)]
  const m = all[all.length - 1]
  if (!m) return null
  const n = Number(m[1])
  const of = Number(m[2])
  if (!(of > 0 && n <= of)) return null
  const p = all.length > 1 ? all[all.length - 2] : null
  const pass = p && Number(p[2]) > 1 && Number(p[1]) <= Number(p[2]) ? { n: Number(p[1]), of: Number(p[2]) } : undefined
  return pass ? { n, of, pass } : { n, of }
}

function lastPhase(j: TrackedJob): PhaseKey | null {
  return j.marks.length ? j.marks[j.marks.length - 1].key : null
}

/** Phase eines Fortschritts-Ereignisses; ohne Angabe des Servers aus Schritt und Fortschritt geschlossen */
function phaseFor(prev: PhaseKey | null, progress: number, stage: string, hint?: string): PhaseKey {
  if (hint === 'start' || hint === 'load' || hint === 'save') return hint
  if (stepOf(stage)) return 'run'
  if (progress >= 0.99) return 'save'
  if (progress > 0.02) return 'run'
  if (progress <= 0) return prev === 'start' || prev === 'load' ? prev : 'prepare'
  // 0 < p ≤ 0.02: nach „Modell lädt“ bis zum ersten Schritt weiter laden, sonst rechnet es schon
  return prev === 'load' ? 'load' : 'run'
}

function fromJob(job: Job, partial: boolean): TrackedJob {
  const now = Date.now()
  const key: PhaseKey | null = job.status === 'queued' ? 'queue'
    : job.status === 'running' ? phaseFor(null, job.progress, job.stage) : null
  return {
    ...job,
    marks: key ? [{ key, at: key === 'queue' ? job.created_at * 1000 : now, stage: job.stage }] : [],
    step: stepOf(job.stage),
    runFrom: null,
    partial,
  }
}

function fetchJob(id: string) {
  if (fetching.has(id)) return
  fetching.add(id)
  api.job(id)
    .then((job) => {
      const known = jobs[id]
      jobs = { ...jobs, [id]: known ? { ...known, ...pick(job, known) } : fromJob(job, true) }
      publish()
    })
    .catch(() => { /* verschwunden oder Server kurz weg */ })
    .finally(() => fetching.delete(id))
}

/** Was die Liste des Servers besser weiß; Zustand und Fortschritt aus den Ereignissen bleiben, wenn sie neuer sind */
function pick(job: Job, known: TrackedJob): Partial<TrackedJob> {
  const finished = !ACTIVE.has(job.status)
  return {
    kind: job.kind,
    params: job.params,
    created_at: job.created_at,
    started_at: job.started_at ?? known.started_at,
    finished_at: job.finished_at ?? known.finished_at,
    // Ein Ereignis kann schneller sein als die Liste: Fertiges nicht wieder auf „läuft“ setzen
    status: ACTIVE.has(known.status) || finished ? job.status : known.status,
    asset_ids: job.asset_ids.length ? job.asset_ids : known.asset_ids,
    error: job.error ?? known.error,
    progress: finished || job.progress > known.progress ? job.progress : known.progress,
    stage: job.progress >= known.progress ? job.stage : known.stage,
  }
}

/** Ein Ereignis des WebSockets einarbeiten (App ruft das für jedes Ereignis auf) */
export function applyJobEvent(e: ServerEvent): void {
  if (!('job_id' in e)) return
  const now = Date.now()
  const id = e.job_id
  const known = jobs[id]
  if (e.type === 'job.queued') {
    if (e.kind === 'download') return // die Download-Leiste zeigt sie
    if (!known) {
      jobs = {
        ...jobs,
        [id]: {
          id, kind: e.kind, status: 'queued', progress: 0, stage: '', params: {}, asset_ids: [], error: null,
          created_at: now / 1000, started_at: null, finished_at: null,
          marks: [{ key: 'queue', at: now, stage: '' }], step: null, runFrom: null, partial: false,
        },
      }
      publish()
    }
    fetchJob(id)
    return
  }
  if (!known) {
    fetchJob(id) // ein Auftrag von vor dem Laden der Seite oder von Claude per MCP
    return
  }
  if (known.kind === 'download') return
  let next: TrackedJob = known
  if (e.type === 'job.started') {
    next = { ...known, status: 'running', started_at: known.started_at ?? now / 1000 }
    if (lastPhase(next) === 'queue' || !next.marks.length) {
      next = { ...next, marks: [...next.marks, { key: 'prepare', at: now, stage: '' }] }
    }
  } else if (e.type === 'job.progress') {
    const prev = lastPhase(known)
    const key = phaseFor(prev, e.progress, e.stage, e.phase)
    const marks = key !== prev ? [...known.marks, { key, at: now, stage: e.stage }]
      : known.marks.map((m, i) => (i === known.marks.length - 1 ? { ...m, stage: e.stage } : m))
    const step = stepOf(e.stage)
    next = {
      ...known,
      status: 'running',
      progress: e.progress,
      stage: e.stage,
      marks,
      step: step ?? (key === 'run' ? known.step : null),
      // Erster Fortschritt beim Rechnen: ab hier gilt die Rate für die Restzeit
      runFrom: key === 'run' && !known.runFrom ? { at: now, progress: e.progress } : known.runFrom,
    }
  } else if (e.type === 'job.done') {
    next = { ...known, status: 'done', progress: 1, asset_ids: e.asset_ids, finished_at: now / 1000 }
  } else if (e.type === 'job.error') {
    next = { ...known, status: 'error', error: e.error, finished_at: now / 1000 }
  } else if (e.type === 'job.cancelled') {
    next = { ...known, status: 'cancelled', finished_at: now / 1000 }
  }
  if (next !== known) {
    jobs = { ...jobs, [id]: next }
    publish()
    if (e.type === 'job.done' && !Object.keys(known.params).length) fetchJob(id)
  }
}

/** Mit der Auftragsliste des Servers abgleichen (beim Start, regelmäßig, nach einem Wiederverbinden) */
export async function syncJobs(): Promise<void> {
  try {
    const list = await api.jobs(40, 0, 'download')
    let changed = false
    const next = { ...jobs }
    for (const job of list) {
      const known = next[job.id]
      if (!known) {
        // Ältere fertige Aufträge nicht in die Leiste holen: nur laufende, wartende und die der letzten 10 Minuten
        if (!ACTIVE.has(job.status) && (job.finished_at ?? 0) < Date.now() / 1000 - 600) continue
        next[job.id] = fromJob(job, true)
        changed = true
      } else {
        const merged = { ...known, ...pick(job, known) }
        if (merged.status !== known.status || merged.progress !== known.progress || merged.params !== known.params) {
          next[job.id] = merged
          changed = true
        }
      }
    }
    // Was als laufend galt und in der Liste fertig ist, ist oben schon aktualisiert; was ganz fehlt (gelöscht), fällt weg
    const ids = new Set(list.map((j) => j.id))
    const oldest = list.length ? Math.min(...list.map((j) => j.created_at)) : Infinity
    for (const j of Object.values(next)) {
      if (!ids.has(j.id) && j.created_at >= oldest && !fetching.has(j.id)) {
        delete next[j.id]
        changed = true
      }
    }
    if (changed) {
      jobs = next
      publish()
    }
  } catch {
    /* Server kurz weg -- beim nächsten Mal */
  }
}

function subscribe(f: () => void): () => void {
  listeners.add(f)
  return () => listeners.delete(f)
}

/** Alle bekannten Aufträge, neueste zuerst */
export function useJobs(): TrackedJob[] {
  return useSyncExternalStore(subscribe, () => snapshot)
}

/** Ein Auftrag (oder undefined, solange er noch nicht gesehen wurde) */
export function useJob(id: string | null | undefined): TrackedJob | undefined {
  const all = useJobs()
  return id ? all.find((j) => j.id === id) : undefined
}

/** Vorab holen, etwa wenn ein Panel einen Auftrag abschickt (die Antwort kann vor dem Ereignis da sein) */
export function trackJob(job: Job, est?: Estimate | null): void {
  noteEstimate(job.id, est)
  if (jobs[job.id] || job.kind === 'download') return
  // Ein frisch abgeschickter Auftrag wartet ab jetzt; ein schon laufender (etwa über „Zeigen“ geöffnet) steht in seiner
  // Phase, deren Beginn wir nicht kennen
  const tracked = fromJob(job, job.status !== 'queued')
  jobs = {
    ...jobs,
    [job.id]: job.status === 'queued' ? { ...tracked, marks: [{ key: 'queue', at: Date.now(), stage: '' }] } : tracked,
  }
  publish()
}

export function isActive(j: { status: string }): boolean {
  return ACTIVE.has(j.status)
}

export function currentPhase(j: TrackedJob): PhaseKey | null {
  return isActive(j) ? lastPhase(j) : null
}

/** Wie lange eine Phase dauerte bzw. bis jetzt dauert (Sekunden); null, wenn unbekannt */
export function phaseSeconds(j: TrackedJob, key: PhaseKey, now = Date.now()): number | null {
  const i = j.marks.findIndex((m) => m.key === key)
  if (i < 0) return null
  if (j.partial && i === 0 && key !== 'queue') return null
  const end = i + 1 < j.marks.length ? j.marks[i + 1].at
    : isActive(j) ? now : (j.finished_at ?? now / 1000) * 1000
  return Math.max(0, (end - j.marks[i].at) / 1000)
}

/**
 * Restzeit in Sekunden: aus der Rate seit Beginn des Rechnens; solange davon noch wenig zu sehen ist, aus der Schätzung
 * vor dem Start (`expected` bzw. die gemerkte Schätzung: Rechenzeit, dazu was von Start und Laden noch fehlt; im Test
 * zeigte die Anzeige sonst während eines 58-s-Starts „noch ≈ 30 s“). null = noch keine Aussage.
 */
export function remainingSeconds(j: TrackedJob, expected?: number | null, now = Date.now()): number | null {
  if (!isActive(j)) return null
  const phase = currentPhase(j)
  if (phase === 'save') return 2
  const est = expectations[j.id]
  const base = expected ?? est?.seconds ?? null
  const from = j.runFrom
  if (phase === 'run' && from) {
    const span = Math.max(0.01, 0.99 - from.progress)
    const frac = (j.progress - from.progress) / span
    const elapsed = (now - from.at) / 1000
    if (frac >= 0.04 && elapsed >= 3) return Math.max(1, (elapsed * (1 - frac)) / frac)
    if (base) return Math.max(1, base - elapsed)
    return null
  }
  if (base == null) return null
  if (phase === 'start') {
    const spent = phaseSeconds(j, 'start', now) ?? 0
    return Math.max(3, (est?.cold.start ?? 32) - spent) + (est?.cold.load ?? 0) + base
  }
  if (phase === 'load') {
    const spent = phaseSeconds(j, 'load', now) ?? 0
    return Math.max(3, (est?.cold.load ?? 0) - spent) + base
  }
  if (phase === 'queue' || phase === 'prepare') {
    // Vor dem Start: Rechenzeit samt Start und Laden, wenn sie anfallen
    return base + (est ? (est.cold.start ?? 0) + (est.cold.load ?? 0) : 0)
  }
  return base
}

/** Rendert jede Sekunde neu, solange `on` gilt (Restzeiten laufen herunter) */
export function useNow(on: boolean, everyMs = 1000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!on) return
    const timer = window.setInterval(() => setNow(Date.now()), everyMs)
    return () => window.clearInterval(timer)
  }, [on, everyMs])
  return now
}
