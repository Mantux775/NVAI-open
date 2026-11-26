// Bausteine des Reiters „Generieren“ für das Konzept „NVAI im Fluss“ (Bildschirme B und C): Platz für ein Bild oder Video
// des Wegs, Chips mit Auswahl, Seed zum Kopieren, nächste Schritte unter einem Ergebnis, Restzeit am Knopf.
import { useState, type DragEvent as RDragEvent, type ReactNode } from 'react'
import { t } from '../../i18n'
import { isActive, remainingSeconds, useJob, useNow } from '../jobs'
import { fmtLeft } from '../time'

/** Ein Asset im Platz eines Wegs: Bild oder Video mit kurzem Namen */
export interface SlotAsset {
  url: string
  thumb?: string | null
  video?: boolean
  name: string
}

/** Platz für Startbild, Endbild, Layout-Video oder das Video zum Verlängern. Klick auf „Wählen“ öffnet die Auswahl
 *  darunter; ein Bild aus der Auswahl oder eine Datei vom Rechner lässt sich auch hierher ziehen. */
export function Slot({ label, asset, empty, required, open, onToggle, onClear, onDropFile, onDropUrl, accept }: {
  label: string
  asset?: SlotAsset | null
  /** ohne Asset: „hierher ziehen“, „Kein Bild nötig“ … */
  empty: string
  required?: boolean
  open?: boolean
  onToggle?: () => void
  onClear?: () => void
  onDropFile?: (f: File) => void
  /** ein Bild aus der Auswahl dieser Seite: true, wenn es bekannt ist (dann wird nichts hochgeladen) */
  onDropUrl?: (url: string) => boolean
  /** Dateiarten für das Ablegen: Bilder oder Videos */
  accept?: 'image' | 'video'
}) {
  const [over, setOver] = useState(false)
  const droppable = !!(onDropFile || onDropUrl)
  const takes = (e: RDragEvent) => droppable
    && (e.dataTransfer.types.includes('Files') || e.dataTransfer.types.includes('text/uri-list'))
  const drop = (e: RDragEvent) => {
    setOver(false)
    if (!takes(e)) return
    e.preventDefault()
    // Zuerst ein schon vorhandenes Bild (aus der Auswahl gezogen), erst dann eine Datei vom Rechner hochladen
    const url = e.dataTransfer.getData('text/uri-list').split('\n').find((l) => l && !l.startsWith('#'))
    if (url && onDropUrl?.(url.trim())) return
    const file = e.dataTransfer.files?.[0]
    if (file && onDropFile && (!accept || file.type.startsWith(`${accept}/`))) onDropFile(file)
  }
  return (
    <div className={`flow-slot gen-slot${asset ? ' filled' : ''}${required && !asset ? ' wanted' : ''}${over ? ' over' : ''}`}
      onDragOver={(e) => {
        if (!takes(e)) return
        e.preventDefault()
        e.dataTransfer.dropEffect = 'copy'
        setOver(true)
      }}
      onDragLeave={() => setOver(false)}
      onDrop={drop}>
      {asset?.url
        ? asset.video
          ? <video src={`${asset.url}#t=0.1`} poster={asset.thumb ?? undefined} preload="metadata" muted />
          : <img src={asset.thumb || asset.url} alt="" />
        : <span className="gen-slot-empty" aria-hidden="true">{asset ? '✓' : required ? '+' : '·'}</span>}
      <span className="gen-slot-text">
        <b>{label}</b>
        {asset ? <span title={asset.name}>: {asset.name}</span> : <span className="muted">: {empty}</span>}
      </span>
      <span className="gen-slot-actions">
        {onToggle && (
          <button type="button" className="btn small ghost" aria-expanded={!!open} onClick={onToggle}>
            {open ? t('Schließen', 'Close') : asset ? t('Ändern', 'Change') : t('Wählen', 'Choose')}
          </button>
        )}
        {asset && onClear && (
          <button type="button" className="btn small ghost" onClick={onClear}
            aria-label={t(`${label} entfernen`, `Remove ${label}`)} title={t('Entfernen', 'Remove')}>×</button>
        )}
      </span>
    </div>
  )
}

export interface ChipOption {
  value: string
  label: string
  disabled?: boolean
}

