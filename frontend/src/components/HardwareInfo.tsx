// Hardware-Katalog in der Oberfläche (seit 0.5.28; Nutzer 14.11.2026: „nutze dieses hardware katalog auch bei model
// vorschlägen in Modelle und anderen berreichen“): die erkannte Karte mit Rechenweg und Geschwindigkeit gegenüber der
// Referenzkarte (Abschnitt „Deine Hardware“ unter „Modelle“) und die typische Rechenzeit je Modell (an den Modellen und
// unter der Modellwahl beim Generieren). Daten: GET /api/hardware (server/nvai/hardware.py, hardware.json).

import { useEffect, useState } from 'react'
import { api, type HardwareInfo } from '../api'
import { EngineChoice, engineShort, useEngine } from './EngineChoice'
import { t } from '../i18n'

let cache: Promise<HardwareInfo | null> | null = null

/** Einmal je Seitenaufruf laden; ein älterer Server ohne /api/hardware gibt null */
export function loadHardware(): Promise<HardwareInfo | null> {
  if (!cache) cache = api.hardware().catch(() => null)
  return cache
}

export function useHardware(): HardwareInfo | null {
  const [hw, setHw] = useState<HardwareInfo | null>(null)
  useEffect(() => {
    let alive = true
    loadHardware().then((h) => alive && setHw(h))
    return () => { alive = false }
  }, [])
  return hw
}

/** Dauer kurz und rund: „≈ 40 s“, „≈ 12 min“, „≈ 1 h 20 min“ */
export function fmtDuration(s: number): string {
  if (s < 10) return `≈ ${Math.max(1, Math.round(s))} s`
  if (s < 90) return `≈ ${Math.round(s / 5) * 5} s`
  const m = Math.round(s / 60)
  if (m < 90) return `≈ ${m} min`
  return `≈ ${Math.floor(m / 60)} h ${m % 60} min`
}

const TASK: Record<string, string> = {
  image_1024: t('je Bild (1024²)', 'per image (1024²)'),
  image_1mp: t('je Bild (1 MP)', 'per image (1 MP)'),
  video_5s_1080: t('je 5-s-Clip in 1080p', 'per 5 s clip at 1080p'),
  video_5s_560: t('je 5-s-Clip (1280 × 560)', 'per 5 s clip (1280 × 560)'),
  video_5s_480: t('je 5-s-Clip (864 × 480)', 'per 5 s clip (864 × 480)'),
  sfx_6s: t('je 6-s-Klang', 'per 6 s sound'),
  music_60s: t('je Minute Musik', 'per minute of music'),
  line: t('je Satz', 'per line'),
  mesh: t('je 3D-Modell', 'per 3D model'),
  upscale_5s: t('je 5-s-Video', 'per 5 s video'),
}

function pathText(path: string | null): string {
  if (path === 'fp4') return t('RTX 50 mit FP4-Einheiten: Die NVFP4-Fassungen sind hier am schnellsten und deshalb empfohlen.',
    'RTX 50 with FP4 units: the NVFP4 versions are fastest here and therefore recommended.')
  if (path === 'int8' || path === 'fp16') return t('Ohne FP4-Einheiten: Die INT8-Fassungen sind auf dieser Karte am schnellsten und deshalb empfohlen.',
    'No FP4 units: the INT8 versions are fastest on this card and therefore recommended.')
  if (path === 'amd') return t('Radeon mit ROCm: Empfohlen sind die FP8-Fassungen (RDNA 4) bzw. bf16 (RDNA 3). Die Zeiten sind grob geschätzt.',
    'Radeon with ROCm: the FP8 versions (RDNA 4) or bf16 (RDNA 3) are recommended. The times are rough estimates.')
  return t('Die Karte steht nicht im Katalog: Empfohlen wird nach Speicher und Architektur, die Zeiten gelten für eine RTX 5060 Ti.',
    'The card is not in the catalog: recommendations follow memory and architecture, the times are for an RTX 5060 Ti.')
}

