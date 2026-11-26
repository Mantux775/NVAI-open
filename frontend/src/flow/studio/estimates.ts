// Zeiten im Studio (seit 0.5.42, Konzept „NVAI im Fluss“: „Ein Knopf nennt Aktion und Zeit“): Schätzungen des Servers
// je Szene aus derselben Anfrage wie beim Erzeugen (POST /api/studio/projects/{id}/estimate; der Server baut sie dafür
// nur zur Probe und legt nichts an), dazu der Seed eines Takes für „Seed festhalten“.

import { useEffect, useRef, useState } from 'react'
import { api, type ModelInfo, type StudioProject, type StudioScene } from '../../api'
import { estimateApi, useEstimates, type Estimate } from '../estimate'
import { startImageItems, sumEstimates, type FlowCtx, type TakeInfo } from './logic'

// ------------------------------------------------------------------------------------ Takes aus der Datenbank

const infos = new Map<string, TakeInfo | null>()

/** Seed eines Takes (für „Seed festhalten“); null, wenn er keinen hat */
export async function takeSeed(id: string): Promise<number | null> {
  if (!infos.has(id)) {
    try {
      const a = await api.asset(id)
      const seed = Number(a.meta?.seed)
      const fps = Number(a.meta?.fps)
      infos.set(id, { kind: a.kind, fps: Number.isFinite(fps) && fps > 0 ? fps : null, seed: Number.isFinite(seed) ? seed : null })
    } catch {
      return null
    }
  }
  return infos.get(id)?.seed ?? null
}

// ----------------------------------------------------------------------------------- Schätzungen des Servers

/**
 * Schätzungen des Servers für Szenen eines Projekts; neu gefragt, wenn sich `key` ändert (kurz entprellt). Schlägt die
 * Anfrage fehl, bleibt die letzte Antwort stehen: Ein Knopf ohne Zeit ist besser als ein falscher.
 */
export function useStudioEstimates(pid: string | undefined, ids: string[] | null, key: string, delayMs = 400): Record<string, Estimate> | null {
  const [out, setOut] = useState<Record<string, Estimate> | null>(null)
  const idsRef = useRef(ids)
  idsRef.current = ids
  useEffect(() => {
    const list = idsRef.current
    if (!pid || !list || !list.length) return
    let gone = false
    const timer = window.setTimeout(() => {
      estimateApi.studio(pid, list)
        .then((r) => { if (!gone) setOut((old) => ({ ...(old ?? {}), ...r.scenes })) })
        .catch(() => { /* alte Zahl bleibt */ })
    }, delayMs)
    return () => { gone = true; window.clearTimeout(timer) }
  }, [pid, key, delayMs])
  return out
}

/** Geschätzte Zeit einer Szene, wie „Neu erzeugen“ sie abschicken würde; null ohne verlässliche Zahl */
export function useSceneEstimate(c: FlowCtx, s: StudioScene): Estimate | null {
  const params = s.params ?? {}
  // Was die Zeit ändert: Modell, Länge, Weg und Zusätze, Format des Projekts, die Vorlage eines Anschlusses
  const source = s.chain_from ? c.p.scenes.find((x) => x.id === s.chain_from)?.take : null
  const key = [s.id, s.model_id, s.duration, s.chain_from, source, s.kind, JSON.stringify(params), c.p.settings.width,
    c.p.settings.height, c.p.settings.video_quality, c.models.length].join('|')
  const got = useStudioEstimates(c.p.id, [s.id], key)
  const e = got?.[s.id]
  return e && e.seconds != null ? e : null
}

/** Zeit für „Startbild erzeugen“ (zwei Varianten je Szene) */
export function useStartImageEstimate(p: StudioProject, models: ModelInfo[], scenes: StudioScene[]): number | null {
  const items = startImageItems(p, models, scenes)
  const key = items ? `${JSON.stringify(items[0])}|${items.length}` : ''
  const est = useEstimates(items, key)
  return est ? sumEstimates(est).seconds : null
}
