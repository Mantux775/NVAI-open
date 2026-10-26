import { useEffect, useRef, useState } from 'react'
import { api, type GpuInfo, type GpuRole } from '../api'
import { t } from '../i18n'

const ROLE_LABEL: Record<GpuRole, string> = {
  image: t('Bild', 'Image'),
  text: t('Text', 'Text'),
  mesh: '3D',
}

export const GPU_ROLES: { id: GpuRole; label: string; hint: string }[] = [
  { id: 'image', label: t('Bilder, Video, Audio', 'Images, video, audio'), hint: t('FLUX 3, Qwen, Wan, LTX, Stable Audio', 'FLUX 3, Qwen, Wan, LTX, Stable Audio') },
  { id: 'text', label: t('Sprachmodelle', 'Language models'), hint: t('Prompt-Upsampler, „Prompt ausbauen“', 'prompt upsampler, “Expand prompt”') },
  { id: 'mesh', label: '3D', hint: 'TripoSG, TRELLIS.2' },
]

/**
 * Eine Karte in der Kopfleiste (mehrere Karten): Balken, Speicher und ihre Aufgaben. Ein Klick
 * öffnet die Auswahl, was diese Karte macht. Jede Aufgabe liegt auf genau einer Karte; „hierher
 * holen“ nimmt sie der anderen Karte ab. Vorher war das ein kleines, ausgegrautes Kästchen, das
 * kaum zu erkennen war (Nutzerrückmeldung 23.10.2026) -- jetzt ganze, eingefärbte Zeilen.
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

  const apply = async (body: Partial<Record<GpuRole, number>> | { auto: true }) => {
    setBusy(true)
    try {
      await api.setGpus(body)
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
          <div className="gpu-pop-title">
            GPU {gpu.index}: {gpu.name} · {total.toFixed(0)} GB
            {gpu.strongest && <span className="badge ok">{t('stärkste Karte', 'strongest card')}</span>}
          </div>
          <div className="muted small">{t('Was rechnet diese Karte?', 'What does this card compute?')}</div>
          <div className="gpu-role-list">
            {GPU_ROLES.map((r) => {
              const here = gpu.roles.includes(r.id)
              return (
                <button
                  key={r.id}
                  type="button"
                  className={here ? 'gpu-role on' : 'gpu-role'}
                  disabled={here || busy}
                  aria-pressed={here}
                  onClick={() => apply({ [r.id]: gpu.index })}
                >
                  <span className="gpu-role-mark" aria-hidden>{here ? '✓' : ''}</span>
                  <span className="gpu-role-text">
                    <strong>{r.label}</strong>
                    <span className="small">{r.hint}</span>
                  </span>
                  <span className="gpu-role-state">
                    {here ? t('läuft hier', 'runs here') : t('hierher holen', 'move here')}
                  </span>
                </button>
              )
            })}
          </div>
          <button type="button" className="btn small ghost full" disabled={busy}
            onClick={() => apply({ auto: true })}>
            {t('Automatisch: alles auf die stärkste Karte', 'Automatic: everything on the strongest card')}
          </button>
          <div className="muted small gpu-pop-note">
            {t(
              'Jede Aufgabe läuft auf genau einer Karte. Wechseln geht nicht, während ein Auftrag läuft.',
              'Each task runs on exactly one card. Switching is not possible while a job is running.',
            )}
          </div>
        </div>
      )}
    </span>
  )
}
