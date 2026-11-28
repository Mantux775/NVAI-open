// Konzept „NVAI im Fluss“, Bildschirm B („Generieren: der Weg bestimmt die Felder“): ein Weg statt sieben Klappen für
// Endbild, Schleife, DFR, 48 fps, Layout, Verlängern und Ton. Der Weg legt fest, welche Felder es gibt und welche
// Qualitäten und Zusätze dazu passen. Die Regeln spiegeln den Server (jobs._check_video_options, _prepare_layout,
// _prepare_extension, _carry_possible): Was nicht zum Weg passt, erscheint nicht und geht nicht mit in den Auftrag, statt
// dass der Server ihn ablehnt.
import type { ModelInfo } from '../../api'
import { t } from '../../i18n'
import { startImageUse } from '../../videoStart'

export type VideoWay = 'text' | 'refs' | 'start' | 'ends' | 'loop' | 'layout' | 'extend'

export interface WayRules {
  /** Startbild: Pflicht, freiwillig oder gar nicht */
  start: 'required' | 'optional' | 'none'
  /** Höchste Qualität (DFR) wählbar, damit auch 48 fps */
  dfr: boolean
  /** Ton vorgeben */
  audio: boolean
  /** Länge automatisch */
  auto: boolean
  /** Mehrere Einstellungen (Multishot) */
  multishot: boolean
  /** Zeitlupe */
  motion: boolean
}

const RULES: Record<VideoWay, WayRules> = {
  text: { start: 'none', dfr: true, audio: true, auto: true, multishot: true, motion: true },
  // Referenz-Modelle (MiniMax H3 Ref2VA, VACE): die Szene entsteht aus dem Text, die Zusätze gibt es nur bei LTX-2.5
  refs: { start: 'none', dfr: false, audio: false, auto: false, multishot: false, motion: false },
  start: { start: 'required', dfr: true, audio: true, auto: true, multishot: true, motion: true },
  // Endbild und Schleife rechnen eine Stufe in voller Auflösung: kein DFR (jobs._check_video_options); das Endbild hält
  // die Einstellung, mehrere Einstellungen passen nicht dazu
  ends: { start: 'optional', dfr: false, audio: true, auto: true, multishot: false, motion: true },
  loop: { start: 'required', dfr: false, audio: true, auto: true, multishot: false, motion: true },
  // Layout: nicht mit DFR, Endbild, Schleife, Ton oder Verlängern; die Länge kommt vom Layout (jobs._prepare_layout)
  layout: { start: 'optional', dfr: false, audio: false, auto: false, multishot: false, motion: true },
  // Verlängern: kein eigenes Startbild, keine Schleife, kein Ton; mit „Länge automatisch“ trüge nur das letzte Bild über
  // statt der letzten Sekunde (jobs._carry_possible)
  extend: { start: 'none', dfr: true, audio: false, auto: false, multishot: true, motion: true },
}

export function wayRules(w: VideoWay): WayRules {
  return RULES[w]
}

type VideoModel = Pick<ModelInfo, 'family' | 'workflow' | 'features'>

/** Die Wege, die das Modell kann, in der Reihenfolge des Konzepts. T2V-Modelle ohne Startbild, I2V-Modelle ohne „Nur
 *  Text“, Referenz-Modelle nur mit Referenzbildern. Das Layout-Video erscheint auch, wenn seine LoRA noch fehlt: dann
 *  steht dort, wie man sie lädt. */
export function videoWays(m: VideoModel | undefined): VideoWay[] {
  if (!m) return ['text']
  const f = m.features ?? {}
  const use = startImageUse(m)
  const ltx = m.family === 'ltx25'
  const out: VideoWay[] = []
  if ((f.references ?? 0) > 0 && !use) out.push('refs')
  else if (use !== 'required') out.push('text')
  if (use) out.push('start')
  if (ltx && f.end_image) out.push('ends')
  if (ltx && use && (f.loop ?? f.end_image)) out.push('loop')
  if (ltx && (f.layout || f.missing?.layout)) out.push('layout')
  if (ltx) out.push('extend')
  return out
}

