// Duenner Typ-Layer ueber die REST-API. Spiegelt server/nvai/schemas.py.

import { getLang, t } from './i18n'

export type JobStatus = 'queued' | 'running' | 'done' | 'error' | 'cancelled'
export type AssetKind = 'image' | 'audio' | 'video' | 'mesh' | 'upload'
/** 'controlnet' erzeugt nichts eigenstaendig — es ist ein Zusatz zum Bild-Modus. Ebenso 'upscale'
 * (SeedVR2): es schärft beim Restaurieren; 'video_upscale' (RelayVSR, seit 0.5.23) verdoppelt fertige Videos. */
export type ModelKind = 'image' | 'audio' | 'speech' | 'video' | '3d' | 'controlnet' | 'lora' | 'upscale' | 'interpolate'
  | 'video_upscale'

/** Eine LoRA beim Generieren: Katalog-ID (kind 'lora') und Stärke. */
export interface LoraRef {
  model_id: string
  strength: number
}
/** Die vier Modi, die wirklich etwas erzeugen. */
export type GenKind = 'image' | 'audio' | 'speech' | 'video' | '3d'
// Wofür "Prompt ausbauen" schreibt (server/nvai/prompt_targets.py)
export type ExpandTarget = 'image' | 'video' | 'video_sound' | 'video_multishot' | 'video_start' | 'sfx' | 'music' | 'music_sa3' | '3d' | 'translate'

export interface Job {
  id: string
  kind: string
  status: JobStatus
  progress: number
  stage: string
  params: Record<string, any>
  asset_ids: string[]
  error: string | null
  created_at: number
  started_at: number | null
  finished_at: number | null
}

export interface Asset {
  id: string
  job_id: string | null
  kind: AssetKind
  /** relativ zum Asset-Ordner; seit 0.5.15 auch in einem Projektordner (Studio/<Name>/…) */
  filename: string
  /** der Ordner, '' = oberste Ebene (Verlauf) */
  folder?: string
  url: string
  thumb_url: string | null
  prompt: string
  model_id: string
  meta: Record<string, any>
  created_at: number
}

/** Adresse einer Asset-Datei unter /files/, je Abschnitt kodiert (Projektnamen mit Leerzeichen, Umlauten, #). */
/** Bild eines LoRA-Datensatzes (datasets/<id>/<datei>) oder Probebild eines Trainings (runs/<id>/test/<datei>) */
export function loraFileUrl(area: 'datasets' | 'runs', item: string, name: string): string {
  return `/api/lora-train/files/${area}/${encodeURIComponent(item)}/${name.split('/').map(encodeURIComponent).join('/')}`
}

export function fileUrl(name: string): string {
  return '/files/' + name.split('/').map(encodeURIComponent).join('/')
}

/** Ein Projektordner im Material (GET /api/folders) */
export interface AssetFolder {
  path: string
  name: string
  items: number
  updated_at: number | null
  project_id: string | null
  project_name: string | null
}

export interface ModelFile {
  repo: string
  file: string
  target: string
  installed: boolean
  local_path: string | null
  size_gb: number | null
  /** Zusatzfunktion, die diese Datei freischaltet (z. B. "dfr"); null = Pflichtdatei */
  optional?: string | null
}

export interface ModelInfo {
  id: string
  name: string
  kind: ModelKind
  family: string
  workflow: string | null
  files: ModelFile[]
  size_gb: number
  vram_gb: number
  license: string
  commercial_ok: boolean
  /** Gesetzt, wenn vor dem Einsatz etwas zu beachten ist (z. B. Lizenzausschluss). */
  warning: string
  /** Harte Lizenzgrenze (ganze Länder ausgeschlossen): rote Marke am Modell, die Warnung steht immer sichtbar. */
  license_badge?: string
  /** Rote Marke an jedem Ergebnis dieses Modells (Verlauf, Studio), z. B. „Nicht veröffentlichen“. */
  output_badge?: string
  /** Eigene Genehmigung für die Lizenz bestätigt (Haken unter „Modelle“): Warnung und rote Marken entfallen. */
  license_confirmed?: boolean
  best_for: string
  description: string
  pros: string[]
  cons: string[]
  installed: boolean
  partially_installed: boolean
  disk_gb: number
  runnable: boolean
  favorite: boolean
  /** Passt das Modell auf die erkannte Karte? 'ja' | 'knapp' | 'nein' | 'unklar' */
  fits_vram: string
  /** Für die erkannte Kartengeneration empfohlen (RTX 50: NVFP4, sonst INT8). */
  recommended: boolean
  /** Hinweis, wenn das Format auf dieser Karte nicht in Hardware rechnet. */
  gpu_note: string
  /** Zensiert oder nicht (Bild und Video); null = unbekannt. Beleg und Quelle dazu (content.py). */
  content: 'uncensored' | 'partial' | 'censored' | null
  content_note: string
  content_source: string
  /** Was das Modell beim Generieren kann — steuert die Bedienelemente (registry.features_for). */
  features: Partial<ModelFeatures>
  /** Generatoren: welche LoRA-Basen sie nehmen. LoRAs: Basis steht in family. */
  lora_bases?: string[]
  trigger?: string
  source_url?: string
  /** Gesperrte Hugging-Face-Repos des Modells und je Repo, ob der hinterlegte Token Zugriff hat. */
  gated_repos?: string[]
  gated_access?: Record<string, 'granted' | 'missing' | 'no_token' | 'unknown'>
  /** Seit 0.5.24: aus dem Nutzer-Katalog (Suche, Civitai, vom Rechner); bei LoRAs ist die Zuordnung änderbar. */
  custom?: boolean
  /** LoRA vom Rechner hinzugefügt: lässt sich nicht herunterladen, nur neu hinzufügen. */
  uploaded?: boolean
  /** LoRAs für Wan 14B: an welchen Experten sie gehen ('high' | 'low' | 'both'); sonst leer. */
  expert?: string
  /** Seit 0.5.29: im Bereich „LoRA erstellen/Bearbeiten“ trainiert (Lauf, Zwischenstand, Epoche, Bilder, Datensatz) */
  trained?: LoraTrained | null
}

export interface LoraTrained {
  run_id: string
  checkpoint: string
  epoch: number
  images?: number
  dataset?: string
  settings?: LoraTrainSettings
}

// ---- LoRA erstellen/Bearbeiten (seit 0.5.29, server/nvai/lora_train.py)

export interface LoraTrainSettings { epochs?: number; lr?: string; rank?: number; alpha?: number; save_every?: number }

export interface LoraTrainImage {
  file: string
  caption: string
  status: 'keep' | 'reject'
  source: 'asset' | 'folder' | 'template' | string
  width: number
  height: number
  pose?: number
  model_id?: string
  license_note?: string
  /** Bild des Datensatzes, aus dem dieses entstand („weitere aus ausgewählten“) */
  ref?: string
}

/** Entwurf der Figur (Assistent): frontal und ganz, aus der Skizze und/oder der Beschreibung */
export interface LoraDraft { file: string; seed: number; from_sketch: boolean; added?: number }

export interface LoraDataset {
  id: string
  name: string
  trigger: string
  class_word: string
  notes: string
  images: LoraTrainImage[]
  template: string | null
  /** Datei, aus der die Vorlage stammt (Skizze oder Entwurf) */
  template_from?: string | null
  /** Ausgangsbild für Entwürfe: Skizze, Foto oder Bild */
  sketch?: string | null
  drafts?: LoraDraft[]
  updated?: number
  /** Hinweis nach dem Hinzufügen (abgelehnte FLUX-Bilder, entfernter Anfang der Bildbeschreibungen) */
  message?: string
}

export interface LoraDatasetSummary {
  id: string
  name: string
  trigger: string
  class_word: string
  images: number
  keep: number
  cover: string | null
  template: string | null
  sketch?: string | null
  drafts?: number
  updated?: number
}

// Bereich „Audio“ (seit 17.11.2026, Server: audio_lab.py)
export interface AudioModel {
  id: string
  label: string
  task: 'voice' | 'dialogue' | 'denoise' | 'music' | string
  license_code: string
  license_weights: string
  commercial_ok: boolean
  license_url?: string
  sample_rate: number
  stems: string[]
  vram_gb?: number
  seconds_per_minute?: number
  device?: 'cuda' | 'cpu'
  notes: string
  installed: boolean
  size_mb: number
  recommended_for: string[]
}

export interface AudioTrack {
  id: string
  name: string
  kind: 'original' | 'stem' | 'processed' | 'preview'
  frames: number
  bars: number
  peak: number
  /** Beginn in Sekunden (Vorschau eines Ausschnitts) */
  offset: number
  gain_db: number
  mute: boolean
  solo: boolean
  color: string
  op: Record<string, any> | null
  created: number
  /** Abtastrate der Spur (sonst die des Projekts) */
  sr?: number
  /** Herkunft, z. B. „VDR“ (Kanäle eines Schiffsschreibers) */
  group?: string
  /** Kanal eines Schiffsschreibers: Eingang (MIC1, VHF1), Ort an Bord, Art (MIC, VHF) */
  channel?: { input: string; position?: string; category?: string }
  /** Spektrogramm (Ton-Forensik), Stufen mit 1-, 32- und 1024-facher Spaltenbreite */
  spec?: { bins: number; hop: number; sr: number; fmax: number; levels: { factor: number; cols: number }[] }
  /** Sprachaktivität (aus dem Spektrogramm-Durchgang oder Silero VAD) */
  activity?: { method: string; rate: number; segments: number; speech_seconds: number }
  /** Sprachkarte mit Silero VAD (je 0,1 s), genauer als activity; nötig bei geschalteten VDR-Mikrofonen */
  vad?: { method: string; rate: number; speech_seconds: number; time: number }
  /** „Bester Kanal“: aus welchen Spuren gemischt */
  mix_of?: string[]
}

export interface AudioMarker { id: string; start: number; end: number; kind: 'noise' | 'keep' | 'note'; label: string; author?: string; created?: number }

export interface AudioProfile {
  id: string
  name: string
  created: number
  track: string
  metrics: { noise_reduction_db: number | null; clean_change_db: number | null; examples: number; example_seconds: number;
    clean_seconds: number; steps: number; train_seconds: number; device: string }
}

/** Fall im Papierkorb der Ton-Forensik (wiederherstellbar, bis er endgültig gelöscht wird) */
export interface AudioTrashEntry { entry: string; id: string; name: string; deleted: number; duration: number | null; tracks: number; kind: string; size: number; exists: boolean }
export interface AudioProjectSummary { id: string; name: string; duration?: number; status?: string; tracks: number; updated?: number; has_video: boolean; kind?: string; source_kind?: string }

