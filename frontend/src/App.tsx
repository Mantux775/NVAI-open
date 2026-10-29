import { useCallback, useEffect, useState } from 'react'
import { api, connectEvents, type Health, type ServerEvent, type StudioChangedEvent } from './api'
import { GpuChip } from './components/GpuChip'
import { ReportDialog } from './components/ReportDialog'
import { useDownloads } from './downloads'
import { getLang, setLang, t, type Lang } from './i18n'
import { GeneratePanel } from './panels/Generate'
import { HistoryPanel } from './panels/History'
import { ModelsPanel } from './panels/Models'
import { StudioPanel } from './panels/Studio'
import { VhsPanel } from './panels/Vhs'

type Tab = 'generate' | 'studio' | 'vhs' | 'history' | 'models'

// Studio vorn und beim Start offen (Nutzer 27.10.2026: „die App soll zukünftig mit Studio in der ersten Position und
// gleich offen starten, danach folgen Generate, History und Models“); VHS seit 28.10. als eigener Reiter (Nutzer:
// „Eigener Reiter VHS“), ganz hinten hinter den Modellen (Nutzer 28.10. abends: „schiebe VHS Abschnitt ganz nach hinten“)
const TABS: { id: Tab; label: string }[] = [
  { id: 'studio', label: t('Studio', 'Studio') },
  { id: 'generate', label: t('Generieren', 'Generate') },
  { id: 'history', label: t('Verlauf', 'History') },
  { id: 'models', label: t('Modelle', 'Models') },
  { id: 'vhs', label: t('VHS', 'VHS') },
]

// Sprachnamen stehen in ihrer eigenen Sprache, damit man sie in jeder Einstellung findet.
const LANGS: { id: Lang; label: string; name: string }[] = [
  { id: 'en', label: 'EN', name: 'English' },
  { id: 'de', label: 'DE', name: 'Deutsch' },
]

