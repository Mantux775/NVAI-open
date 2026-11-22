import { useCallback, useEffect, useState } from 'react'
import { api, connectEvents, type Health, type ServerEvent, type StudioChangedEvent } from './api'
import { GpuChip } from './components/GpuChip'
import { VramChip } from './components/VramChip'
import { ReportDialog } from './components/ReportDialog'
import { useDownloads } from './downloads'
import { getLang, setLang, t, type Lang } from './i18n'
import { GeneratePanel } from './panels/Generate'
import { HistoryPanel } from './panels/History'
import { LorasPanel } from './panels/Loras'
import { ModelsPanel } from './panels/Models'
import { StudioPanel } from './panels/Studio'
import { VhsPanel } from './panels/Vhs'
import { AudioPanel } from './panels/Audio'

type Tab = 'generate' | 'studio' | 'vhs' | 'history' | 'models' | 'loras' | 'audio'

// Studio vorn und beim Start offen (Nutzer 27.10.2026: „die App soll zukünftig mit Studio in der ersten Position und
// gleich offen starten, danach folgen Generate, History und Models“); VHS seit 28.10. als eigener Reiter (Nutzer:
// „Eigener Reiter VHS“), ganz hinten hinter den Modellen (Nutzer 28.10. abends: „schiebe VHS Abschnitt ganz nach hinten“)
const TABS: { id: Tab; label: string }[] = [
  { id: 'studio', label: t('Studio', 'Studio') },
  { id: 'generate', label: t('Generieren', 'Generate') },
  { id: 'history', label: t('Verlauf', 'History') },
  { id: 'models', label: t('Modelle', 'Models') },
  // Seit 0.5.29 (Nutzer 16.11.2026: „integriere neuen Bereich ‚LoRA erstellen/Bearbeiten‘“), vor VHS, das ganz hinten bleibt
  { id: 'loras', label: t('LoRA erstellen/Bearbeiten', 'Create/Edit LoRA') },
  // Seit 17.11.2026 (Nutzer: „dann neuer Bereich Audio“): Stimme trennen, entrauschen, Filter, Export, vor VHS
  { id: 'audio', label: t('Ton-Forensik', 'Audio forensics') },
  { id: 'vhs', label: t('VHS', 'VHS') },
]

// Sprachnamen stehen in ihrer eigenen Sprache, damit man sie in jeder Einstellung findet.
const LANGS: { id: Lang; label: string; name: string }[] = [
  { id: 'en', label: 'EN', name: 'English' },
  { id: 'de', label: 'DE', name: 'Deutsch' },
]

