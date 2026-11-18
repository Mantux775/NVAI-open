import { useEffect, useMemo, useRef, useState } from 'react'
import { api, loraFileUrl, type Job, type LoraRun, type LoraTrainStatus } from '../api'
import { t } from '../i18n'
import { fmtDuration, fmtTime, STATUS_LABEL, type Progress, type Viewer } from './loraShared'

// Trainings-Monitor (Nutzer 17.11.2026: „es soll fortschritt anzeigen ich soll es pausieren und fortsetzen und
// korrigieren und testen können, baue es komplett aus so wie studio“). Server: lora_train.py (request_pause,
// resume_training, branch_training, _quick_test, log_tail).

type Tab = 'compare' | 'quick' | 'fix' | 'log'

function nextAt(hhmm: string): number {
  const [h, m] = hhmm.split(':').map((x) => Number(x) || 0)
  const d = new Date()
  d.setHours(h, m, 0, 0)
  if (d.getTime() < Date.now() + 60_000) d.setDate(d.getDate() + 1)
  return Math.round(d.getTime() / 1000)
}

const fmtLoss = (v: number) => v.toLocaleString(undefined, { minimumFractionDigits: 3, maximumFractionDigits: 3 })

/** Verlust über die Schritte: eine Linie, Epochen als feine Linien, Zwischenstände als Marken, Fadenkreuz */
function LossChart({ loss, stepsPerEpoch, totalSteps, epochs, marks }: {
  loss: [number, number][]
  stepsPerEpoch: number
  totalSteps: number
  epochs: number
  marks: number[]
}) {
  const [hover, setHover] = useState<number | null>(null)
  const box = useRef<SVGSVGElement>(null)
  const W = 860, H = 230, L = 46, R = 12, T = 12, B = 28
  const pts = loss.filter((p) => Number.isFinite(p[1]))
  const ys = pts.map((p) => p[1])
  const lo = ys.length ? Math.min(...ys) : 0
  const hi = ys.length ? Math.max(...ys) : 1
  const pad = (hi - lo) * 0.08 || 0.01
  const y0 = Math.max(0, lo - pad), y1 = hi + pad
  const xMax = Math.max(totalSteps, pts.length ? pts[pts.length - 1][0] : 1, 1)
  const x = (s: number) => L + (W - L - R) * (s / xMax)
  const y = (v: number) => T + (H - T - B) * (1 - (v - y0) / (y1 - y0 || 1))
  const path = pts.map((p, i) => `${i ? 'L' : 'M'}${x(p[0]).toFixed(1)},${y(p[1]).toFixed(1)}`).join('')
  const yTicks = [y0, (y0 + y1) / 2, y1]
  const epochStep = epochs > 40 ? 10 : epochs > 12 ? 5 : epochs > 6 ? 2 : 1
  const onMove = (e: React.MouseEvent) => {
    if (!box.current || !pts.length) return
    const r = box.current.getBoundingClientRect()
    const sx = ((e.clientX - r.left) / r.width) * W
    const step = ((sx - L) / (W - L - R)) * xMax
    let best = 0
    for (let i = 1; i < pts.length; i++) if (Math.abs(pts[i][0] - step) < Math.abs(pts[best][0] - step)) best = i
    setHover(best)
  }
  const hp = hover != null ? pts[hover] : null
  return (
    <div className="lr-chart">
      <div className="lr-chart-head">
        <strong>{t('Verlust', 'Loss')}</strong>
        <span className="muted small">{t('gleitender Mittelwert je Schritt; sinkt er nicht mehr, lernt die LoRA kaum noch dazu', 'moving average per step; once it stops falling, the LoRA learns little more')}</span>
      </div>
      {pts.length < 2 ? (
        <p className="muted small lr-chart-empty">{t('Die Kurve erscheint mit den ersten Trainingsschritten.', 'The curve appears with the first training steps.')}</p>
      ) : (
        <svg ref={box} viewBox={`0 0 ${W} ${H}`} className="lr-chart-svg" onMouseMove={onMove} onMouseLeave={() => setHover(null)}
          role="img" aria-label={t(`Verlust über ${pts.length} Schritte, zuletzt ${fmtLoss(pts[pts.length - 1][1])}`, `Loss over ${pts.length} steps, last ${fmtLoss(pts[pts.length - 1][1])}`)}>
          {Array.from({ length: epochs + 1 }, (_, e) => e).filter((e) => e > 0 && e % epochStep === 0).map((e) => (
            <g key={e}>
              <line x1={x(e * stepsPerEpoch)} x2={x(e * stepsPerEpoch)} y1={T} y2={H - B} className="lr-grid" />
              <text x={x(e * stepsPerEpoch)} y={H - 10} className="lr-axis" textAnchor="middle">{e}</text>
            </g>
          ))}
          {yTicks.map((v, i) => (
            <g key={i}>
              <line x1={L} x2={W - R} y1={y(v)} y2={y(v)} className="lr-grid" />
              <text x={L - 6} y={y(v) + 4} className="lr-axis" textAnchor="end">{fmtLoss(v)}</text>
            </g>
          ))}
          <text x={L} y={H - 10} className="lr-axis" textAnchor="start">{t('Epoche', 'epoch')}</text>
          <path d={path} className="lr-line" />
          {marks.map((e) => (
            <circle key={e} cx={x(e * stepsPerEpoch)} cy={H - B} r={4} className="lr-mark">
              <title>{t(`Zwischenstand Epoche ${e}`, `checkpoint epoch ${e}`)}</title>
            </circle>
          ))}
          {hp && (
            <g>
              <line x1={x(hp[0])} x2={x(hp[0])} y1={T} y2={H - B} className="lr-cross" />
              <circle cx={x(hp[0])} cy={y(hp[1])} r={4.5} className="lr-dot" />
            </g>
          )}
        </svg>
      )}
      {hp && (
        <div className="lr-tip">
          {t(`Schritt ${hp[0]} · Epoche ${Math.ceil(hp[0] / Math.max(1, stepsPerEpoch))} · Verlust ${fmtLoss(hp[1])}`,
            `step ${hp[0]} · epoch ${Math.ceil(hp[0] / Math.max(1, stepsPerEpoch))} · loss ${fmtLoss(hp[1])}`)}
        </div>
      )}
    </div>
  )
}

