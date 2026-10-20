import { useCallback, useEffect, useState } from 'react'
import { api, connectEvents, type Health, type ServerEvent } from './api'
import { useDownloads } from './downloads'
import { getLang, setLang, t, type Lang } from './i18n'
import { GeneratePanel } from './panels/Generate'
import { HistoryPanel } from './panels/History'
import { ModelsPanel } from './panels/Models'

type Tab = 'generate' | 'history' | 'models'

const TABS: { id: Tab; label: string }[] = [
  { id: 'generate', label: t('Generieren', 'Generate') },
  { id: 'history', label: t('Verlauf', 'History') },
  { id: 'models', label: t('Modelle', 'Models') },
]

// Sprachnamen stehen in ihrer eigenen Sprache, damit man sie in jeder Einstellung findet.
const LANGS: { id: Lang; label: string; name: string }[] = [
  { id: 'en', label: 'EN', name: 'English' },
  { id: 'de', label: 'DE', name: 'Deutsch' },
]

export function App() {
  const [tab, setTab] = useState<Tab>('generate')
  const [health, setHealth] = useState<Health | null>(null)
  const [events, setEvents] = useState<ServerEvent | null>(null)
  const [starting, setStarting] = useState(false)
  const [stopping, setStopping] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const downloads = useDownloads(events, setNotice)
  const dlList = Object.entries(downloads.active)

  const refreshHealth = useCallback(() => {
    api.health().then(setHealth).catch(() => setHealth(null))
  }, [])

  useEffect(() => {
    refreshHealth()
    const timer = setInterval(refreshHealth, 5000)
    return () => clearInterval(timer)
  }, [refreshHealth])

  // Ein WS-Abo fuer die ganze App; die Panels bekommen das letzte Event durchgereicht.
  useEffect(() => {
    return connectEvents((e) => {
      if (e.type !== 'ping') setEvents(e)
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

  const usedGb = health?.gpu
    ? (health.gpu.vram_total_mb - health.gpu.vram_free_mb) / 1024
    : 0
  const totalGb = health?.gpu ? health.gpu.vram_total_mb / 1024 : 0
  const vram = health?.gpu ? `${usedGb.toFixed(1)} / ${totalGb.toFixed(0)} GB` : '–'
  const vramPct = totalGb > 0 ? Math.min(100, (usedGb / totalGb) * 100) : 0
  const loaded = health?.vram_loaded ?? []
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
        <div className="brand">
          NV<span>-AI</span>
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
          <span className="vram" title={`${health?.gpu?.name ?? 'GPU'} · ${vram}`}>
            <span className="vram-bar">
              <span
                className={vramPct > 85 ? 'vram-fill high' : 'vram-fill'}
                style={{ width: `${vramPct}%` }}
              />
            </span>
            <span className="muted small">{vram}</span>
          </span>

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
              <button
                key={id}
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
            )
          })}
        </div>
      )}

      <main className="content">
        {tab === 'generate' && (
          <GeneratePanel health={health} event={events} downloads={downloads} onShowModels={() => setTab('models')} />
        )}
        {tab === 'history' && <HistoryPanel event={events} />}
        {tab === 'models' && <ModelsPanel event={events} onChanged={refreshHealth} downloads={downloads} />}
      </main>
    </div>
  )
}
