// Studio im Fluss (seit 0.5.42, Konzept „NVAI im Fluss“, Bildschirme D und E): Zustand je Szene, Weg einer Videoszene
// und der nächste Schritt des Projekts, abgeleitet aus dem Projektmodell (Szenen mit Bahn und Art, Takes, Startbilder,
// Anschlüsse, Clips im Schnitt, Export). Reine Funktionen; die Oberfläche steht in FlowBar.tsx und SceneFocus.tsx.
// Jeder Bildschirm beantwortet „Was passiert gerade? Was fehlt noch? Was kommt als Nächstes?“.

import { TPS, type Asset, type ModelInfo, type StudioProject, type StudioScene } from '../../api'
import type { Downloads } from '../../downloads'
import { t } from '../../i18n'
import { decimal, sec, snapFrame } from '../../studio/time'
import { startImageUse } from '../../videoStart'
import type { Estimate } from '../estimate'

export type Tone = 'ok' | 'info' | 'warn' | 'err' | ''

/** „Startbild erzeugen“ einer Szene: zwei Varianten, die erste wird das Startbild (studio.submit_start_image). Gehört
 *  dem Studio, nicht den Eigenschaften: Der Auftrag läuft weiter, wenn man eine andere Szene wählt. */
export interface StartRun {
  pid: string
  job: string
  /** Startbild beim Abschicken: ersetzt wird nur, wenn inzwischen kein anderes gewählt wurde */
  before: string | null
  status: 'running' | 'done' | 'error'
  variants: Asset[]
  error?: string
}

/** Was das Studio den Eigenschaften einer Szene mitgibt (Bildschirm E) */
export interface SceneFlow {
  startRuns: Record<string, StartRun>
  onStartImages: (sceneIds: string[]) => void
  /** Nur diese Szenen in den Schnitt legen (fragt wie „Übernehmen“ nach, wenn Vorhandenes betroffen ist) */
  onConform: (sceneIds: string[]) => void
  /** Fortschritt (0 bis 1) des laufenden Auftrags einer Szene, null = unbekannt */
  progressOf: (s: StudioScene) => number | null
  downloads?: Downloads
  /** Ein Feld nach einem Klick auf den großen Knopf in den Blick holen (n zählt hoch) */
  focus?: { scene: string; field: FocusField; n: number } | null
}

export type FocusField = 'prompt' | 'takes' | 'model' | 'state' | 'way'

export interface FlowCtx {
  p: StudioProject
  models: ModelInfo[]
  active?: Partial<Record<string, string | null>>
  startRuns: Record<string, StartRun>
  progress: (s: StudioScene) => number | null
}

// ----------------------------------------------------------------------------------------------- Benennen

const LANE_ORDER = ['video', 'voice', 'music', 'sfx']

/** Bildszenen nach ihrem Start, danach Sprecher, Musik und Klang */
export function sceneOrder(p: StudioProject): StudioScene[] {
  return [...p.scenes].sort((a, b) => LANE_ORDER.indexOf(a.lane) - LANE_ORDER.indexOf(b.lane) || a.start - b.start)
}

/** Nummer einer Bildszene (1, 2, 3 …) bzw. Bahn und Nummer einer Tonszene („Sprecher 2“, bei nur einer „Musik“) */
export function sceneNum(p: StudioProject, id: string | null | undefined): string {
  const s = p.scenes.find((x) => x.id === id)
  if (!s) return '?'
  const same = p.scenes.filter((x) => x.lane === s.lane).sort((a, b) => a.start - b.start)
  const n = same.findIndex((x) => x.id === s.id) + 1
  if (s.lane === 'video') return String(n)
  const one = same.length === 1
  if (s.lane === 'voice') return one ? t('Sprecher', 'Voice') : t(`Sprecher ${n}`, `Voice ${n}`)
  if (s.lane === 'music') return one ? t('Musik', 'Music') : t(`Musik ${n}`, `Music ${n}`)
  return one ? t('Klang', 'Sound') : t(`Klang ${n}`, `Sound ${n}`)
}

/** „Szene 3“ bzw. „Sprecher 2“, für Sätze wie „wartet auf Szene 3“ */
export function sceneRef(p: StudioProject, id: string | null | undefined): string {
  const s = p.scenes.find((x) => x.id === id)
  if (!s) return t('eine gelöschte Szene', 'a deleted scene')
  const num = sceneNum(p, id)
  return s.lane === 'video' ? t(`Szene ${num}`, `Scene ${num}`) : num
}

/** Titel einer Szene; ohne Titel der Anfang des Prompts */
export function sceneTitle(s: StudioScene): string {
  return s.title || s.prompt.slice(0, 40) || t('ohne Titel', 'untitled')
}

/** Länge kurz: „22 s“, „1:05 min“ */
export function fmtLength(ticks: number): string {
  const s = Math.round(sec(ticks))
  return s < 60 ? `${s} s` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')} min`
}

// --------------------------------------------------------------------------------------------- Modelle

export type ModelKindOf = 'image' | 'video' | 'speech' | 'audio'

export function modelKindOf(s: StudioScene): ModelKindOf {
  return s.lane === 'video' ? (s.kind === 'image' ? 'image' : 'video') : s.lane === 'voice' ? 'speech' : 'audio'
}