export interface AudioProject {
  id: string
  name: string
  status: 'preparing' | 'ready' | 'error'
  error?: string | null
  source: { kind?: 'vdr' | string; name: string; asset_id?: string; path?: string; has_video?: boolean; sha256?: string; size?: number; sha256_time?: number; video?: { width: number; height: number; fps: number | null; codec: string } | null; codec?: string; container?: string; source_rate?: number; source_channels?: number }
  sample_rate?: number
  channels?: number
  duration?: number
  analysis?: { lufs: number | null; noise_floor_db: number | null; peak_db: number | null; clipped: number; levels_db?: number[]; hum?: { freq: number; db_over_floor: number; harmonics_db: number[]; present: boolean } | null }
  tracks: AudioTrack[]
  markers: AudioMarker[]
  history: Record<string, any>[]
  suggestions?: { kind: 'classic' | 'ai' | 'info'; chain?: Record<string, any>[]; task?: string; model?: string; text: string }[]
  /** gelernte Geräusche (Geräusch lernen) */
  profiles?: AudioProfile[]
  /** Ergebnis der Ton-Suche (Alarme, Piepser): Gruppen nach Tonhöhe mit ihren Stellen */
  scan?: { clusters: { freqs: number[]; freq: number; count: number; total_s: number; mean_s: number; tonality_db: number; score: number;
    events: [number, number][] }[]; events: number; seconds_scanned: number; track: string; time: number }
  job_id?: string
  updated?: number
  /** Zeitpunkt (UTC, Unix-Sekunden) von Sekunde 0, z. B. Beginn der Aufzeichnung eines Schiffsschreibers */
  time_origin?: number | null
  /** Zusammenfassung eines Schiffsschreibers (audio_vdr.py) */
  vdr?: Record<string, any>
  /** zugeordnetes Video (z. B. Bildschirmaufnahme des Wiedergabeprogramms), über den Ton ausgerichtet:
   * Video-Zeit = a · Aufnahme-Zeit + b */
  video?: { path: string; name: string; size: number; fit: { a: number; b: number }; drift_ppm: number; method?: 'clock' | 'audio';
    residual_ms: { median: number; max: number }; points: number; duration: number; time: number }
}

/** Ton-Forensik: Block der Übersetzer-Spur */
export interface TranscriptSegment {
  /** Spur von Hand festgelegt (Übersetzer-KI mit fester Spur); ein Lauf mit Automatik lässt den Block stehen */
  pinned?: boolean
  id: string
  start: number
  end: number
  track: string
  speaker: string
  kind: 'speech' | 'radio' | 'sound' | 'note'
  /** Original in der Quellsprache */
  text: string
  lang: string
  /** Übersetzung je Zielsprache */
  translation: Record<string, string>
  conf: number | null
  /** draft = Entwurf der KI, checked = von einem Menschen geprüft */
  status: 'draft' | 'checked'
  /** ai: ungeänderter Entwurf der KI (ein neuer Lauf ersetzt ihn), human: von Hand angelegt oder geändert */
  origin?: 'ai' | 'human'
  /** zweitbester Kanal (Gegenprobe) */
  second?: string | null
  note: string
  /** je Wort: Anfang, Ende, Wort, Sicherheit (min. Whisper/Omnilingual), bestätigt (Omnilingual hört dasselbe) */
  words?: [number | null, number | null, string, number, number?][]
  /** Zweitmeinung: was Omnilingual CTC 1B selbst hört */
  alt_text?: string
  /** Buchstaben-Ähnlichkeit zwischen Whisper und Zweitmeinung (0–1), null = keine brauchbare Zweitmeinung */
  second_sim?: number | null
}

export interface TranscriptDoc {
  version?: number
  source_lang: string
  target_lang: string
  speakers: { id: string; name: string; color: string }[]
  segments: TranscriptSegment[]
  runs?: Record<string, any>[]
  updated?: number
  /** womit gerechnet wurde (vom Server zusammengefasst, im Prüfpaket fest eingetragen) */
  credits?: TranscriptCredits | null
}

/** Modelle (Hersteller, Lizenz), Grafikkarten und Programmstand der Läufe der Übersetzer-Spur */
export interface TranscriptCredits {
  local: boolean
  models: { role: 'asr' | 'translate' | 'second' | 'vad' | string; id: string; name: string; by: string; license: string; license_url: string }[]
  /** festgehaltene Karten; gpus_now = Karte des Auswerte-Rechners für Läufe ohne Eintrag (unrecorded) */
  gpus: string[]
  gpus_now: string[]
  runs: number
  unrecorded: number
  programs: string[]
}

/** Daten eines Schiffsschreibers: je Sekunde ein Wert (null = keiner) */
export interface VdrSeries { t0_utc: number; dt: number; n: number; series: Record<string, { label_de: string; label_en: string; unit: string; values: (number | null)[] }> }
export interface VdrEvent { t: number; end: number | null; kind: string; label: string; detail: string; source: string }
export interface VdrImages { sources: { id: string; label: string; count: number }[]; frames: Record<string, [number, string][]> }

export interface AudioStatus {
  root: string
  models_dir: string
  env_ready: boolean
  env: string
  nvidia: boolean
  free_gb: number
  models: AudioModel[]
  recommended: Record<string, string>
  projects: AudioProjectSummary[]
  tasks: Record<string, { label: string; stems: string[] }>
  stem_labels: Record<string, string>
}

export interface AudioOp {
  kind: 'classic' | 'ai' | 'learned'
  /** bei kind = learned: das gelernte Geräusch */
  profile?: string
  track: string
  chain?: Record<string, any>[]
  model?: string
  task?: string
  params?: Record<string, any>
  region?: [number, number] | null
  name?: string
}

/** Kennung dieses Browserfensters: Es lädt bei seinen eigenen Speicher-Meldungen nicht neu */
export const CLIENT_ID = Math.random().toString(36).slice(2, 12)

/** Prüf-App (eigenständig, ohne Server): Ton, Video und Dateien kommen aus dem Fallordner. Der Haken liefert dann für
 * eine Server-Adresse eine Objekt-URL; ohne Prüf-App bleibt er leer. */
export const mediaHook: { url?: (path: string) => string | undefined } = {}
const media = (path: string): string => mediaHook.url?.(path) ?? path

export function audioSpecUrl(pid: string, tid: string, level: '0' | '1' | '2' | '3' | 'act' | 'vad'): string {
  return `/api/audio/projects/${encodeURIComponent(pid)}/spec/${encodeURIComponent(tid)}/${level}`
}

export function vdrImageUrl(pid: string, source: string, index: number): string {
  return `/api/audio/projects/${encodeURIComponent(pid)}/vdr/image/${encodeURIComponent(source)}/${index}`
}

export function audioVideoUrl(pid: string): string {
  return media(`/api/audio/projects/${encodeURIComponent(pid)}/video`)
}

export function audioSourceUrl(pid: string): string {
  return media(`/api/audio/projects/${encodeURIComponent(pid)}/source`)
}

export function audioFileUrl(pid: string, area: 'tracks' | 'peaks' | 'proxy' | 'exports' | 'data', name: string): string {
  return media(`/api/audio/projects/${encodeURIComponent(pid)}/files/${area}/${encodeURIComponent(name)}`)
}

export interface LoraCheckpoint { file: string; epoch: number; final: boolean; size_mb: number }

export interface LoraRun {
  id: string
  name: string
  trigger: string
  class_word?: string
  dataset_id?: string
  images?: number
  settings: LoraTrainSettings
  status: 'scheduled' | 'queued' | 'running' | 'done' | 'error' | 'cancelled' | string
  /** geplanter Start (Unix-Sekunden), solange status = scheduled */
  start_at?: number
  queued?: number
  started?: number
  finished?: number
  job_id?: string
  error?: string | null
  log?: string
  checkpoints: LoraCheckpoint[]
  test_prompts?: string[]
  tests: { prompts?: string[]; images?: Record<string, string[]>; time?: number; model_id?: string }
  adopted?: { checkpoint: string; model_id: string; time: number }[]
  /** Verlauf des Verlusts: [Schritt, gleitender Mittelwert] (nur in GET /runs/{id}) */
  loss?: [number, number][]
  /** während des Trainings: Stand und Tempo */
  live?: { step: number; steps: number; epoch: number; epochs: number; s_per_step: number | null; eta: string; loss: number | null; time: number } | null
  /** angeforderte Pause, solange der Lauf noch rechnet */
  pause?: 'epoch' | 'now' | null
  /** Haltepunkt zum Fortsetzen: Zustand nach dieser Epoche */
  state?: { dir: string; epoch: number; size_mb: number } | null
  epochs_done?: number
  /** Abzweigung: Epoche des Zwischenstands, ab dem es weiterging */
  epoch_base?: number
  parent?: { run: string; checkpoint: string; epoch: number }
  quick?: { file: string; checkpoint: string; epoch: number; strength: number; prompt: string; seed: number; time: number }[]
  note?: string | null
  resumed?: number | null
}

export interface LoraFilePart { key: string; label: string; size_gb: number; installed: boolean }

export interface LoraTrainStatus {
  root: string
  nvidia: boolean
  vendor: string | null
  vram_gb: number | null
  free_gb: number
  tool: { installed: boolean; version: string | null; tag: string; size_gb: number; uv: boolean }
  weights: LoraFilePart[]
  edit: LoraFilePart[]
  base: { installed: boolean; model_id: string | null; te_fp8: boolean }
  ready: boolean
  template_ready: boolean
  defaults: Required<LoraTrainSettings>
  timing: { seconds_per_step: number; te_seconds_per_caption: number; test_seconds_per_image: number;
    edit_seconds_per_image: number }
  poses: string[]
  test_prompts: string[]
  min_images: number
  datasets: LoraDatasetSummary[]
  runs: LoraRun[]
}

/** Prüfung einer LoRA-Datei vor dem Hochladen (POST /api/loras/inspect), aus ihrem safetensors-Kopf. */
export interface LoraCheck {
  /** LoRA mit erkannter Basis, für die es ein Modell im Katalog gibt */
  ok: boolean
  /** überhaupt eine LoRA */
  lora: boolean
  /** am Dateikopf erkannte Basis (LORA_BASE_LABEL); null = nicht erkannt */
  family: string | null
  /** erkannte Basis oder Vorschlag aus den Metadaten der Datei */
  suggested: string | null
  /** Katalogmodelle, die LoRAs dieser Basis nehmen */
  catalog: string[]
  verdict: string
  /** Trigger-Wörter aus den Metadaten der Datei */
  trigger: string
  /** Wan 2.2 A14B: Experte laut Dateiname */
  expert: 'high' | 'low' | null
  /** Vorschlag für den Namen: der Dateiname ohne Endung */
  name: string
}

