import { useCallback, useEffect, useMemo, useState } from 'react'
import { api, KIND_LABEL, type ModelInfo, type ModelKind, type ServerEvent } from '../api'
import type { Downloads } from '../downloads'
import { t } from '../i18n'
import { GpuSettings } from '../components/GpuSettings'
import { ContentBadge } from '../components/ContentBadge'
import { FolderSettings } from '../components/FolderSettings'
import { HfSearch } from './HfSearch'
import { CivitaiSearch } from './CivitaiSearch'
import { HfToken } from './HfToken'

interface Props {
  event: ServerEvent | null
  onChanged: () => void
  downloads: Downloads
}

type Filter = ModelKind | 'all' | 'fav' | 'rec'

const FILTERS: { id: Filter; label: string }[] = [
  { id: 'all', label: t('Alle', 'All') },
  { id: 'rec', label: t('Für deine Karte', 'For your GPU') },
  { id: 'fav', label: t('★ Favoriten', '★ Favorites') },
  { id: 'image', label: t('Bild', 'Image') },
  { id: 'audio', label: 'Audio' },
  { id: 'video', label: 'Video' },
  { id: '3d', label: '3D' },
  { id: 'controlnet', label: 'ControlNet' },
  { id: 'lora', label: 'LoRA' },
]