export function wayLabel(w: VideoWay): string {
  switch (w) {
    case 'text': return t('Nur Text', 'Text only')
    case 'refs': return t('Mit Referenzbildern', 'With reference images')
    case 'start': return t('Mit Startbild', 'With start image')
    case 'ends': return t('Start und Ende', 'Start and end')
    case 'loop': return t('Schleife', 'Loop')
    case 'layout': return t('Layout-Video', 'Layout video')
    case 'extend': return t('Verlängern', 'Extend')
  }
}

/** Kurzer Hinweis je Weg (Texte aus dem Konzept); ausführlich steht es im Tooltip (wayDetail) */
export function wayNote(w: VideoWay, opts: { ltx: boolean; dfr: boolean }): string {
  switch (w) {
    case 'text':
      return opts.ltx && opts.dfr
        ? t('Reines Text-zu-Video. DFR und 48 fps stehen zur Wahl.', 'Pure text to video. DFR and 48 fps are available.')
        : t('Reines Text-zu-Video.', 'Pure text to video.')
    case 'refs':
      return t('Die Referenzbilder geben Figur, Gesicht oder Stil vor; die Szene entsteht aus dem Text, ohne Startbild.',
        'The reference images set the character, face or style; the scene comes from the text, without a start image.')
    case 'start':
      return t('Im Prompt nur die Bewegung beschreiben, auch die im Hintergrund (Wasser, Rauch, Lichter), sonst steht er '
        + 'still; das Format folgt dem Startbild.',
        'Describe only the motion in the prompt, including the background (water, smoke, lights), or it stands still; '
          + 'the format follows the start image.')
    case 'ends':
      return t('Das Endbild hält Kamera und Gesicht. DFR entfällt bei diesem Weg.',
        'The end image holds camera and face. DFR is not available on this path.')
    case 'loop':
      return t('Nur mit ruhiger Kamera; Wasser und Rauch stehen dann still. DFR entfällt.',
        'Only with a still camera; water and smoke then stand still. No DFR.')
    case 'layout':
      return t('Kamera und Bewegung kommen aus dem Layout. DFR, Endbild und Ton vorgeben entfallen.',
        'Camera and motion come from the layout. DFR, end image and given sound are not available.')
    case 'extend':
      return t('Die letzte Sekunde trägt über; Gesicht und Licht bleiben.',
        'The last second carries over; face and light stay.')
  }
}

/** Die ausführlichen, gemessenen Hinweise der früheren Klappen, als Tooltip des Hinweises */
export function wayDetail(w: VideoWay): string {
  switch (w) {
    case 'ends':
      return t('Mit Endbild läuft das Video vom Startbild zum Endbild (Übergang). Eine Stufe in voller Auflösung, '
        + 'deshalb langsamer als ohne. Was in beiden Bildern gleich ist, steht dazwischen still (Wasser und Rauch im Test '
        + 'wie das Ufer); für bewegten Hintergrund ohne Endbild.',
      'With an end image the video runs from the start image to the end image (a transition). One stage at full '
        + 'resolution, so slower than without. Whatever is the same in both images stands still in between (water and '
        + 'smoke as still as the shore in the test); for a moving background, leave it out.')
    case 'loop':
      return t('Die Kamera ruhig lassen, mit Kamerafahrt zerfiel im Test der Schluss. Mit Schleife bewegt sich nur die '
        + 'beschriebene Handlung: Wasser und Rauch standen so still wie das Ufer, auch wenn der Prompt sie bewegen sollte.',
      'Keep the camera still, with a camera move the ending fell apart in the test. With a loop only the described '
        + 'action moves: water and smoke stood as still as the shore, even when the prompt asked them to move.')
    case 'layout':
      return t('Eine grobe Ton- oder Klötzchen-Animation, etwa aus Blender mit 24 fps, gibt Kamera, Bewegung und Lage der '
        + 'Dinge vor. Als erstes Bild ein Bild wählen, das aus dem ersten Bild des Layouts gemalt ist, nicht das graue Bild '
        + 'selbst: Es gibt Look, Licht und Material. Ohne Ton, höchstens so lang wie das Layout.',
      'A rough clay or blocky animation, for example from Blender at 24 fps, sets the camera, the motion and where '
        + 'things sit. As the first image pick a picture painted from the first frame of the layout, not the grey frame '
        + 'itself: it sets the look, light and materials. No sound, at most as long as the layout.')
    case 'extend':
      return t('Die letzte Sekunde des Videos steht fest am Anfang des neuen Stücks, es setzt die Bewegung fort und wird '
        + 'mit einer Überblendung über diese Sekunde angehängt (Latent-Kette, seit 0.5.17; im Test ragte die Naht nicht '
        + 'mehr heraus). Format und Bildrate kommen vom Video. Der Prompt beschreibt, was als Nächstes passiert; die Länge '
        + 'gilt für das neue Stück.',
      'The last second of the video is pinned at the start of the new part, which continues the motion and is appended '
        + 'with a crossfade over that second (latent chain, since 0.5.17; in our test the seam no longer stood out). '
        + 'Size and frame rate come from the video. The prompt describes what happens next; the length applies to the '
        + 'new part.')
    case 'start':
      return t('Mit Startbild wird daraus Bild-zu-Video. Das Format wird beim Wählen des Startbilds auf das nächste '
        + 'passende Seitenverhältnis gestellt; danach gilt, was du einstellst.',
      'With a start image this becomes image-to-video. Choosing a start image sets the format to the closest matching '
        + 'aspect ratio; after that, what you set applies.')
    default:
      return ''
  }
}

