// Erster Start (seit 0.5.42, Konzept „NVAI im Fluss“, Bildschirm A): erst die Absicht, dann genau die Modelle dafür,
// mit Größe, Lizenz und Ladezeit. Der Klick auf „Laden und loslegen“ ist die Rückfrage vor dem Download. Vorher
// erklärte das Studio Szenen und Marker, sagte aber nicht, dass ein Modell fehlt, und die Modellliste begann mit allen
// Einträgen.
import { useEffect, useMemo, useState } from 'react'
import { api, type HardwareDevice, type ModelInfo, type WizardPlan } from '../api'
import { hfGuideUrl } from '../components/GatedNotice'
import type { Downloads } from '../downloads'
import { t } from '../i18n'
import { gatedMissing, licenseLine } from './ModelNeed'
import { downloadSeconds, fmtGb, fmtSpan } from './time'

export type Intent = 'video' | 'image' | 'audio' | 'photo'

/** Arten, die etwas erzeugen: Ist davon keins geladen, ist es ein erster Start */
const MAKERS = new Set(['image', 'video', 'audio', 'speech'])

const DISMISS_KEY = 'nvai-welcome-dismissed'

function dismissed(): boolean {
  try {
    return localStorage.getItem(DISMISS_KEY) === '1' || sessionStorage.getItem(DISMISS_KEY) === '1'
  } catch {
    return false
  }
}

function remember(forever: boolean) {
  try {
    ;(forever ? localStorage : sessionStorage).setItem(DISMISS_KEY, '1')
  } catch {
    /* nicht speicherbar: dann erscheint er beim nächsten Laden wieder */
  }
}

/** Bestes Modell einer Art für diese Karte: empfohlene Fassung (NVFP4 auf RTX 50, INT8 sonst, Vulkan-Modelle auf
 *  älteren Radeons), Familien in der Reihenfolge der Vorliebe, Geladenes vor Fehlendem */
function pick(models: ModelInfo[], kind: string, families: string[], skip: (m: ModelInfo) => boolean = () => false): ModelInfo | null {
  const of = models.filter((m) => m.kind === kind && m.usable !== false && !skip(m))
  const rank = (m: ModelInfo) => {
    const i = families.indexOf(m.family)
    return i < 0 ? families.length : i
  }
  const sorted = [...of].sort((a, b) =>
    Number(b.recommended) - Number(a.recommended) || rank(a) - rank(b) || Number(b.installed) - Number(a.installed))
  return sorted[0] ?? null
}

interface Need {
  model: ModelInfo
  role: string
}