export type LoraExpert = 'high' | 'low' | 'both'

/** Zuordnung einer LoRA: Basis (bei welchen Modellen sie erscheint), Name, Trigger, bei Wan 14B der Experte. */
export interface LoraAssignment {
  family: string
  name: string
  trigger: string
  expert?: LoraExpert | ''
}

export interface LoraUploadResult {
  model: ModelInfo
  /** dieselbe Datei war schon da; sie bekam nur die neuen Angaben */
  existing: boolean
  /** Zuordnung weicht vom Dateikopf ab */
  warning: string
}

/** Ein Treffer der Hugging-Face-Suche (GET /api/models/search). */
export interface HfResult {
  repo: string
  downloads: number
  likes: number
  license: string
  gated: boolean
  pipeline_tag: string
  /** safetensors-Dateien, die als Checkpoint in Frage kommen */
  files: string[]
  /** Erkannte Modellteile: Diffusionsmodell, Text-Encoder, VAE, LoRA … */
  parts: { file: string; kind: HfPartKind }[]
  /** Was das Repo im Ganzen ist: ladbare Checkpoints, Teile eines Modells, LoRA oder nichts davon */
  kind: 'checkpoint' | 'parts' | 'lora' | 'other'
  /** Grundmodell laut Repo-Tags, z. B. "Qwen/Qwen-Image-2.1" */
  base_model: string
  /** Warum keine Datei in Frage kommt (Diffusers, GGUF …) */
  note: string
  /** LoRA-Repos: Basis laut Tags (loras.BASES) und Trigger-Wörter aus der Modellkarte */
  lora_base?: string | null
  trigger?: string
}

/** Ergebnis der Prüfung vor dem Laden (GET /api/models/inspect). */
export type HfPartKind = 'lora' | 'text_encoder' | 'vae' | 'controlnet' | 'upscaler' | 'diffusion'

export interface HfCheck {
  repo: string
  file: string
  ok: boolean
  family: string | null
  workflow: string | null
  size_gb: number | null
  verdict: string
  /** Katalogmodelle mit derselben Architektur */
  catalog?: string[]
  /** LoRAs: kind 'lora', family = LoRA-Basis, Trigger-Wörter */
  kind?: 'lora'
  trigger?: string
}

/** Ein Treffer der Civitai-Suche (GET /api/civitai/search), je Modell die neueste Version. */
export interface CivitaiResult {
  model_id: number
  version_id: number
  name: string
  version: string
  base_model: string
  lora_base: string | null
  targets: string[]
  trigger: string
  file: string
  size_gb: number
  url: string
  page: string
  nsfw: boolean
  commercial: string
  creator: string
  downloads: number
}

export interface CivitaiCheck {
  ok: boolean
  family: string | null
  checked: boolean
  catalog: string[]
  verdict: string
  size_gb?: number | null
  trigger?: string
}

export interface ModelSize {
  label: string
  w: number
  h: number
}

export interface ModelFeatures {
  steps: number
  cfg: number
  /** Wirkt der negative Prompt? Nur bei CFG > 1. */
  negative_prompt: boolean
  /** Greift, wenn kein eigener Negativprompt angegeben ist. */
  default_negative: string
  /** FLUX 3: Prompt-Upsampler baut die Anfrage vorher aus. */
  upsampler: boolean
  /** Wie viele Referenzbilder das Modell nimmt (0 = keine). */
  references: number
  bbox: boolean
  img2img: boolean
  /** Maske (Inpainting) und damit auch Outpainting. */
  mask: boolean
  /** Erweitern: über ein Referenzbild (FLUX 3 u. a.), über eine Maske (Qwen) oder gar nicht. */
  outpaint: 'reference' | 'mask' | null
  hires: boolean
  text_rendering: boolean
  /** Zusätzliche, für dieses Modell empfohlene Formate. */
  sizes: ModelSize[]
  prompt_hint: string
  placeholder: string
  // Video, LTX-2.5 (seit 0.5.8). auto_duration, dfr und temporal_upscale sind nur true, wenn die
  // optionalen Dateien da sind; sonst nennt missing die Seite auf Hugging Face.
  start_image: 'optional' | boolean
  end_image: boolean
  loop: boolean
  audio_input: boolean
  auto_duration: boolean
  dfr: boolean
  temporal_upscale: boolean
  motion_speed: boolean
  multishot: boolean
  fps: number
  max_seconds: number
  // Videomodelle mit eigenem Bilderraster (seit 31.10.2026): Vorgabe, Grenzen und Schritt der Bildzahl, dazu die
  // Rundungsregel für den Hinweis (sonst 4n+1).
  default_frames: number
  min_frames: number
  max_frames: number
  frame_step: number
  frame_rule: string
  /** Kandinsky 6 (seit 0.5.25): eigene Tonbeschreibung (audio_prompt) mit Beispieltext */
  audio_prompt?: boolean
  audio_placeholder?: string
  missing: Record<string, string>
  // Krea 2 (seit 0.5.10): Referenzbilder geben nur den Stil vor, freigeschaltet durch die optionale
  // Stil-LoRA (style_reference); ohne sie steht die Quelle unter missing.style_reference.
  reference_kind: 'style'
  style_reference: boolean
  // LoRAs: empfohlene Stärke, wozu sie gehört, für welche Modellfamilien empfohlen, Testergebnis. tested gibt es auch bei
  // Modellen: gemessene Zeiten, kurz unter dem Modell angezeigt.
  strength: number
  use: 'start_image' | 'end_image' | 'audio_input' | 'motion_speed' | 'loop'
  recommended_for: string[]
  tested: string
  // MiniMax H3 (seit 0.5.18): Beschleuniger, die das Modell auf dieser Karte kennt, und die gemessene Empfehlung, die
  // die Generieren-Seite beim Wechsel aufs Modell vorwählt (Studio und MCP bekommen sie vom Server).
  sparse_attention: SparseAttention[]
  int8_attention: boolean
  /** Vorwahl für das bestmögliche Ergebnis (seit 0.5.18): Format [w, h], Länge in s, Qualität; bei MiniMax H3 auch
   *  Turbo-LoRA, Sparse Attention und INT8-Attention */
  recommended: {
    size?: [number, number]; seconds?: number; quality?: 'standard' | 'dfr'
    loras?: LoraRef[]; sparse_attention?: SparseAttention; int8_attention?: boolean
  }
  /** Turbo-LoRAs (MiniMax H3): Schritte, Shift, Sampler; immer nur eine aktiv */
  turbo: { steps: number; shift?: number[]; sampler?: string; scheduler?: string; ref_image_size?: string }
}

export type SparseAttention = 'sol-attn' | 'veda'

export interface Health {
  ok: boolean
  comfy_running: boolean
  gpu: { name: string; vram_total_mb: number; vram_free_mb: number | null } | null
  active_models: Record<GenKind, string | null>
  queue_depth: number
  current_job: string | null
  download_queue_depth: number
  current_download: string | null
  hf_token: boolean
  /** Mesh-Worker (TripoSG, TRELLIS.2) je Schlüssel — eingerichtet und laufend. */
  mesh_workers: Record<string, { name: string; ready: boolean; running: boolean }>
  /** Was gerade wirklich im VRAM liegt. Leer = nichts geladen. */
  vram_loaded: { backend: string; model: string }[]
  /** Alle Karten (experimentell seit 0.5). Fehlt bei älteren Servern. */
  gpus?: GpuInfo[]
  /** Eigenes ComfyUI für die Sprachmodelle, wenn sie auf einer anderen Karte liegen. */
  text_backend?: { separate: boolean; running: boolean; loaded: string | null }
  /** Keine Karte, auf der PyTorch rechnet: ComfyUI läuft auf dem Prozessor (GitHub-Issue #3). */
  cpu_mode?: {
    reason: 'amd_unsupported' | 'no_gpu_compute' | string
    cards: string[]
    /** seit 0.5.33: ComfyUI rechnet über DirectML auf der Radeon (GitHub-Issue #3) */
    directml?: { device: string } | null
    /** DirectML war eingerichtet, startete aber in dieser Sitzung nicht */
    directml_failed?: string | null
  } | null
}

export type GpuRole = 'image' | 'text' | 'mesh'

/** GET /api/settings/folders: Daten- und Modellordner (Setup-Fassung: änderbar). */
export interface FolderSettings {
  data_dir: string
  models_dir: string
  models_dir_set: boolean
  data_free_gb: number | null
  models_free_gb: number | null
  managed: boolean
  env_override: string[]
  can_restart: boolean
}

/** POST /api/report: anonymisierter Fehlerbericht fuer GitHub. */
export interface ProblemReport {
  filename: string
  text: string
  created_at: number
  summary: { version: string; os: string; graphics: string; driver: string; torch?: string; last_error: string | null; time: string }
  issues_url: string
}

export interface GpuInfo {
  index: number
  vendor: 'nvidia' | 'amd'
  name: string
  vram_total_mb: number
  vram_used_mb: number | null
  roles: GpuRole[]
  /** Die Karte mit dem meisten Grafikspeicher (bei Gleichstand der neueren Architektur). */
  strongest?: boolean
  /** Anschluss (seit 0.5.10): höchste Generation, ausgehandelte Breite, nutzbare GB/s */
  pcie_gen?: number | null
  pcie_width?: number | null
  pcie_gbps?: number | null
}

export interface DeleteResult {
  model_id: string
  removed: string[]
  freed_gb: number
  failed: string[]
}

export interface ImageParams {
  loras?: LoraRef[]
  prompt: string
  negative_prompt?: string
  model_id?: string | null
  width?: number
  height?: number
  steps?: number | null
  cfg?: number | null
  seed?: number | null
  batch_size?: number
  sampler?: string | null
  scheduler?: string | null
  /** Vorhandenes Bild ueberarbeiten statt neu wuerfeln */
  image_asset_id?: string | null
  denoise?: number
  /** Bild über den Rand hinaus erweitern: [links, oben, rechts, unten] in Pixeln */
  outpaint?: number[] | null
  /** Nur FLUX 3: bis zu 10 Referenzbilder, im Prompt "the first image", ... */
  reference_asset_ids?: string[]
  /** Nur FLUX 3: Upsampler an (null = Modellstandard) */
  upsample_prompt?: boolean | null
  /** Zweiter Sampling-Durchgang auf vergroessertem Latent */
  hires?: boolean
  hires_scale?: number
  hires_denoise?: number
  /** SkipLayerGuidanceSD3 — wirkt nur bei SD3-Modellen */
  slg?: boolean
  slg_scale?: number
  /** Form aus einer Vorlage erzwingen */
  controlnet_model_id?: string | null
  controlnet_image_asset_id?: string | null
  controlnet_strength?: number
  controlnet_end?: number
  controlnet_preprocess?: 'none' | 'canny'
  /** Studio-Projekt: das Ergebnis gleich in seinen Ordner statt in den Verlauf (seit 0.5.15) */
  project_id?: string | null
}