export function RunMonitor({ st, run, progress, testProgress, onJob, onCancel, onReload, onDeleted, onAdopted, onOpenRun,
  onOpenDataset, setViewer }: {
  st: LoraTrainStatus
  run: LoraRun
  progress: Progress | null
  testProgress: (Progress & { id: string }) | null
  onJob: (job: Job) => void
  onCancel: (id: string) => void
  onReload: () => void
  onDeleted: () => void
  onAdopted: () => void
  onOpenRun: (id: string) => void
  onOpenDataset: (id: string) => void
  setViewer: (v: Viewer) => void
}) {
  const [tab, setTab] = useState<Tab>('compare')
  const [prompts, setPrompts] = useState<string[]>(run.tests.prompts?.length ? run.tests.prompts : st.test_prompts)
  const [names, setNames] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [moreEpochs, setMoreEpochs] = useState<number>(Number(run.settings.epochs) || 20)
  const [when, setWhen] = useState<'now' | 'night'>('now')
  const [nightTime, setNightTime] = useState('02:00')
  const latest = run.checkpoints[run.checkpoints.length - 1]
  const [qCk, setQCk] = useState(latest?.file ?? '')
  const [qPrompt, setQPrompt] = useState(st.test_prompts[0] ?? '')
  const [qStrengths, setQStrengths] = useState<number[]>([1])
  const [qSeed, setQSeed] = useState(777)
  const [bCk, setBCk] = useState(latest?.file ?? '')
  const [bEpochs, setBEpochs] = useState(10)
  const [bLr, setBLr] = useState(String(run.settings.lr ?? st.defaults.lr))
  const [log, setLog] = useState<string[]>([])

  useEffect(() => {
    setPrompts(run.tests.prompts?.length ? run.tests.prompts : st.test_prompts)
    setConfirmDelete(false)
  }, [run.id, run.tests.time]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setMoreEpochs(Number(run.settings.epochs) || 20) }, [run.id, run.settings.epochs])
  useEffect(() => {
    if (!run.checkpoints.some((c) => c.file === qCk)) setQCk(latest?.file ?? '')
    if (!run.checkpoints.some((c) => c.file === bCk)) setBCk(latest?.file ?? '')
  }, [run.checkpoints.length]) // eslint-disable-line react-hooks/exhaustive-deps

  const running = run.status === 'running' || run.status === 'queued'
  useEffect(() => {
    if (tab !== 'log') return
    let alive = true
    const load = () => api.loraRunLog(run.id, 120).then((r) => { if (alive) setLog(r.lines) }).catch(() => {})
    load()
    const timer = running ? window.setInterval(load, 8000) : undefined
    return () => { alive = false; if (timer) window.clearInterval(timer) }
  }, [tab, run.id, running, run.status])

  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    setError('')
    setNotice('')
    setBusy(true)
    try {
      await fn()
      if (ok) setNotice(ok)
      onReload()
    } catch (e) {
      setError(String((e as Error).message ?? e))
    } finally {
      setBusy(false)
    }
  }

  const s = run.settings
  const epochs = Number(s.epochs) || 0
  const spe = Math.max(1, Number(run.images) || 1)
  const totalSteps = epochs * spe
  const live = run.live
  const doneEpochs = run.state?.epoch ?? run.epochs_done ?? 0
  const base = run.epoch_base ?? 0
  const step = live?.step ?? (running ? doneEpochs * spe : run.status === 'done' ? totalSteps : doneEpochs * spe)
  const frac = progress && running ? progress.progress : totalSteps ? step / totalSteps : 0
  const ckEpochs = run.checkpoints.map((c) => c.epoch)
  const canResume = !running && run.status !== 'scheduled' && (run.status !== 'done' || Boolean(run.state))
  const columns: { key: string; label: string; file?: string }[] = [
    { key: '_ohne', label: t('ohne LoRA', 'without LoRA') },
    ...run.checkpoints.map((c) => ({ key: c.file, label: t(`Epoche ${c.epoch}`, `epoch ${c.epoch}`), file: c.file })),
  ]
  const images = run.tests.images ?? {}
  const rows = run.tests.prompts ?? []
  const allUrls: string[] = []
  const allLabels: string[] = []
  rows.forEach((p, r) => columns.forEach((c) => {
    const name = images[c.key]?.[r]
    if (name) { allUrls.push(loraFileUrl('runs', run.id, `test/${name}`)); allLabels.push(`${c.label} · ${p}`) }
  }))
  const adopted = new Map((run.adopted ?? []).map((a) => [a.checkpoint, a.model_id]))
  const testCount = (run.checkpoints.length + 1) * prompts.filter((p) => p.trim()).length
  const quick = run.quick ?? []
  const quickUrls = useMemo(() => quick.map((q) => loraFileUrl('runs', run.id, `test/${q.file}`)), [quick, run.id])
  const startAt = when === 'night' ? nextAt(nightTime) : undefined

  return (
    <div className="lr">
      <div className="lr-head">
        <div className="lr-title">
          <strong>{run.name}</strong>
          <span className="muted small">
            <code>{run.trigger}</code>{run.images ? <> · {run.images} {t('Bilder', 'images')}</> : null}
            {s.epochs ? <> · {s.epochs} {t('Epochen', 'epochs')}, {t('Lernrate', 'learning rate')} {s.lr}, {t('Rang', 'rank')} {s.rank}, Alpha {s.alpha ?? 1}</> : null}
            {run.parent ? <> · {t('ab', 'from')} <button className="linklike" onClick={() => onOpenRun(run.parent!.run)}>{run.parent.run}</button> {t(`Epoche ${run.parent.epoch}`, `epoch ${run.parent.epoch}`)}</> : null}
          </span>
        </div>
        <span className={`lt-status ${run.pause && run.status === 'running' ? 'pausing' : run.status}`}>
          {run.pause && run.status === 'running' ? t('hält an …', 'pausing …') : STATUS_LABEL[run.status] ?? run.status}
        </span>
      </div>

      <div className="lr-progress">
        <div className="lr-bar">
          <div className="lr-fill" style={{ width: `${Math.round(Math.min(1, frac) * 1000) / 10}%` }} />
          {Array.from({ length: epochs }, (_, e) => e + 1).filter((e) => e < epochs).map((e) => (
            <span key={e} className={`lr-tick${ckEpochs.includes(e) ? ' ck' : ''}${e <= base ? ' base' : ''}`} style={{ left: `${(e / epochs) * 100}%` }} />
          ))}
        </div>
        <div className="lr-stats">
          {running && progress && <span>{progress.stage}</span>}
          {!running && live == null && (
            <span className="muted">
              {run.status === 'done' ? t(`fertig: ${epochs} Epochen`, `done: ${epochs} epochs`)
                : doneEpochs ? t(`${doneEpochs} von ${epochs} Epochen trainiert`, `${doneEpochs} of ${epochs} epochs trained`)
                  : t(`${epochs} Epochen geplant`, `${epochs} epochs planned`)}
              {run.started ? ` · ${t('begonnen', 'started')} ${fmtTime(run.started)}` : ''}
              {run.finished && run.status === 'done' && run.started ? ` · ${fmtDuration(run.finished - run.started)}` : ''}
            </span>
          )}
          {live?.s_per_step ? <span className="muted">{live.s_per_step.toLocaleString(undefined, { maximumFractionDigits: 1 })} {t('s je Schritt', 's per step')}</span> : null}
          {run.state && <span className="muted">{t(`Haltepunkt: Epoche ${run.state.epoch} (${(run.state.size_mb / 1024).toFixed(1)} GB)`, `resume point: epoch ${run.state.epoch} (${(run.state.size_mb / 1024).toFixed(1)} GB)`)}</span>}
        </div>
      </div>

      <div className="lr-controls">
        {run.status === 'running' && !run.pause && (
          <>
            <button className="btn" disabled={busy} onClick={() => act(() => api.loraRunPause(run.id, 'epoch'), t('Hält nach der laufenden Epoche an; bis dahin geht nichts verloren.', 'Pauses after the current epoch; nothing is lost until then.'))}>
              ⏸ {t('Pausieren nach dieser Epoche', 'Pause after this epoch')}
            </button>
            <button className="btn ghost" disabled={busy} onClick={() => act(() => api.loraRunPause(run.id, 'now'))}
              title={t('Die angefangene Epoche geht verloren', 'The started epoch is lost')}>{t('Sofort anhalten', 'Stop now')}</button>
          </>
        )}
        {run.status === 'running' && run.pause && (
          <span className="hint small">{run.pause === 'now' ? t('Hält sofort an …', 'Stopping now …') : t('Hält am Ende der laufenden Epoche an; die Grafikkarte ist danach frei.', 'Pauses at the end of the current epoch; the graphics card is free afterwards.')}</span>
        )}
        {run.status === 'queued' && (
          <button className="btn" disabled={busy} onClick={() => act(() => api.loraRunPause(run.id, 'epoch'))}>{t('Zurückstellen', 'Hold back')}</button>
        )}
        {run.status === 'scheduled' && (
          <>
            <span className="hint small">{t(`Vorgemerkt für ${fmtTime(run.start_at)}; es startet, sobald NVAI-open läuft.`, `Scheduled for ${fmtTime(run.start_at)}; it starts as soon as NVAI-open is running.`)}</span>
            <button className="btn small ghost" disabled={busy} onClick={() => act(() => api.loraRunPause(run.id, 'epoch'))}>{t('Vormerkung aufheben', 'Remove schedule')}</button>
          </>
        )}
        {canResume && (
          <>
            <label className="lr-inline">{t('Epochen gesamt', 'Epochs in total')}
              <input type="number" className="lt-num" min={doneEpochs + 1} max={200} value={moreEpochs} onChange={(e) => setMoreEpochs(Math.max(1, Number(e.target.value) || 1))} /></label>
            <select value={when} onChange={(e) => setWhen(e.target.value as 'now' | 'night')}>
              <option value="now">{t('jetzt', 'now')}</option>
              <option value="night">{t('um …', 'at …')}</option>
            </select>
            {when === 'night' && <input type="time" value={nightTime} onChange={(e) => setNightTime(e.target.value)} />}
            <button className="btn primary" disabled={busy || moreEpochs <= doneEpochs}
              onClick={() => act(() => api.loraRunResume(run.id, { epochs: moreEpochs, start_at: startAt }))}>
              ▶ {run.state
                ? (run.status === 'done' ? t(`Verlängern auf ${moreEpochs} Epochen`, `Extend to ${moreEpochs} epochs`) : t(`Fortsetzen ab Epoche ${doneEpochs}`, `Resume from epoch ${doneEpochs}`))
                : t('Neu starten', 'Start again')}
            </button>
          </>
        )}
      </div>
      {run.note && <p className="hint small">{run.note}</p>}
      {run.error && <p className="error">{run.error}</p>}

      <LossChart loss={(run.loss ?? []) as [number, number][]} stepsPerEpoch={spe} totalSteps={totalSteps} epochs={epochs} marks={ckEpochs} />

      <div className="lr-tabs">
        {([['compare', t('Zwischenstände', 'Checkpoints')], ['quick', t('Schnelltest', 'Quick test')], ['fix', t('Korrigieren', 'Correct')], ['log', t('Protokoll', 'Log')]] as [Tab, string][]).map(([k, label]) => (
          <button key={k} className={`lr-tab${tab === k ? ' on' : ''}`} onClick={() => setTab(k)}>{label}</button>
        ))}
      </div>

      {tab === 'compare' && (
        <div className="lr-pane">
          {run.checkpoints.length === 0 && <p className="muted small">{t('Noch keine Zwischenstände.', 'No checkpoints yet.')}</p>}
          {run.checkpoints.length > 0 && (
            <>
              <p className="hint small">
                {t('Jede Spalte ein Zwischenstand, jede Zeile ein Probe-Prompt mit festem Seed. Den wählen, der die Figur trifft und den neuen Prompt trotzdem umsetzt; bei unseren Somi-LoRAs ab Epoche 15.',
                  'Each column is a checkpoint, each row a test prompt with a fixed seed. Pick the one that matches the character and still follows the new prompt; for our Somi LoRAs from epoch 15 on.')}
              </p>
              <div className="lt-compare" style={{ gridTemplateColumns: `repeat(${columns.length}, minmax(140px, 1fr))` }}>
                {columns.map((c) => (
                  <div key={c.key} className="lt-compare-head">
                    <strong>{c.label}</strong>
                    {c.file && (adopted.has(c.file)
                      ? <span className="lt-status done">{t('übernommen', 'added')}</span>
                      : (
                        <div className="lt-adopt">
                          <input value={names[c.file] ?? ''} placeholder={`${run.name} (${c.label})`} onChange={(e) => setNames({ ...names, [c.file!]: e.target.value })} />
                          <button className="btn small primary" disabled={busy || running}
                            onClick={() => act(async () => {
                              const r = await api.loraRunAdopt(run.id, c.file!, names[c.file!] ?? '')
                              setNotice(t(`„${r.model.name}“ steht jetzt unter den LoRAs für Qwen-Image-2512, mit dem Auslösewort ${run.trigger}.`,
                                `“${r.model.name}” is now among the LoRAs for Qwen-Image-2512, with the trigger word ${run.trigger}.`))
                              onAdopted()
                            })}>{t('Übernehmen', 'Add as LoRA')}</button>
                        </div>
                      ))}
                  </div>
                ))}
                {rows.map((p, r) => columns.map((c) => {
                  const name = images[c.key]?.[r]
                  const url = name ? loraFileUrl('runs', run.id, `test/${name}`) : ''
                  return (
                    <div key={`${c.key}-${r}`} className="lt-compare-cell">
                      {name ? <img src={url} alt={p} loading="lazy" onClick={() => setViewer({ urls: allUrls, labels: allLabels, index: Math.max(0, allUrls.indexOf(url)) })} />
                        : <span className="muted small">–</span>}
                    </div>
                  )
                }))}
              </div>
              <h4>{t('Probebilder rechnen', 'Render test images')}</h4>
              {prompts.map((p, i) => (
                <input key={i} className="lt-prompt" value={p} onChange={(e) => setPrompts(prompts.map((x, j) => (j === i ? e.target.value : x)))} />
              ))}
              {testProgress ? (
                <div className="lt-progress">
                  <div className="progress"><div className="bar" style={{ width: `${Math.round(testProgress.progress * 100)}%` }} /></div>
                  <span className="muted small">{testProgress.stage}</span>
                  <button className="btn small ghost danger-text" onClick={() => onCancel(testProgress.id)}>{t('Abbrechen', 'Cancel')}</button>
                </div>
              ) : (
                <div className="lt-toolbar">
                  <button className="btn small" disabled={busy || running || !st.base.installed}
                    onClick={() => act(async () => onJob(await api.loraRunTest(run.id, prompts.filter((x) => x.trim()))))}>
                    {t(`${testCount} Probebilder rechnen (rund ${fmtDuration(testCount * st.timing.test_seconds_per_image)})`,
                      `Render ${testCount} test images (about ${fmtDuration(testCount * st.timing.test_seconds_per_image)})`)}
                  </button>
                  <button className="btn small ghost" onClick={() => setPrompts([...prompts, ''])} disabled={prompts.length >= 4}>{t('+ Prompt', '+ prompt')}</button>
                  {running && <span className="hint small">{t('Während des Trainings ist die Grafikkarte belegt: pausieren, dann testen.', 'The graphics card is busy while training: pause, then test.')}</span>}
                </div>
              )}
            </>
          )}
        </div>
      )}

      {tab === 'quick' && (
        <div className="lr-pane">
          <p className="hint small">{t('Ein Prompt mit einem Zwischenstand in einer oder mehreren Stärken, gleicher Seed. Rund 100 s je Bild; während des Trainings erst pausieren.',
            'One prompt with one checkpoint at one or more strengths, same seed. About 100 s per image; pause first while training.')}</p>
          <div className="lr-quick-form">
            <select value={qCk} onChange={(e) => setQCk(e.target.value)} disabled={!run.checkpoints.length}>
              {run.checkpoints.map((c) => <option key={c.file} value={c.file}>{t(`Epoche ${c.epoch}`, `epoch ${c.epoch}`)}{c.final ? ` (${t('Ende', 'final')})` : ''}</option>)}
            </select>
            <input className="lr-quick-prompt" value={qPrompt} onChange={(e) => setQPrompt(e.target.value)} placeholder={t('Prompt (Auslösewort und Gattung kommen davor)', 'Prompt (trigger word and class go in front)')} />
            <span className="lr-chips">
              {[0.6, 0.8, 1, 1.2, 1.5].map((v) => (
                <button key={v} className={`btn small${qStrengths.includes(v) ? ' on' : ''}`}
                  onClick={() => setQStrengths((cur) => (cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v].sort((a, b) => a - b).slice(-4)))}>
                  {v.toLocaleString()}</button>
              ))}
            </span>
            <label className="lr-inline">Seed<input type="number" className="lt-num" value={qSeed} onChange={(e) => setQSeed(Number(e.target.value) || 0)} /></label>
            <button className="btn primary" disabled={busy || running || !qCk || !qPrompt.trim() || !qStrengths.length || !st.base.installed}
              onClick={() => act(async () => onJob(await api.loraRunQuick(run.id, { checkpoint: qCk, prompt: qPrompt, strengths: qStrengths, seed: qSeed })))}>
              {t(`${qStrengths.length} Bild${qStrengths.length > 1 ? 'er' : ''} rechnen (rund ${fmtDuration(qStrengths.length * st.timing.test_seconds_per_image)})`,
                `Render ${qStrengths.length} image${qStrengths.length > 1 ? 's' : ''} (about ${fmtDuration(qStrengths.length * st.timing.test_seconds_per_image)})`)}
            </button>
          </div>
          {testProgress && (
            <div className="lt-progress">
              <div className="progress"><div className="bar" style={{ width: `${Math.round(testProgress.progress * 100)}%` }} /></div>
              <span className="muted small">{testProgress.stage}</span>
              <button className="btn small ghost danger-text" onClick={() => onCancel(testProgress.id)}>{t('Abbrechen', 'Cancel')}</button>
            </div>
          )}
          <div className="lr-quick-grid">
            {quick.map((q, i) => (
              <figure key={q.file} className="lr-quick">
                <img src={quickUrls[i]} alt={q.prompt} loading="lazy" title={q.prompt}
                  onClick={() => setViewer({ urls: quickUrls, labels: quick.map((x) => t(`Epoche ${x.epoch} · Stärke ${x.strength.toLocaleString()} · ${x.prompt}`, `epoch ${x.epoch} · strength ${x.strength} · ${x.prompt}`)), index: i })} />
                <figcaption className="muted small">{t(`Epoche ${q.epoch} · Stärke ${q.strength.toLocaleString()}`, `epoch ${q.epoch} · strength ${q.strength}`)} · {fmtTime(q.time)}</figcaption>
              </figure>
            ))}
          </div>
        </div>
      )}

      {tab === 'fix' && (
        <div className="lr-pane lr-fix">
          <div className="lr-fix-box">
            <strong>{t('Datensatz korrigieren', 'Correct the dataset')}</strong>
            <p className="hint small">{t('Bilder aussortieren oder ersetzen, Bildbeschreibungen ändern. Beim Fortsetzen gilt der Datensatz, wie er dann ist: Aussortierte fallen weg, geänderte Beschreibungen werden neu gerechnet, neue Bilder kommen dazu.',
              'Reject or replace images, change captions. On resume the dataset counts as it is then: rejected images drop out, changed captions are encoded again, new images are added.')}</p>
            {run.dataset_id && <button className="btn small" onClick={() => onOpenDataset(run.dataset_id!)}>{t('Datensatz öffnen', 'Open the dataset')}</button>}
          </div>
          <div className="lr-fix-box">
            <strong>{t('Mit anderer Lernrate weiter (ab Zwischenstand)', 'Continue with another learning rate (from a checkpoint)')}</strong>
            <p className="hint small">{t('Ein neues Training beginnt mit den Gewichten des gewählten Zwischenstands und einem frischen Optimierer. Gut, wenn die Figur zu schwach ist (mehr Epochen) oder kippt (kleinere Lernrate). Rang und Alpha bleiben.',
              'A new training starts with the weights of the chosen checkpoint and a fresh optimizer. Good when the character is too weak (more epochs) or tips over (smaller learning rate). Rank and alpha stay.')}</p>
            <div className="lt-toolbar">
              <select value={bCk} onChange={(e) => setBCk(e.target.value)} disabled={!run.checkpoints.length}>
                {run.checkpoints.map((c) => <option key={c.file} value={c.file}>{t(`ab Epoche ${c.epoch}`, `from epoch ${c.epoch}`)}</option>)}
              </select>
              <label className="lr-inline">{t('weitere Epochen', 'more epochs')}<input type="number" className="lt-num" min={1} max={100} value={bEpochs} onChange={(e) => setBEpochs(Math.max(1, Number(e.target.value) || 1))} /></label>
              <label className="lr-inline">{t('Lernrate', 'learning rate')}<input className="lt-num" value={bLr} onChange={(e) => setBLr(e.target.value)} /></label>
              <button className="btn primary" disabled={busy || running || !bCk}
                onClick={() => act(async () => { const r = await api.loraRunBranch(run.id, { checkpoint: bCk, epochs: bEpochs, lr: bLr, start_at: startAt }); onOpenRun(r.id) })}>
                {t('Neues Training starten', 'Start a new training')}
              </button>
            </div>
          </div>
          {run.state && !running && (
            <div className="lr-fix-box">
              <strong>{t('Haltepunkt', 'Resume point')}</strong>
              <p className="hint small">{t(`Der Zustand nach Epoche ${run.state.epoch} belegt ${(run.state.size_mb / 1024).toFixed(1)} GB. Ohne ihn lässt sich das Training nicht mehr fortsetzen oder verlängern; die Zwischenstände bleiben.`,
                `The state after epoch ${run.state.epoch} takes ${(run.state.size_mb / 1024).toFixed(1)} GB. Without it the training can no longer be resumed or extended; the checkpoints stay.`)}</p>
              <button className="btn small ghost danger-text" disabled={busy} onClick={() => act(() => api.loraRunStateDelete(run.id))}>{t('Haltepunkt löschen', 'Delete resume point')}</button>
            </div>
          )}
        </div>
      )}

      {tab === 'log' && (
        <div className="lr-pane">
          <pre className="lr-log">{log.length ? log.join('\n') : t('Noch kein Protokoll.', 'No log yet.')}</pre>
        </div>
      )}

      {notice && <p className="hint">{notice}</p>}
      {error && <p className="error">{error}</p>}
      <div className="lt-toolbar lt-danger">
        {confirmDelete ? (
          <>
            <button className="btn small danger-text" disabled={running} onClick={() => act(async () => { await api.loraRunDelete(run.id); onDeleted() })}>
              {t(`Training mit ${run.checkpoints.length} Zwischenständen löschen (übernommene LoRAs bleiben)`, `Delete training with ${run.checkpoints.length} checkpoints (added LoRAs stay)`)}
            </button>
            <button className="btn small ghost" onClick={() => setConfirmDelete(false)}>{t('Nein', 'No')}</button>
          </>
        ) : (
          <button className="btn small ghost danger-text" disabled={running} onClick={() => setConfirmDelete(true)}>
            {run.status === 'scheduled' ? t('Vormerkung löschen', 'Delete schedule') : t('Training löschen', 'Delete training')}
          </button>
        )}
      </div>
    </div>
  )
}
