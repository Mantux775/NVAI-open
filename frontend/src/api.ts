// Duenner Typ-Layer ueber die REST-API. Spiegelt server/nvai/schemas.py.

import { getLang, t } from './i18n'

export type JobStatus = 'queued' | 'running' | 'done' | 'error' | 'cancelled'
export type AssetKind = 'image' | 'audio' | 'video' | 'mesh' | 'upload'
/** 'controlnet' erzeugt nichts eigenstaendig — es ist ein Zusatz zum Bild-Modus. Ebenso 'upscale'
 * (SeedVR2): es schärft beim Restaurieren. */
export type ModelKind = 'image' | 'audio' | 'video' | '3d' | 'controlnet' | 'lora' | 'upscale' | 'interpolate'

/** Eine LoRA beim Generieren: Katalog-ID (kind 'lora') und Stärke. */
export interface LoraRef {
  model_id: string
  strength: number
}
/** Die vier Modi, die wirklich etwas erzeugen. */
export type GenKind = 'image' | 'audio' | 'video' | '3d'
// Wofür "Prompt ausbauen" schreibt (server/nvai/prompt_targets.py)
export type ExpandTarget = 'image' | 'video' | 'video_sound' | 'video_multishot' | 'video_start' | 'sfx' | 'music' | 'music_sa3' | '3d'

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
  if (!res.ok) {
    const body = await res.text()
    let detail = body.slice(0, 400)
    try {
      detail = JSON.parse(body).detail ?? detail
    } catch {
      /* Klartext-Fehler unveraendert lassen */
    }
    throw new Error(detail)
  }
  return res.json() as Promise<T>
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
  generateVideo: (p: VideoParams) =>
    req<Job>('/api/generate/video', { method: 'POST', body: JSON.stringify(p) }),
  generate3D: (p: Mesh3DParams) =>
    req<Job>('/api/generate/3d', { method: 'POST', body: JSON.stringify(p) }),
  /** Foto restaurieren (seit 0.5.11): Schäden entfernen, einfärben, schärfen. */
  restoreImage: (p: RestoreParams) =>
    req<Job>('/api/image/restore', { method: 'POST', body: JSON.stringify(p) }),
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
  studioExport: (id: string, preset: string) =>
    req<Job>(`/api/studio/projects/${id}/export`, { method: 'POST', body: JSON.stringify({ preset }) }),
  studioPresets: () => req<{ id: string; label: string; codec: string; ext: string }[]>('/api/studio/presets'),
  studioConformPlan: (id: string) =>
    req<{ items: StudioConformItem[]; without_take: number; transition_markers: number }>(`/api/studio/projects/${id}/conform`),
  studioPackageInfo: (id: string) =>
    req<{ name: string; files: number; bytes: number; master_bytes: number }>(`/api/studio/projects/${id}/package/info`),
  /** Download-Adresse des Pakets (ZIP); der Browser lädt es über einen Link */
  studioPackageUrl: (id: string, masters: boolean) => `/api/studio/projects/${id}/package?masters=${masters ? 'true' : 'false'}`,
  studioImport: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    // wie upload: den Content-Type (multipart mit Boundary) setzt der Browser
    const res = await fetch('/api/studio/import', { method: 'POST', body: fd, headers: { 'Accept-Language': getLang() } })
    if (!res.ok) {
      const body = await res.text()
      let detail = body.slice(0, 400)
      try {
        detail = JSON.parse(body).detail ?? detail
      } catch {
        /* Klartext */
      }
      throw new Error(detail)
    }
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
  video: 'Video',
  '3d': '3D',
  controlnet: 'ControlNet',
  lora: 'LoRA',
  upscale: t('Hochskalieren', 'Upscale'),
  interpolate: t('Zwischenbilder', 'Frame interpolation'),
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
}

/** Was „Übernehmen“ täte (GET /api/studio/projects/{id}/conform) */
export interface StudioConformItem {
  scene_id: string
  title: string
  lane: StudioLane
  track: string
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
  updated_at: number
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