/** Das Modell, mit dem die Szene rechnet: ihr eigenes, wenn es zur Art passt, sonst das aktive (wie
 *  studio._known_model) */
export function sceneModel(s: StudioScene, models: ModelInfo[], active?: Partial<Record<string, string | null>>): ModelInfo | undefined {
  const kind = modelKindOf(s)
  const own = s.model_id ? models.find((m) => m.id === s.model_id && m.kind === kind) : undefined
  return own ?? models.find((m) => m.id === active?.[kind] && m.kind === kind)
}

// Beste Familie je Bahn wie studio.BEST_FAMILY; Standbilder wie der Assistent (Qwen-Image-2512 zuerst: Apache-2.0)
const BEST_FAMILY: Record<string, string[]> = {
  video: ['ltx25'], speech: ['qwen3_tts'], music: ['stable_audio3'], sfx: ['stable_audio'],
  image: ['qwenimage', 'flux3', 'krea2', 'moss_image'],
}

/** Das empfohlene Modell der Art, das man laden müsste, wenn keins da ist */
export function bestModelFor(s: StudioScene, models: ModelInfo[]): ModelInfo | undefined {
  const kind = modelKindOf(s)
  const families = BEST_FAMILY[kind === 'audio' ? s.lane : kind] ?? []
  const ofKind = models.filter((m) => m.kind === kind && !/lightning|klein-base/i.test(m.id))
  for (const fam of families) {
    const cands = ofKind.filter((m) => m.family === fam)
    const m = cands.find((x) => x.recommended) ?? cands[0]
    if (m) return m
  }
  return ofKind.find((m) => m.recommended)
}

/** Fehlt das Modell der Szene? Das fehlende Modell (zum Laden), sonst null. Solange die Liste lädt: null. */
export function missingModel(s: StudioScene, models: ModelInfo[], active?: Partial<Record<string, string | null>>): ModelInfo | null {
  if (!models.length) return null
  const m = sceneModel(s, models, active)
  if (m) return m.installed ? null : m
  const kind = modelKindOf(s)
  if (models.some((x) => x.kind === kind && x.installed)) return null // aktives Modell noch nicht gemeldet
  return bestModelFor(s, models) ?? null
}

/** Ein geladenes Modell, das es auch tut (für „Lieber … (geladen)“) */
export function loadedAlternative(s: StudioScene, models: ModelInfo[], missing: ModelInfo): ModelInfo | undefined {
  const kind = modelKindOf(s)
  const loaded = models.filter((m) => m.kind === kind && m.installed && m.id !== missing.id)
  return loaded.find((m) => m.family === missing.family && m.recommended) ?? loaded.find((m) => m.family === missing.family)
    ?? loaded.find((m) => m.recommended) ?? loaded[0]
}

// ------------------------------------------------------------------------------------------- Weg (Video)

/** Wege einer Videoszene, eine Wahl statt Klappen (Bildschirm E, wie B im Reiter Generieren) */
export type Way = 'text' | 'start' | 'chain' | 'loop' | 'ends' | 'layout'
export const WAY_ORDER: Way[] = ['text', 'start', 'chain', 'loop', 'ends', 'layout']

/** Der Weg aus den Angaben der Szene; ohne eigene Wahl ein Startbild, wenn das Modell eins nimmt (so arbeitet auch der
 *  Assistent). params.way merkt sich die Wahl, solange das Bild bzw. Layout noch fehlt. */
export function wayOf(s: StudioScene, model?: ModelInfo): Way {
  const q = s.params ?? {}
  const use = model ? startImageUse(model) : 'optional'
  if (s.chain_from) return 'chain'
  if (q.guide_asset_id) return 'layout'
  if (q.loop) return 'loop'
  if (q.end_image_asset_id) return 'ends'
  if (q.way === 'layout' || q.way === 'ends') return q.way
  if (q.image_asset_id) return 'start'
  if (q.way === 'text' && use !== 'required') return 'text'
  return use === null ? 'text' : 'start'
}

/** Was das Modell kann (features); die aktuelle Wahl zeigt die Oberfläche zusätzlich, auch wenn es sie nicht kann */
export function waysFor(model: ModelInfo | undefined, hasEarlier: boolean): Way[] {
  const use = model ? startImageUse(model) : 'optional'
  const f = model?.features ?? {}
  const out: Way[] = []
  if (use !== 'required') out.push('text')
  if (use !== null) out.push('start')
  if (use !== null && hasEarlier) out.push('chain')
  if (f.loop) out.push('loop')
  if (f.end_image) out.push('ends')
  if (model?.family === 'ltx25' && f.layout) out.push('layout')
  return out
}

/** Die Bildszene direkt davor (Ziel von „Anschluss an“, wie studio._resolve_chain_markers) */
export function sceneBefore(p: StudioProject, s: StudioScene): StudioScene | undefined {
  return p.scenes.filter((x) => x.lane === 'video' && x.id !== s.id && x.start < s.start)
    .sort((a, b) => b.start - a.start)[0]
}

/** Anschluss, der nicht mehr an seine Vorlage grenzt (seit sich Szenen in der Kartenreihe umordnen lassen): die
 *  Vorlage, wenn sie nicht direkt (± 0,5 s) vor der Szene endet, sonst null. Mit Take zählt, wessen Ende der Take
 *  wirklich fortsetzt (carry_from vom Server, auch bei einem Anschluss aus einem Marker), ohne Take der Anschluss, mit
 *  dem er entstünde. Der Anschluss bleibt bestehen; der Zustand zeigt nur an, dass die Naht nicht mehr passt. */
