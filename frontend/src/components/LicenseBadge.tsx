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

/**
 * Modelle, deren Ergebnisse markiert werden (output_badge), nach id. Verlauf und Studio kennen am Asset nur die
 * model_id; einmal laden genügt, ein Fehler lässt die Marken weg.
 */
export function useOutputBadges(): Record<string, ModelInfo> {
  const [byId, setById] = useState<Record<string, ModelInfo>>({})
  useEffect(() => {
    let alive = true
    api
      .models()
      .then((ms) => {
        if (alive) {
          setById(Object.fromEntries(ms.filter((m) => m.output_badge && !m.license_confirmed).map((m) => [m.id, m])))
        }
      })
      .catch(() => {})
    return () => {
      alive = false
    }
  }, [])
  return byId
}