export interface AudioParams {
  prompt: string
  negative_prompt?: string
  model_id?: string | null
  seconds?: number
  steps?: number | null
  cfg?: number | null
  seed?: number | null
  /** Studio-Projekt: das Ergebnis gleich in seinen Ordner statt in den Verlauf (seit 0.5.15) */
  project_id?: string | null
}

/** Sprecherstimme (seit 0.5.21, Qwen3-TTS): Stimme aus einer Beschreibung oder einer Aufnahme. */
export interface SpeechParams {
  text: string
  voice?: string
  voice_asset_id?: string | null
  voice_text?: string
  language?: SpeechLanguage
  model_id?: string | null
  seed?: number | null
  project_id?: string | null
}

export type SpeechLanguage = 'auto' | 'de' | 'en' | 'fr' | 'es' | 'it' | 'pt' | 'ru' | 'zh' | 'ja' | 'ko'

/** Sprachen von Qwen3-TTS, jeweils in ihrer eigenen Schreibweise (nur „Automatisch“ übersetzt). */
export const SPEECH_LANGUAGES: { id: SpeechLanguage; label: string }[] = [
  { id: 'auto', label: t('Automatisch', 'Automatic') },
  { id: 'de', label: 'Deutsch' }, { id: 'en', label: 'English' }, { id: 'fr', label: 'Français' },
  { id: 'es', label: 'Español' }, { id: 'it', label: 'Italiano' }, { id: 'pt', label: 'Português' },
  { id: 'ru', label: 'Русский' }, { id: 'zh', label: '中文' }, { id: 'ja', label: '日本語' }, { id: 'ko', label: '한국어' },
]

/** Hardware-Katalog (seit 0.5.28): die rechnende Karte und typische Rechenzeit je Modell für sie */
export interface HardwareDevice {
  name: string | null
  vendor: string | null
  vram_gb: number | null
  catalog_id: string | null
  catalog_name?: string | null
  arch?: string | null
  laptop?: boolean | null
  speed: number | null
  path: string | null
  uncertain?: boolean
  reference?: string
}

export interface HardwareInfo {
  device: HardwareDevice
  /** je Modell-ID: Sekunden für einen typischen Auftrag (task) auf dieser Karte */
  estimates: Record<string, { seconds: number; task: string; measured: boolean }>
  catalog: { devices: number; generated: string | null }
}

/** Assistent im Studio (seit 0.5.28): ein Modell je Aufgabe, für diese Karte gewählt (beste Qualität zuerst) */
export interface WizardModel {
  id: string
  name: string
  family: string
  installed: boolean
  runnable: boolean
  /** angefangener Download */
  partial: boolean
  recommended: boolean
  size_gb: number
  vram_gb: number
  fits_vram: string
  dfr: boolean
  commercial_ok: boolean
  license: string
  /** Video: Ton aus dem Bild, Lippen zum vorgegebenen Satz, Schleife (Endbild = Startbild) */
  sound: boolean
  lipsync: boolean
  loop: boolean
  /** gesperrte Hugging-Face-Repos ohne Freigabe für den hinterlegten Token */
  gated: string[]
}

export type WizardRole = 'image' | 'video' | 'speech' | 'music'

/** Plan des Assistenten: erkannte Karte (Hardware-Katalog), Modelle, Bildgröße, Qualität, geschätzte Rechenzeiten */
export interface WizardPlan {
  device: HardwareDevice
  models: { image: WizardModel | null; video: WizardModel | null; speech: WizardModel | null; music: WizardModel | null }
  width: number
  height: number
  tier: string
  quality: 'dfr' | 'standard'
  /** zur Wahl je Aufgabe, die beste zuerst; best = vorgewählt */
  options: Record<WizardRole, WizardModel[]>
  best: Record<WizardRole, string | null>
  /** seconds null: keine Messung für das gewählte Modell (source 'unknown'); 'rough' = aus einem anderen Modell hochgerechnet */
  steps: { key: string; seconds: number | null; source: 'history' | 'estimate' | 'rough' | 'unknown'; runs: number }[]
  total_seconds: number
  notes: string[]
}

export interface VideoParams {
  loras?: LoraRef[]
  prompt: string
  negative_prompt?: string
  model_id?: string | null
  width?: number
  height?: number
  frames?: number
  fps?: number
  steps?: number | null
  cfg?: number | null
  seed?: number | null
  /** Startbild fuer Bild-zu-Video. Bei I2V-Modellen Pflicht. */
  image_asset_id?: string | null
  /** Nur Videomodelle mit features.references (MiniMax H3 Referenz): Figur, Gesicht, Stil statt erstem Bild */
  reference_asset_ids?: string[]
  // Beschleuniger (features.sparse_attention, int8_attention). recommended=false: genau das, was hier steht; ohne
  // ergänzt der Server die Empfehlung des Modells.
  sparse_attention?: SparseAttention | null
  int8_attention?: boolean | null
  recommended?: boolean
  // Nur LTX-2.5 (features des Modells)
  end_image_asset_id?: string | null
  loop?: boolean
  quality?: 'standard' | 'dfr'
  temporal_upscale?: boolean
  auto_duration?: boolean
  audio_asset_id?: string | null
  motion_speed?: number
  /** Nur Modelle mit features.audio_prompt (Kandinsky 6): was zu hören ist, getrennt vom Bild */
  audio_prompt?: string
  /** verlustfreie Kopie (FFV1/MKV) neben dem MP4, Vorgabe an */
  master?: boolean
  /** Studio-Projekt: das Ergebnis gleich in seinen Ordner statt in den Verlauf (seit 0.5.15) */
  project_id?: string | null
}

/** POST /api/image/restore (server: schemas.RestoreImageRequest). */
/** auto (Vorgabe): der Upsampler von FLUX 3 prüft auf Wasserflecken und Rissnetze -> thorough, sonst gentle. */
export type RestoreMode = 'auto' | 'thorough' | 'gentle'

export interface RestoreParams {
  image_asset_id: string
  repair: boolean
  repair_mode: RestoreMode
  colorize: boolean
  sharpen: boolean
  scale: number
  notes: string
  batch_size: number
  model_id?: string | null
  upscale_model_id?: string | null
  seed?: number | null
  /** Studio-Projekt: das Ergebnis gleich in seinen Ordner statt in den Verlauf (seit 0.5.15) */
  project_id?: string | null
}

/** VHS-Bereich (seit 0.5.16): Ergebnis von POST /api/vhs/analyze (server/nvai/vhs_tools.py analyze) */
export interface VhsInfo {
  width: number
  height: number
  fps: [number, number]
  seconds: number | null
  codec: string
  standard: 'PAL' | 'NTSC' | 'other'
  interlaced: boolean
  parity: 'tff' | 'bff'
  aspect: '4:3' | '16:9'
  square_size: [number, number]
  crop: { left: number; top: number; right: number; bottom: number }
  out_fps: [number, number]
  audio: { codec: string; rate: number; channels: number } | null
  sar?: [number, number] | null
  /** 16:9-Datei ohne seitliche Säulen: vom Wandler vermutlich von 4:3 in die Breite gezogen */
  stretched?: boolean
  suggest_aspect?: 'source' | '4:3'
  /** Bildtakt einer 30-fps-Aufnahme: 50to30 = aus 50 Halbbildern/s ausgewählt (Schritte 40/40/20 ms) */
  cadence?: { kind: 'unknown' | 'native' | 'even' | 'mixed' | '50to30' | '25to30'; windows: number }
  /** Sprung an 8-px-Rastergrenzen gegen dazwischen; über 1,1 = sichtbare Blockkanten */
  blockiness?: number
  blocky?: boolean
}

export type VhsAspect = 'auto' | 'source' | '4:3' | '16:9'
export type VhsDeinterlace = 'auto' | 'double' | 'single' | 'off'
export type VhsDenoise = 'off' | 'light' | 'medium' | 'strong'
export type VhsAiSize = '720' | '1080' | 'original'
export type VhsSharpen = 'off' | 'light' | 'medium' | 'strong'
export type VhsChroma = 'off' | 'clean' | 'strong'

export interface VhsSettings {
  deinterlace: VhsDeinterlace
  parity: 'auto' | 'tff' | 'bff'
  crop: [number, number, number, number]
  aspect: VhsAspect
  denoise: VhsDenoise
  /** Farbflecken: clean = neue Farbstufe (auch true), strong = Filter vom 28.10. nachmittags, off */
  chroma_denoise: boolean | VhsChroma
  /** Blockkanten der Kompression glätten (Vorschlag der Analyse) */
  deblock: boolean
  sharpen: VhsSharpen
  /** Takt glätten: 30 fps aus einem 50-Hz-Band mit RIFE-Zwischenbildern auf 50 fps (cadence 50to30) */
  smooth: boolean
  chroma_shift: number
  levels: boolean
  deflicker: boolean
  stabilize: boolean
  ai: boolean
  ai_size: VhsAiSize
  audio_denoise: boolean
  loudnorm: boolean
  codec: 'h264' | 'hevc'
}

export interface VhsAnalysis {
  asset_id: string
  info: VhsInfo
  defaults: VhsSettings
  thumb_url: string
  estimate: { frames: number; classic_s: number; ai_s: number; total_s: number }
}

export interface VhsParams extends VhsSettings {
  asset_id: string
  preview: boolean
  start: number
  duration?: number | null
  upscale_model_id?: string | null
  project_id?: string | null
}

export interface Mesh3DParams {
  image_asset_id: string
  model_id?: string | null
  steps?: number
  guidance?: number
  seed?: number | null
  faces?: number
  remove_background?: boolean
  /** Vorderseite aus dem Bild (seit 0.5.10): Quellbild auf die sichtbare Vorderseite projizieren */
  project_front?: boolean
  /** Nur TRELLIS.2 */
  resolution?: number
  texture_size?: number
  background_mode?: 'birefnet' | 'flood' | 'alpha'
  clean_specks?: boolean
  speck_ratio?: number
}

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      // Der Server antwortet in derselben Sprache (Modelltexte, Hinweise, Fehler).
      'Accept-Language': getLang(),
      ...(init?.headers ?? {}),
    },
  })
  if (!res.ok) throw new Error(errorText(await res.text()))
  return res.json() as Promise<T>
}