export function chainApart(p: StudioProject, s: StudioScene): StudioScene | null {
  if (s.lane !== 'video' || s.kind !== 'video') return null
  const id = s.take ? s.carry_from : s.chain_from
  const src = id ? p.scenes.find((x) => x.id === id) : undefined
  if (!src) return null
  const before = sceneBefore(p, s)
  return before?.id === src.id && Math.abs(src.start + src.duration - s.start) <= TPS / 2 ? null : src
}

/** Neue Startzeiten, wenn die Szenen einer Bahn in der Reihenfolge `ids` liegen sollen: lückenlos ab dem Start der
 *  bisher ersten, Längen bleiben, aufs Bildraster des Projekts. Nur die Szenen, deren Start sich ändert. */
export function reorderStarts(p: StudioProject, lane: string, ids: string[]): { id: string; start: number }[] {
  const scenes = p.scenes.filter((s) => s.lane === lane)
  if (!scenes.length) return []
  let at = Math.min(...scenes.map((s) => s.start))
  const out: { id: string; start: number }[] = []
  for (const id of ids) {
    const s = scenes.find((x) => x.id === id)
    if (!s) continue
    const start = snapFrame(p, at)
    if (start !== s.start) out.push({ id, start })
    at += s.duration
  }
  return out
}

/** Was ein Klick auf einen Weg an der Szene ändert (Felder für scene.update). Endbild, Schleife und Layout gehen nicht
 *  mit DFR und 48 fps (wie bisher unter „Vorlagen und Zusätze“); „Nur Text“ nimmt das Startbild heraus, Strg+Z holt es
 *  zurück. */
export function wayChange(s: StudioScene, way: Way, chainTo: string | null): Record<string, unknown> {
  const plain = { quality: null, temporal_upscale: null }
  const free = { end_image_asset_id: null, loop: false, guide_asset_id: null }
  const chain = s.chain_from ? { chain_from: null } : {}
  switch (way) {
    case 'text': return { ...chain, params: { way, image_asset_id: null, ...free } }
    case 'start': return { ...chain, params: { way, ...free } }
    case 'chain': return { chain_from: chainTo, params: { way, ...free } }
    case 'loop': return { ...chain, params: { way, ...free, loop: true, ...plain } }
    case 'ends': return { ...chain, params: { way, ...free, ...plain } }
    case 'layout': return { ...chain, params: { way, ...free, ...plain } }
  }
}

/** Endbild, Schleife und Layout rechnet LTX-2.5 ohne DFR */
export const noDfrWay = (way: Way) => way === 'ends' || way === 'loop' || way === 'layout'

/** Rechnet die Videoszene mit DFR (eigene Wahl, sonst das Projekt), wie studio._job_request */
export function usesDfr(p: StudioProject, s: StudioScene, model: ModelInfo | undefined): boolean {
  if (model?.family !== 'ltx25' || !model.features?.dfr) return false
  const q = s.params ?? {}
  if (q.guide_asset_id || q.end_image_asset_id || q.loop) return false
  return q.quality ? q.quality === 'dfr' : (p.settings.video_quality ?? 'dfr') === 'dfr'
}

/** Auflösung des Clips wie studio._video_size: „1080p“, „720p“ … */
export function videoRes(p: StudioProject, s: StudioScene, model: ModelInfo | undefined): string {
  const q = s.params ?? {}
  if (q.width && q.height) return `${Math.min(Number(q.width), Number(q.height))}p`
  const { width: w, height: h } = p.settings
  const f = model?.features
  if (f?.frame_rule && f.sizes?.length) {
    const long = Math.max(...f.sizes.map((z) => Math.max(z.w, z.h)))
    const cap = Math.max(...f.sizes.map((z) => Math.min(z.w, z.h)))
    return `${Math.max(256, Math.min(cap, Math.round((long * Math.min(w, h)) / Math.max(w, h) / 32) * 32))}p`
  }
  if (!(model?.id ?? '').startsWith('ltx')) return '480p'
  return Math.max(w, h) >= 1900 ? '1080p' : '720p'
}

/** „5 s · 1080p · Standard“ unter dem Modell-Chip */
export function sceneFacts(p: StudioProject, s: StudioScene, model: ModelInfo | undefined): string {
  const len = `${decimal(String(Math.round(sec(s.duration) * 10) / 10))} s`
  if (s.lane === 'voice') return t('Länge folgt dem Satz', 'length follows the line')
  if (s.lane !== 'video') return len
  if (s.kind === 'image') return t(`Standbild · ${len}`, `still image · ${len}`)
  const parts = [len, videoRes(p, s, model)]
  if (model?.family === 'ltx25') parts.push(usesDfr(p, s, model) ? 'DFR' : t('Standard', 'standard'))
  if (s.params?.temporal_upscale && usesDfr(p, s, model)) parts.push('48 fps')
  return parts.join(' · ')
}

// ------------------------------------------------------------------------------------------ Zustand je Szene

/** Der gewählte Take liegt als Clip im Schnitt */
export function inEdit(p: StudioProject, s: StudioScene): boolean {
  return !!s.take && p.clips.some((c) => c.scene_id === s.id && c.asset_id === s.take)
}

