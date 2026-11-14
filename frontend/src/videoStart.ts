// Welche Videomodelle ein Startbild brauchen oder nehmen; gemeinsam für den Reiter „Generieren“ und die Eigenschaften
// einer Videoszene im Studio (Feld „Startbild“ seit 0.5.27).

import type { ModelInfo } from './api'

/** Video-Workflows, die ohne Startbild nicht laufen (siehe workflows.py). */
export const I2V_WORKFLOWS = new Set(['wan_i2v', 'wan22_i2v', 'hunyuan15_i2v', 'kandinsky5_i2v'])
/** Diese nehmen ein Startbild, wenn eines gewählt ist, sonst Text zu Video (workflows.OPTIONAL_START_WORKFLOWS). */
export const OPTIONAL_START_WORKFLOWS = new Set(['wan22_ti2v', 'ltx25', 'ltx23'])

/** „required“: ohne Startbild läuft das Modell nicht; „optional“: es nimmt eines, wenn gewählt; null: es nimmt keins. */
export function startImageUse(m: Pick<ModelInfo, 'workflow' | 'features'>): 'required' | 'optional' | null {
  if (I2V_WORKFLOWS.has(m.workflow ?? '')) return 'required'
  if (OPTIONAL_START_WORKFLOWS.has(m.workflow ?? '') || m.features?.start_image === 'optional') return 'optional'
  return null
}