export function Welcome({ downloads, modelsVersion, onGo, onShowModels }: {
  downloads: Downloads
  /** zählt hoch, wenn sich Modelle ändern (Download fertig, gelöscht) */
  modelsVersion: number
  onGo: (intent: Intent) => void
  onShowModels: () => void
}) {
  const [models, setModels] = useState<ModelInfo[] | null>(null)
  const [device, setDevice] = useState<HardwareDevice | null>(null)
  const [plan, setPlan] = useState<WizardPlan | null>(null)
  const [intent, setIntent] = useState<Intent>('video')
  const [hidden, setHidden] = useState(dismissed)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (hidden) return
    api.models().then(setModels).catch(() => setModels(null))
  }, [hidden, modelsVersion, downloads.finished])
  useEffect(() => {
    if (hidden) return
    api.hardware().then((h) => setDevice(h.device)).catch(() => setDevice(null))
    // Dieselben Modelle wie der Assistent, der beim Video gleich weitermacht (beste Fassung für diese Karte)
    api.studioWizardPlan({ quality: 'best', start_images: 4, video_seconds: 20, music: true })
      .then(setPlan).catch(() => setPlan(null))
  }, [hidden])

  const firstStart = !!models && !models.some((m) => MAKERS.has(m.kind) && m.installed)

  const needs: Need[] = useMemo(() => {
    if (!models) return []
    const byId = (id: string | null | undefined) => (id ? models.find((m) => m.id === id) ?? null : null)
    const out: (Need | null)[] = []
    if (intent === 'video') {
      out.push(
        { role: t('Video mit Ton', 'Video with sound'), model: byId(plan?.models.video?.id) ?? pick(models, 'video', ['ltx25'])! },
        { role: t('Startbilder', 'Start images'), model: byId(plan?.models.image?.id) ?? pick(models, 'image', ['flux3', 'qwenimage'])! },
        { role: t('Musik', 'Music'), model: byId(plan?.models.music?.id) ?? pick(models, 'audio', ['stable_audio3'])! },
      )
    } else if (intent === 'image') {
      out.push({ role: t('Bilder, Schrift im Bild', 'Images, text in the image'),
        model: pick(models, 'image', ['qwenimage', 'flux3', 'krea2', 'moss_image'], (m) => m.id.includes('lightning'))! })
    } else if (intent === 'audio') {
      out.push({ role: t('Musik und Geräusche', 'Music and sounds'),
        model: pick(models, 'audio', ['stable_audio3', 'stable_audio'], (m) => m.id.includes('small'))! })
    } else {
      out.push(
        { role: t('Schäden entfernen, einfärben', 'Remove damage, colorize'), model: pick(models, 'image', ['flux3'], (m) => m.family !== 'flux3' || m.id.includes('base'))! },
        { role: t('Schärfen', 'Sharpen'), model: pick(models, 'upscale', ['seedvr2'], (m) => m.family !== 'seedvr2' || m.id.includes('-3b-'))! },
      )
    }
    return out.filter((n): n is Need => !!n && !!n.model)
  }, [models, plan, intent])

  if (hidden || !firstStart) return null

  const missing = needs.filter((n) => !n.model.installed)
  const loadable = missing.filter((n) => !gatedMissing(n.model))
  const gb = missing.reduce((s, n) => s + Math.max(0, (n.model.size_gb || 0) - (n.model.partially_installed ? n.model.disk_gb || 0 : 0)), 0)
  const total = models!.filter((m) => m.kind !== 'lora').length
  const card = device?.name
    ? [device.catalog_name ?? device.name, device.vram_gb ? `${Math.round(device.vram_gb)} GB` : '', device.arch ?? ''].filter(Boolean).join(', ')
    : null

  const go = async () => {
    setBusy(true)
    setError(null)
    try {
      // Der Server lädt nacheinander; die Download-Leiste oben zeigt den Fortschritt auf jeder Seite
      for (const n of loadable) {
        if (!downloads.active[n.model.id]) await downloads.start(n.model.id)
      }
      remember(false)
      setHidden(true)
      onGo(intent)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  // Was man währenddessen schon tun kann; beim alten Foto gibt es keinen Prompt (Hinweis aus der Mac-Fassung)
  const meanwhile = intent === 'video' ? t('der Assistent beginnt schon', 'the assistant starts right away')
    : intent === 'photo' ? t('du kannst schon das Foto wählen', 'you can already choose the photo')
    : t('du kannst schon den Prompt schreiben', 'you can already write the prompt')

  const intents: { id: Intent; title: string; text: string }[] = [
    { id: 'video', title: t('Ein Video mit Ton', 'A video with sound'), text: t('Assistent, sieben kurze Schritte', 'Assistant, seven short steps') },
    { id: 'image', title: t('Ein Bild', 'An image'), text: t('Figur, Objekt, Plakat, Schrift', 'Character, object, poster, lettering') },
    { id: 'audio', title: t('Musik oder Geräusch', 'Music or a sound'), text: t('bis 5 Minuten', 'up to 5 minutes') },
    { id: 'photo', title: t('Ein altes Foto', 'An old photo'), text: t('Schäden weg, Farbe, schärfen', 'Remove damage, add color, sharpen') },
  ]

  return (
    <section className="flow-welcome" aria-labelledby="flow-welcome-title">
      <div className="flow-row" style={{ justifyContent: 'space-between', alignItems: 'start' }}>
        <div>
          <b id="flow-welcome-title" style={{ fontSize: 16 }}>{t('Willkommen bei NVAI-open', 'Welcome to NVAI-open')}</b>
          <div className="muted">
            {card ? t(`Deine Karte: ${card}. Noch ist kein Modell geladen.`, `Your card: ${card}. No model is downloaded yet.`)
              : t('Noch ist kein Modell geladen.', 'No model is downloaded yet.')}
          </div>
        </div>
        <button type="button" className="btn small ghost" onClick={() => { remember(true); setHidden(true) }}
          title={t('Nicht mehr zeigen; Modelle gibt es unter „Modelle“', 'Do not show again; models are under "Models"')}>✕</button>
      </div>

      <span className="flow-label">{t('Womit möchtest du anfangen?', 'What would you like to start with?')}</span>
      <div className="flow-intents">
        {intents.map((i) => (
          <button key={i.id} type="button" className="flow-intent" aria-pressed={intent === i.id} onClick={() => setIntent(i.id)}>
            <b>{i.title}</b>
            <span>{i.text}</span>
            {i.id === 'video' && <span className="flow-chip ok" style={{ justifySelf: 'start' }}>{t('empfohlen', 'recommended')}</span>}
          </button>
        ))}
      </div>

      <span className="flow-label">{t('Dafür brauchst du', 'For this you need')}</span>
      <div className="flow-needs">
        {needs.map((n) => {
          const dl = downloads.active[n.model.id]
          return (
            <div key={n.model.id} className="row">
              <span>
                <b>{n.model.name}</b> · {n.role}{' '}
                <span className="muted">
                  · {gatedMissing(n.model)
                    ? <>{t('Hugging-Face-Konto und Lizenz nötig, ', 'Hugging Face account and license needed, ')}<a href={hfGuideUrl()} target="_blank" rel="noreferrer">{t('Anleitung', 'guide')}</a></>
                    : licenseLine(n.model)}
                </span>
              </span>
              <span className="size">
                {n.model.installed ? <span className="ok-text">✓ {t('geladen', 'downloaded')}</span>
                  : dl ? `${Math.round(dl.progress * 100)} %`
                  : fmtGb(Math.max(0, (n.model.size_gb || 0) - (n.model.partially_installed ? n.model.disk_gb || 0 : 0)))}
              </span>
            </div>
          )
        })}
      </div>

      <div className="flow-row" style={{ justifyContent: 'space-between' }}>
        <span className="muted small">
          {missing.length === 0
            ? t('Alles da, es kann losgehen.', 'Everything is there, you can start.')
            : t(`Zusammen ${fmtGb(gb)}, bei 100 MBit/s rund ${fmtSpan(downloadSeconds(gb))}. Lädt im Hintergrund, ${meanwhile}.`,
              `${fmtGb(gb)} in total, about ${fmtSpan(downloadSeconds(gb))} at 100 Mbit/s. Downloads in the background, ${meanwhile}.`)}
          {missing.length > loadable.length && (
            <> {t('Gesperrte Modelle lädst du nach der Anleitung unter „Modelle“.', 'Gated models: follow the guide, then download them under "Models".')}</>
          )}
        </span>
        <span className="flow-row">
          <button type="button" className="btn small" onClick={onShowModels}>{t(`Selbst auswählen (${total})`, `Choose yourself (${total})`)}</button>
          <button type="button" className="btn small primary" disabled={busy} onClick={go}>
            {missing.length === 0 ? t('Loslegen', 'Start') : loadable.length ? t('Laden und loslegen', 'Download and start') : t('Loslegen', 'Start')}
          </button>
        </span>
      </div>
      {error && <p className="warn-text small" style={{ margin: 0 }}>{error}</p>}
    </section>
  )
}
