import { useCallback, useEffect, useMemo, useState } from 'react'
import { api, type Asset, type Job, type ServerEvent } from '../api'
import { AssetView } from '../components/AssetView'
import { locale, t } from '../i18n'

interface Props {
  event: ServerEvent | null
}

const KIND_FILTERS = [
  { id: 'all', label: t('Alle', 'All') },
  { id: 'image', label: t('Bild', 'Image') },
  { id: 'audio', label: 'Audio' },
  { id: 'video', label: 'Video' },
  { id: 'mesh', label: '3D' },
]

export function HistoryPanel({ event }: Props) {
  const [jobs, setJobs] = useState<Job[]>([])
  const [assets, setAssets] = useState<Record<string, Asset[]>>({})
  const [selected, setSelected] = useState<Asset | null>(null)
  const [filter, setFilter] = useState('all')
  const [confirmJob, setConfirmJob] = useState<string | null>(null)
  const [confirmClear, setConfirmClear] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  // Aufgeklappte Prompts (Job-IDs): lange Video-Prompts passen nicht in eine Zeile.
  const [openPrompts, setOpenPrompts] = useState<Set<string>>(() => new Set())
  const togglePrompt = (id: string) => {
    // Beim Markieren von Text nicht zuklappen.
    if (window.getSelection()?.toString()) return
    setOpenPrompts((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const load = useCallback(async () => {
    const js = (await api.jobs(80)).filter((j) => j.kind !== 'download')
    setJobs(js)
    const done = js.filter((j) => j.status === 'done' && j.asset_ids.length)
    const pairs = await Promise.all(
      done.map(async (j) => [j.id, await api.jobAssets(j.id)] as const),
    )
    setAssets(Object.fromEntries(pairs))
  }, [])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (event && (event.type === 'job.done' || event.type === 'job.error')) load()
  }, [event, load])

  const removeJob = async (job: Job) => {
    setConfirmJob(null)
    setBusy(true)
    setError(null)
    try {
      const res = await api.deleteJob(job.id)
      setMessage(
        t(
          `Eintrag gelöscht — ${res.assets} Datei(en), ${res.freed_mb} MB frei`,
          `Entry deleted — ${res.assets} file(s), ${res.freed_mb} MB freed`,
        ),
      )
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const removeAsset = async (asset: Asset) => {
    setBusy(true)
    setError(null)
    try {
      const res = await api.deleteAsset(asset.id)
      setMessage(
        t(`Datei gelöscht — ${res.freed_mb} MB frei`, `File deleted — ${res.freed_mb} MB freed`),
      )
      setSelected(null)
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const clearAll = async () => {
    setConfirmClear(false)
    setBusy(true)
    setError(null)
    try {
      const res = await api.clearHistory(filter === 'all' ? undefined : filter)
      setMessage(
        t(
          `Verlauf geleert — ${res.jobs} Einträge, ${res.assets} Dateien, ${res.freed_mb} MB frei`,
          `History cleared — ${res.jobs} entries, ${res.assets} files, ${res.freed_mb} MB freed`,
        ),
      )
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const shown = useMemo(() => {
    if (filter === 'all') return jobs
    return jobs.filter((j) =>
      (assets[j.id] ?? []).some((a) => {
        if (a.kind !== filter) return false
        // Das Freistell-Bild eines 3D-Jobs soll den Bild-Filter nicht füllen.
        if (filter === 'image' && a.meta?.cutout_for) return false
        return true
      }),
    )
  }, [jobs, assets, filter])

  return (
    <div className="history">
      <div className="model-toolbar">
        <div className="filters">
          {KIND_FILTERS.map((f) => (
            <button
              key={f.id}
              className={filter === f.id ? 'tab active' : 'tab'}
              onClick={() => setFilter(f.id)}
            >
              {f.label}
            </button>
          ))}
        </div>

        {jobs.length > 0 &&
          (confirmClear ? (
            <span className="confirm">
              <span className="muted small">
                {filter === 'all'
                  ? t(
                      `Alle ${jobs.length} Einträge samt Dateien löschen?`,
                      `Delete all ${jobs.length} entries including their files?`,
                    )
                  : t(
                      `Alle ${shown.length} ${filter}-Einträge löschen?`,
                      `Delete all ${shown.length} ${filter} entries?`,
                    )}
              </span>
              <button className="btn small danger" onClick={clearAll} disabled={busy}>
                {t('Ja, löschen', 'Yes, delete')}
              </button>
              <button className="btn small ghost" onClick={() => setConfirmClear(false)}>
                {t('Abbrechen', 'Cancel')}
              </button>
            </span>
          ) : (
            <button
              className="btn small ghost danger-text"
              onClick={() => setConfirmClear(true)}
              disabled={busy || shown.length === 0}
            >
              {filter === 'all'
                ? t('Verlauf leeren', 'Clear history')
                : t(`${filter} leeren`, `Clear ${filter} entries`)}
            </button>
          ))}
      </div>

      {error && <div className="error">{error}</div>}
      {message && <div className="notice">{message}</div>}

      {!jobs.length && (
        <div className="placeholder">{t('Noch nichts generiert.', 'Nothing generated yet.')}</div>
      )}

      {shown.map((job) => {
        const list = assets[job.id] ?? []
        // Bild→3D-Jobs haben keinen eigenen Prompt; sie erben den des Quellbilds.
        const prompt =
          String(job.params.prompt ?? '') ||
          list.find((a) => a.prompt && !a.prompt.startsWith('Freistellung'))?.prompt ||
          (job.kind === 'img23d' ? t('Bild → 3D', 'Image → 3D') : '')
        return (
          <article key={job.id} className="panel run">
            <header className="run-head">
              <span className={`badge ${job.status}`}>{job.status}</span>
              {prompt ? (
                <span
                  className={openPrompts.has(job.id) ? 'prompt open' : 'prompt'}
                  role="button"
                  tabIndex={0}
                  aria-expanded={openPrompts.has(job.id)}
                  title={openPrompts.has(job.id)
                    ? t('Klicken zum Zuklappen', 'Click to collapse')
                    : t('Klicken für den ganzen Prompt', 'Click for the whole prompt')}
                  onClick={() => togglePrompt(job.id)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault()
                      togglePrompt(job.id)
                    }
                  }}
                >
                  {prompt}
                </span>
              ) : (
                <span className="prompt"><em>{t('ohne Prompt', 'no prompt')}</em></span>
              )}
              <span className="muted small">
                {new Date(job.created_at * 1000).toLocaleString(locale())}
              </span>
              {confirmJob === job.id ? (
                <span className="confirm">
                  <button className="btn small danger" onClick={() => removeJob(job)} disabled={busy}>
                    {t('Löschen', 'Delete')}
                  </button>
                  <button className="btn small ghost" onClick={() => setConfirmJob(null)}>
                    {t('Abbrechen', 'Cancel')}
                  </button>
                </span>
              ) : (
                <button
                  className="icon-btn"
                  title={t('Diesen Eintrag samt Dateien löschen', 'Delete this entry including its files')}
                  onClick={() => setConfirmJob(job.id)}
                  disabled={busy}
                >
                  ×
                </button>
              )}
            </header>

            {job.error && <div className="error">{job.error}</div>}

            {/* Jedes Asset nach seinem eigenen Typ darstellen. Ein Job kann
                gemischt sein: Bild→3D liefert das freigestellte Quellbild UND
                das Mesh. Über den Typ des ersten Assets zu entscheiden, würde
                das Mesh als <img> rendern. */}
            {list.length > 0 && (
              <div className="asset-mix">
                {list.map((a) =>
                  a.kind === 'image' || a.kind === 'upload' ? (
                    <button
                      key={a.id}
                      className="card as-button"
                      onClick={() => setSelected(a)}
                      title={a.prompt}
                    >
                      <img src={a.url} alt="" loading="lazy" />
                    </button>
                  ) : (
                    <div key={a.id} className="card result wide">
                      <AssetView asset={a} compact />
                      <div className="muted small pad row-between">
                        <span>
                          {a.model_id}
                          {a.meta.seed != null && ` · seed ${a.meta.seed}`} ·{' '}
                          <a href={a.url} download>
                            Download
                          </a>
                        </span>
                        <button
                          className="icon-btn"
                          title={t('Nur diese Datei löschen', 'Delete only this file')}
                          onClick={() => removeAsset(a)}
                          disabled={busy}
                        >
                          ×
                        </button>
                      </div>
                    </div>
                  ),
                )}
              </div>
            )}
          </article>
        )
      })}

      {selected && (
        <div className="lightbox" onClick={() => setSelected(null)}>
          <img src={selected.url} alt={selected.prompt} />
          <div className="lightbox-meta" onClick={(e) => e.stopPropagation()}>
            <p>{selected.prompt}</p>
            <p className="muted small">
              {selected.model_id} · seed {String(selected.meta.seed ?? '?')} · {selected.filename}
            </p>
            <div className="lightbox-actions">
              <a className="btn small" href={selected.url} download>
                {t('Herunterladen', 'Download')}
              </a>
              <button
                className="btn small ghost danger-text"
                onClick={() => removeAsset(selected)}
                disabled={busy}
              >
                {t('Löschen', 'Delete')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