/** Mehrere Takes, keiner bestätigt (Klick auf einen Take oder „Diesen behalten“ setzt params.take_ok), und noch nicht
 *  im Schnitt: Dann wählt der Nutzer, bevor es weitergeht (Bildschirm D: „Take wählen (2)“). */
export function needsChoice(p: StudioProject, s: StudioScene): boolean {
  return s.takes.length > 1 && !!s.take && s.params?.take_ok !== s.take && !inEdit(p, s)
}

/** Ein Sprechersatz, den eine Videoszene als Ton spricht (params.audio_from, nur LTX-2.5): kommt nicht eigens in den
 *  Schnitt (wie studio._spoken_in_video) */
export function spokenInVideo(c: FlowCtx, s: StudioScene): boolean {
  if (s.lane !== 'voice') return false
  if (c.p.clips.some((x) => x.scene_id === s.id)) return false
  return c.p.scenes.some((v) => v.lane === 'video' && v.kind === 'video' && v.params?.audio_from === s.id
    && sceneModel(v, c.models, c.active)?.family === 'ltx25')
}

export type StateKey =
  | 'running' | 'waiting' | 'start_running' | 'error' | 'cancelled' | 'stale' | 'choose' | 'in_edit' | 'done'
  | 'model' | 'prompt' | 'chain_wait' | 'start_missing' | 'end_missing' | 'layout_missing' | 'start_set' | 'ready'
  | 'chain_apart'

export interface SceneState {
  key: StateKey
  tone: Tone
  label: string
}

function doneLabel(s: StudioScene): string {
  if (s.lane === 'voice') return t('Satz fertig', 'line done')
  if (s.lane !== 'video') return t('Ton fertig', 'sound done')
  return s.kind === 'image' ? t('Bild fertig', 'image done') : t('Video fertig', 'video done')
}

/** Zustand einer Szene als Chip: was gerade passiert, was fehlt, was als Nächstes kommt */
export function sceneState(c: FlowCtx, s: StudioScene): SceneState {
  const { p } = c
  if (s.status === 'running') {
    const pr = c.progress(s)
    return { key: 'running', tone: 'info', label: pr == null ? t('rechnet', 'computing') : t(`rechnet ${Math.round(pr * 100)} %`, `computing ${Math.round(pr * 100)} %`) }
  }
  if (s.status === 'waiting') {
    return { key: 'waiting', tone: '', label: t(`wartet auf ${sceneRef(p, s.waiting_for)}`, `waits for ${sceneRef(p, s.waiting_for)}`) }
  }
  if (c.startRuns[s.id]?.status === 'running') return { key: 'start_running', tone: 'info', label: t('Startbild entsteht', 'start image in progress') }
  if (s.status === 'error') return { key: 'error', tone: 'err', label: t('Fehler', 'error') }
  if (s.stale && s.take) return { key: 'stale', tone: 'warn', label: t('veraltet', 'outdated') }
  const apart = { key: 'chain_apart' as const, tone: 'warn' as const, label: t('Anschluss getrennt', 'chain apart') }
  if (s.take && chainApart(p, s)) return apart
  if (s.take) {
    if (needsChoice(p, s)) return { key: 'choose', tone: 'info', label: t(`Take wählen (${s.takes.length})`, `choose a take (${s.takes.length})`) }
    if (inEdit(p, s)) return { key: 'in_edit', tone: 'ok', label: t('im Schnitt', 'in the edit') }
    return { key: 'done', tone: 'ok', label: doneLabel(s) }
  }
  if (s.cancelled) return { key: 'cancelled', tone: 'warn', label: t('abgebrochen', 'cancelled') }
  if (missingModel(s, c.models, c.active)) return { key: 'model', tone: 'warn', label: t('Modell fehlt', 'model missing') }
  if (!s.prompt.trim()) return { key: 'prompt', tone: 'warn', label: t('Prompt fehlt', 'prompt missing') }
  if (s.lane === 'video' && s.kind === 'video') {
    const way = wayOf(s, sceneModel(s, c.models, c.active))
    const q = s.params ?? {}
    if (way === 'chain') {
      if (chainApart(p, s)) return apart
      const src = p.scenes.find((x) => x.id === s.chain_from)
      return src && !src.take
        ? { key: 'chain_wait', tone: '', label: t(`wartet auf ${sceneRef(p, src.id)}`, `waits for ${sceneRef(p, src.id)}`) }
        : { key: 'ready', tone: '', label: t(`Anschluss an ${sceneNum(p, s.chain_from)}`, `chained to ${sceneNum(p, s.chain_from)}`) }
    }
    if (way === 'layout' && !q.guide_asset_id) return { key: 'layout_missing', tone: 'warn', label: t('Layout fehlt', 'layout missing') }
    if ((way === 'start' || way === 'loop' || way === 'ends') && !q.image_asset_id) {
      return { key: 'start_missing', tone: 'warn', label: t('Startbild fehlt', 'start image missing') }
    }
    if (way === 'ends' && !q.end_image_asset_id) return { key: 'end_missing', tone: 'warn', label: t('Endbild fehlt', 'end image missing') }
    if (q.image_asset_id) return { key: 'start_set', tone: '', label: t('Startbild gewählt', 'start image chosen') }
    return { key: 'ready', tone: '', label: way === 'text' ? t('nur Text', 'text only') : t('bereit', 'ready') }
  }
  return { key: 'ready', tone: '', label: t('bereit', 'ready') }
}