/** Chip mit Auswahl („1920 × 1088 ▾“): sichtbar ist der kurze Text, die Liste zeigt die vollen Namen */
export function ChipSelect({ value, options, onChange, display, title, label, className = '', disabled, groups }: {
  value: string
  options: ChipOption[]
  onChange: (v: string) => void
  display: ReactNode
  title?: string
  /** für Screenreader */
  label: string
  className?: string
  disabled?: boolean
  /** weitere Gruppen in der Liste (etwa „Noch nicht geladen“) */
  groups?: { label: string; options: ChipOption[] }[]
}) {
  return (
    <label className={`flow-chip gen-chip-pick ${className}`.trim()} title={title}>
      <span className="gen-chip-text">{display}</span>
      {!disabled && <span className="gen-chip-caret" aria-hidden="true">▾</span>}
      <select value={value} onChange={(e) => onChange(e.target.value)} aria-label={label} disabled={disabled}>
        {options.map((o) => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
        {groups?.filter((g) => g.options.length).map((g) => (
          <optgroup key={g.label} label={g.label}>
            {g.options.map((o) => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
          </optgroup>
        ))}
      </select>
    </label>
  )
}

/** Chip mit Zahl („5 s“, „4 Bilder“) */
export function ChipNumber({ value, onChange, min, max, step = 1, unit, label, title, disabled, className = '' }: {
  value: number
  onChange: (v: number) => void
  min: number
  max: number
  step?: number
  unit: string
  label: string
  title?: string
  disabled?: boolean
  className?: string
}) {
  return (
    <label className={`flow-chip gen-chip-num ${className}`.trim()} title={title}>
      <input type="number" value={value} min={min} max={max} step={step} disabled={disabled} aria-label={label}
        onChange={(e) => {
          const v = Number(e.target.value)
          if (Number.isFinite(v)) onChange(v)
        }} />
      <span>{unit}</span>
    </label>
  )
}

/** Text in die Zwischenablage; ohne Clipboard-API (ältere Browser) über eine markierte Textfläche */
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    const area = document.createElement('textarea')
    area.value = text
    area.style.position = 'fixed'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    let ok = false
    try {
      ok = document.execCommand('copy')
    } catch {
      ok = false
    }
    area.remove()
    return ok
  }
}

/** Seed genau als Text, mit „kopieren“ (Konzept, Bildschirm C: „Der Seed wird genau angezeigt und lässt sich kopieren“) */
export function SeedCopy({ seed }: { seed: string | number }) {
  const [state, setState] = useState<'idle' | 'done' | 'fail'>('idle')
  const copy = async () => {
    setState((await copyText(String(seed))) ? 'done' : 'fail')
    window.setTimeout(() => setState('idle'), 1600)
  }
  return (
    <span className="gen-seed">
      {t('Seed', 'Seed')} <span className="gen-mono">{String(seed)}</span>{' '}
      <button type="button" className="btn small ghost gen-copy" onClick={copy} aria-live="polite">
        {state === 'done' ? t('kopiert', 'copied') : state === 'fail' ? t('nicht kopiert', 'not copied') : t('kopieren', 'copy')}
      </button>
    </span>
  )
}

export interface NextStep {
  key: string
  icon: string
  label: string
  /** Modell und Zeit: „Startbild, LTX-2.5, ≈ 1:50“ */
  small: string
  primary?: boolean
  disabled?: boolean
  title?: string
  onClick: () => void
}

/** Die naheliegenden nächsten Schritte unter einem Ergebnis (Konzept, Bildschirm C: „Jedes Ergebnis führt weiter“) */
export function NextSteps({ heading, steps, children }: { heading: string; steps: NextStep[]; children?: ReactNode }) {
  if (!steps.length) return null
  return (
    <div className="gen-next">
      <span className="flow-label">{heading}</span>
      <div className="flow-next">
        {steps.map((s) => (
          <button key={s.key} type="button" className={s.primary ? 'btn primary' : 'btn'} disabled={s.disabled}
            title={s.title} onClick={s.onClick}>
            <span>{s.icon} {s.label}</span>
            <small>{s.small}</small>
          </button>
        ))}
      </div>
      {children}
    </div>
  )
}

/** Restzeit am Knopf, solange der eigene Auftrag läuft */
export function RunningEta({ jobId, expected }: { jobId: string; expected?: number | null }) {
  const job = useJob(jobId)
  const now = useNow(!!job && isActive(job))
  if (!job) return null
  return <span className="flow-eta">{fmtLeft(remainingSeconds(job, expected, now))}</span>
}