/** Fehlertext einer Serverantwort: FastAPI schickt {detail: "…"}, bei ungültigen Feldern (422) aber eine Liste
 * [{loc, msg}] -- die erschien sonst als „[object Object]“, und niemand sah, welches Feld nicht passt. */
export function errorText(body: string): string {
  try {
    const detail = JSON.parse(body).detail
    if (typeof detail === 'string') return detail
    if (Array.isArray(detail)) {
      return detail
        .map((d: { loc?: unknown[]; msg?: string }) => {
          const field = (d.loc ?? []).filter((x) => x !== 'body').join('.')
          return field ? `${field}: ${d.msg ?? ''}` : String(d.msg ?? '')
        })
        .join('; ')
    }
    if (detail != null) return JSON.stringify(detail)
  } catch {
    /* Klartext-Fehler unveraendert lassen */
  }
  return body.slice(0, 400)
}

/** Welche Upsampler-Fassung die Karte der Sprachmodelle bekommt und ob sie ganz hineinpasst. */
export interface UpsamplerFit {
  variant: 'int8' | 'w4a8' | 'bf16'
  need_gb: number
  card: number
  card_gb: number | null
  fits: boolean
}

export const api = {
  health: () => req<Health>('/api/health'),
  version: () => req<{ version: string; comfyui: string | null }>('/api/version'),
  startBackend: () => req<{ started: boolean }>('/api/backend/start', { method: 'POST' }),
  freeVram: () => req<{ ok: boolean; freed: string[] }>('/api/backend/free', { method: 'POST' }),
  gpus: () =>
    req<{ gpus: GpuInfo[]; assignment: Record<GpuRole, number>; vendor: 'nvidia' | 'amd' | null;
      separate_text_backend: boolean; recommended?: Record<GpuRole, number>; auto?: boolean
      upsampler?: UpsamplerFit | null }>('/api/gpus'),
  /** Teilangaben verschieben einzelne Aufgaben; {auto: true} stellt die automatische Verteilung her. */
  setGpus: (a: Partial<Record<GpuRole, number>> | { auto: true }) =>
    req<{ assignment: Record<GpuRole, number>; separate_text_backend: boolean; auto?: boolean }>(
      '/api/gpus', { method: 'PUT', body: JSON.stringify(a) },
    ),
  /** Stoppt den laufenden GPU-Job (Generierung), nicht die Downloads. */
  cancelCurrentJob: () =>
    req<{ ok: boolean; job_id?: string; stopped?: string[]; reason?: string }>(
      '/api/jobs/current/cancel',
      { method: 'POST' },
    ),
  backendLog: () => req<{ log: string }>('/api/backend/log'),

  models: (kind?: ModelKind) => req<ModelInfo[]>(`/api/models${kind ? `?kind=${kind}` : ''}`),
  /** clean=true löscht einen unvollständigen Stand vorher und lädt frisch. */
  downloadModel: (model_id: string, clean = false) =>
    req<Job>('/api/models/download', {
      method: 'POST',
      body: JSON.stringify({ model_id, clean }),
    }),
  hfTokenStatus: () => req<{ logged_in: boolean; name: string | null }>('/api/settings/hf-token'),
  setHfToken: (token: string) =>
    req<{ logged_in: boolean; name: string | null }>('/api/settings/hf-token', {
      method: 'POST',
      body: JSON.stringify({ token }),
    }),
  deleteHfToken: () =>
    req<{ logged_in: boolean; name: string | null }>('/api/settings/hf-token', {
      method: 'DELETE',
    }),
  searchHf: (q: string, limit = 50, kind?: 'lora') =>
    req<HfResult[]>(`/api/models/search?q=${encodeURIComponent(q)}&limit=${limit}${kind ? `&kind=${kind}` : ''}`),
  civitaiStatus: () => req<{ logged_in: boolean; name: string | null }>('/api/settings/civitai'),
  setCivitaiToken: (token: string) =>
    req<{ logged_in: boolean; name: string | null }>('/api/settings/civitai', {
      method: 'POST', body: JSON.stringify({ token }),
    }),
  deleteCivitaiToken: () =>
    req<{ logged_in: boolean; name: string | null }>('/api/settings/civitai', { method: 'DELETE' }),
  searchCivitai: (q: string, loraBase?: string) =>
    req<CivitaiResult[]>(
      `/api/civitai/search?q=${encodeURIComponent(q)}&limit=40${loraBase ? `&lora_base=${encodeURIComponent(loraBase)}` : ''}`,
    ),
  checkCivitai: (r: CivitaiResult) =>
    req<CivitaiCheck>(
      `/api/civitai/check?url=${encodeURIComponent(r.url)}&base_model=${encodeURIComponent(r.base_model)}`,
    ),
  /** Lädt eine Civitai-LoRA direkt von dort und nimmt sie in den Katalog auf. */
  downloadCivitai: (r: CivitaiResult, family: string, trigger: string) =>
    req<Job>('/api/models/download', {
      method: 'POST',
      body: JSON.stringify({
        repo: `civitai/${r.name.replace(/[^\w.-]+/g, '_').slice(0, 60)}`,
        file: r.file, kind: 'lora', family, workflow: null, target: 'loras',
        license: r.commercial ? `Civitai: ${r.commercial}` : 'Civitai',
        size_gb: r.size_gb, url: r.url, source_url: r.page, trigger,
      }),
    }),
  inspectHf: (repo: string, file: string) =>
    req<HfCheck>(
      `/api/models/inspect?repo=${encodeURIComponent(repo)}&file=${encodeURIComponent(file)}`,
    ),
  /** Lädt eine geprüfte Datei aus der Suche und nimmt sie in den Katalog auf. */
  downloadChecked: (c: HfCheck, license: string) =>
    req<Job>('/api/models/download', {
      method: 'POST',
      body: JSON.stringify({
        repo: c.repo,
        file: c.file,
        target: 'checkpoints',
        kind: 'image',
        family: c.family,
        workflow: c.workflow,
        license: license || null,
        size_gb: c.size_gb,
        ...(c.kind === 'lora'
          ? { kind: 'lora', target: 'loras', workflow: null, trigger: c.trigger ?? '' }
          : {}),
      }),
    }),
  deleteModel: (model_id: string) =>
    req<DeleteResult>(`/api/models/${model_id}`, { method: 'DELETE' }),
  /** Prüft eine LoRA-Datei vor dem Hochladen. An den Server geht nur ihr Anfang: 8 Byte Kopflänge und der
   * safetensors-Kopf (meist wenige KB), nicht die ganze Datei. */
  inspectLora: async (file: File) => {
    const first = new DataView(await file.slice(0, 8).arrayBuffer())
    let end = Math.min(8, file.size)
    if (first.byteLength === 8) {
      // Kopflänge als 64-Bit-Zahl (little endian). Was nicht passt, schickt nur die 8 Byte; der Server meldet es.
      const n = first.getUint32(0, true) + first.getUint32(4, true) * 2 ** 32
      if (n > 0 && n <= 64 * 1024 * 1024 && 8 + n <= file.size) end = 8 + n
    }
    return req<LoraCheck>(`/api/loras/inspect?file_name=${encodeURIComponent(file.name)}`, {
      method: 'POST', body: file.slice(0, end), headers: { 'Content-Type': 'application/octet-stream' },
    })
  },
  /** Lädt eine LoRA-Datei hoch und ordnet sie zu. XHR statt fetch: nur so gibt es den Fortschritt beim Senden. */
  uploadLora: (file: File, a: LoraAssignment, onProgress?: (fraction: number) => void, signal?: AbortSignal) =>
    new Promise<LoraUploadResult>((resolve, reject) => {
      const q = new URLSearchParams({
        file_name: file.name, family: a.family, name: a.name, trigger: a.trigger, expert: a.expert ?? '',
      })
      const xhr = new XMLHttpRequest()
      xhr.open('POST', `/api/loras/upload?${q}`)
      xhr.setRequestHeader('Content-Type', 'application/octet-stream')
      xhr.setRequestHeader('Accept-Language', getLang())
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) onProgress?.(e.loaded / e.total)
      }
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) resolve(JSON.parse(xhr.responseText) as LoraUploadResult)
        else reject(new Error(errorText(xhr.responseText)))
      }
      xhr.onerror = () =>
        reject(new Error(t('Verbindung zum Server unterbrochen.', 'The connection to the server was interrupted.')))
      xhr.onabort = () => reject(new DOMException('aborted', 'AbortError'))
      signal?.addEventListener('abort', () => xhr.abort())
      xhr.send(file)
    }),
  /** Zuordnung einer LoRA aus dem Nutzer-Katalog ändern; fehlende Felder bleiben, wie sie sind. */
  updateLora: (id: string, a: Partial<LoraAssignment>) =>
    req<ModelInfo>(`/api/loras/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(a) }),
  // Bereich „Audio“ (seit 17.11.2026)
  audioStatus: () => req<AudioStatus>('/api/audio/status'),
  audioSetup: (o: { env?: boolean; models?: string[] }) => req<Job>('/api/audio/setup', { method: 'POST', body: JSON.stringify(o) }),
  audioModelDelete: (id: string) => req<{ ok: boolean }>(`/api/audio/models/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  audioCreate: (o: { asset_id?: string; path?: string; name?: string }) =>
    req<AudioProject>('/api/audio/projects', { method: 'POST', body: JSON.stringify(o) }),
  audioProject: (id: string) => req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}`),
  /** Einlesen wiederholen, etwa nach einem Abbruch oder Fehler (seit 0.5.31; VDR-Fälle lesen ihren Export neu) */
  audioPrepare: (id: string) => req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/prepare`, { method: 'POST' }),
  audioProjectUpdate: (id: string, o: { name?: string }) =>
    req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify(o) }),
  audioProjectDelete: (id: string) => req<{ ok: boolean; trash: string }>(`/api/audio/projects/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  audioTrash: () => req<AudioTrashEntry[]>('/api/audio/trash'),
  audioTrashRestore: (entry: string) => req<{ ok: boolean; id: string }>(`/api/audio/trash/${encodeURIComponent(entry)}/restore`, { method: 'POST' }),
  audioTrashPurge: (entry: string) => req<{ ok: boolean; count: number; freed: number }>(`/api/audio/trash/${encodeURIComponent(entry)}`, { method: 'DELETE' }),
  audioTrashEmpty: () => req<{ ok: boolean; count: number; freed: number }>('/api/audio/trash', { method: 'DELETE' }),
  audioTrack: (id: string, tid: string, o: Partial<Pick<AudioTrack, 'name' | 'gain_db' | 'mute' | 'solo' | 'color'>>) =>
    req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}/tracks/${encodeURIComponent(tid)}`, { method: 'PUT', body: JSON.stringify(o) }),
  audioTrackDelete: (id: string, tid: string) =>
    req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}/tracks/${encodeURIComponent(tid)}`, { method: 'DELETE' }),
  audioMarkers: (id: string, markers: AudioMarker[]) =>
    req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}/markers`, { method: 'PUT', body: JSON.stringify({ markers }) }),
  audioOp: (id: string, op: AudioOp) => req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/ops`, { method: 'POST', body: JSON.stringify(op) }),
  audioLearn: (id: string, o: { name: string; track: string; steps: number }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/learn`, { method: 'POST', body: JSON.stringify(o) }),
  audioScan: (id: string, track = 't_orig') => req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/scan?track=${encodeURIComponent(track)}`, { method: 'POST' }),
  audioProfileDelete: (id: string, prof: string) =>
    req<AudioProject>(`/api/audio/projects/${encodeURIComponent(id)}/profiles/${encodeURIComponent(prof)}`, { method: 'DELETE' }),
  audioPackageEstimate: (id: string) => req<{ base: number; images: number; video: number; video_name: string | null; originals: Record<string, number>; app: boolean }>(`/api/audio/projects/${encodeURIComponent(id)}/package/estimate`),
  audioPackage: (id: string, o: { dest_dir: string; images: boolean; video: boolean; originals: string[] }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/package`, { method: 'POST', body: JSON.stringify(o) }),
  audioReveal: (id: string, index: number) => req<{ ok: boolean }>(`/api/audio/projects/${encodeURIComponent(id)}/reveal/${index}`, { method: 'POST' }),
  audioExport: (id: string, o: { tracks: { id: string; gain_db: number; mute?: boolean }[]; format: string; into_video: boolean; name?: string; mono?: boolean; region?: [number, number] | null; dest_dir?: string | null }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/export`, { method: 'POST', body: JSON.stringify(o) }),
  // Ton-Forensik (seit 17.11.2026 abends, Server: audio_forensic.py, audio_vdr.py)
  audioSpectro: (id: string, tid: string) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/tracks/${encodeURIComponent(tid)}/spectro`, { method: 'POST' }),
  audioActivity: (id: string, tid: string) =>
    req<{ track: string; rate: number; method: string; segments: [number, number][]; speech_seconds: number }>(`/api/audio/projects/${encodeURIComponent(id)}/activity/${encodeURIComponent(tid)}`),
  audioTranscript: (id: string) => req<TranscriptDoc>(`/api/audio/projects/${encodeURIComponent(id)}/transcript`),
  audioHash: (id: string) => req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/hash`, { method: 'POST' }),
  audioVideoLink: (id: string, path: string, method: 'clock' | 'audio' = 'clock') =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/video`, { method: 'POST', body: JSON.stringify({ path, method }) }),
  audioVideoExport: (id: string, o: { tracks: { id: string; gain_db: number; mute?: boolean }[]; region: [number, number] | null; subtitles: 'none' | 'original' | 'translation'; burn?: boolean; mono: boolean; name?: string; dest_dir?: string | null }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/video/export`, { method: 'POST', body: JSON.stringify(o) }),
  audioRenderVideo: (id: string, o: { panels: string[]; tracks: { id: string; gain_db: number; view: string }[]; region: [number, number] | null; fps: number; mono: boolean; lang: string; spec: { lo: number; hi: number; fmax: number }; dest_dir?: string | null }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/render`, { method: 'POST', body: JSON.stringify(o) }),
  audioVad: (id: string, tracks: string[]) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/vad`, { method: 'POST', body: JSON.stringify({ tracks }) }),
  audioAutomix: (id: string, tracks: string[]) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/automix`, { method: 'POST', body: JSON.stringify({ tracks }) }),
  audioTranscribe: (id: string, o: { tracks: string[]; source_lang: string; target_lang: string; region: [number, number] | null; translate?: boolean; force?: boolean }) =>
    req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/transcribe`, { method: 'POST', body: JSON.stringify(o) }),
  audioTranscriptSave: (id: string, doc: TranscriptDoc) =>
    req<TranscriptDoc>(`/api/audio/projects/${encodeURIComponent(id)}/transcript`, { method: 'PUT', body: JSON.stringify({ ...doc, client: CLIENT_ID }) }),
  vdrInspect: (path: string) => req<Record<string, any>>('/api/audio/vdr/inspect', { method: 'POST', body: JSON.stringify({ path }) }),
  vdrCreate: (o: { path: string; name?: string }) => req<AudioProject>('/api/audio/vdr/projects', { method: 'POST', body: JSON.stringify(o) }),
  vdrVerify: (id: string) => req<Job>(`/api/audio/projects/${encodeURIComponent(id)}/vdr/verify`, { method: 'POST' }),
  vdrRaw: (id: string, time: number) =>
    req<{ block: string; start: number; lines: { t: number; channel: string; text: string }[] }>(`/api/audio/projects/${encodeURIComponent(id)}/vdr/raw?t=${time}`),
  // LoRA erstellen/Bearbeiten (seit 0.5.29)
  loraTrainStatus: () => req<LoraTrainStatus>('/api/lora-train/status'),
  loraTrainSetup: (parts: ('tool' | 'weights' | 'edit')[]) =>
    req<Job>('/api/lora-train/setup', { method: 'POST', body: JSON.stringify({ parts }) }),
  loraDatasetCreate: (d: { name: string; trigger: string; class_word: string; notes?: string }) =>
    req<LoraDataset>('/api/lora-train/datasets', { method: 'POST', body: JSON.stringify(d) }),
  loraDataset: (id: string) => req<LoraDataset>(`/api/lora-train/datasets/${id}`),
  loraDatasetUpdate: (id: string, d: Partial<Pick<LoraDataset, 'name' | 'trigger' | 'class_word' | 'notes'>>) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}`, { method: 'PUT', body: JSON.stringify(d) }),
  loraDatasetDelete: (id: string) => req<{ ok: boolean }>(`/api/lora-train/datasets/${id}`, { method: 'DELETE' }),
  loraDatasetAddAssets: (id: string, asset_ids: string[], caption = '') =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/assets`, { method: 'POST', body: JSON.stringify({ asset_ids, caption }) }),
  loraDatasetAddFolder: (id: string, path: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/folder`, { method: 'POST', body: JSON.stringify({ path }) }),
  loraDatasetTemplate: (id: string, asset_id: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/template`, { method: 'POST', body: JSON.stringify({ asset_id }) }),
  loraDatasetGenerate: (id: string, o: { count?: number; notes?: string; replace?: string[]; sources?: string[] }) =>
    req<Job>(`/api/lora-train/datasets/${id}/generate`, { method: 'POST', body: JSON.stringify(o) }),
  loraDatasetSketch: (id: string, asset_id: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/sketch`, { method: 'POST', body: JSON.stringify({ asset_id }) }),
  loraDatasetDrafts: (id: string, o: { count: number; notes?: string }) =>
    req<Job>(`/api/lora-train/datasets/${id}/drafts`, { method: 'POST', body: JSON.stringify(o) }),
  loraDatasetDraftsClear: (id: string, keep?: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/drafts${keep ? `?keep=${encodeURIComponent(keep)}` : ''}`, { method: 'DELETE' }),
  loraTemplatePick: (id: string, file: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/template/pick`, { method: 'POST', body: JSON.stringify({ file }) }),
  loraImageUpdate: (id: string, file: string, d: { caption?: string; status?: 'keep' | 'reject' }) =>
    req<LoraTrainImage>(`/api/lora-train/datasets/${id}/images/${encodeURIComponent(file)}`, { method: 'PUT', body: JSON.stringify(d) }),
  loraImageDelete: (id: string, file: string) =>
    req<LoraDataset>(`/api/lora-train/datasets/${id}/images/${encodeURIComponent(file)}`, { method: 'DELETE' }),
  /** Sofort: der Auftrag. Mit start_at (Unix-Sekunden): der vorgemerkte Lauf mit scheduled = true. */
  loraTrain: (id: string, s: Required<LoraTrainSettings> & { test: boolean; prompts: string[]; start_at?: number }) =>
    req<Job | (LoraRun & { scheduled: true })>(`/api/lora-train/datasets/${id}/train`, { method: 'POST', body: JSON.stringify(s) }),
  loraRun: (id: string) => req<LoraRun>(`/api/lora-train/runs/${encodeURIComponent(id)}`),
  loraRunTest: (id: string, prompts: string[]) =>
    req<Job>(`/api/lora-train/runs/${encodeURIComponent(id)}/test`, { method: 'POST', body: JSON.stringify({ prompts }) }),
  loraRunAdopt: (id: string, checkpoint: string, name: string) =>
    req<{ model: ModelInfo }>(`/api/lora-train/runs/${encodeURIComponent(id)}/adopt`, { method: 'POST', body: JSON.stringify({ checkpoint, name }) }),
  loraRunDelete: (id: string) => req<{ ok: boolean }>(`/api/lora-train/runs/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  loraRunPause: (id: string, mode: 'epoch' | 'now') =>
    req<LoraRun>(`/api/lora-train/runs/${encodeURIComponent(id)}/pause`, { method: 'POST', body: JSON.stringify({ mode }) }),
  loraRunResume: (id: string, o: { epochs?: number; test?: boolean; start_at?: number }) =>
    req<LoraRun & { scheduled?: boolean }>(`/api/lora-train/runs/${encodeURIComponent(id)}/resume`, { method: 'POST', body: JSON.stringify(o) }),
  loraRunBranch: (id: string, o: { checkpoint: string; epochs: number; lr: string; save_every?: number; test?: boolean; start_at?: number }) =>
    req<LoraRun & { scheduled?: boolean }>(`/api/lora-train/runs/${encodeURIComponent(id)}/branch`, { method: 'POST', body: JSON.stringify(o) }),
  loraRunQuick: (id: string, o: { checkpoint: string; prompt: string; strengths: number[]; seed: number }) =>
    req<Job>(`/api/lora-train/runs/${encodeURIComponent(id)}/quicktest`, { method: 'POST', body: JSON.stringify(o) }),
  loraRunLog: (id: string, lines = 80) => req<{ path: string | null; lines: string[] }>(`/api/lora-train/runs/${encodeURIComponent(id)}/log?lines=${lines}`),
  loraRunStateDelete: (id: string) => req<LoraRun>(`/api/lora-train/runs/${encodeURIComponent(id)}/state`, { method: 'DELETE' }),
  /** Einen Job abbrechen: wartend sofort, Generierung sofort, Download nach dem aktuellen Datenblock. */
  cancelJob: (id: string) =>
    req<{ ok: boolean; job_id?: string; reason?: string; pending?: boolean; stopped?: string[] }>(
      `/api/jobs/${id}/cancel`, { method: 'POST' },
    ),
  cancelDownloads: () =>
    req<{ ok: boolean; cancelled: number; was_running: string | null }>(
      '/api/downloads/cancel',
      { method: 'POST' },
    ),
  cleanupPartial: () =>
    req<{ ok: boolean; cleaned: { model_id: string; name: string }[]; freed_gb: number }>(
      '/api/models/cleanup',
      { method: 'POST' },
    ),
  setActiveModel: (model_id: string) =>
    req<{ active_model: string; kind: ModelKind }>('/api/models/active', {
      method: 'POST',
      body: JSON.stringify({ model_id }),
    }),
  /** Favorit setzen/entfernen. Ohne Wert wird umgeschaltet. */
  toggleFavorite: (model_id: string, favorite?: boolean) =>
    req<{ model_id: string; favorite: boolean }>(`/api/models/${model_id}/favorite`, {
      method: 'POST',
      body: JSON.stringify(favorite === undefined ? {} : { favorite }),
    }),
  /** Eigene Genehmigung für die Lizenz des Modells bestätigen oder widerrufen (gilt für alle Modelle der Lizenz). */
  confirmLicense: (model_id: string, confirmed: boolean) =>
    req<{ model_id: string; license: string; confirmed: boolean }>(`/api/models/${model_id}/license`, {
      method: 'POST',
      body: JSON.stringify({ confirmed }),
    }),

  generateImage: (p: ImageParams) =>
    req<Job>('/api/generate/image', { method: 'POST', body: JSON.stringify(p) }),
  /** Prompt ausbauen: der FLUX-3-Upsampler schreibt die volle Bildbeschreibung, für jedes Bildmodell. */
  folders: () => req<FolderSettings>('/api/settings/folders'),
  checkFolder: (path: string) =>
    req<{ path: string; free_gb: number | null }>('/api/settings/folders/check', { method: 'POST', body: JSON.stringify({ path }) }),
  browseFolder: (initial: string) =>
    req<{ path: string | null }>('/api/settings/folders/browse', { method: 'POST', body: JSON.stringify({ initial }) }),
  saveFolders: (f: { data_dir?: string; models_dir?: string }) =>
    req<{ saved: Record<string, string>; restart_needed: boolean }>('/api/settings/folders', { method: 'PUT', body: JSON.stringify(f) }),
  restart: () => req<{ ok: boolean }>('/api/restart', { method: 'POST' }),
  report: (description: string) =>
    req<ProblemReport>('/api/report', { method: 'POST', body: JSON.stringify({ description }) }),
  expandPrompt: (p: {
    prompt: string; width: number; height: number; reference_asset_ids?: string[]
    target?: ExpandTarget
  }) =>
    req<{ prompt: string; expanded: string; seconds: number }>(
      '/api/prompt/expand', { method: 'POST', body: JSON.stringify(p) },
    ),
  generateAudio: (p: AudioParams) =>
    req<Job>('/api/generate/audio', { method: 'POST', body: JSON.stringify(p) }),
  generateSpeech: (p: SpeechParams) =>
    req<Job>('/api/generate/speech', { method: 'POST', body: JSON.stringify(p) }),
  generateVideo: (p: VideoParams) =>
    req<Job>('/api/generate/video', { method: 'POST', body: JSON.stringify(p) }),
  generate3D: (p: Mesh3DParams) =>
    req<Job>('/api/generate/3d', { method: 'POST', body: JSON.stringify(p) }),
  /** Foto restaurieren (seit 0.5.11): Schäden entfernen, einfärben, schärfen. */
  restoreImage: (p: RestoreParams) =>
    req<Job>('/api/image/restore', { method: 'POST', body: JSON.stringify(p) }),
  /** Video hochskalieren (seit 0.5.23): RelayVSR verdoppelt Breite und Höhe, Ton und Bildrate bleiben. */
  upscaleVideo: (p: { asset_id: string; detail?: number; model_id?: string | null; project_id?: string | null }) =>
    req<Job>('/api/video/upscale', { method: 'POST', body: JSON.stringify(p) }),
  vhsAnalyze: (asset_id: string) =>
    req<VhsAnalysis>('/api/vhs/analyze', { method: 'POST', body: JSON.stringify({ asset_id }) }),
  vhsProcess: (p: VhsParams) => req<Job>('/api/vhs/process', { method: 'POST', body: JSON.stringify(p) }),

  /** Bild-Upload als Quelle für Bild→3D. Kein JSON — FormData. `folder`: ein Projektordner (Material im Studio). */
  upload: async (file: File, folder?: string) => {
    const fd = new FormData()
    fd.append('file', file)
    if (folder) fd.append('folder', folder)
    // Content-Type setzt der Browser selbst (multipart mit Boundary), die Sprache nicht.
    const res = await fetch('/api/upload', {
      method: 'POST',
      body: fd,
      headers: { 'Accept-Language': getLang() },
    })
    if (!res.ok) throw new Error(`${res.status}: ${(await res.text()).slice(0, 300)}`)
    return (await res.json()) as Asset
  },

  /** Neueste zuerst; `exclude` laesst eine Art weg (Verlauf: Downloads). `folder` (seit 0.5.15): ohne Angabe alles samt
   * Projektordnern, '' nur der allgemeine Verlauf, 'Studio/<Name>' ein Projektordner. */
  jobs: (limit = 50, offset = 0, exclude?: string, folder?: string) =>
    req<Job[]>(`/api/jobs?limit=${limit}&offset=${offset}${exclude ? `&exclude=${exclude}` : ''}${folder !== undefined ? `&folder=${encodeURIComponent(folder)}` : ''}`),
  /** Alle wartenden und laufenden Aufträge einer Art, unabhängig davon, wie viele neuere es gibt */
  activeJobs: (kind: string) => req<Job[]>(`/api/jobs?limit=1000&kind=${encodeURIComponent(kind)}&active=true`),
  job: (id: string) => req<Job>(`/api/jobs/${id}`),
  jobAssets: (id: string) => req<Asset[]>(`/api/jobs/${id}/assets`),
  assets: (kind?: string, limit = 100) =>
    req<Asset[]>(`/api/assets?limit=${limit}${kind ? `&kind=${kind}` : ''}`),
  /** Eine Seite fürs Material des Studios: media zählt Uploads nach Endung dazu, q sucht in allen Assets, folder nur
   * in einem Ordner ('' = oberste Ebene) */
  assetPage: (opts: { media: 'all' | 'image' | 'video' | 'audio'; q?: string; folder?: string; limit: number; offset: number }) =>
    req<Asset[]>(`/api/assets?media=${opts.media}&limit=${opts.limit}&offset=${opts.offset}${opts.q ? `&q=${encodeURIComponent(opts.q)}` : ''}${opts.folder !== undefined ? `&folder=${encodeURIComponent(opts.folder)}` : ''}`),
  /** Die Projektordner (seit 0.5.15) */
  assetFolders: () => req<AssetFolder[]>('/api/folders'),
  /** Einen Projektordner im Explorer öffnen (nur auf dem Rechner mit NVAI-open) */
  revealFolder: (path: string) => req<{ ok: boolean; path: string }>('/api/folders/reveal', { method: 'POST', body: JSON.stringify({ path }) }),
  asset: (id: string) => req<Asset>(`/api/assets/${id}`),

  // Studio (seit 0.6): Projekte mit Komposition und Schnitt; jede Änderung ist ein Befehl.
  studioProjects: () => req<StudioProjectInfo[]>('/api/studio/projects'),
  studioCreate: (name: string, width = 1920, height = 1080, fps: [number, number] = [24, 1]) =>
    req<StudioProject>('/api/studio/projects', { method: 'POST', body: JSON.stringify({ name, width, height, fps }) }),
  studioProject: (id: string) => req<StudioProject>(`/api/studio/projects/${id}`),
  studioDelete: (id: string) => req<{ ok: boolean }>(`/api/studio/projects/${id}`, { method: 'DELETE' }),
  studioCommand: (id: string, command: string, params: Record<string, unknown> = {}) =>
    req<{ project: StudioProject; result: any }>(`/api/studio/projects/${id}/command`, {
      method: 'POST',
      body: JSON.stringify({ command, params }),
    }),
  studioUndo: (id: string) => req<StudioProject>(`/api/studio/projects/${id}/undo`, { method: 'POST' }),
  studioRedo: (id: string) => req<StudioProject>(`/api/studio/projects/${id}/redo`, { method: 'POST' }),
  studioGenerate: (id: string, scene_ids?: string[]) =>
    req<{ jobs: Record<string, string>; waiting: Record<string, string>; errors: Record<string, string> }>(`/api/studio/projects/${id}/generate`, {
      method: 'POST',
      body: JSON.stringify(scene_ids ? { scene_ids } : {}),
    }),
  /** „Startbild erzeugen“ für eine Videoszene: zwei Varianten im Projektordner (seit 0.5.30) */
  studioStartImage: (id: string, sceneId: string) =>
    req<Job>(`/api/studio/projects/${id}/scenes/${sceneId}/start-image`, { method: 'POST' }),
  /** Erzeugen abbrechen: laufende und wartende Aufträge der Szenen, wartende Anschlüsse (seit 0.5.19) */
  studioCancel: (id: string) =>
    req<{ cancelled: string[] }>(`/api/studio/projects/${id}/cancel`, { method: 'POST' }),
  studioExport: (id: string, preset: string) =>
    req<Job>(`/api/studio/projects/${id}/export`, { method: 'POST', body: JSON.stringify({ preset }) }),
  studioPresets: () => req<{ id: string; label: string; codec: string; ext: string }[]>('/api/studio/presets'),
  /** Hardware-Katalog (seit 0.5.28): erkannte Karte und typische Zeiten je Modell */
  hardware: () => req<HardwareInfo>('/api/hardware'),
  /** Assistent (seit 0.5.28): Karte, Modelle und geschätzte Zeiten für ein Vorhaben */
  studioWizardPlan: (body: Record<string, unknown>) =>
    req<WizardPlan>('/api/studio/wizard/plan', { method: 'POST', body: JSON.stringify(body) }),
  studioConformPlan: (id: string) =>
    req<{ items: StudioConformItem[]; without_take: number; transition_markers: number; spoken_in_video?: number }>(`/api/studio/projects/${id}/conform`),
  studioPackageInfo: (id: string) =>
    req<{ name: string; files: number; bytes: number; master_bytes: number }>(`/api/studio/projects/${id}/package/info`),
  /** Download-Adresse des Pakets (ZIP); der Browser lädt es über einen Link */
  studioPackageUrl: (id: string, masters: boolean) => `/api/studio/projects/${id}/package?masters=${masters ? 'true' : 'false'}`,
  studioImport: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    // wie upload: den Content-Type (multipart mit Boundary) setzt der Browser
    const res = await fetch('/api/studio/import', { method: 'POST', body: fd, headers: { 'Accept-Language': getLang() } })
    if (!res.ok) throw new Error(errorText(await res.text()))
    return (await res.json()) as StudioProject
  },
  revealAsset: (id: string) => req<{ ok: boolean; path: string }>(`/api/assets/${id}/reveal`, { method: 'POST' }),

  /** H.264-Vorschau für ein Video, das der Browser nicht abspielt (MKV, MOV …); fertig meldet assets.changed */
  assetPreview: (id: string) => req<{ ok: boolean }>(`/api/assets/${id}/preview`, { method: 'POST' }),
  deleteAsset: (id: string) =>
    req<{ ok: boolean; freed_mb: number }>(`/api/assets/${id}`, { method: 'DELETE' }),
  deleteJob: (id: string) =>
    req<{ ok: boolean; assets: number; freed_mb: number }>(`/api/jobs/${id}`, { method: 'DELETE' }),
  clearHistory: (kind?: string) =>
    req<{ ok: boolean; jobs: number; assets: number; freed_mb: number }>(
      `/api/history${kind ? `?kind=${kind}` : ''}`,
      { method: 'DELETE' },
    ),
}

export type ServerEvent =
  | { type: 'ping' }
  | { type: 'job.queued'; job_id: string; kind: string }
  | { type: 'job.started'; job_id: string }
  | { type: 'job.progress'; job_id: string; progress: number; stage: string }
  | { type: 'job.done'; job_id: string; asset_ids: string[] }
  | { type: 'job.error'; job_id: string; error: string }
  | { type: 'job.cancelled'; job_id: string }
  | StudioChangedEvent
  | { type: 'assets.changed' }
  /** LoRA hinzugefügt, zugeordnet oder gelöscht (auch per MCP): Modelllisten neu laden */
  | { type: 'models.changed' }
  /** LoRA erstellen/Bearbeiten: Datensatz oder Training geändert (neue Bilder, Zwischenstände, Probebilder) */
  | { type: 'lora.changed'; dataset_id?: string; run_id?: string }
  /** Bereich „Audio“: Projekt oder Modelle geändert */
  | { type: 'audio.changed'; project_id?: string }
  /** Ton-Forensik: Übersetzer-Spur geändert */
  | { type: 'audio.transcript'; project_id: string; client?: string }

/** Ein Studio-Projekt wurde gespeichert (Befehl, Claude per MCP, fertiger Auftrag, startender Anschluss). */
export type StudioChangedEvent = { type: 'studio.changed'; project_id: string; updated_at: number | null }

/** Reconnectender WebSocket auf den Job-Event-Feed. */
export function connectEvents(onEvent: (e: ServerEvent) => void): () => void {
  let ws: WebSocket | null = null
  let closed = false
  let retry: number | undefined

  const open = () => {
    if (closed) return
    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    ws = new WebSocket(`${proto}://${location.host}/ws`)
    ws.onmessage = (ev) => onEvent(JSON.parse(ev.data))
    ws.onclose = () => {
      if (!closed) retry = window.setTimeout(open, 2000)
    }
    ws.onerror = () => ws?.close()
  }
  open()

  return () => {
    closed = true
    if (retry) clearTimeout(retry)
    ws?.close()
  }
}