export function ModelsPanel({ event: _event, onChanged, downloads: dls }: Props) {
  const [models, setModels] = useState<ModelInfo[]>([])
  const [active, setActive] = useState<Record<string, string | null>>({})
  const [filter, setFilter] = useState<Filter>('all')
  const [query, setQuery] = useState('')
  const [hfOpen, setHfOpen] = useState(false)
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const [confirmCleanup, setConfirmCleanup] = useState(false)
  const [busyDownloads, setBusyDownloads] = useState(0)
  const [busyDelete, setBusyDelete] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    const [m, h] = await Promise.all([api.models(), api.health()])
    setModels(m)
    setActive(h.active_models)
    setBusyDownloads((h.current_download ? 1 : 0) + h.download_queue_depth)
  }, [])

  const cancelDownloads = async () => {
    setError(null)
    try {
      const res = await api.cancelDownloads()
      setMessage(
        res.cancelled
          ? t(
              `${res.cancelled} Download(s) abgebrochen. Fertige Teile bleiben zum Fortsetzen liegen.`,
              `${res.cancelled} download(s) cancelled. Finished parts stay so they can resume.`,
            )
          : t('Es lief kein Download.', 'No download was running.'),
      )
      await dls.sync()
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const cleanup = async () => {
    setConfirmCleanup(false)
    setError(null)
    try {
      const res = await api.cleanupPartial()
      const names = res.cleaned.map((c) => c.name).join(', ')
      setMessage(
        res.cleaned.length
          ? t(
              `Aufgeräumt: ${names} — ${res.freed_gb} GB frei`,
              `Cleaned up: ${names} — ${res.freed_gb} GB freed`,
            )
          : t('Keine unvollständigen Installationen gefunden.', 'No incomplete installations found.'),
      )
      await load()
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  useEffect(() => {
    load()
  }, [load])

  // Ein Download ist fertig geworden (egal auf welcher Seite gestartet): Liste neu lesen.
  useEffect(() => {
    if (dls.finished === 0) return
    load()
    onChanged()
  }, [dls.finished, load, onChanged])

  // clean=true bei unvollstaendigem Stand: Reste weg, dann frisch laden.
  // Fortsetzen ist bei kaputten Fragmenten unzuverlaessiger als ein Neustart.
  const download = async (m: ModelInfo, clean = false) => {
    setError(null)
    try {
      await dls.start(m.id, clean)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const remove = async (m: ModelInfo) => {
    setConfirmDelete(null)
    setBusyDelete(m.id)
    setError(null)
    setMessage(null)
    try {
      const res = await api.deleteModel(m.id)
      const parts = []
      if (res.removed.length) {
        parts.push(
          t(
            `${res.removed.length} Datei(en), ${res.freed_gb} GB frei`,
            `${res.removed.length} file(s), ${res.freed_gb} GB freed`,
          ),
        )
      }
      if (res.failed.length) {
        const kept = res.failed.join('; ')
        parts.push(t(`behalten: ${kept}`, `kept: ${kept}`))
      }
      setMessage(`${m.name}: ${parts.join(' · ') || t('nichts zu löschen', 'nothing to delete')}`)
      await load()
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyDelete(null)
    }
  }

  const toggleFav = async (m: ModelInfo) => {
    // Sofort umschalten, damit der Klick nicht nachhängt; bei Fehler zurückdrehen.
    setModels((list) =>
      list.map((x) => (x.id === m.id ? { ...x, favorite: !x.favorite } : x)),
    )
    try {
      await api.toggleFavorite(m.id, !m.favorite)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setModels((list) =>
        list.map((x) => (x.id === m.id ? { ...x, favorite: m.favorite } : x)),
      )
    }
  }

  const activate = async (m: ModelInfo) => {
    setError(null)
    try {
      await api.setActiveModel(m.id)
      await load()
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const toggle = (id: string) =>
    setExpanded((s) => {
      const next = new Set(s)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })

  const shown = useMemo(() => {
    const base =
      filter === 'fav'
        ? models.filter((m) => m.favorite)
        : filter === 'rec'
          ? models.filter((m) => m.recommended)
          : filter === 'all'
            ? models
            : models.filter((m) => m.kind === filter)
    // Jedes Wort muss irgendwo vorkommen: Name, Einsatzzweck, Familie, Lizenz oder Beschreibung.
    const words = query.toLowerCase().split(/\s+/).filter(Boolean)
    const hits = words.length
      ? base.filter((m) => {
          const text = [m.name, m.id, m.best_for, m.family, m.license, m.description]
            .join(' ')
            .toLowerCase()
          return words.every((w) => text.includes(w))
        })
      : base
    // Favoriten oben -- der Zweck der Markierung ist schnelles Wiederfinden --, dann
    // die Empfehlungen für die erkannte Karte.
    return [...hits].sort(
      (a, b) =>
        Number(b.favorite) - Number(a.favorite) || Number(b.recommended) - Number(a.recommended),
    )
  }, [models, filter, query])

  const favCount = useMemo(() => models.filter((m) => m.favorite).length, [models])

  const totalDisk = useMemo(
    () => models.filter((m) => m.installed).reduce((s, m) => s + m.disk_gb, 0),
    [models],
  )
  const hasPartial = useMemo(() => models.some((m) => m.partially_installed), [models])

  return (
    <div className="models">
      <FolderSettings />
      <GpuSettings />
      <div className="model-toolbar">
        <div className="filters">
          {FILTERS.map((f) => (
            <button
              key={f.id}
              className={filter === f.id ? 'tab active' : 'tab'}
              onClick={() => setFilter(f.id)}
            >
              {f.label}
              <span className="count">
                {f.id === 'all'
                  ? models.length
                  : f.id === 'fav'
                    ? favCount
                    : f.id === 'rec'
                      ? models.filter((m) => m.recommended).length
                      : models.filter((m) => m.kind === f.id).length}
              </span>
            </button>
          ))}
        </div>
        <div className="toolbar-actions">
          <input
            className="model-search"
            type="search"
            placeholder={t('Modelle durchsuchen …', 'Search models …')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <button
            className={hfOpen ? 'btn small' : 'btn small ghost'}
            onClick={() => setHfOpen((o) => !o)}
          >
            {hfOpen
              ? t('Suche schließen', 'Close search')
              : t('Modelle und LoRAs suchen', 'Search models and LoRAs')}
          </button>
          {busyDownloads > 0 && (
            <button className="btn small ghost danger-text" onClick={cancelDownloads}>
              {t(
                `${busyDownloads} Download${busyDownloads > 1 ? 's' : ''} abbrechen`,
                `Cancel ${busyDownloads} download${busyDownloads > 1 ? 's' : ''}`,
              )}
            </button>
          )}
          {hasPartial &&
            (confirmCleanup ? (
              <span className="confirm">
                <span className="muted small">
                  {t('Unfertige Daten löschen?', 'Delete incomplete data?')}
                </span>
                <button className="btn small danger" onClick={cleanup}>
                  {t('Ja', 'Yes')}
                </button>
                <button className="btn small ghost" onClick={() => setConfirmCleanup(false)}>
                  {t('Nein', 'No')}
                </button>
              </span>
            ) : (
              <button
                className="btn small ghost"
                title={t(
                  'Löscht unvollständige Installationen und Download-Fragmente',
                  'Deletes incomplete installations and download fragments',
                )}
                onClick={() => setConfirmCleanup(true)}
              >
                {t('Unfertiges aufräumen', 'Clean up incomplete')}
              </button>
            ))}
          <span className="muted small">
            {t(`${totalDisk.toFixed(1)} GB belegt`, `${totalDisk.toFixed(1)} GB used`)}
          </span>
        </div>
      </div>

      {error && <div className="error">{error}</div>}
      {message && <div className="notice">{message}</div>}

      {/* key: beim Wechsel auf den LoRA-Filter neu aufgeklappt */}
      <details className="lora-intro" open={filter === 'lora'} key={filter === 'lora' ? 'open' : 'closed'}>
        <summary>{t('Wozu sind LoRAs gut?', 'What are LoRAs for?')}</summary>
        <p>
          {t(
            'Eine LoRA ist ein kleiner Zusatz (meist 50 MB bis 1 GB) zu einem großen Modell. Sie bringt ihm '
              + 'eine Sache bei, die es allein nicht so gut kann: einen Stil (Pixel-Art, Film-Look), mehr '
              + 'Realismus (Hautstruktur, natürliches Licht), eine Kamerafahrt im Video oder eine bestimmte '
              + 'Figur. Das Modell selbst bleibt unverändert, die LoRA wird nur beim Generieren dazugeschaltet.',
            'A LoRA is a small add-on (usually 50 MB to 1 GB) for a large model. It teaches the model one '
              + 'thing it cannot do as well on its own: a style (pixel art, film look), more realism (skin '
              + 'texture, natural light), a camera move in a video or a specific character. The model itself '
              + 'stays unchanged; the LoRA is only switched on while generating.',
          )}
        </p>
        <p>
          {t(
            'So geht es: Über „Modelle und LoRAs suchen“ eine LoRA laden, NV-AI prüft vorher, zu welchem '
              + 'Modell sie passt. Beim Generieren erscheint sie unter dem gewählten Modell: anhaken, Stärke '
              + 'meist 0,6 bis 1,0, und die Trigger-Wörter in den Prompt. Eine LoRA kostet etwas Rechenzeit. '
              + 'Ob Ergebnisse verkauft werden dürfen, steht bei jeder LoRA unter Lizenz.',
            'How to use: load a LoRA via “Search models and LoRAs”; NV-AI checks first which model it fits. '
              + 'When generating it appears below the selected model: tick it, strength usually 0.6 to 1.0, '
              + 'and put the trigger words into the prompt. A LoRA costs some extra time. Whether results '
              + 'may be sold is shown under license for each LoRA.',
          )}
        </p>
      </details>

      <HfToken />

      {hfOpen && (
        <HfSearch
          catalog={models}
          onShowModel={(id) => {
            setFilter('all')
            setQuery('')
            setExpanded((s) => new Set(s).add(id))
            setTimeout(() => document.getElementById(`model-${id}`)?.scrollIntoView({ behavior: 'smooth' }), 50)
          }}
          onQueued={(text) => {
            setMessage(text)
            load()
          }}
        />
      )}
      {hfOpen && (
        <CivitaiSearch
          catalog={models}
          onQueued={(text) => {
            setMessage(text)
            load()
          }}
        />
      )}

      {shown.map((m) => {
        const dl = dls.active[m.id]
        const isActive = active[m.kind] === m.id
        const open = expanded.has(m.id)
        return (
          <article
            key={m.id}
            id={`model-${m.id}`}
            className={`panel model${m.installed ? ' installed' : ''}${m.favorite ? ' fav' : ''}`}
          >
            <button
              className={m.favorite ? 'fav-star on' : 'fav-star'}
              title={
                m.favorite
                  ? t('Favorit entfernen', 'Remove favorite')
                  : t('Als Favorit markieren', 'Mark as favorite')
              }
              onClick={() => toggleFav(m)}
            >
              {m.favorite ? '★' : '☆'}
            </button>
            <div className="model-head">
              <div className="model-title">
                <h3>
                  {m.warning && (
                    <span className="warn-mark" title={m.warning}>
                      !
                    </span>
                  )}
                  {m.name}
                  <span className="badge kind">{KIND_LABEL[m.kind]}</span>
                  <ContentBadge model={m} />
                  {isActive && <span className="badge done">{t('aktiv', 'active')}</span>}
                  {m.recommended && (
                    <span
                      className="badge rec"
                      title={t(
                        'Für die erkannte Grafikkarte empfohlen',
                        'Recommended for the detected graphics card',
                      )}
                    >
                      {t('empfohlen', 'recommended')}
                    </span>
                  )}
                  {m.partially_installed && (
                    <span className="badge running">{t('unvollständig', 'incomplete')}</span>
                  )}
                  {m.fits_vram === 'knapp' && (
                    <span
                      className="badge warn"
                      title={t(
                        'Läuft, aber ohne Reserve — vorher VRAM leeren',
                        'Runs, but without headroom — free VRAM first',
                      )}
                    >
                      {t('knapp für diese Karte', 'tight for this GPU')}
                    </span>
                  )}
                  {m.fits_vram === 'nein' && (
                    <span
                      className="badge error"
                      title={t(
                        'Passt nicht in den Videospeicher. Läuft nur mit ständigem Nachladen und ist dadurch um ein Vielfaches langsamer.',
                        'Does not fit into video memory. Runs only with constant offloading and is therefore many times slower.',
                      )}
                    >
                      {t('zu groß für diese Karte', 'too large for this GPU')}
                    </span>
                  )}
                  {!m.workflow && <span className="badge">{t('kein Workflow', 'no workflow')}</span>}
                </h3>
                <p className="best-for">{m.best_for}</p>
                {m.kind === 'lora' && m.trigger && (
                  <p className="muted small">{t('Trigger', 'Trigger')}: <code>{m.trigger}</code></p>
                )}
                {m.gpu_note && <p className="warn-text small">{m.gpu_note}</p>}
                <p className="muted small">
                  {t(
                    `${m.size_gb} GB Download · ~${m.vram_gb} GB VRAM · ${m.files.length} Datei`
                      + (m.files.length > 1 ? 'en' : ''),
                    `${m.size_gb} GB download · ~${m.vram_gb} GB VRAM · ${m.files.length} `
                      + (m.files.length === 1 ? 'file' : 'files'),
                  )} ·{' '}
                  <span className={m.commercial_ok ? 'ok-text' : 'warn-text'}>
                    {m.license}
                    {m.commercial_ok ? '' : t(' · nicht kommerziell', ' · non-commercial')}
                  </span>
                </p>
              </div>

              <div className="model-actions">
                {dl ? (
                  <div className="dl">
                    <div className="progress">
                      <div className="bar" style={{ width: `${Math.round(dl.progress * 100)}%` }} />
                    </div>
                    <span className="muted small">
                      {dl.status === 'queued'
                        ? t('wartet auf den laufenden Download', 'waiting for the running download')
                        : `${Math.round(dl.progress * 100)} % · ${dl.stage}`}
                    </span>
                    <button
                      className="btn small ghost danger-text"
                      onClick={() => dls.cancel(m.id)}
                      title={t('Fertige Teile bleiben liegen; ein neuer Download setzt dort fort.',
                        'Finished parts stay; a new download resumes from there.')}
                    >
                      {t('Abbrechen', 'Cancel')}
                    </button>
                  </div>
                ) : m.installed ? (
                  <>
                    {!isActive && m.runnable && (
                      <button className="btn small" onClick={() => activate(m)}>
                        {t('Aktivieren', 'Activate')}
                      </button>
                    )}
                    {confirmDelete === m.id ? (
                      <span className="confirm">
                        <span className="muted small">
                          {t(`${m.disk_gb} GB löschen?`, `Delete ${m.disk_gb} GB?`)}
                        </span>
                        <button className="btn small danger" onClick={() => remove(m)}>
                          {t('Ja', 'Yes')}
                        </button>
                        <button className="btn small ghost" onClick={() => setConfirmDelete(null)}>
                          {t('Nein', 'No')}
                        </button>
                      </span>
                    ) : (
                      <button
                        className="btn small ghost danger-text"
                        onClick={() => setConfirmDelete(m.id)}
                        disabled={busyDelete === m.id}
                      >
                        {busyDelete === m.id ? t('löscht…', 'deleting…') : t('Löschen', 'Delete')}
                      </button>
                    )}
                  </>
                ) : m.partially_installed ? (
                  <button
                    className="btn small primary"
                    title={t(
                      'Unvollständigen Stand löschen und komplett neu laden',
                      'Delete the incomplete download and download everything again',
                    )}
                    onClick={() => download(m, true)}
                  >
                    {t('Neu laden', 'Download again')}
                  </button>
                ) : (
                  <button className="btn small primary" onClick={() => download(m)}>
                    {t('Herunterladen', 'Download')}
                  </button>
                )}
                <button className="btn small ghost" onClick={() => toggle(m.id)}>
                  {open ? t('Weniger', 'Less') : 'Details'}
                </button>
              </div>
            </div>

            {open && (
              <div className="model-detail">
                {m.warning && <p className="warn-banner">{m.warning}</p>}
                <p className="description">{m.description}</p>
                <div className="proscons">
                  <div>
                    <h4 className="pro">{t('Spricht dafür', 'Pros')}</h4>
                    <ul>
                      {m.pros.map((p) => (
                        <li key={p}>{p}</li>
                      ))}
                    </ul>
                  </div>
                  <div>
                    <h4 className="con">{t('Spricht dagegen', 'Cons')}</h4>
                    <ul>
                      {m.cons.map((c) => (
                        <li key={c}>{c}</li>
                      ))}
                    </ul>
                  </div>
                </div>
                <details className="files">
                  <summary className="muted small">
                    {t(`Dateien (${m.files.length})`, `Files (${m.files.length})`)}
                  </summary>
                  <ul>
                    {m.files.map((f) => (
                      <li key={f.file} className="small">
                        <span className={f.installed ? 'ok-text' : 'muted'}>
                          {f.installed ? '✓' : '○'}
                        </span>{' '}
                        <code>{f.repo}</code> → {f.target}/{f.file.split('/').pop()}
                        {f.size_gb ? ` (${f.size_gb} GB)` : ''}
                      </li>
                    ))}
                  </ul>
                </details>
              </div>
            )}
          </article>
        )
      })}
    </div>
  )
}
