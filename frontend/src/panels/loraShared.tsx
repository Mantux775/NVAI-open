import { useEffect, useState } from 'react'
import { api, type Asset } from '../api'
import { t } from '../i18n'

// Gemeinsame Teile des Bereichs „LoRA erstellen/Bearbeiten“: Loras.tsx (alles auf einer Seite) und LoraWizard.tsx
// (Assistent in fünf Schritten, seit 17.11.2026).

export type Progress = { progress: number; stage: string }
/** Bildanzeige in voller Größe; mit marks/onMark lässt sich darin aussortieren (Taste 1 behalten, 2 aussortieren) */
export type Viewer = {
  urls: string[]
  labels: string[]
  index: number
  marks?: ('keep' | 'reject')[]
  onMark?: (index: number, status: 'keep' | 'reject') => void
}

export function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  if (s < 90) return `${s} s`
  const m = Math.round(s / 60)
  if (m < 90) return `${m} min`
  return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} min`
}

export function fmtGb(gb: number): string {
  return `${gb.toLocaleString(undefined, { maximumFractionDigits: 1 })} GB`
}

export function fmtTime(ts?: number): string {
  if (!ts) return ''
  return new Date(ts * 1000).toLocaleString(undefined, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })
}

export const STATUS_LABEL: Record<string, string> = {
  scheduled: t('geplant', 'scheduled'),
  queued: t('wartet', 'queued'),
  running: t('läuft', 'running'),
  done: t('fertig', 'done'),
  error: t('Fehler', 'error'),
  cancelled: t('abgebrochen', 'cancelled'),
}

/** Bildanzeige in voller Größe mit Blättern (← →) und Esc; mit marks auch Behalten (1) und Aussortieren (2) */
export function ImageViewer({ viewer, onIndex, onClose }: { viewer: Viewer; onIndex: (i: number) => void; onClose: () => void }) {
  const { urls, labels, index, marks, onMark } = viewer
  const [local, setLocal] = useState(marks)
  useEffect(() => { setLocal(marks) }, [marks])
  const mark = (status: 'keep' | 'reject') => {
    if (!onMark || !local) return
    onMark(index, status)
    setLocal(local.map((m, i) => (i === index ? status : m)))
    if (index < urls.length - 1) onIndex(index + 1)  // gleich zum nächsten Bild
  }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      else if (e.key === 'ArrowRight') onIndex((index + 1) % urls.length)
      else if (e.key === 'ArrowLeft') onIndex((index - 1 + urls.length) % urls.length)
      else if (e.key === '1') mark('keep')
      else if (e.key === '2') mark('reject')
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }) // bei jedem Rendern neu, damit mark den aktuellen Stand sieht
  const current = local?.[index]
  return (
    <div className="lt-viewer" onClick={onClose}>
      <img src={urls[index]} alt={labels[index]} onClick={(e) => e.stopPropagation()}
        className={current === 'reject' ? 'rejected' : undefined} />
      <div className="lt-viewer-bar" onClick={(e) => e.stopPropagation()}>
        <button className="btn small" onClick={() => onIndex((index - 1 + urls.length) % urls.length)}>←</button>
        <span>{labels[index]} · {index + 1}/{urls.length}</span>
        <button className="btn small" onClick={() => onIndex((index + 1) % urls.length)}>→</button>
        {onMark && local && (
          <>
            <button className={`btn small${current !== 'reject' ? ' on' : ''}`} onClick={() => mark('keep')}>
              ✓ {t('Behalten', 'Keep')} <kbd>1</kbd>
            </button>
            <button className={`btn small${current === 'reject' ? ' off' : ''}`} onClick={() => mark('reject')}>
              ✕ {t('Aussortieren', 'Reject')} <kbd>2</kbd>
            </button>
          </>
        )}
        <button className="btn small ghost" onClick={onClose}>{t('Schließen', 'Close')} <kbd>Esc</kbd></button>
      </div>
    </div>
  )
}

/** Bilder aus dem Verlauf wählen (mehrere oder eines); FLUX-3-Bilder sind gesperrt (Lizenz 4(b)) */
export function AssetPicker({ multiple, title, onPick, onClose }: {
  multiple: boolean
  title?: string
  onPick: (ids: string[]) => void
  onClose: () => void
}) {
  const [assets, setAssets] = useState<Asset[]>([])
  const [q, setQ] = useState('')
  const [chosen, setChosen] = useState<string[]>([])
  const [limit, setLimit] = useState(60)
  useEffect(() => {
    const timer = window.setTimeout(() => {
      api.assetPage({ media: 'image', q: q.trim() || undefined, limit, offset: 0 }).then(setAssets).catch(() => setAssets([]))
    }, 250)
    return () => window.clearTimeout(timer)
  }, [q, limit])
  const blocked = (a: Asset) => a.model_id.startsWith('flux3')
  const toggle = (a: Asset) => {
    if (blocked(a)) return
    if (!multiple) { onPick([a.id]); return }
    setChosen((c) => (c.includes(a.id) ? c.filter((x) => x !== a.id) : [...c, a.id]))
  }
  return (
    <div className="lt-modal" onClick={onClose}>
      <div className="lt-modal-box panel" onClick={(e) => e.stopPropagation()}>
        <div className="lt-modal-head">
          <strong>{title ?? (multiple ? t('Bilder aus dem Verlauf', 'Images from the history') : t('Vorlage aus dem Verlauf', 'Template from the history'))}</strong>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('Suchen (Prompt, Dateiname) …', 'Search (prompt, file name) …')} />
          <button className="btn small ghost" onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
          {multiple && (
            <button className="btn small primary" disabled={!chosen.length} onClick={() => onPick(chosen)}>
              {t(`Übernehmen (${chosen.length})`, `Add (${chosen.length})`)}
            </button>
          )}
        </div>
        <p className="hint small">
          {t('Bilder aus FLUX 3 sind gesperrt: Die FLUX Kommunity License verbietet in 4(b), mit ihren Bildern ein anderes Bildmodell zu trainieren.',
            'Images from FLUX 3 are locked: the FLUX Kommunity License forbids in 4(b) training another image model with its images.')}
        </p>
        <div className="lt-pick-grid">
          {assets.map((a) => (
            <button key={a.id} className={`lt-pick${chosen.includes(a.id) ? ' on' : ''}${blocked(a) ? ' blocked' : ''}`}
              title={blocked(a) ? t('FLUX 3: nicht fürs Training anderer Modelle', 'FLUX 3: not for training other models') : a.prompt}
              onClick={() => toggle(a)}>
              <img src={a.thumb_url || a.url} alt="" loading="lazy" />
              <span>{a.filename.split('/').pop()}</span>
            </button>
          ))}
        </div>
        {assets.length >= limit && (
          <button className="btn small" onClick={() => setLimit((l) => l + 60)}>{t('Mehr laden', 'Load more')}</button>
        )}
      </div>
    </div>
  )
}

export function CaptionField({ value, onSave }: { value: string; onSave: (v: string) => void }) {
  const [text, setText] = useState(value)
  return (
    <textarea rows={2} value={text} onChange={(e) => setText(e.target.value)} onBlur={() => { if (text.trim() !== value) onSave(text) }}
      placeholder={t('Bildbeschreibung', 'Caption')} />
  )
}