/** Abschnitt „Deine Hardware“ unter „Modelle“, zugeklappt wie die Speicherorte */
export function HardwareSection() {
  const hw = useHardware()
  const [engine] = useEngine()
  const [open, setOpen] = useState(false)
  if (!hw) return null
  const d = hw.device
  const summary = d.name
    ? [d.name.replace(/^NVIDIA GeForce |^NVIDIA |^AMD /, ''), d.vram_gb ? `${Math.round(d.vram_gb)} GB` : '', d.arch ?? '', engineShort(engine)].filter(Boolean).join(' · ')
    : t('keine Grafikkarte erkannt', 'no graphics card detected')
  const isRef = d.catalog_id === 'rtx-5060-ti-16'
  return (
    <section className="panel folder-settings hw-settings">
      <button className="folder-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="folder-title">{t('Deine Hardware', 'Your hardware')}</span>
        <span className="muted small folder-summary">{summary}</span>
        <span className="muted">{open ? '▴' : '▾'}</span>
      </button>
      {open && (
        <div className="folder-body small">
          {/* Rechenweg (seit 0.5.35): ComfyUI oder stable-diffusion.cpp über CUDA/Vulkan, nur was hier läuft */}
          <EngineChoice />
          <p>{d.name
            ? <>{d.name}{d.vram_gb ? `, ${Math.round(d.vram_gb)} GB` : ''}{d.catalog_id ? ` (${t('im Hardware-Katalog', 'in the hardware catalog')}: ${d.arch}${d.laptop ? t(', Laptop', ', laptop') : ''})` : ` (${t('nicht im Katalog', 'not in the catalog')})`}.</>
            : t('Es wurde keine Grafikkarte erkannt.', 'No graphics card was detected.')}</p>
          <p>{pathText(d.catalog_id ? d.path : null)}</p>
          {d.speed && !isRef && (
            <p>{t(`Geschätzt etwa ${d.speed.toLocaleString('de-DE')}-mal so schnell wie die RTX 5060 Ti 16 GB, auf der die Zeiten gemessen sind.`,
              `Estimated at about ${d.speed}× the speed of the RTX 5060 Ti 16 GB the times were measured on.`)}</p>
          )}
          {isRef && <p>{t('Auf genau dieser Karte sind die Zeiten gemessen.', 'The times were measured on exactly this card.')}</p>}
          {d.uncertain && <p className="muted">{t('Einige Werte dieser Karte sind im Katalog als unsicher markiert.', 'Some values of this card are marked as uncertain in the catalog.')}</p>}
          <p className="muted">{t(`Die Zeiten an den Modellen gelten für einen typischen Auftrag. Der Katalog kennt ${hw.catalog.devices} Grafikkarten und Chips (NVIDIA RTX 20 bis 50, AMD Radeon, Apple Silicon), mit Quellen.`,
            `The times on the models are for a typical job. The catalog knows ${hw.catalog.devices} graphics cards and chips (NVIDIA RTX 20 to 50, AMD Radeon, Apple silicon), with sources.`)}</p>
        </div>
      )}
    </section>
  )
}

/** Typische Zeit an einem Modell in der Liste */
export function EstimateBadge({ id }: { id: string }) {
  const hw = useHardware()
  const e = hw?.estimates[id]
  if (!e) return null
  return (
    <span className="badge time" title={e.measured ? t('Gemessen auf dieser Karte, typischer Auftrag', 'Measured on this card, typical job') : t('Geschätzt für deine Karte (Hardware-Katalog), typischer Auftrag', 'Estimated for your card (hardware catalog), typical job')}>
      {fmtDuration(e.seconds)} {TASK[e.task] ?? ''}
    </span>
  )
}

/** Unter der Modellwahl beim Generieren: „Auf deiner Karte ≈ 30 s je Bild (1024²)“ */
export function ModelEstimate({ id }: { id?: string | null }) {
  const hw = useHardware()
  const e = id ? hw?.estimates[id] : undefined
  if (!e) return null
  return (
    <p className="model-estimate muted small">
      {e.measured ? t('Auf deiner Karte gemessen', 'Measured on your card') : t('Auf deiner Karte geschätzt', 'Estimated on your card')}: {fmtDuration(e.seconds)} {TASK[e.task] ?? ''}
    </p>
  )
}
