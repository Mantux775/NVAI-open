import type { Asset } from '../api'
import { MeshView } from './MeshView'

/** Einheitliche Vorschau fuer alle Asset-Typen. Audio und Video bekommen
 *  native Player -- WEBM/VP9 und MP3 laufen in jedem aktuellen Browser. */
export function AssetView({ asset, compact = false }: { asset: Asset; compact?: boolean }) {
  if (asset.kind === 'audio') {
    return (
      <div className="asset audio">
        <div className="waveform-hint">
          <span className="icon">♪</span>
          <span className="muted small">
            {asset.meta.seconds ? `${asset.meta.seconds} s` : ''} {asset.meta.model_name ?? ''}
          </span>
        </div>
        <audio controls preload="metadata" src={asset.url} />
      </div>
    )
  }

  if (asset.kind === 'video') {
    return (
      <div className="asset video">
        <video
          controls
          loop
          muted
          playsInline
          preload="metadata"
          src={asset.url}
          poster={asset.thumb_url ?? undefined}
        />
        {!compact && (
          <div className="muted small">
            {asset.meta.width}×{asset.meta.height} · {asset.meta.frames} Frames ·{' '}
            {asset.meta.fps} fps · {asset.meta.duration_s} s
          </div>
        )}
      </div>
    )
  }

  if (asset.kind === 'mesh') {
    return <MeshView asset={asset} />
  }

  return (
    <div className="asset image">
      <img src={asset.url} alt={asset.prompt} loading="lazy" />
    </div>
  )
}
