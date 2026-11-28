import { useEffect, useState } from 'react'
import { api, type ModelInfo } from '../api'

type Licensed = Pick<ModelInfo, 'license_badge' | 'license_confirmed' | 'warning'>

/** Harte Lizenzgrenze, für die der Nutzer noch keine eigene Genehmigung bestätigt hat: dann Warnung und Marken. */
export function licenseBlocked(model?: Pick<ModelInfo, 'license_badge' | 'license_confirmed'> | null): boolean {
  return !!model?.license_badge && !model.license_confirmed
}

/**
 * Rote Marke am Modell mit harter Lizenzgrenze (license_badge im Katalog, z. B. ganze Länder ausgeschlossen).
 * Der volle Warntext hängt im Tooltip; wo das Modell gewählt wird, steht er zusätzlich als Banner.
 */
export function LicenseBadge({ model }: { model?: Licensed | null }) {
  if (!model || !licenseBlocked(model)) return null
  return (
    <span className="badge error" title={model.warning}>
      {model.license_badge}
    </span>
  )
}

/** Rote Marke an einem Ergebnis, dessen Modell output_badge setzt (z. B. „Nicht veröffentlichen“). */
export function OutputBadge({ model }: { model?: Pick<ModelInfo, 'output_badge' | 'license_confirmed' | 'warning'> | null }) {
  if (!model?.output_badge || model.license_confirmed) return null
  return (
    <span className="badge error output-badge" title={model.warning}>
      {model.output_badge}
    </span>
  )
}

/** Ereignis nach einer Änderung am Lizenzhaken (Modelle): alle Marken neu prüfen */
export const LICENSES_CHANGED = 'nvai-licenses-changed'

/**
 * Modelle, deren Ergebnisse markiert werden (output_badge, Lizenz nicht bestätigt), nach id. Wird bei jeder Änderung
 * am Lizenzhaken und beim Zurückkehren ins Fenster neu geladen (Nutzer 27.11.: „es sollte immer wieder überprüft
 * werden“; vorher einmal je Ansicht, die Marken blieben nach dem Haken bis zum Neuladen). Ein Fehler lässt die
 * Marken, wie sie sind.
 */
export function useOutputBadges(): Record<string, ModelInfo> {
  const [byId, setById] = useState<Record<string, ModelInfo>>({})
  useEffect(() => {
    let alive = true
    const load = () => {
      api
        .models()
        .then((ms) => {
          if (alive) {
            setById(Object.fromEntries(ms.filter((m) => m.output_badge && !m.license_confirmed).map((m) => [m.id, m])))
          }
        })
        .catch(() => {})
    }
    const onVisible = () => {
      if (document.visibilityState === 'visible') load()
    }
    load()
    window.addEventListener(LICENSES_CHANGED, load)
    window.addEventListener('focus', load)
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive = false
      window.removeEventListener(LICENSES_CHANGED, load)
      window.removeEventListener('focus', load)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [])
  return byId
}

/** Marke eines Assets: das eigene Modell oder die Herkunft (meta.badge_model: hochgerechnet, exportiert, bearbeitet) */
export function badgeOf(byId: Record<string, ModelInfo>, a?: { model_id?: string; meta?: Record<string, any> } | null) {
  if (!a) return undefined
  return byId[a.model_id ?? ''] ?? (a.meta?.badge_model ? byId[a.meta.badge_model] : undefined)
}
