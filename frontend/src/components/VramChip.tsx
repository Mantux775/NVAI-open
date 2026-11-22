import { useEffect, useRef, useState } from 'react'
import type { Health } from '../api'
import { t } from '../i18n'
import { EngineChoice } from './EngineChoice'

/**
 * Speicher-Anzeige in der Kopfleiste bei einer Karte (seit 0.5.35; Nutzer 22.11.2026: „genau so beim anklicken auf die
 * ram anzeige (wie beim multigpu)“): Balken und Belegung wie bisher, ein Klick öffnet die Wahl des Rechenwegs. Rechnet
 * stable-diffusion.cpp, steht das vor dem Balken.
 */
export function VramChip({ name, label, pct, engine, onChanged }: {
  name?: string
  label: string
  pct: number
  engine?: Health['engine']
  onChanged: () => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', esc)
    return () => {
      document.removeEventListener('mousedown', close)
      document.removeEventListener('keydown', esc)
    }
  }, [open])

  const sd = engine?.engine === 'sdcpp' && engine.ready
  return (
    <span className="gpu-chip" ref={ref}>
      <button
        type="button"
        className={open ? 'vram gpu-chip-btn open' : 'vram gpu-chip-btn'}
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        title={`${name ?? 'GPU'} · ${label} · ` + t('Klicken: Rechenweg wählen', 'Click: choose the compute engine')}
      >
        {sd && <span className="gpu-roles">sd.cpp ({engine?.backend === 'cuda' ? 'CUDA' : 'Vulkan'})</span>}
        <span className="vram-bar">
          <span className={pct > 85 ? 'vram-fill high' : 'vram-fill'} style={{ width: `${pct}%` }} />
        </span>
        <span className="muted small">{label}</span>
        <span className="gpu-chip-caret">▾</span>
      </button>
      {open && (
        <div className="gpu-pop" role="dialog">
          <div className="gpu-pop-title">{name ?? 'GPU'}</div>
          <EngineChoice onChanged={onChanged} />
        </div>
      )}
    </span>
  )
}