export const KIND_LABEL: Record<ModelKind, string> = {
  image: t('Bild', 'Image'),
  audio: 'Audio',
  speech: t('Sprache', 'Speech'),
  video: 'Video',
  '3d': '3D',
  controlnet: 'ControlNet',
  lora: 'LoRA',
  upscale: t('Hochskalieren', 'Upscale'),
  interpolate: t('Zwischenbilder', 'Frame interpolation'),
  video_upscale: t('Video hochskalieren', 'Upscale video'),
}

/** Anzeigenamen der LoRA-Basen (server: loras.BASES). */
export const LORA_BASE_LABEL: Record<string, string> = {
  sdxl: 'SDXL (Pony, Illustrious, NoobAI …)',
  sd15: 'SD 1.5',
  qwenimage: 'Qwen-Image',
  zimage: 'Z-Image',
  flux1: 'FLUX.1 / Chroma',
  flux2: 'FLUX.2 Klein',
  'wan-1.3b': 'Wan 2.1 1.3B',
  'wan-5b': 'Wan 2.2 TI2V 5B',
  'wan-14b': 'Wan 14B (2.1, 2.2 A14B)',
  ltx2: 'LTX-2 / 2.3',
  ltxv: 'LTX-Video 0.9',
  minimax_h3_fl2va: 'MiniMax H3 FL2VA',
  minimax_h3_ref2va: 'MiniMax H3 Ref2VA',
}