/** Szenen, auf deren Take diese wartet (Anschluss, Satz für die Lippen, gleiche Stimme), wie studio._dependencies */
export function dependencies(p: StudioProject, s: StudioScene): string[] {
  const q = s.params ?? {}
  if (s.lane === 'voice') {
    const ch = (p.characters ?? []).find((x) => x.id === q.character)
    const from = ch ? (ch.voice_from !== s.id ? ch.voice_from : null) : q.voice_from
    return from ? [from] : []
  }
  return [s.chain_from, s.lane === 'video' && s.kind === 'video' ? q.audio_from : null].filter((x): x is string => !!x)
}

/** Die Szene samt ihren Vorlagen ohne Take, die noch nicht laufen: Allein scheiterte ein Anschluss an „braucht die
 *  vorherige Szene erst ein Video“; zusammen wartet er auf sie (studio.generate). */
export function withSources(p: StudioProject, ids: string[]): string[] {
  const out = new Set<string>()
  const add = (id: string, depth: number) => {
    if (out.has(id) || depth > 20) return
    out.add(id)
    const s = p.scenes.find((x) => x.id === id)
    if (!s) return
    for (const d of dependencies(p, s)) {
      const src = p.scenes.find((x) => x.id === d)
      if (src && !src.take && !src.jobs.length && !src.waiting_for) add(d, depth + 1)
    }
  }
  ids.forEach((id) => add(id, 0))
  return [...out]
}

// ------------------------------------------------------------------------------------- Nächster Schritt (D)

export interface ExportInfo {
  status: 'none' | 'running' | 'done' | 'error'
  progress: number
  /** Dateiname der fertigen Datei */
  file?: string
  /** Der fertige Export zeigt den heutigen Schnitt (nach einer Änderung wird neu exportiert) */
  fresh: boolean
  /** „Shorts 1080 × 1920“ */
  preset: string
}

export type NextKind = 'wizard' | 'model' | 'prompt' | 'start' | 'pick' | 'choose' | 'stale' | 'generate' | 'busy'
  | 'error' | 'conform' | 'export' | 'exporting' | 'done' | 'idle'

export interface Next {
  kind: NextKind
  /** Schritt der Leiste, der dran ist (0 Idee … 5 Export, 6 alles erledigt) */
  step: number
  scenes: StudioScene[]
  label: string
  /** zweite Zeile, wenn keine Zeit passt: „2 Varianten“, „4 Clips“, „ansehen“ */
  note?: string
  disabled?: boolean
  /** Feld, das nach dem Klick in den Blick kommt */
  field?: FocusField
}

const nums = (p: StudioProject, list: StudioScene[]) => list.map((s) => sceneNum(p, s.id))

/** „Szene 4“, „Szene 3 und 4“, bei mehr als drei „5 Szenen“ */
function forScenes(p: StudioProject, list: StudioScene[]): { de: string; en: string } {
  const n = nums(p, list)
  const pics = list.every((s) => s.lane === 'video')
  if (list.length === 1) return { de: sceneRef(p, list[0].id), en: sceneRef(p, list[0].id) }
  if (list.length <= 3 && pics) {
    const head = n.slice(0, -1).join(', ')
    return { de: `Szene ${head} und ${n[n.length - 1]}`, en: `scenes ${head} and ${n[n.length - 1]}` }
  }
  return { de: `${list.length} Szenen`, en: `${list.length} scenes` }
}