export function App() {
  const [tab, setTab] = useState<Tab>('studio')
  // Reiter, die nach dem ersten Besuch bestehen bleiben (siehe unten bei <main>)
  const [kept, setKept] = useState<{ generate?: boolean; vhs?: boolean; loras?: boolean; audio?: boolean }>({})
  useEffect(() => {
    if ((tab === 'generate' || tab === 'vhs' || tab === 'loras' || tab === 'audio') && !kept[tab]) setKept((k) => ({ ...k, [tab]: true }))
  }, [tab, kept])
  const [health, setHealth] = useState<Health | null>(null)
  const [events, setEvents] = useState<ServerEvent | null>(null)
  // Eigener Platz: Studio speichert oft, das darf ein job.done im gemeinsamen Platz nicht verdrängen
  const [studioEvent, setStudioEvent] = useState<StudioChangedEvent | null>(null)
  // Material gelöscht oder hochgeladen: zählt hoch, das Studio lädt seine Medienleiste neu
  const [assetsVersion, setAssetsVersion] = useState(0)
  // LoRA hinzugefügt, zugeordnet oder gelöscht (auch per MCP): Generieren und Modelle laden ihre Liste neu
  const [modelsVersion, setModelsVersion] = useState(0)
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
      else if (e.type === 'models.changed') setModelsVersion((v) => v + 1)
      else if (e.type !== 'ping') setEvents(e)
    })
  }, [])

  const startBackend = async () => {
    setStarting(true)
    try {
      await api.startBackend()
    } catch (e) {
      setNotice(String((e as Error).message ?? e))
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
    } catch (e) {
      setNotice(String((e as Error).message ?? e))
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
          {health?.cpu_mode && <CpuModeChip mode={health.cpu_mode} vulkan={!!health.vulkan_engine} audio={!!health.vulkan_audio} />}
          <span className={health?.comfy_running ? 'dot ok' : 'dot off'} />

          {/* Was liegt im VRAM? Wichtiger als der GPU-Name, deshalb zuerst. */}
          {multiGpu ? (
            // Mehrere Karten (experimentell): je Karte ein Balken und ihre Aufgaben; ein Klick
            // wählt, was die Karte macht.
            health!.gpus!.map((g) => (
              <GpuChip key={g.index} gpu={g} onChanged={refreshHealth} onError={setNotice} />
            ))
          ) : (
            // Eine Karte: Balken und Belegung; ein Klick wählt den Rechenweg (ComfyUI oder stable-diffusion.cpp)
            <VramChip name={health?.gpu?.name} label={vram} pct={vramPct} engine={health?.engine}
              onChanged={refreshHealth} />
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
                  title={t('Download abbrechen (fertige Dateien bleiben, „Fortsetzen“ lädt den Rest)',
                    'Cancel download (finished files stay; “Resume” downloads the rest)')}
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
        {/* Generieren und VHS bleiben nach dem ersten Besuch bestehen, nur ausgeblendet: Ein laufender Auftrag behält so
            Fortschritt und „Abbrechen“, Prompt und Einstellungen bleiben (vorher war beim Zurückkommen alles weg) */}
        {(tab === 'generate' || kept.generate) && (
          <div hidden={tab !== 'generate'}>
            <GeneratePanel health={health} event={events} downloads={downloads} modelsVersion={modelsVersion}
              onShowModels={() => setTab('models')} />
          </div>
        )}
        {(tab === 'vhs' || kept.vhs) && (
          <div hidden={tab !== 'vhs'}>
            <VhsPanel event={events} downloads={downloads} onShowModels={() => setTab('models')} />
          </div>
        )}
        {(tab === 'loras' || kept.loras) && (
          <div hidden={tab !== 'loras'}>
            <LorasPanel event={events} modelsVersion={modelsVersion} onShowModels={() => setTab('models')} />
          </div>
        )}
        {(tab === 'audio' || kept.audio) && (
          <div hidden={tab !== 'audio'}>
            <AudioPanel event={events} active={tab === 'audio'} />
          </div>
        )}
        {tab === 'history' && <HistoryPanel event={events} />}
        {tab === 'models' && (
          <ModelsPanel event={events} onChanged={refreshHealth} downloads={downloads} modelsVersion={modelsVersion} />
        )}
        {tab === 'studio' && (
          <StudioPanel event={events} studioEvent={studioEvent} assetsVersion={assetsVersion} modelsVersion={modelsVersion} />
        )}
      </main>
    </div>
  )
}

/** Hinweis oben in der Leiste: Karte ohne CUDA/ROCm (GitHub-Issue #3; Nutzer 21.11.2026: „oben in der Leiste warnen,
 * dass es auf der CPU läuft, und mouse over Hinweis, was es für ihn bedeutet und was zu machen wäre“). Seit 0.5.35
 * rechnen Bilder (SDXL) und Videos (Wan 2.1 1.3B) dort über die Vulkan-Engine (stable-diffusion.cpp), Ton auf dem
 * Prozessor; DirectML ist raus. Ohne Vulkan-Engine rechnet alles auf dem Prozessor. */
function CpuModeChip({ mode, vulkan, audio }: {
  mode: NonNullable<Health['cpu_mode']>; vulkan: boolean; audio: boolean
}) {
  const cards = mode.cards.length ? mode.cards.join(', ') : t('die Grafikkarte', 'the graphics card')
  const why = mode.reason === 'amd_unsupported'
    ? t(`${cards} wird von AMDs PyTorch für Windows (ROCm) nicht unterstützt.`,
      `${cards} is not supported by AMD's PyTorch for Windows (ROCm).`)
    : mode.reason === 'no_cuda_rocm'
      ? t(`PyTorch rechnet unter Windows nur auf NVIDIA-Karten (CUDA) und neueren Radeons (ROCm), nicht auf ${cards}.`,
        `On Windows, PyTorch computes only on NVIDIA cards (CUDA) and newer Radeons (ROCm), not on ${cards}.`)
      : t(`PyTorch konnte beim Einrichten nicht auf ${cards} rechnen.`,
        `PyTorch could not compute on ${cards} during setup.`)
  const report = t('Läuft etwas nicht oder ist es sehr langsam: bitte über „Problem melden“ (oben rechts) berichten, der Bericht enthält die Zeiten.',
    'If something does not work or is very slow: please tell us via "Report a problem" (top right); the report includes the timings.')
  if (vulkan) {
    const how = t('Deshalb rechnet NVAI-open Bilder und Videos über Vulkan auf der Karte (stable-diffusion.cpp, experimentell).',
      'NVAI-open therefore computes images and videos through Vulkan on the card (stable-diffusion.cpp, experimental).')
    const sound = audio
      ? t('Ton (Stable Audio 3) und Sprecherstimme (Qwen3-TTS) rechnen über audio.cpp ebenfalls auf der Karte. Große Modelle wie Qwen-Image, FLUX 3 oder LTX-2.5 und 3D gehen auf dieser Karte nicht.',
        'Sound (Stable Audio 3) and the narrator voice (Qwen3-TTS) also compute on the card through audio.cpp. Large models such as Qwen-Image, FLUX 3 or LTX-2.5 and 3D do not work on this card.')
      : t('Ton rechnet auf dem Prozessor und braucht länger. Große Modelle wie Qwen-Image, FLUX 3 oder LTX-2.5, die Sprecherstimme und 3D gehen auf dieser Karte nicht.',
        'Sound computes on the processor and takes longer. Large models such as Qwen-Image, FLUX 3 or LTX-2.5, the narrator voice and 3D do not work on this card.')
    const means = t('Was das heißt: Gedacht sind die Modelle, die unter „Modelle“ als empfohlen markiert sind: SDXL-Modelle wie Juggernaut XL, Pony oder Illustrious für Bilder und Wan 2.1 T2V 1.3B für Videos (langsam).',
      'What this means: the models marked as recommended under "Models" are meant for it: SDXL models such as Juggernaut XL, Pony or Illustrious for images and Wan 2.1 T2V 1.3B for videos (slow).') + ' ' + sound + ' ' + t('Studio-Schnitt und Export laufen normal.', 'Studio editing and export work normally.')
    return (
      <span className="cpu-mode" title={`${why} ${how}\n\n${means}\n\n${report}`}>
        ⚠ {t('Vulkan (experimentell)', 'Vulkan (experimental)')}
      </span>
    )
  }
  const means = t('Deshalb rechnet NVAI-open auf dem Prozessor. Was das heißt: Bilder und Videos dauern sehr lange (viele Minuten je Bild), große Modelle wie Qwen-Image, FLUX oder LTX sind kaum nutzbar, Sprecherstimme und 3D gehen nicht. Studio-Schnitt und Export laufen normal; Audio-Werkzeuge und Ton-Forensik rechnen ebenfalls auf dem Prozessor und brauchen länger.',
    'NVAI-open therefore computes on the processor. What this means: images and videos take very long (many minutes per image), large models such as Qwen-Image, FLUX or LTX are hardly usable, the narrator voice and 3D do not work. Studio editing and export work normally; the audio tools and audio forensics also compute on the processor and take longer.')
  const todo = mode.reason === 'amd_unsupported' || mode.reason === 'no_cuda_rocm'
    ? t('Was hilft: den aktuellen Grafiktreiber installieren und im Startmenü „NVAI-open reparieren“ ausführen; dann richtet das Setup Vulkan für die Karte ein, wenn Vulkan sie sieht. Am schnellsten ist eine NVIDIA-Grafikkarte oder eine Radeon RX 7000 oder 9000 (RX 6000 experimentell).',
      'What helps: install the current graphics driver and run "Repair NVAI-open" from the Start menu; the setup then sets up Vulkan for the card if Vulkan sees it. Fastest is an NVIDIA graphics card or a Radeon RX 7000 or 9000 (RX 6000 experimental).')
    : t('Was hilft: den aktuellen Grafiktreiber installieren (bei AMD Adrenalin 26.2.2 oder neuer), danach im Startmenü „NVAI-open reparieren“ ausführen.',
      'What helps: install the current graphics driver (for AMD, Adrenalin 26.2.2 or newer), then run "Repair NVAI-open" from the Start menu.')
  return (
    <span className="cpu-mode" title={`${why} ${means}\n\n${todo}\n\n${report}`}>
      ⚠ {t('Rechnet auf dem Prozessor', 'Running on the CPU')}
    </span>
  )
}
