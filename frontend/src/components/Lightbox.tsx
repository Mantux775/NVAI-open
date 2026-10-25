import { useEffect, useState } from 'react'
import { api, type Asset } from '../api'
import { t } from '../i18n'

/**
 * Große Ansicht der Ergebnisbilder (Nutzerwunsch 25.10.2026: Ergebnisse anklicken können). Blättern mit den
 * Pfeiltasten oder Knöpfen, schließen mit Esc oder Klick aufs Bild bzw. daneben. Restaurierte Fotos tragen
 * meta.source_asset_id: Dann zeigt „Original“ das Foto davor an derselben Stelle, zum Vergleichen der
 * Gesichter in voller Größe (die Varianten fallen je Seed etwas anders aus).
 */
export function Lightbox({ assets, index, onIndex, onClose }: {
  assets: Asset[]
  index: number
  onIndex: (i: number) => void
  onClose: () => void
}) {
  const asset = assets[index]
  const sourceId = typeof asset?.meta.source_asset_id === 'string' ? asset.meta.source_asset_id : ''
  const [original, setOriginal] = useState<Asset | null>(null)
  const [showOriginal, setShowOriginal] = useState(false)

  useEffect(() => {
    setOriginal(null)
    if (!sourceId) return
    let alive = true
    api.asset(sourceId).then((a) => alive && setOriginal(a)).catch(() => undefined)
    return () => {
      alive = false
    }
  }, [sourceId])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      else if (e.key === 'ArrowRight' && index < assets.length - 1) onIndex(index + 1)
      else if (e.key === 'ArrowLeft' && index > 0) onIndex(index - 1)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [index, assets.length, onIndex, onClose])

  if (!asset) return null
  const shown = showOriginal && original ? original : asset
  return (
    <div className="lightbox" onClick={onClose}>
      <img src={shown.url} alt={shown.prompt} />
      <div className="lightbox-meta" onClick={(e) => e.stopPropagation()}>
        <p>
          {showOriginal && original ? t('Original', 'Original') : asset.prompt}
          {assets.length > 1 && <span className="muted"> · {index + 1}/{assets.length}</span>}
        </p>
        <p className="muted small">
          {asset.model_id} · seed {String(asset.meta.seed ?? '?')}
          {asset.meta.width ? ` · ${asset.meta.width} × ${asset.meta.height}` : ''}
        </p>
        <div className="lightbox-actions">
          {assets.length > 1 && (
            <button className="btn small ghost" disabled={index === 0} onClick={() => onIndex(index - 1)}
              title={t('Vorheriges (Pfeil links)', 'Previous (left arrow)')}>
              ←
            </button>
          )}
          {original && (
            <button className={showOriginal ? 'btn small' : 'btn small ghost'}
              onClick={() => setShowOriginal((v) => !v)}
              title={t('Zwischen Original und Ergebnis umschalten', 'Switch between original and result')}>
              {showOriginal ? t('Ergebnis zeigen', 'Show result') : t('Original zeigen', 'Show original')}
            </button>
          )}
          <a className="btn small" href={asset.url} download>
            {t('Herunterladen', 'Download')}
          </a>
          {assets.length > 1 && (
            <button className="btn small ghost" disabled={index === assets.length - 1}
              onClick={() => onIndex(index + 1)} title={t('Nächstes (Pfeil rechts)', 'Next (right arrow)')}>
              →
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