export function nextStep(c: FlowCtx, ex: ExportInfo): Next {
  const { p } = c
  const all = sceneOrder(p)
  if (!all.length) {
    return { kind: 'wizard', step: 0, scenes: [], label: t('Mit dem Assistenten beginnen', 'Start with the assistant'),
      note: t('ein ganzes Video, sieben kurze Schritte', 'a whole video, seven short steps') }
  }
  const states = new Map(all.map((s) => [s.id, sceneState(c, s)]))
  const of = (...keys: StateKey[]) => all.filter((s) => keys.includes(states.get(s.id)!.key))
  const first = (...keys: StateKey[]) => of(...keys)[0]

  const model = first('model')
  if (model) {
    const m = missingModel(model, c.models, c.active)
    return { kind: 'model', step: 3, scenes: [model], field: 'model',
      label: t(`${m?.name ?? 'Modell'} für ${sceneRef(p, model.id)} laden`, `Download ${m?.name ?? 'the model'} for ${sceneRef(p, model.id)}`),
      note: t('Größe und Lizenz ansehen', 'see size and license') }
  }
  const prompt = first('prompt')
  if (prompt) {
    return { kind: 'prompt', step: 1, scenes: [prompt], field: 'prompt',
      label: t(`Prompt für ${sceneRef(p, prompt.id)} schreiben`, `Write the prompt for ${sceneRef(p, prompt.id)}`) }
  }
  // Startbilder, die gerade entstehen, erst ansehen (zwei Varianten), dann die Videos
  const making = of('start_running')
  if (making.length) {
    const f = forScenes(p, making)
    return { kind: 'busy', step: 2, scenes: making, field: 'way',
      label: making.length === 1 ? t(`Startbild für ${f.de} entsteht`, `Start image for ${f.en} in progress`)
        : t(`Startbilder für ${f.de} entstehen`, `Start images for ${f.en} in progress`) }
  }
  const starts = of('start_missing')
  if (starts.length && c.models.length && !startImageModel(c.models)) {
    // Ohne Bildmodell gibt es kein Startbild: erst das Modell, an Ort und Stelle in der Szene
    return { kind: 'model', step: 2, scenes: [starts[0]], field: 'state',
      label: t('Bildmodell für die Startbilder laden', 'Download an image model for the start images'),
      note: t('Größe und Lizenz ansehen', 'see size and license') }
  }
  if (starts.length) {
    const f = forScenes(p, starts)
    return { kind: 'start', step: 2, scenes: starts,
      label: starts.length === 1 ? t(`Startbild für ${f.de} erzeugen`, `Generate the start image for ${f.en}`)
        : t(`Startbilder für ${f.de} erzeugen`, `Generate start images for ${f.en}`) }
  }
  const pick = first('end_missing', 'layout_missing')
  if (pick) {
    const end = states.get(pick.id)!.key === 'end_missing'
    return { kind: 'pick', step: 2, scenes: [pick], field: 'way',
      label: end ? t(`Endbild für ${sceneRef(p, pick.id)} wählen`, `Choose the end image for ${sceneRef(p, pick.id)}`)
        : t(`Layout-Video für ${sceneRef(p, pick.id)} wählen`, `Choose the layout video for ${sceneRef(p, pick.id)}`) }
  }
  // Takes wählen: Vorlagen von Anschlüssen zuerst, ihr Take bestimmt den Anfang der nächsten Szene
  const isSource = (s: StudioScene) => p.scenes.some((x) => x.chain_from === s.id)
  const choose = of('choose').sort((a, b) => Number(isSource(b)) - Number(isSource(a)))[0]
  if (choose) {
    return { kind: 'choose', step: 3, scenes: [choose], field: 'takes',
      label: t(`Take für ${sceneRef(p, choose.id)} wählen`, `Choose a take for ${sceneRef(p, choose.id)}`),
      note: t(`${choose.takes.length} Varianten`, `${choose.takes.length} variants`) }
  }
  const stale = first('stale')
  if (stale) {
    return { kind: 'stale', step: 3, scenes: [stale], field: 'state',
      label: t(`${sceneRef(p, stale.id)} ist veraltet`, `${sceneRef(p, stale.id)} is outdated`), note: t('ansehen', 'review') }
  }
  const gen = all.filter((s) => ['ready', 'start_set', 'chain_wait', 'cancelled'].includes(states.get(s.id)!.key)
    || (states.get(s.id)!.key === 'chain_apart' && !s.take))
  if (gen.length) {
    const f = forScenes(p, gen)
    const videos = gen.every((s) => s.lane === 'video' && s.kind === 'video')
    return { kind: 'generate', step: 3, scenes: gen,
      label: videos
        ? gen.length === 1 ? t(`Video für ${f.de} erzeugen`, `Generate the video for ${f.en}`) : t(`Videos für ${f.de} erzeugen`, `Generate videos for ${f.en}`)
        : gen.length === 1 ? t(`${f.de} erzeugen`, `Generate ${f.en}`) : t(`${gen.length} Szenen erzeugen`, `Generate ${gen.length} scenes`) }
  }
  const busy = of('running', 'waiting')
  if (busy.length) {
    const cur = busy.find((s) => s.status === 'running') ?? busy[0]
    const pr = c.progress(cur)
    const more = busy.length > 1 ? t(` · ${busy.length - 1} weitere`, ` · ${busy.length - 1} more`) : ''
    return { kind: 'busy', step: 3, scenes: [cur], field: 'state',
      label: cur.status === 'running'
        ? t(`${sceneRef(p, cur.id)} rechnet${pr == null ? '' : ` · ${Math.round(pr * 100)} %`}`, `${sceneRef(p, cur.id)} computing${pr == null ? '' : ` · ${Math.round(pr * 100)} %`}`) + more
        : t(`${sceneRef(p, cur.id)} wartet`, `${sceneRef(p, cur.id)} waiting`) + more }
  }
  const err = first('error')
  if (err) {
    return { kind: 'error', step: 3, scenes: [err], field: 'state',
      label: t(`Fehler in ${sceneRef(p, err.id)}`, `Error in ${sceneRef(p, err.id)}`), note: t('ansehen', 'review') }
  }
  const withTake = all.filter((s) => s.take && !spokenInVideo(c, s))
  const pending = withTake.filter((s) => !inEdit(p, s))
  if (pending.length) {
    return { kind: 'conform', step: 4, scenes: pending,
      label: pending.length === withTake.length ? t('Alles in den Schnitt legen', 'Put everything into the edit') : t('In den Schnitt legen', 'Put into the edit'),
      note: pending.length === 1 ? t('1 Clip', '1 clip') : t(`${pending.length} Clips`, `${pending.length} clips`) }
  }
  if (!p.clips.length) {
    return { kind: 'idle', step: 4, scenes: [], label: t('Der Schnitt ist leer', 'The edit is empty'), disabled: true }
  }
  if (ex.status === 'running') {
    return { kind: 'exporting', step: 5, scenes: [], disabled: true,
      label: t(`Export läuft · ${Math.round(ex.progress * 100)} %`, `Exporting · ${Math.round(ex.progress * 100)} %`) }
  }
  if (ex.status === 'done' && ex.fresh) {
    return { kind: 'done', step: 6, scenes: [], label: t(`Fertig: ${ex.file ?? ''}`, `Done: ${ex.file ?? ''}`),
      note: t('ansehen, liegt auch im Projektordner', 'view, also in the project folder') }
  }
  return { kind: 'export', step: 5, scenes: [], label: t(`Exportieren · ${ex.preset}`, `Export · ${ex.preset}`),
    note: t(`${fmtLength(p.edit_duration)} Film`, `${fmtLength(p.edit_duration)} film`) }
}

