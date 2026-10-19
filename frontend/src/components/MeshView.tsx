import { createElement, useEffect, useRef, useState } from 'react'
import type { Asset } from '../api'
import { locale, t } from '../i18n'

/** GLB-Vorschau über <model-viewer>.
 *
 *  Das Paket wiegt rund 1 MB und wird deshalb erst geladen, wenn wirklich ein
 *  Mesh angezeigt werden soll. Das Element wird per createElement erzeugt —
 *  so braucht es keine JSX-Typdeklaration für ein Custom Element.
 *
 *  Fehler werden im Klartext angezeigt: Ein stummes „geht nicht" ist beim
 *  Debuggen wertlos, und die Ursachen sind vielfältig (Chunk nicht geladen,
 *  Custom Element nicht registriert, GLB nicht parsebar).
 */
export function MeshView({ asset }: { asset: Asset }) {
  const [state, setState] = useState<'laden' | 'bereit' | 'fehler'>('laden')
  const [detail, setDetail] = useState<string>('')
  const hostRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    let alive = true

    const load = async () => {
      try {
        // Schon registriert? Dann nicht erneut importieren.
        if (!customElements.get('model-viewer')) {
          await import('@google/model-viewer')
          // Die Registrierung passiert asynchron zum Modul-Import.
          await customElements.whenDefined('model-viewer')
        }
        if (alive) setState('bereit')
      } catch (e) {
        if (!alive) return
        setDetail(e instanceof Error ? `${e.name}: ${e.message}` : String(e))
        setState('fehler')
      }
    }
    load()

    return () => {
      alive = false
    }
  }, [])

  // Ladefehler des Modells selbst meldet <model-viewer> per Event.
  useEffect(() => {
    const host = hostRef.current
    if (!host || state !== 'bereit') return
    const el = host.firstElementChild
    if (!el) return

    const onError = (ev: Event) => {
      const d = (ev as CustomEvent).detail
      setDetail(
        d?.sourceError?.message ??
          d?.type ??
          t('Modell konnte nicht geladen werden', 'Model could not be loaded'),
      )
      setState('fehler')
    }
    el.addEventListener('error', onError)
    return () => el.removeEventListener('error', onError)
  }, [state, asset.url])

  const meta = asset.meta ?? {}

  const viewer =
    state === 'bereit'
      ? createElement('model-viewer', {
          src: asset.url,
          alt: asset.prompt || asset.filename,
          'camera-controls': '',
          'auto-rotate': '',
          'shadow-intensity': '0.4',
          'environment-image': 'neutral',
          'touch-action': 'pan-y',
          style: {
            width: '100%',
            height: '340px',
            background: '#0d1013',
            borderRadius: '8px',
          },
        })
      : null

  return (
    <div className="asset mesh">
      {state === 'fehler' ? (
        <div className="mesh-error">
          <strong>{t('3D-Vorschau nicht möglich', '3D preview not available')}</strong>
          {detail && <div className="muted small">{detail}</div>}
          <div className="muted small">
            {t(
              'Die Datei selbst ist davon unberührt — sie lässt sich herunterladen und in '
                + 'Blender oder Unity öffnen.',
              'The file itself is not affected — you can download it and open it in '
                + 'Blender or Unity.',
            )}
          </div>
        </div>
      ) : state === 'laden' ? (
        <div className="placeholder small">{t('3D-Vorschau lädt…', 'Loading 3D preview…')}</div>
      ) : null}

      <div ref={hostRef}>{viewer}</div>

      <div className="mesh-meta muted small">
        <span>
          {meta.faces ? `${Number(meta.faces).toLocaleString(locale())} Faces` : ''}
          {meta.vertices ? ` · ${Number(meta.vertices).toLocaleString(locale())} Vertices` : ''}
          {meta.specks_removed
            ? t(
                ` · ${meta.specks_removed} Splitter entfernt`,
                ` · ${meta.specks_removed} loose fragments removed`,
              )
            : ''}
          {meta.seconds ? ` · ${meta.seconds} s` : ''}
        </span>
        <a className="btn small" href={asset.url} download>
          {t('GLB herunterladen', 'Download GLB')}
        </a>
      </div>
    </div>
  )
}
