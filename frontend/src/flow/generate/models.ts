// Welches Modell eine Art oder ein nächster Schritt braucht, und welches noch fehlt (Konzept „NVAI im Fluss“: „Fehlendes
// an Ort und Stelle“). Bevorzugt werden die Familien, die gemessen am besten sind, in der für diese Karte empfohlenen
// Fassung (ModelInfo.recommended: NVFP4 auf RTX 50, sonst INT8).
import type { ModelInfo } from '../../api'

export type GenMode = 'image' | 'audio' | 'speech' | 'video' | '3d' | 'restore'

/** Bevorzugte Familien je Reiter, die beste zuerst (die vier Favoriten bei Bildern, LTX-2.5 bei Video) */
export const MODE_FAMILIES: Record<GenMode, string[]> = {
  image: ['qwenimage', 'flux3', 'krea2', 'moss_image'],
  video: ['ltx25'],
  audio: ['stable_audio3', 'stable_audio'],
  speech: ['qwen3_tts'],
  '3d': ['triposg', 'trellis2'],
  restore: ['flux3'],
}

/** Passt das Modell zum Reiter? Restaurieren nimmt Bildmodelle, die per Referenzbild bearbeiten (keine Stilvorlagen). */
export function fitsMode(m: ModelInfo, mode: GenMode): boolean {
  if (mode === 'restore') {
    return m.kind === 'image' && (m.features?.references ?? 0) > 0 && m.features?.reference_kind !== 'style'
  }
  return m.kind === mode
}

/** Das geladene, lauffähige Modell, das `pred` erfüllt: zuerst bevorzugte Familien in empfohlener Fassung */
export function pickRunnable(models: ModelInfo[], pred: (m: ModelInfo) => boolean, families: string[] = []):
  ModelInfo | undefined {
  const c = models.filter((m) => pred(m) && m.runnable && m.usable !== false)
  for (const fam of families) {
    const hit = c.find((m) => m.family === fam && m.recommended) ?? c.find((m) => m.family === fam)
    if (hit) return hit
  }
  return c.find((m) => m.recommended) ?? c[0]
}

/** Das noch nicht geladene Modell der bevorzugten Familien, das `pred` erfüllt (angefangene Downloads zuerst nach der
 *  empfohlenen Fassung); keins, wenn von der Familie schon eine Fassung da ist */
export function pickMissing(models: ModelInfo[], pred: (m: ModelInfo) => boolean, families: string[]):
  ModelInfo | undefined {
  for (const fam of families) {
    const c = models.filter((m) => pred(m) && m.family === fam && m.usable !== false && !m.custom)
    if (!c.length || c.some((m) => m.installed)) continue
    const hit = c.find((m) => m.recommended) ?? c.find((m) => m.partially_installed) ?? c[0]
    if (hit) return hit
  }
  return undefined
}

/** Fehlende Modelle für die Modellwahl eines Reiters: je bevorzugter Familie die passende Fassung, solange von der Familie
 *  noch keine geladen ist */
export function missingChoices(models: ModelInfo[], mode: GenMode): ModelInfo[] {
  const out: ModelInfo[] = []
  for (const fam of MODE_FAMILIES[mode]) {
    const hit = pickMissing(models, (m) => fitsMode(m, mode), [fam])
    if (hit) out.push(hit)
  }
  return out
}

/** Art des Auftrags (Job.kind) → Reiter, in dem er hingehört */
export const MODE_OF_KIND: Record<string, GenMode> = {
  txt2img: 'image', img2img: 'image', txt2video: 'video', img2video: 'video', video_upscale: 'video',
  txt2audio: 'audio', tts: 'speech', img23d: '3d', restore: 'restore',
}
