// Fortschritt in Phasen (seit 0.5.42, Konzept „NVAI im Fluss“, Bildschirm C): Rechner startet, Modell lädt, rechnet
// mit Schritt und Restzeit, speichert. Vorher stand beim ersten Auftrag 70 s lang nur „generiert · 2 %“.
import { t } from '../i18n'
import { currentPhase, isActive, phaseSeconds, remainingSeconds, useJob, useJobs, useNow, type PhaseKey } from './jobs'
import { fmtClock, fmtGb, fmtLeft } from './time'

interface Props {
  jobId: string
  /** Name des Modells für „Modell lädt (…)“ */
  modelName?: string
  /** Speicherbedarf des Modells (GB) für „Modell lädt (…, 14 GB)“ */
  modelGb?: number
  /** Rechenzeit laut Schätzung vor dem Start (ohne Start und Laden): Restzeit, solange die Rate noch unsicher ist */
  expected?: number | null
  /** Wer im Hinweis unten nur noch rechnet, schon übersetzt: t('das nächste Bild', 'the next image') */
  next?: string
}

const ORDER: PhaseKey[] = ['queue', 'prepare', 'start', 'load', 'run', 'save']

export function JobPhases({ jobId, modelName, modelGb, expected, next }: Props) {
  const job = useJob(jobId)
  const all = useJobs()
  const now = useNow(!!job && isActive(job))
  if (!job) return null
  const phase = currentPhase(job)
  const seen = new Set(job.marks.map((m) => m.key))
  const at = phase ? ORDER.indexOf(phase) : ORDER.length
  const state = (k: PhaseKey) => {
    if (!isActive(job)) return job.status === 'done' ? 'done' : job.status === 'error' ? 'err' : ''
    const i = ORDER.indexOf(k)
    return i < at ? 'done' : i === at ? 'run' : ''
  }
  const secs = (k: PhaseKey) => {
    const s = phaseSeconds(job, k, now)
    return s == null ? '' : s < 1 ? '' : fmtClock(s)
  }
  const ahead = phase === 'queue'
    ? all.filter((j) => j.id !== job.id && isActive(j) && j.created_at <= job.created_at && j.kind !== 'download').length
    : 0
  const left = remainingSeconds(job, expected, now)
  const pct = Math.max(0, Math.min(100, Math.round(((job.progress - 0.02) / 0.97) * 100)))
  const loadLabel = [modelName, modelGb ? fmtGb(modelGb) : ''].filter(Boolean).join(', ')
  const prepStage = job.marks.find((m) => m.key === 'prepare')?.stage || (phase === 'prepare' ? job.stage : '')
  const rows: { key: PhaseKey; label: React.ReactNode; right: React.ReactNode }[] = []

  if (phase === 'queue' || (seen.has('queue') && (phaseSeconds(job, 'queue', now) ?? 0) >= 2)) {
    rows.push({
      key: 'queue',
      label: <>{t('Wartet auf die GPU', 'Waiting for the GPU')}{ahead > 0 && <span className="muted"> · {ahead === 1 ? t('1 Auftrag davor', '1 job ahead') : t(`${ahead} Aufträge davor`, `${ahead} jobs ahead`)}</span>}</>,
      right: <span className="muted">{secs('queue')}</span>,
    })
  }
  if (seen.has('prepare') && (phase === 'prepare' || (phaseSeconds(job, 'prepare', now) ?? 0) >= 2)) {
    rows.push({
      key: 'prepare',
      label: <>{t('Bereitet vor', 'Preparing')}{prepStage && <span className="muted"> ({prepStage})</span>}</>,
      right: <span className="muted">{secs('prepare')}</span>,
    })
  }
  if (seen.has('start')) {
    rows.push({
      key: 'start',
      label: <>{t('Rechner startet', 'Engine starts')} <span className="muted">(ComfyUI)</span></>,
      right: <span className="muted">{secs('start')}</span>,
    })
  }
  if (seen.has('load')) {
    rows.push({
      key: 'load',
      label: <>{t('Modell lädt', 'Model loads')}{loadLabel && <span className="muted"> ({loadLabel})</span>}</>,
      right: <span className="muted">{secs('load')}</span>,
    })
  }
  rows.push({
    key: 'run',
    label: (
      <>
        {t('Rechnet', 'Computing')}
        {job.step && phase === 'run' && job.step.pass && <> · {t(`Durchgang ${job.step.pass.n} von ${job.step.pass.of}`, `pass ${job.step.pass.n} of ${job.step.pass.of}`)}</>}
        {job.step && phase === 'run' && <> · {t(`Schritt ${job.step.n} von ${job.step.of}`, `step ${job.step.n} of ${job.step.of}`)}</>}
        {phase === 'run' && <div className="flow-bar"><i style={{ width: `${pct}%` }} /></div>}
      </>
    ),
    right: phase === 'run' ? <span>{fmtLeft(left)}</span> : <span className="muted">{secs('run')}</span>,
  })
  rows.push({ key: 'save', label: <span className={state('save') ? '' : 'muted'}>{t('Speichern', 'Saving')}</span>, right: <span /> })

  return (
    <div className="flow-phases-box">
      <ol className="flow-phases" aria-live="polite">
        {rows.map((r) => (
          <li key={r.key}>
            <span className={`flow-dot ${state(r.key)}`} aria-hidden="true" />
            <span>{r.label}</span>
            {r.right}
          </li>
        ))}
      </ol>
      {(seen.has('start') || seen.has('load')) && (
        <p className="flow-note small">
          {t(`Start und Laden fallen nur beim ersten Auftrag an; ${next ?? 'der nächste Auftrag'} braucht nur die Rechenzeit.`,
            `Starting and loading only happen for the first job; ${next ?? t('der nächste Auftrag', 'the next job')} only needs the computing time.`)}
        </p>
      )}
    </div>
  )
}