// ------------------------------------------------------------------------------------------- Studio

/** Zeit in Ticks wie bei FilmCraft: 254 016 000 000 je Sekunde (teilt jede Bild- und Abtastrate). */
export const TPS = 254_016_000_000

export type StudioLane = 'video' | 'voice' | 'music' | 'sfx'
export type StudioMarkerKind = 'place' | 'transition' | 'chain' | 'audio' | 'ai' | 'note'

export interface StudioScene {
  id: string
  lane: StudioLane
  start: number
  duration: number
  title: string
  prompt: string
  kind: 'video' | 'image' | 'audio'
  model_id: string | null
  lyrics: string
  params: Record<string, any>
  chain_from: string | null
  /** Anschluss kommt aus einem Marker (nur angezeigt, nicht gespeichert) */
  chain_marker?: string
  /** Wartet auf die Vorlage, die im selben Lauf entsteht */
  waiting_for?: string
  takes: string[]
  take: string | null
  jobs: string[]
  error: string | null
  status: 'empty' | 'waiting' | 'running' | 'done' | 'error'
  /** Hinweise wie im Assistenten: zu lang für die Karte, Figur ohne Startbild, Prompt nicht englisch … (seit 0.5.30) */
  hints?: string[]
}

export interface StudioMarker {
  id: string
  at: number
  duration: number
  kind: StudioMarkerKind
  name: string
  comment: string
  color: string
  params: Record<string, any>
  done: boolean
}