// -------------------------------------------------------------------------------------------- Leiste (D)

export interface RailStep {
  key: 'idea' | 'scenes' | 'starts' | 'videos' | 'edit' | 'export'
  label: string
  small: string
  done: boolean
  title: string
}

/** `nextKind`: Art des nächsten Schritts; „n Clips bereit“ steht erst, wenn das Übernehmen dran ist (vorher „leer“) */
export function railSteps(c: FlowCtx, ex: ExportInfo, nextKind?: NextKind): RailStep[] {
  const { p } = c
  const all = p.scenes
  const states = new Map(all.map((s) => [s.id, sceneState(c, s)]))
  const clips = all.filter((s) => s.lane === 'video' && s.kind === 'video')
  const relevant = clips.filter((s) => wayOf(s, sceneModel(s, c.models, c.active)) !== 'text')
  const covered = relevant.filter((s) => s.take || s.chain_from || s.params?.image_asset_id || s.params?.guide_asset_id).length
  const fine = all.filter((s) => ['done', 'in_edit'].includes(states.get(s.id)!.key)).length
  const withTake = all.filter((s) => s.take && !spokenInVideo(c, s))
  const pending = withTake.filter((s) => !inEdit(p, s)).length
  const sounds = all.filter((s) => s.lane !== 'video').length
  const pictures = all.filter((s) => s.lane === 'video')
  const finePictures = pictures.filter((s) => ['done', 'in_edit'].includes(states.get(s.id)!.key)).length
  return [
    { key: 'idea', label: t('Idee', 'Idea'), small: p.name, done: all.length > 0,
      title: t('Der Name des Projekts; der Assistent nennt es nach der Idee.', 'The project name; the assistant names it after the idea.') },
    { key: 'scenes', label: t('Szenen', 'Scenes'),
      small: all.length ? t(`${all.length} Szenen · ${fmtLength(p.composition_duration)}`, `${all.length} scenes · ${fmtLength(p.composition_duration)}`) : t('noch keine', 'none yet'),
      done: all.length > 0 && all.every((s) => s.take || s.prompt.trim()),
      title: sounds ? t(`Davon ${sounds} auf den Tonbahnen (Sprecher, Musik, Klang).`, `${sounds} of them on the sound lanes (voice, music, sound).`)
        : t('Szenen der Komposition.', 'Scenes of the composition.') },
    { key: 'starts', label: t('Startbilder', 'Start images'),
      small: relevant.length ? t(`${covered} von ${relevant.length}`, `${covered} of ${relevant.length}`) : t('nicht nötig', 'not needed'),
      done: all.length > 0 && covered === relevant.length,
      title: t('Videoszenen mit Startbild, Anschluss oder fertigem Take; „Nur Text“ braucht keins.', 'Video scenes with a start image, a chain or a finished take; "Text only" needs none.') },
    // Gezählt werden die Bildszenen (unter „Videos“ las sich „3 von 4“ mit der Musik als vierter wie ein fehlendes
    // Video); erledigt ist der Schritt erst, wenn auch Sprecher, Musik und Klang einen Take haben
    { key: 'videos', label: t('Videos', 'Videos'),
      small: pictures.length ? t(`${finePictures} von ${pictures.length}`, `${finePictures} of ${pictures.length}`)
        : t(`${fine} von ${all.length}`, `${fine} of ${all.length}`),
      done: all.length > 0 && fine === all.length,
      title: sounds ? t(`Bildszenen mit gewähltem Take; erledigt, wenn auch die ${sounds} Ton-Szenen fertig sind.`,
        `Picture scenes with a chosen take; done when the ${sounds} sound scenes are finished too.`)
        : t('Szenen mit gewähltem Take.', 'Scenes with a chosen take.') },
    { key: 'edit', label: t('Schnitt', 'Edit'),
      small: pending && nextKind === 'conform' ? (pending === 1 ? t('1 Clip bereit', '1 clip ready') : t(`${pending} Clips bereit`, `${pending} clips ready`))
        : p.clips.length ? t(`${fmtLength(p.edit_duration)} im Schnitt`, `${fmtLength(p.edit_duration)} in the edit`) : t('leer', 'empty'),
      done: p.clips.length > 0 && pending === 0,
      title: t('„Übernehmen“ legt die gewählten Takes in den Schnitt.', '"Conform" puts the chosen takes into the edit.') },
    { key: 'export', label: t('Export', 'Export'),
      small: ex.status === 'running' ? `${Math.round(ex.progress * 100)} %` : ex.status === 'done' && ex.fresh && ex.file ? ex.file : ex.preset,
      done: ex.status === 'done' && ex.fresh,
      title: t('Die Vorlage folgt dem Projektformat (Hochformat: Shorts).', 'The preset follows the project format (portrait: Shorts).') },
  ]
}