/** 8n+1 Bilder, die nächsten zu `seconds` (wie workflows.ltx_frames_for_seconds: 5 s = 121), höchstens 481 */
export function ltxFramesFor(seconds: number, fps: number, maxSeconds = 20): number {
  const max = Math.min(maxSeconds, Math.floor(480 / fps))
  return Math.max(9, Math.min(481, 1 + Math.floor((Math.min(seconds, max) * fps - 1) / 8 + 0.5) * 8))
}

/** Aus einer Liste von Formaten das mit dem nächsten Seitenverhältnis; bei gleich gutem das mit der Fläche nahe `near` */
export function closestSize<S extends { w: number; h: number }>(sizes: S[], aspect: number,
  near?: { w: number; h: number }): S | undefined {
  let best: S | undefined
  let bestA = Infinity
  let bestB = Infinity
  for (const s of sizes) {
    const a = Math.abs(Math.log(s.w / s.h / aspect))
    const b = near ? Math.abs(Math.log((s.w * s.h) / (near.w * near.h))) : 0
    if (a < bestA - 0.02 || (Math.abs(a - bestA) <= 0.02 && b < bestB)) {
      best = s
      bestA = a
      bestB = b
    }
  }
  return best
}

/** Weicht das Seitenverhältnis spürbar ab (mehr als rund 6 %)? */
export function aspectDiffers(a: { w: number; h: number }, aspect: number, tolerance = 0.06): boolean {
  return Math.abs(Math.log(a.w / a.h / aspect)) > tolerance
}

/** Rand fürs Erweitern auf ein Seitenverhältnis (links, oben, rechts, unten), auf 8 px gerundet; null, wenn das Bild
 *  schon passt oder das Ergebnis die Grenzen des Servers sprengt (je Seite 1024, zusammen 2560) */
export function padToAspect(w: number, h: number, aspect: number): [number, number, number, number] | null {
  if (!w || !h || !aspectDiffers({ w, h }, aspect, 0.03)) return null
  let pad: [number, number, number, number]
  if (w / h < aspect) {
    const add = Math.round((h * aspect) / 16) * 16 - w
    const left = Math.round(add / 2 / 8) * 8
    pad = [left, 0, Math.max(0, add - left), 0]
  } else {
    const add = Math.round((w / aspect) / 16) * 16 - h
    const top = Math.round(add / 2 / 8) * 8
    pad = [0, top, 0, Math.max(0, add - top)]
  }
  const [l, tp, r, b] = pad
  if (Math.max(l, tp, r, b) > 1024 || w + l + r > 2560 || h + tp + b > 2560) return null
  return pad
}