export function App() {
  const [tab, setTab] = useState<Tab>('studio')
  const [health, setHealth] = useState<Health | null>(null)
  const [events, setEvents] = useState<ServerEvent | null>(null)
  // Eigener Platz: Studio speichert oft, das darf ein job.done im gemeinsamen Platz nicht verdrängen
  const [studioEvent, setStudioEvent] = useState<StudioChangedEvent | null>(null)
  // Material gelöscht oder hochgeladen: zählt hoch, das Studio lädt seine Medienleiste neu
  const [assetsVersion, setAssetsVersion] = useState(0)
  const [starting, setStarting] = useState(false)
  const [stopping, setStopping] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [reporting, setReporting] = useState(false)
  const [versions, setVersions] = useState<{ version: string; comfyui: string | null } | null>(null)
  const downloads = useDownloads(events, setNotice)
  const dlList = Object.entries(downloads.active)

  const refreshHealth = useCallback(() => {
    api.health().then(setHealth).catch(() => setHealth(null))
  }, [])

  // Versionen neben dem Logo: einmal beim Laden, sie ändern sich nur mit einem Update.
  useEffect(() => {
    api.version().then(setVersions).catch(() => setVersions(null))
  }, [])

  useEffect(() => {
    refreshHealth()
    const timer = setInterval(refreshHealth, 5000)
    return () => clearInterval(timer)
  }, [refreshHealth])

  // Ein WS-Abo fuer die ganze App; die Panels bekommen das letzte Event durchgereicht.
  useEffect(() => {
    return connectEvents((e) => {
      if (e.type === 'studio.changed') setStudioEvent(e)
      else if (e.type === 'assets.changed') setAssetsVersion((v) => v + 1)
      else if (e.type !== 'ping') setEvents(e)
    })
  }, [])

  const startBackend = async () => {
    setStarting(true)
    try {
      await api.startBackend()
    } finally {
      setStarting(false)
      refreshHealth()
    }
  }

  // Ohne Angabe (AMD bei ausgeschaltetem Backend) nicht „voll“ anzeigen
  const freeMb = health?.gpu?.vram_free_mb
  const usedGb = health?.gpu && freeMb != null
    ? (health.gpu.vram_total_mb - freeMb) / 1024
    : 0
  const totalGb = health?.gpu ? health.gpu.vram_total_mb / 1024 : 0
  const vram = health?.gpu ? `${freeMb != null ? usedGb.toFixed(1) : '–'} / ${totalGb.toFixed(0)} GB` : '–'
  const vramPct = totalGb > 0 ? Math.min(100, (usedGb / totalGb) * 100) : 0
  const multiGpu = (health?.gpus?.length ?? 0) > 1
  const loaded = [
    ...(health?.vram_loaded ?? []),
    // Eigenes ComfyUI für Sprachmodelle (mehrere Karten): was dort geladen ist.
    ...(health?.text_backend?.running && health.text_backend.loaded
      ? [{ backend: 'ComfyUI (Text)', model: health.text_backend.loaded }] : []),
  ]
  const busy = !!health?.current_job

  const stopJob = async () => {
    setStopping(true)
    try {
      const res = await api.cancelCurrentJob()
      if (!res.ok && res.reason) setNotice(res.reason)
      else if (res.stopped?.length) {
        const list = res.stopped.join(', ')
        setNotice(t(`Gestoppt: ${list}`, `Stopped: ${list}`))
      }
    } catch (e) {
      setNotice(e instanceof Error ? e.message : String(e))
    } finally {
      setStopping(false)
      refreshHealth()
    }
  }

  const freeVram = async () => {
    setStopping(true)
    try {
      const res = await api.freeVram()
      const list = res.freed.join(', ')
      setNotice(t(`VRAM freigegeben: ${list}`, `VRAM freed: ${list}`))
    } finally {
      setStopping(false)
      refreshHealth()
    }
  }

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand" title="NVAI-open">
          NV<span>AI</span>
          {versions && (
            <span className="brand-version" title={t('Versionen von NVAI-open und ComfyUI', 'Versions of NVAI-open and ComfyUI')}>
              {versions.version}
              {versions.comfyui && <><br />ComfyUI {versions.comfyui}</>}
            </span>
          )}
        </div>

        <nav className="tabs">
          {TABS.map((tb) => (
            <button
              key={tb.id}
              className={tab === tb.id ? 'tab active' : 'tab'}
              onClick={() => setTab(tb.id)}
            >
              {tb.label}
            </button>
          ))}
        </nav>

        <div className="status">
          <span className={health?.comfy_running ? 'dot ok' : 'dot off'} />

          {/* Was liegt im VRAM? Wichtiger als der GPU-Name, deshalb zuerst. */}
          {multiGpu ? (
            // Mehrere Karten (experimentell): je Karte ein Balken und ihre Aufgaben; ein Klick
            // wählt, was die Karte macht.
            health!.gpus!.map((g) => (
              <GpuChip key={g.index} gpu={g} onChanged={refreshHealth} onError={setNotice} />
            ))
          ) : (
            <span className="vram" title={`${health?.gpu?.name ?? 'GPU'} · ${vram}`}>
              <span className="vram-bar">
                <span
                  className={vramPct > 85 ? 'vram-fill high' : 'vram-fill'}
                  style={{ width: `${vramPct}%` }}
                />
              </span>
              <span className="muted small">{vram}</span>
            </span>
          )}

          <span className="loaded">
            {loaded.length === 0 ? (
              <span className="muted small">{t('VRAM leer', 'VRAM empty')}</span>
            ) : (
              loaded.map((l) => (
                <span
                  key={l.backend}
                  className="badge ok"
                  title={t(`geladen in ${l.backend}`, `loaded in ${l.backend}`)}
                >
                  {l.model}
                </span>
              ))
            )}
          </span>

          {busy && (
            <button
              className="btn small danger"
              onClick={stopJob}
              disabled={stopping}
              title={t('Laufende Generierung abbrechen', 'Cancel the running generation')}
            >
              {stopping ? '…' : t('■ Stopp', '■ Stop')}
            </button>
          )}

          {health && !health.comfy_running && (
            <button className="btn small" onClick={startBackend} disabled={starting}>
              {starting ? t('startet…', 'starting…') : t('Backend starten', 'Start backend')}
            </button>
          )}
          {loaded.length > 0 && !busy && (
            <button className="btn small ghost" onClick={freeVram} disabled={stopping}>
              {t('VRAM leeren', 'Free VRAM')}
            </button>
          )}
        </div>

        <button
          className="btn small ghost report-btn"
          onClick={() => setReporting(true)}
          title={t('Anonymisierten Fehlerbericht erstellen und auf GitHub melden',
            'Create an anonymized problem report and send it to GitHub')}
        >
          {t('Problem melden', 'Report a problem')}
        </button>

        {/* Sprachwahl: speichert und laedt neu (i18n.setLang). */}
        <div className="lang-switch" role="group" aria-label={t('Sprache', 'Language')}>
          {LANGS.map((l) => (
            <button
              key={l.id}
              lang={l.id}
              className={getLang() === l.id ? 'tab active' : 'tab'}
              aria-pressed={getLang() === l.id}
              title={l.name}
              onClick={() => {
                if (getLang() !== l.id) setLang(l.id)
              }}
            >
              {l.label}
            </button>
          ))}
        </div>
      </header>

      {reporting && <ReportDialog onClose={() => setReporting(false)} />}

      {notice && (
        <div
          className="topnotice"
          onClick={() => setNotice(null)}
          title={t('klicken zum Schließen', 'click to close')}
        >
          {notice}
        </div>
      )}

      {/* Downloads auf jeder Seite: Name, Balken, Prozent, was gerade geladen wird. */}
      {dlList.length > 0 && (
        <div className="dlbar" role="status" aria-live="polite">
          {dlList.map(([id, d]) => {
            const pct = Math.round(d.progress * 100)
            return (
              <span key={id} className="dl-row">
                <button
                  className="dl-item"
                  onClick={() => setTab('models')}
                  title={t('Zur Modellverwaltung', 'Go to model management')}
                >
                  <span className="dl-icon">⬇</span>
                  <span className="dl-name">{d.name}</span>
                  <span className="dl-track">
                    <span className="dl-fill" style={{ width: `${d.status === 'queued' ? 0 : pct}%` }} />
                  </span>
                  <span className="dl-pct">{d.status === 'queued' ? t('wartet', 'queued') : `${pct} %`}</span>
                  {d.stage && d.status === 'running' && <span className="dl-stage muted small">{d.stage}</span>}
                </button>
                <button
                  className="dl-cancel"
                  onClick={() => downloads.cancel(id)}
                  title={t('Download abbrechen (fertige Teile bleiben zum Fortsetzen)',
                    'Cancel download (finished parts stay to resume)')}
                  aria-label={t(`${d.name}: Download abbrechen`, `${d.name}: cancel download`)}
                >
                  ✕
                </button>
              </span>
            )
          })}
        </div>
      )}

      <main className={tab === 'studio' ? 'content studio-mode' : 'content'}>
        {tab === 'generate' && (
          <GeneratePanel health={health} event={events} downloads={downloads} onShowModels={() => setTab('models')} />
        )}
        {tab === 'vhs' && <VhsPanel event={events} downloads={downloads} onShowModels={() => setTab('models')} />}
        {tab === 'history' && <HistoryPanel event={events} />}
        {tab === 'models' && <ModelsPanel event={events} onChanged={refreshHealth} downloads={downloads} />}
        {tab === 'studio' && <StudioPanel event={events} studioEvent={studioEvent} assetsVersion={assetsVersion} />}
      </main>
    </div>
  )
}