/** Kurzname einer Exportvorlage für Leiste und Knopf */
export function presetShort(id: string, label: string, p: StudioProject): string {
  const map: Record<string, string> = {
    'shorts-1080x1920': t('Shorts 1080 × 1920', 'Shorts 1080 × 1920'),
    'youtube-1080p': 'YouTube 1080p',
    'youtube-2160p': 'YouTube 4K',
    'av1-1080p': 'AV1 1080p',
    'master': t('Master (FFV1)', 'Master (FFV1)'),
    'prores': 'ProRes 4444',
    'project': `${p.settings.width} × ${p.settings.height}`,
  }
  return map[id] ?? label
}

// ------------------------------------------------------------------------------------------------- Zeiten

/** Bildmodell für „Startbild erzeugen“ wie studio._start_image_model (ohne die Gewichtung nach LoRAs der Figuren) */
const START_FAMILIES = ['flux3', 'qwenimage', 'krea2', 'moss_image']

/** Fehlt jedes Bildmodell für Startbilder: das, das man laden sollte (Qwen-Image-2512 zuerst, Apache-2.0 und ohne
 *  Freigabe auf Hugging Face) */
export function startImageNeed(models: ModelInfo[]): ModelInfo | undefined {
  if (!models.length || startImageModel(models)) return undefined
  return bestModelFor({ lane: 'video', kind: 'image' } as StudioScene, models)
}
export function startImageModel(models: ModelInfo[]): ModelInfo | undefined {
  for (const fam of START_FAMILIES) {
    const cands = models.filter((m) => m.kind === 'image' && m.family === fam && m.installed && m.runnable
      && !m.id.startsWith('flux3-klein-base') && !m.id.startsWith('qwen-image-2512-lightning'))
    const m = cands.find((x) => x.recommended) ?? cands[0]
    if (m) return m
  }
  return undefined
}

/** Bildgröße im Seitenverhältnis des Projekts wie studio._image_size */
export function imageSize(p: StudioProject, model: ModelInfo | undefined): { width: number; height: number } {
  const rec = model?.features?.recommended?.size
  const target = rec ? rec[0] * rec[1] : 1_048_576
  const { width: w, height: h } = p.settings
  const scale = Math.sqrt(target / (w * h))
  const fit = (x: number) => Math.min(2048, Math.max(256, Math.floor((x * scale) / 16) * 16))
  return { width: fit(w), height: fit(h) }
}

/** Schätzanfragen für „Startbild erzeugen“ (zwei Varianten je Szene) */
export function startImageItems(p: StudioProject, models: ModelInfo[], scenes: StudioScene[]) {
  const m = startImageModel(models)
  if (!m || !scenes.length) return null
  return scenes.map(() => ({ kind: 'txt2img', params: { model_id: m.id, ...imageSize(p, m), batch_size: 2 } }))
}

/** Eine Folge von Aufträgen: Rechenzeit je Auftrag, Start einmal, Laden einmal je Modell. unknown zählt die ohne Zahl. */
export function sumEstimates(list: (Estimate | null | undefined)[]): { seconds: number | null; unknown: number } {
  let total = 0
  let start = 0
  let known = 0
  const loads = new Map<string, number>()
  for (const e of list) {
    if (!e || e.seconds == null) continue
    known += 1
    total += e.seconds
    start = Math.max(start, e.cold?.start ?? 0)
    const key = e.model_id ?? ''
    if (!loads.has(key)) loads.set(key, e.cold?.load ?? 0)
  }
  const load = [...loads.values()].reduce((a, b) => a + b, 0)
  return { seconds: known ? total + start + load : null, unknown: list.length - known }
}

/** Zeit je Szene: was der Server schätzt; Szenen ohne Zahl (ein Anschluss, dessen Vorlage erst im selben Lauf
 *  entsteht) aus der Rate einer Szene mit demselben Modell, hochgerechnet auf ihre Länge */
export function sceneEstimates(c: FlowCtx, scenes: StudioScene[], got: Record<string, Estimate> | null): (Estimate | null)[] {
  const out = scenes.map((s) => (got?.[s.id]?.seconds != null ? got[s.id] : null))
  const rate = new Map<string, { perSec: number; e: Estimate }>()
  scenes.forEach((s, i) => {
    const e = out[i]
    const m = sceneModel(s, c.models, c.active)?.id
    if (e && m && !rate.has(m)) rate.set(m, { perSec: (e.seconds ?? 0) / Math.max(0.5, sec(s.duration)), e })
  })
  return scenes.map((s, i) => {
    if (out[i]) return out[i]
    const m = sceneModel(s, c.models, c.active)?.id
    const r = m ? rate.get(m) : undefined
    return r ? { ...r.e, seconds: r.perSec * sec(s.duration), source: 'rough' as const } : null
  })
}

// ---------------------------------------------------------------------------------------------- Takes

/** Art, Bildrate und Seed eines Takes aus der Datenbank (api.asset), für „Seed festhalten“ */
export interface TakeInfo { kind: string; fps: number | null; seed: number | null }

