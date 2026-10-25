// Duenner Typ-Layer ueber die REST-API. Spiegelt server/nvai/schemas.py.

import { getLang, t } from './i18n'

export type JobStatus = 'queued' | 'running' | 'done' | 'error' | 'cancelled'
export type AssetKind = 'image' | 'audio' | 'video' | 'mesh' | 'upload'
/** 'controlnet' erzeugt nichts eigenstaendig — es ist ein Zusatz zum Bild-Modus. Ebenso 'upscale'
 * (SeedVR2): es schärft beim Restaurieren. */
export type ModelKind = 'image' | 'audio' | 'video' | '3d' | 'controlnet' | 'lora' | 'upscale'

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
  filename: string
  url: string
  thumb_url: string | null
  prompt: string
  model_id: string
  meta: Record<string, any>
  created_at: number
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
  missing: Record<string, string>
  // Krea 2 (seit 0.5.10): Referenzbilder geben nur den Stil vor, freigeschaltet durch die optionale
  // Stil-LoRA (style_reference); ohne sie steht die Quelle unter missing.style_reference.
  reference_kind: 'style'
  style_reference: boolean
  // LoRAs: empfohlene Stärke, wozu sie gehört, für welche Modellfamilien empfohlen, Testergebnis
  strength: number
  use: 'start_image' | 'end_image' | 'audio_input' | 'motion_speed' | 'loop'
  recommended_for: string[]
  tested: string
}

export interface Health {
  ok: boolean
  comfy_running: boolean
  gpu: { name: string; vram_total_mb: number; vram_free_mb: number } | null
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
  summary: { version: string; os: string; graphics: string; driver: string; last_error: string | null; time: string }
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
}

export interface AudioParams {
  prompt: string
  negative_prompt?: string
  lyrics?: string
  model_id?: string | null
  seconds?: number
  steps?: number | null
  cfg?: number | null
  seed?: number | null
  bpm?: number | null
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
  // Nur LTX-2.5 (features des Modells)
  end_image_asset_id?: string | null
  loop?: boolean
  quality?: 'standard' | 'dfr'
  temporal_upscale?: boolean
  auto_duration?: boolean
  audio_asset_id?: string | null
  motion_speed?: number
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

  /** Bild-Upload als Quelle für Bild→3D. Kein JSON — FormData. */
  upload: async (file: File) => {
    const fd = new FormData()
    fd.append('file', file)
    // Content-Type setzt der Browser selbst (multipart mit Boundary), die Sprache nicht.
    const res = await fetch('/api/upload', {
      method: 'POST',
      body: fd,
      headers: { 'Accept-Language': getLang() },
    })
    if (!res.ok) throw new Error(`${res.status}: ${(await res.text()).slice(0, 300)}`)
    return (await res.json()) as Asset
  },

  /** Neueste zuerst; `exclude` laesst eine Art weg (Verlauf: Downloads). */
  jobs: (limit = 50, offset = 0, exclude?: string) =>
    req<Job[]>(`/api/jobs?limit=${limit}&offset=${offset}${exclude ? `&exclude=${exclude}` : ''}`),
  job: (id: string) => req<Job>(`/api/jobs/${id}`),
  jobAssets: (id: string) => req<Asset[]>(`/api/jobs/${id}/assets`),
  assets: (kind?: string, limit = 100) =>
    req<Asset[]>(`/api/assets?limit=${limit}${kind ? `&kind=${kind}` : ''}`),
  asset: (id: string) => req<Asset>(`/api/assets/${id}`),

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