export interface StudioClip {
  /** Datei gelöscht (nur in der Ansicht) */
  missing?: boolean
  id: string
  track: string
  asset_id: string
  scene_id: string | null
  start: number
  in: number
  out: number
  /** 1 = 100 %; die Länge auf der Zeitleiste ist (out − in) / speed */
  speed?: number
  gain_db: number
  muted: boolean
  /** Übergang am Anfang; marker: kommt von einem Übergang-Marker (wandert mit ihm) */
  transition: { kind: StudioTransitionKind; duration: number; marker?: string } | null
  /** Skalieren (seit 0.5.16): 1 = 100 %, gilt ohne Keyframes */
  scale?: number
  /** Fokuspunkt [x, y] von 0 bis 1: bleibt beim Skalieren an seiner Stelle (Vorgabe Mitte) */
  anchor?: [number, number]
  /** Keyframes der Skalierung, `at` in Ticks Medienzeit wie in/out; dazwischen linear */
  scale_keys?: { at: number; value: number }[]
}

export type StudioTransitionKind = 'dissolve' | 'dip_black' | 'dip_white' | 'wipe'

export interface StudioTrack {
  id: string
  kind: 'video' | 'audio'
  /** Bild der Videospur aus (Vorschau und Export) */
  hidden?: boolean
  /** Ton der Spur aus, bei Videospuren der Ton ihrer Clips */
  muted?: boolean
  /** 'voice': die Tonspur „Stimme“, auf die das Übernehmen Sprecherzeilen legt (seit 0.5.22) */
  lane?: 'voice'
}

/** Was „Übernehmen“ täte (GET /api/studio/projects/{id}/conform) */
export interface StudioConformItem {
  scene_id: string
  title: string
  lane: StudioLane
  track: string
  /** Name der Spur, nur bei der Spur „Stimme“ */
  track_name?: string
  /** die Spur „Stimme“ gibt es noch nicht, das Übernehmen legt sie an */
  track_new?: boolean
  action: 'create' | 'replace' | 'same' | 'error'
  start_s?: number
  length_s?: number
  scene_s?: number
  clip_ids?: string[]
  overlaps?: { clip_id: string; title: string; seconds: number }[]
  in_edit?: boolean
  edited?: boolean
  error?: string
  default: boolean
}

export interface StudioMedia {
  kind: 'video' | 'image' | 'audio'
  duration: number | null
  audio?: boolean
  width?: number
  height?: number
}

export interface StudioProject {
  id: string
  name: string
  settings: { width: number; height: number; fps: [number, number]; sample_rate: number; video_quality?: 'dfr' | 'standard' }
  scenes: StudioScene[]
  markers: StudioMarker[]
  tracks: StudioTrack[]
  clips: StudioClip[]
  media: Record<string, StudioMedia>
  /** Adresse und Art aller verwendeten Assets (Takes und Clips) */
  assets: Record<string, { url: string; kind: string; prompt: string; preview?: string }>
  tps: number
  edit_duration: number
  composition_duration: number
  history: { undo: number; redo: number }
  /** eigener Ordner im Material (Studio/<Name>, seit 0.5.15) */
  folder?: string
  /** Figuren (seit 0.5.24): Aussehen über LoRAs, Stimme wie bei Sprecher-Szenen */
  characters?: StudioCharacter[]
  updated_at: number
}

/** Eine Figur im Studio-Projekt (seit 0.5.24). Bild- und Videoszenen nennen sie in params.characters (ihre LoRAs, die
 * zum Modell passen, und deren Trigger), Sprecher-Szenen in params.character (ihre Stimme); eine Videoszene mit
 * params.audio_from spricht den Satz einer Sprecher-Szene, LTX-2.5 bewegt die Lippen dazu. */
export interface StudioCharacter {
  id: string
  name: string
  loras: { model_id: string; strength: number }[]
  /** Beschreibung der Stimme */
  voice: string
  /** Sprecher-Szene, deren Take die Stimme vorgibt */
  voice_from: string | null
  /** Aufnahme als Vorlage, mit voice_text wortgenau */
  voice_asset_id: string | null
  voice_text: string
  language: string
}

export interface StudioProjectInfo {
  id: string
  name: string
  updated_at: number
  scenes: number
  clips: number
  duration_s: number
  folder?: string | null
}
