// Geschätzte Rechenzeiten vom Server (seit 0.5.42, server/nvai/estimate.py): aus eigenen Läufen auf diesem Rechner,
// sonst aus den Referenzmessungen und dem Hardware-Katalog. Ein Hook bündelt die Anfragen einer Seite.
import { useEffect, useRef, useState } from 'react'
import { req } from '../api'
import { t } from '../i18n'

export interface Estimate {
  /** Rechenzeit in Sekunden; null = keine Zahl (etwa auf dem Prozessor) */
  seconds: number | null
  source: 'history' | 'estimate' | 'rough' | 'unknown'
  runs: number
  /** Was nur jetzt noch anfällt: GPU-Backend starten, Modell laden (Sekunden) */
  cold: { start?: number; load?: number }
  model_id?: string | null
  /** Studio: Art des Auftrags der Szene */
  kind?: string
  /** Studio: die Szene lässt sich so noch nicht erzeugen (Text des Servers) */
  error?: string
}

export interface EstimateItem {
  kind: string
  params: Record<string, unknown>
}

export const estimateApi = {
  many: (items: EstimateItem[]) =>
    req<{ items: Estimate[] }>('/api/estimate', { method: 'POST', body: JSON.stringify({ items }) }),
  studio: (projectId: string, sceneIds?: string[] | null) =>
    req<{ scenes: Record<string, Estimate> }>(`/api/studio/projects/${projectId}/estimate`, {
      method: 'POST', body: JSON.stringify({ scene_ids: sceneIds ?? null }),
    }),
}

/** Rechenzeit samt Start und Laden, wenn sie anfallen */
export function totalSeconds(e: Estimate | null | undefined, withCold = true): number | null {
  if (!e || e.seconds == null) return null
  return e.seconds + (withCold ? (e.cold.start ?? 0) + (e.cold.load ?? 0) : 0)
}

/** Woher die Zahl kommt, für den Tooltip */
export function sourceText(e: Estimate | null | undefined): string {
  if (!e) return ''
  const base = {
    history: t(`gemessen bei dir (${e.runs} Läufe)`, `measured here (${e.runs} runs)`),
    estimate: t('geschätzt aus Messungen auf einer RTX 5060 Ti', 'estimated from measurements on an RTX 5060 Ti'),
    rough: t('grob geschätzt', 'rough estimate'),
    unknown: t('keine Messung', 'not measured'),
  }[e.source]
  const cold = (e.cold.start ?? 0) + (e.cold.load ?? 0)
  return cold > 0
    ? base + t(`; dazu einmalig ≈ ${Math.round(cold)} s für Start und Laden`, `; plus ≈ ${Math.round(cold)} s once to start and load`)
    : base
}

/**
 * Schätzungen für mehrere Aufträge einer Seite; neu gefragt, wenn sich `key` ändert (kurz entprellt). Schlägt die
 * Anfrage fehl, bleibt die letzte Antwort stehen: Ein Knopf ohne Zeit ist besser als ein falscher.
 */
export function useEstimates(items: EstimateItem[] | null, key: string, delayMs = 350): Estimate[] | null {
  const [out, setOut] = useState<Estimate[] | null>(null)
  const itemsRef = useRef(items)
  itemsRef.current = items
  useEffect(() => {
    const list = itemsRef.current
    if (!list || list.length === 0) {
      setOut(null)
      return
    }
    let gone = false
    const timer = window.setTimeout(() => {
      estimateApi.many(list).then((r) => { if (!gone) setOut(r.items) }).catch(() => { /* alte Zahl bleibt */ })
    }, delayMs)
    return () => { gone = true; window.clearTimeout(timer) }
  }, [key, delayMs])
  return out
}
