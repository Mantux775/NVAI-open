import { useEffect, useRef, useState } from 'react'
import { api, type GpuInfo, type GpuRole } from '../api'
import { t } from '../i18n'

const ROLE_LABEL: Record<GpuRole, string> = {
  image: t('Bild', 'Image'),
  text: t('Text', 'Text'),
  mesh: '3D',
}

const ROLES: { id: GpuRole; label: string; hint: string }[] = [
  { id: 'image', label: t('Bildmodelle', 'Image models'), hint: t('auch Video und Audio', 'also video and audio') },
  { id: 'text', label: t('Sprachmodelle', 'Language models'), hint: t('Upsampler, Prompt ausbauen', 'upsampler, expand prompt') },
  { id: 'mesh', label: '3D', hint: 'TripoSG, TRELLIS.2' },
]

/**
 * Eine Karte in der Kopfleiste (mehrere Karten, experimentell): Balken, Speicher und ihre
 * Aufgaben. Ein Klick öffnet die Auswahl, was diese Karte macht. Jede Aufgabe liegt auf genau
 * einer Karte; hier anhaken holt sie von der anderen Karte herüber.
 */
export function GpuChip({ gpu, onChanged, onError }: {
  gpu: GpuInfo
  onChanged: () => void
  onError: (msg: string) => void
}) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
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

  const total = gpu.vram_total_mb / 1024
  const used = (gpu.vram_used_mb ?? 0) / 1024
  const pct = total > 0 ? Math.min(100, (used / total) * 100) : 0

  const take = async (role: GpuRole) => {
    setBusy(true)
    try {
      await api.setGpus({ [role]: gpu.index })
      onChanged()
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <span className="gpu-chip" ref={ref}>
      <button
        type="button"
        className={open ? 'vram gpu-chip-btn open' : 'vram gpu-chip-btn'}
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        title={`GPU ${gpu.index}: ${gpu.name} · ${used.toFixed(1)} / ${total.toFixed(0)} GB · `
          + t('Klicken: Aufgaben dieser Karte wählen', 'Click: choose what this card does')}
      >
        <span className="gpu-roles">
          {gpu.roles.map((r) => ROLE_LABEL[r]).join(' + ') || `GPU ${gpu.index}`}
        </span>
        <span className="vram-bar">
          <span className={pct > 85 ? 'vram-fill high' : 'vram-fill'} style={{ width: `${pct}%` }} />
        </span>
        <span className="muted small">
          {gpu.vram_used_mb == null ? `${total.toFixed(0)} GB` : `${used.toFixed(1)} / ${total.toFixed(0)} GB`}
        </span>
        <span className="gpu-chip-caret">▾</span>
      </button>

      {open && (
        <div className="gpu-pop" role="dialog">
          <div className="gpu-pop-title">GPU {gpu.index}: {gpu.name}</div>
          <div className="muted small">{t('Was soll diese Karte machen?', 'What should this card do?')}</div>
          {ROLES.map((r) => {
            const here = gpu.roles.includes(r.id)
            return (
              <label key={r.id} className={here ? 'gpu-pop-row here' : 'gpu-pop-row'}>
                <input
                  type="checkbox"
                  checked={here}
                  disabled={here || busy}
                  onChange={() => take(r.id)}
                />
                <span>
                  {r.label} <span className="muted small">({r.hint})</span>
                </span>
              </label>
            )
          })}
          <div className="muted small gpu-pop-note">
            {t(
              'Jede Aufgabe läuft auf genau einer Karte. Anhaken holt sie hierher; zum Abgeben auf einer '
                + 'anderen Karte anhaken. Geht nicht, während ein Auftrag läuft.',
              'Each task runs on exactly one card. Ticking moves it here; to hand it off, tick it on '
                + 'another card. Not possible while a job is running.',
            )}{' '}
            <span className="badge warn">{t('experimentell', 'experimental')}</span>
          </div>
        </div>
      )}
    </span>
  )
}
