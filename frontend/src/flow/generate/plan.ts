// Ein Auftrag, wie ihn der große Knopf oder ein nächster Schritt abschickt: die Art (wie /api/estimate sie kennt) und
// genau seine Parameter. Dieselben Parameter gehen in die Schätzung (Konzept „NVAI im Fluss“: „Ehrliche Zeit“), damit
// die Zeit am Knopf zu dem passt, was wirklich läuft.
import {
  api, type Asset, type AudioParams, type ImageParams, type Job, type Mesh3DParams, type ModelInfo, type RestoreParams,
  type SpeechParams, type VideoParams,
} from '../../api'
import type { EstimateItem } from '../estimate'

export type Plan =
  | { kind: 'txt2img'; params: ImageParams }
  | { kind: 'restore'; params: RestoreParams }
  | { kind: 'tts'; params: SpeechParams }
  | { kind: 'txt2audio'; params: AudioParams }
  | { kind: 'txt2video'; params: VideoParams }
  | { kind: 'img23d'; params: Mesh3DParams }
  | { kind: 'video_upscale'; params: { asset_id: string; model_id?: string | null; project_id?: string | null } }
  | { kind: 'face_fix'; params: { asset_id: string; reference_asset_id: string; project_id?: string | null } }

export function sendPlan(p: Plan): Promise<Job> {
  switch (p.kind) {
    case 'txt2img': return api.generateImage(p.params)
    case 'restore': return api.restoreImage(p.params)
    case 'tts': return api.generateSpeech(p.params)
    case 'txt2audio': return api.generateAudio(p.params)
    case 'txt2video': return api.generateVideo(p.params)
    case 'img23d': return api.generate3D(p.params)
    case 'video_upscale': return api.upscaleVideo(p.params)
    case 'face_fix': return api.faceFix(p.params)
  }
}

// Texte ändern die Rechenzeit nicht: ohne sie fragt die Seite nicht bei jedem Tastendruck neu
const TEXT_KEYS = new Set(['prompt', 'negative_prompt', 'text', 'voice', 'voice_text', 'notes', 'audio_prompt'])

/** Platzhalter für eine leere Stelle in einer Liste fester Länge (der Server antwortet mit „keine Zahl“) */
export const NO_ITEM: EstimateItem = { kind: 'none', params: {} }

export function estimateItem(p: Plan | null | undefined): EstimateItem {
  if (!p) return NO_ITEM
  const params: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(p.params as unknown as Record<string, unknown>)) {
    if (!TEXT_KEYS.has(k)) params[k] = v
  }
  return { kind: p.kind, params }
}

/** Parameter eines fertigen Auftrags für einen neuen Lauf desselben Auftrags (Varianten): das Projekt wie beim
 *  Abschicken (der Server speichert es als studio_project), neuer Seed */
export function rerunParams(job: Job, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const { studio_project: project, ...rest } = job.params ?? {}
  return { ...rest, project_id: project ?? null, seed: null, ...extra }
}

/** Ab dieser Kartengröße (GB) schlägt „Final“ die volle Länge vor; darunter gilt die gemessene Grenze final_max_frames
 *  (MiniMax H3 in 1080p auf 16 GB: 73 Bilder in 1090 s, 15,3 GB). Größere Karten sind nicht gemessen. */
export const FINAL_FULL_LENGTH_GB = 23

/** „⇧ Final“ (Nutzer 27.11.2026: „schnell 768, dann 1080 final rechnen, als empfehlung“): derselbe Auftrag im
 *  Finalformat des Modells (features.draft_final) mit dem Seed des Entwurfs; DFR nur, wenn das Modell es gerade kann.
 *  Gibt null zurück, wenn das Video schon im Finalformat ist oder das Modell kein Entwurf/Final kennt; `capped` nennt
 *  die gekürzte Bildzahl, wenn die Karte für die volle Länge in 1080p zu klein ist. */
export function finalPlan(job: Job, asset: Asset, model: ModelInfo | undefined, vramMb: number):
  { plan: Plan; capped: number | null } | null {
  const df = model?.features?.draft_final
  const w = Number(asset.meta?.width) || 0
  if (!df || job.kind !== 'txt2video' || !w || w >= df.final.w) return null
  const frames = Number(job.params?.frames) || 0
  const limit = vramMb / 1024 >= FINAL_FULL_LENGTH_GB ? 0 : df.final_max_frames ?? 0
  const capped = limit && frames > limit ? limit : null
  const quality = df.final.quality === 'dfr' && !model?.features?.dfr ? 'standard' : df.final.quality
  const params = rerunParams(job, {
    width: df.final.w, height: df.final.h, seed: asset.meta?.seed ?? null, recommended: false,
    ...(quality ? { quality } : {}), ...(capped ? { frames: capped } : {}),
  })
  return { plan: { kind: 'txt2video', params: params as unknown as VideoParams }, capped }
}

/** „⟳ Varianten“: derselbe Auftrag noch einmal mit neuem Seed; Bilder und Fotos gleich `count`-mal (Fotos höchstens
 *  4), Ton und Stimme einmal. Andere Arten bieten keine Varianten. */
export function rerunPlan(job: Job, count: number): Plan | null {
  switch (job.kind) {
    case 'txt2img':
      return { kind: 'txt2img', params: rerunParams(job, { batch_size: count }) as unknown as ImageParams }
    case 'restore':
      return { kind: 'restore', params: rerunParams(job, { batch_size: Math.min(4, count) }) as unknown as RestoreParams }
    case 'txt2audio':
      return { kind: 'txt2audio', params: rerunParams(job) as unknown as AudioParams }
    case 'tts':
      return { kind: 'tts', params: rerunParams(job) as unknown as SpeechParams }
    default:
      return null
  }
}
