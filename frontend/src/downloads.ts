import { useCallback, useEffect, useRef, useState } from 'react'
import { api, type Job, type ServerEvent } from './api'
import { t } from './i18n'

/** Ein laufender oder wartender Modell-Download, je Modell-ID. */
export interface DlState {
  job: string
  name: string
  status: 'queued' | 'running'
  progress: number
  stage: string
}

export interface Downloads {
  active: Record<string, DlState>
  /** Zählt abgeschlossene Downloads hoch -- Panels laden daraufhin ihre Modellliste neu. */
  finished: number
  start: (modelId: string, clean?: boolean) => Promise<void>
  /** Download eines Modells abbrechen; fertige Teile bleiben zum Fortsetzen. */
  cancel: (modelId: string) => Promise<void>
  sync: () => Promise<void>
}

function fromJobs(jobs: Job[]): Record<string, DlState> {
  const out: Record<string, DlState> = {}
  for (const j of jobs) {
    if (j.kind !== 'download' || (j.status !== 'queued' && j.status !== 'running')) continue
    const entry = j.params.entry as { id?: string; name?: string } | undefined
    const id = entry?.id ?? j.id
    out[id] = {
      job: j.id,
      name: String(j.params.name ?? entry?.name ?? id),
      status: j.status,
      progress: j.progress,
      stage: j.stage,
    }
  }
  return out
}

/**
 * Download-Stand für die ganze App. Wahrheit ist die Jobliste des Servers: beim Start und
 * regelmäßig neu gelesen, dazwischen hält der Event-Feed den Fortschritt aktuell. So geht
 * nichts verloren, wenn man die Seite wechselt oder neu lädt.
 */
export function useDownloads(
  event: ServerEvent | null,
  onError: (message: string) => void,
): Downloads {
  const [active, setActive] = useState<Record<string, DlState>>({})
  const [finished, setFinished] = useState(0)
  const activeRef = useRef(active)
  activeRef.current = active

  const sync = useCallback(async () => {
    try {
      const next = fromJobs(await api.jobs(50))
      // Was eben noch lief und jetzt fehlt, ist fertig geworden (oder abgebrochen).
      if (Object.keys(activeRef.current).some((id) => !(id in next))) setFinished((n) => n + 1)
      setActive(next)
    } catch {
      /* Server kurz weg -- beim nächsten Durchlauf wieder */
    }
  }, [])

  useEffect(() => {
    sync()
    const timer = setInterval(sync, 4000)
    return () => clearInterval(timer)
  }, [sync])

  useEffect(() => {
    if (!event || !('job_id' in event)) return
    if (event.type === 'job.queued') {
      if (event.kind === 'download') sync()
      return
    }
    const hit = Object.entries(activeRef.current).find(([, d]) => d.job === event.job_id)
    if (!hit) return
    const [id] = hit
    if (event.type === 'job.started') {
      setActive((a) => (a[id] ? { ...a, [id]: { ...a[id], status: 'running' } } : a))
    } else if (event.type === 'job.progress') {
      setActive((a) =>
        a[id] ? { ...a, [id]: { ...a[id], status: 'running', progress: event.progress, stage: event.stage } } : a,
      )
    } else {
      setActive((a) => {
        const { [id]: _drop, ...rest } = a
        return rest
      })
      setFinished((n) => n + 1)
      if (event.type === 'job.error') onError(event.error)
    }
  }, [event, sync, onError])

  const start = useCallback(
    async (modelId: string, clean = false) => {
      const job = await api.downloadModel(modelId, clean)
      setActive((a) => ({
        ...a,
        [modelId]: {
          job: job.id,
          name: String(job.params.name ?? modelId),
          status: 'queued',
          progress: 0,
          stage: '',
        },
      }))
    },
    [],
  )

  const cancel = useCallback(async (modelId: string) => {
    const dl = activeRef.current[modelId]
    if (!dl) return
    try {
      const res = await api.cancelJob(dl.job)
      if (!res.ok && res.reason) onError(res.reason)
      // Laufender Download: bis zum Ende des Datenblocks "bricht ab …" anzeigen
      setActive((a) => (a[modelId] ? { ...a, [modelId]: { ...a[modelId], stage: t('bricht ab …', 'cancelling …') } } : a))
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e))
    }
    await sync()
  }, [onError, sync])

  return { active, finished, start, cancel, sync }
}
