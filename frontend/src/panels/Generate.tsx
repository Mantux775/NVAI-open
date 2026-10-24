import { useEffect, useMemo, useRef, useState } from 'react'
import { api, type ExpandTarget, type LoraRef, type Asset, type GenKind, type Health, type ModelInfo, type ServerEvent } from '../api'
import { AssetView } from '../components/AssetView'
import type { Downloads } from '../downloads'
import { ContentBadge } from '../components/ContentBadge'
import { locale, t } from '../i18n'

// Dezimalzahl im Format der gewählten Sprache (Deutsch mit Komma)
const dec = (n: number, digits: number) =>
  n.toLocaleString(locale(), { minimumFractionDigits: digits, maximumFractionDigits: digits })

type Mode = GenKind

const MODES: { id: Mode; label: string; icon: string }[] = [
  { id: 'image', label: t('Bild', 'Image'), icon: '▣' },
  { id: 'audio', label: 'Audio', icon: '♪' },
  { id: 'video', label: 'Video', icon: '▶' },
  { id: '3d', label: '3D', icon: '◈' },
]

// Video-Workflows, die ohne Startbild nicht laufen (siehe workflows.py).
const I2V_WORKFLOWS = new Set(['wan_i2v', 'wan22_i2v', 'hunyuan15_i2v', 'kandinsky5_i2v'])
// Diese nehmen ein Startbild, wenn eines gewählt ist, sonst Text zu Video (workflows.OPTIONAL_START_WORKFLOWS).
const OPTIONAL_START_WORKFLOWS = new Set(['wan22_ti2v', 'ltx25', 'ltx23'])

// Allgemeine Formate, alle rund 1 Megapixel. Das Format folgt der Silhouette: ein
// stehender Mensch im Quadrat verliert eher Beine und bekommt weniger Pixel für die
// Teile, auf die es ankommt. Modelle mit eigenen Empfehlungen (Qwen nativ, FLUX 3
// bis 4 MP) bringen weitere über features.sizes mit.
const IMAGE_SIZES = [
  { label: t('832 × 1216 — Figuren, Soldaten', '832 × 1216 — figures, soldiers'), w: 832, h: 1216 },
  { label: t('896 × 1152 — Figuren, moderat', '896 × 1152 — figures, moderate'), w: 896, h: 1152 },
  { label: t('1024 × 1024 — Objekte, Icons', '1024 × 1024 — objects, icons'), w: 1024, h: 1024 },
  { label: t('1216 × 832 — Fahrzeuge quer', '1216 × 832 — vehicles, landscape'), w: 1216, h: 832 },
  { label: t('1344 × 768 — breit, Panorama', '1344 × 768 — wide, panorama'), w: 1344, h: 768 },
  { label: t('512 × 512 — Icon/Tile', '512 × 512 — icon/tile'), w: 512, h: 512 },
]

const SAMPLERS = ['euler', 'dpmpp_2m', 'dpmpp_2m_sde', 'dpmpp_3m_sde', 'uni_pc', 'ddim']
// karras und exponential fehlen bewusst: sie quetschen die formgebende Phase in
// wenige Riesenschritte und verschlimmern genau die Deformationen, um die es geht.
const SCHEDULERS = ['simple', 'normal', 'sgm_uniform', 'beta', 'ddim_uniform']

const VIDEO_SIZES = [
  { label: t('832 × 480 (Wan-Standard)', '832 × 480 (Wan default)'), w: 832, h: 480 },
  { label: t('768 × 512 (Kandinsky)', '768 × 512 (Kandinsky)'), w: 768, h: 512 },
  { label: t('640 × 640 (quadratisch)', '640 × 640 (square)'), w: 640, h: 640 },
  { label: t('480 × 832 (Hochformat)', '480 × 832 (portrait)'), w: 480, h: 832 },
  { label: t('1280 × 720 (720p, langsam)', '1280 × 720 (720p, slow)'), w: 1280, h: 720 },
]

const PLACEHOLDER: Record<Mode, string> = {
  image: 'stylized fantasy sword, game asset, orthographic, clean background',
  audio: 'footsteps on gravel, close mic, dry, no music',
  video: 'a torch flickering in a dark stone corridor, slow camera push in',
  '3d': 'a weathered stone gargoyle',
}

// Was "Prompt ausbauen" je Reiter daraus macht -- steht im Tooltip des Knopfs.
const EXPAND_TIP: Record<Mode, string> = {
  image: t('Aus „a medieval blacksmith“ wird eine ganze Schmiede: Esse, Amboss, Funken, Licht.',
    'Turns “a medieval blacksmith” into a whole forge: hearth, anvil, sparks, light.'),
  video: t('Ergänzt Bewegung, Kamerafahrt, Ort und Licht; bei LTX-2.5 auch den Ton, mit Startbild nur die Bewegung.',
    'Adds motion, camera move, setting and light; with LTX-2.5 also the sound, with a start image only the motion.'),
  audio: t('Stable Audio: Klang-Tags (Quelle, Material, Raum, Mikrofon). ACE-Step: Genre-, Instrument- und Stimmungs-Tags.',
    'Stable Audio: sound tags (source, material, room, microphone). ACE-Step: genre, instrument and mood tags.'),
  '3d': t('Beschreibt ein einzelnes, geschlossenes Objekt ohne Boden und Schatten, so wie die 3D-Modelle es brauchen.',
    'Describes a single closed object without floor or shadow, the way the 3D models need it.'),
}

// Wie mcp_server.MESH_PROMPT_SUFFIX / MESH_NEGATIVE: was ein Bild für die Mesh-Rekonstruktion braucht.
const MESH_SUFFIX = 'Show the complete object, including any base or plinth that belongs to it, as a '
  + 'single subject, centered and fully visible. It floats in empty space against a plain, flat light '
  + 'grey background, lit by even, diffuse, shadowless studio light. Product shot.'
const MESH_NEGATIVE = 'cast shadow, drop shadow, floor, ground plane, table surface, room, landscape, '
  + 'environment, background objects, multiple objects, cropped, text, watermark'

const HINT: Record<Mode, string> = {
  image: '',
  audio: t(
    'Stable Audio: Klang beschreiben (SFX). ACE-Step: Genre-Tags, kommagetrennt.',
    'Stable Audio: describe the sound (SFX). ACE-Step: genre tags, comma-separated.',
  ),
  video: t(
    'Bewegung mitbeschreiben — je genauer, desto stabiler der Clip.',
    'Describe the motion too — the more precise, the more stable the clip.',
  ),
  '3d': t(
    'Ein einzelnes Objekt ohne Untergrund und Schlagschatten. Ein Sockel, der zum Objekt '
      + 'gehört, darf bleiben. TRELLIS.2 und TripoSG arbeiten rein bildbasiert — was im Bild '
      + 'steht, landet im Mesh.',
    'A single object without ground or cast shadow. A base that belongs to the object '
      + 'may stay. TRELLIS.2 and TripoSG work purely from the image — whatever is in the '
      + 'image ends up in the mesh.',
  ),
}

interface Props {
  health: Health | null
  event: ServerEvent | null
  downloads: Downloads
  onShowModels: () => void
}

export function GeneratePanel({ health, event, downloads, onShowModels }: Props) {
  const [mode, setMode] = useState<Mode>('image')
  const [models, setModels] = useState<ModelInfo[]>([])
  const [modelId, setModelId] = useState<Record<Mode, string>>({
    image: '', audio: '', video: '', '3d': '',
  })

  const [prompt, setPrompt] = useState('')
  const [negative, setNegative] = useState('')
  const [lyrics, setLyrics] = useState('')
  const [seconds, setSeconds] = useState(10)
  const [imgSize, setImgSize] = useState(IMAGE_SIZES[0])
  const [vidSize, setVidSize] = useState(VIDEO_SIZES[0])
  const [frames, setFrames] = useState(49)
  const [fps, setFps] = useState(16)
  // LTX-2.5: Länge in Sekunden statt Frames, und die Zusatzwege (features des Modells)
  const [ltxSeconds, setLtxSeconds] = useState(5)
  const [ltxFps, setLtxFps] = useState(24)
  const [autoDuration, setAutoDuration] = useState(false)
  const [endId, setEndId] = useState('')
  const [loop, setLoop] = useState(false)
  const [quality, setQuality] = useState<'standard' | 'dfr'>('standard')
  const [temporal, setTemporal] = useState(false)
  const [audioId, setAudioId] = useState('')
  const [audioAssets, setAudioAssets] = useState<Asset[]>([])
  const [motionSpeed, setMotionSpeed] = useState(1)
  const [multishot, setMultishot] = useState(false)
  // Person aus einem Foto (seit 0.5.8): Rolle, in der FLUX 3 die Person aus dem Startbild zeigen soll
  const [roleText, setRoleText] = useState('')
  const [steps, setSteps] = useState('')
  const [seed, setSeed] = useState('')
  const [batch, setBatch] = useState(1)

  // Bild: Feineinstellung
  const [cfg, setCfg] = useState('')
  const [sampler, setSampler] = useState('')
  const [scheduler, setScheduler] = useState('')
  const [hires, setHires] = useState(false)
  const [hiresScale, setHiresScale] = useState(1.25)
  const [hiresDenoise, setHiresDenoise] = useState(0.45)
  const [slg, setSlg] = useState(false)
  const [slgScale, setSlgScale] = useState(3.0)
  const [useSource, setUseSource] = useState(false)
  const [denoise, setDenoise] = useState(0.5)
  const [outpaintOn, setOutpaintOn] = useState(false)
  const [pad, setPad] = useState({ left: 0, top: 0, right: 0, bottom: 0 })
  const [srcDims, setSrcDims] = useState<{ w: number; h: number } | null>(null)
  const [cnId, setCnId] = useState('')
  const [cnImageId, setCnImageId] = useState('')
  const [cnStrength, setCnStrength] = useState(0.7)
  const [cnEnd, setCnEnd] = useState(0.8)
  const [cnPre, setCnPre] = useState<'none' | 'canny'>('none')
  const [advanced, setAdvanced] = useState(false)
  // FLUX 3: Upsampler und Referenzbilder (Reihenfolge = "the first image", ...)
  const [upsample, setUpsample] = useState(true)
  const [refIds, setRefIds] = useState<string[]>([])
  const [loraPicks, setLoraPicks] = useState<LoraRef[]>([])
  // "Prompt ausbauen": vorheriger Prompt zum Zurücknehmen, Laufzeit der letzten Runde
  const [expanding, setExpanding] = useState(false)
  const [promptBefore, setPromptBefore] = useState<string | null>(null)
  const [expandSecs, setExpandSecs] = useState<number | null>(null)

  // 3D
  const [sourceImages, setSourceImages] = useState<Asset[]>([])
  const [sourceId, setSourceId] = useState<string>('')
  const [faces, setFaces] = useState('')
  const [textureSize, setTextureSize] = useState(2048)
  const [bgMode, setBgMode] = useState<'birefnet' | 'flood' | 'alpha'>('birefnet')
  const [cleanSpecks, setCleanSpecks] = useState(true)
  const [confirmClearSources, setConfirmClearSources] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)

  const [jobId, setJobId] = useState<string | null>(null)
  const [progress, setProgress] = useState(0)
  const [stage, setStage] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [results, setResults] = useState<Asset[]>([])
  const busy = jobId !== null

  const jobRef = useRef<string | null>(null)
  jobRef.current = jobId

  useEffect(() => {
    api.models().then((all) => {
      setModels(all)
      setModelId((cur) => {
        const next = { ...cur }
        for (const m of MODES) {
          if (next[m.id]) continue
          next[m.id] = health?.active_models?.[m.id] ?? all.find((x) => x.kind === m.id && x.runnable)?.id ?? ''
        }
        return next
      })
    })
  }, [health?.active_models, downloads.finished])

  // Quellbilder für den 3D-Modus nachladen
  const loadSources = () => {
    Promise.all([api.assets('image', 40), api.assets('upload', 20)]).then(([imgs, ups]) => {
      const all = [...imgs, ...ups].sort((a, b) => b.created_at - a.created_at)
      setSourceImages(all)
      setSourceId((cur) => cur || all[0]?.id || '')
    })
  }

  // Bilder werden überall gebraucht: als Mesh-Quelle, als Video-Startbild, als
  // Vorlage zum Überarbeiten und als ControlNet-Referenz.
  useEffect(() => {
    loadSources()
  }, [mode])

  useEffect(() => {
    if (!event || !('job_id' in event) || event.job_id !== jobRef.current) return
    if (event.type === 'job.progress') {
      setProgress(event.progress)
      setStage(event.stage)
    } else if (event.type === 'job.done') {
      api.jobAssets(event.job_id).then((assets) => {
        setResults(assets)
        // 3D aus Text und Person aus einem Foto: das frische Bild gleich als Quell- bzw. Startbild auswählen.
        if ((mode === '3d' || mode === 'video') && assets[0]?.kind === 'image') {
          setSourceId(assets[0].id)
          loadSources()
        }
      })
      setJobId(null)
      setProgress(1)
      setStage(t('fertig', 'done'))
      if (mode === 'image') loadSources()
    } else if (event.type === 'job.error') {
      setError(event.error)
      setJobId(null)
    } else if (event.type === 'job.cancelled') {
      // Auch ein Stopp über die Kopfleiste oder aus dem PhotoCraft-Add-on landet hier.
      setJobId(null)
      setStage(t('abgebrochen', 'cancelled'))
    }
  }, [event, mode])

  const cancelJob = async () => {
    if (!jobId) return
    try {
      const res = await api.cancelJob(jobId)
      if (!res.ok && res.reason) setError(res.reason)
      else {
        setJobId(null)
        setStage(t('abgebrochen', 'cancelled'))
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const available = useMemo(
    () => models.filter((m) => m.kind === mode && m.runnable),
    [models, mode],
  )
  const selected = available.find((m) => m.id === modelId[mode])
  const noModel = available.length === 0
  const modeLabel = MODES.find((m) => m.id === mode)?.label ?? ''
  const isAce = selected?.family?.startsWith('ace') ?? false
  // TRELLIS.2 liefert PBR-Texturen; TripoSG nur Geometrie.
  const isTextured = selected?.workflow === 'trellis2'
  // Skip Layer Guidance und die SD3-ControlNets gelten nur für diese Familie.
  const isSD3 = selected?.workflow === 'sd3'
  // Nur ControlNets derselben Architektur — ein SD3-Netz an Chroma oder FLUX
  // liefert Matsch statt Führung.
  const controlnets = useMemo(
    () => models.filter(
      (m) => m.kind === 'controlnet' && m.installed && m.family === selected?.family,
    ),
    [models, selected],
  )
  // Bild-zu-Video: diese Modelle brauchen zwingend ein Startbild, Wan 2.2 TI2V
  // kann beides. Reine Text-zu-Video-Modelle bekommen die Auswahl gar nicht erst.
  const needsStart = mode === 'video' && I2V_WORKFLOWS.has(selected?.workflow ?? '')
  const usesStart = needsStart || (mode === 'video' && OPTIONAL_START_WORKFLOWS.has(selected?.workflow ?? ''))
  const meshWorker = selected?.workflow ? health?.mesh_workers?.[selected.workflow] : undefined

  // LoRAs, die zum gewählten Modell passen (Basis in lora_bases). Die Auswahl gilt je Modell;
  // was nicht passt, fällt beim Wechsel weg.
  const loraChoices = useMemo(
    () => models.filter((m) => m.kind === 'lora' && m.installed
      && (selected?.lora_bases ?? []).includes(m.family)),
    [models, selected],
  )
  const activeLoras = loraPicks.filter((p) => loraChoices.some((l) => l.id === p.model_id))
  const toggleLora = (id: string, strength = 0.8) =>
    setLoraPicks((list) => (list.some((p) => p.model_id === id)
      ? list.filter((p) => p.model_id !== id)
      : [...list, { model_id: id, strength }]))

  // LTX-2.5 (seit 0.5.8): eigene Formate, Länge in Sekunden, Zusatzwege laut features.
  const vfeat = mode === 'video' ? selected?.features : undefined
  const isLtx25 = mode === 'video' && selected?.family === 'ltx25'
  const videoSizes = isLtx25 && vfeat?.sizes?.length ? vfeat.sizes : VIDEO_SIZES
  // 8n+1 Frames, der nächste Wert zu ltxSeconds (wie workflows.ltx_frames_for_seconds: 5 s = 121).
  // Höchstens 481 Frames (API-Grenze): 20 s bei 24 fps, 19 s bei 25, 16 s bei 30.
  const ltxMaxSeconds = Math.min(vfeat?.max_seconds ?? 20, Math.floor(480 / ltxFps))
  const ltxFrames = Math.max(9, Math.min(481,
    1 + Math.floor((Math.min(ltxSeconds, ltxMaxSeconds) * ltxFps - 1) / 8 + 0.5) * 8))
  // Empfohlene LoRAs für die gewählte Videofamilie (catalog.LORA_MODELS, features.recommended_for)
  const recLoras = useMemo(
    () => models.filter((m) => m.kind === 'lora'
      && (m.features?.recommended_for ?? []).includes(selected?.family ?? '-')),
    [models, selected],
  )
  useEffect(() => {
    if (!videoSizes.some((s) => s.label === vidSize.label)) setVidSize(videoSizes[0])
  }, [videoSizes, vidSize.label])
  useEffect(() => {
    if (isLtx25) api.assets('audio', 30).then(setAudioAssets).catch(() => setAudioAssets([]))
  }, [isLtx25, results])
  // Fehlt eine optionale Datei (eigene Freigabe auf Hugging Face), steht der Weg dorthin daneben.
  const missingNote = (name: string) => {
    const url = vfeat?.missing?.[name]
    if (!url) return null
    return (
      <>
        {' '}{t('Fehlt noch: ', 'Not available yet: ')}
        <a href={url} target="_blank" rel="noreferrer">{t('Freigabe auf Hugging Face', 'access on Hugging Face')}</a>
        {t(', dann LTX-2.5 unter „Modelle“ erneut laden.', ', then download LTX-2.5 again under “Models”.')}
      </>
    )
  }
  const setLoraStrength = (id: string, strength: number) =>
    setLoraPicks((list) => list.map((p) => (p.model_id === id ? { ...p, strength } : p)))

  // Was das gewählte Bildmodell kann (registry.features_for). Fehlt ein Eintrag, gilt
  // das alte Verhalten: alles anbieten.
  const feat = mode === 'image' ? selected?.features : undefined
  const negWorks = feat?.negative_prompt !== false
  const canImg2img = feat?.img2img !== false
  const canHires = feat?.hires !== false
  // Erweitern geht über Masken (Qwen) oder über ein Referenzbild (FLUX 3 und andere
  // Bearbeitungsmodelle; dort deutlich nahtloser).
  const outpaintByRef = (feat?.references ?? 0) > 0
  const canOutpaint = (canImg2img && feat?.mask !== false) || outpaintByRef
  const outpainting = mode === 'image' && useSource && canOutpaint && outpaintOn
    && pad.left + pad.top + pad.right + pad.bottom > 0
  const maxRefs = feat?.references ?? 0
  const sizes = useMemo(() => [...IMAGE_SIZES, ...(feat?.sizes ?? [])], [feat])
  const chips = useMemo(() => {
    if (!feat) return []
    const out: { text: string; ok: boolean }[] = [
      {
        text: negWorks
          ? t('Negativprompt wirkt', 'Negative prompt works')
          : t('Negativprompt wirkungslos', 'Negative prompt has no effect'),
        ok: negWorks,
      },
    ]
    if (feat.text_rendering) out.push({ text: t('Schrift im Bild', 'Text in images'), ok: true })
    if (feat.upsampler) out.push({ text: t('Prompt-Upsampler', 'Prompt upsampler'), ok: true })
    if (feat.references) {
      out.push({
        text: t(`bis ${feat.references} Referenzbilder`, `up to ${feat.references} reference images`),
        ok: true,
      })
    }
    if (feat.bbox) out.push({ text: t('Platzierung per Box', 'Box placement'), ok: true })
    if (feat.sizes?.length) out.push({ text: t('eigene Formate', 'own sizes'), ok: true })
    if (feat.steps) {
      out.push({
        text: t(`${feat.steps} Schritte · CFG ${feat.cfg}`, `${feat.steps} steps · CFG ${feat.cfg}`),
        ok: true,
      })
    }
    return out
  }, [feat, negWorks])

  // Ein modelleigenes Format gilt nach dem Wechsel nicht mehr -- zurück auf das erste.
  useEffect(() => {
    if (!sizes.some((s) => s.label === imgSize.label)) setImgSize(sizes[0])
  }, [sizes, imgSize.label])

  const toggleRef = (id: string) =>
    setRefIds((list) =>
      list.includes(id) ? list.filter((x) => x !== id) : list.length < maxRefs ? [...list, id] : list,
    )

  const removeSource = async (asset: Asset) => {
    setError(null)
    try {
      await api.deleteAsset(asset.id)
      setSourceImages((list) => {
        const rest = list.filter((a) => a.id !== asset.id)
        // War das ausgewählte Bild dabei, rückt das nächste nach.
        if (sourceId === asset.id) setSourceId(rest[0]?.id ?? '')
        return rest
      })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const clearSources = async () => {
    setConfirmClearSources(false)
    setError(null)
    try {
      // Nur Bilder und Uploads — erzeugte Meshes bleiben erhalten.
      await Promise.all(sourceImages.map((a) => api.deleteAsset(a.id)))
      setSourceImages([])
      setSourceId('')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const upload = async (file: File) => {
    setError(null)
    try {
      const asset = await api.upload(file)
      setSourceImages((s) => [asset, ...s])
      setSourceId(asset.id)
      // Bei FLUX 3 ist ein hochgeladenes Bild fast immer als Referenz gemeint.
      if (mode === 'image' && maxRefs > 0) {
        setRefIds((r) => (r.length < maxRefs ? [...r, asset.id] : r))
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Größe des Quellbilds, damit das Outpainting das Zielformat vorher anzeigen kann.
  const sourceUrl = sourceImages.find((a) => a.id === sourceId)?.url
  useEffect(() => {
    setSrcDims(null)
    if (!sourceUrl) return
    const img = new Image()
    img.onload = () => setSrcDims({ w: img.naturalWidth, h: img.naturalHeight })
    img.src = sourceUrl
  }, [sourceUrl])
  const padTo = srcDims && {
    w: Math.round((srcDims.w + pad.left + pad.right) / 16) * 16,
    h: Math.round((srcDims.h + pad.top + pad.bottom) / 16) * 16,
  }
  const padPreset = (left: number, top: number, right: number, bottom: number) =>
    setPad({ left, top, right, bottom })

  const canGenerate =
    mode === '3d'
      ? !!sourceId
      : needsStart
        ? !!prompt.trim() && !!sourceId
        : mode === 'image' && useSource && (canImg2img || outpainting)
          ? !!prompt.trim() && !!sourceId
          : mode === 'image' && cnId
            ? !!prompt.trim() && !!cnImageId
            : !!prompt.trim()

  // Prompt ausbauen geht mit jedem Modell, braucht aber die Upsampler-Datei von FLUX 3.
  const canExpand = models.some((m) => m.files.some((f) => f.installed && f.file.includes('upsampler')))
  const expandTarget: ExpandTarget =
    mode === 'image' ? 'image'
      : mode === '3d' ? '3d'
        : mode === 'audio' ? (selected?.family === 'stable_audio3' ? 'music_sa3' : isAce ? 'music' : 'sfx')
          : isLtx25 && multishot ? 'video_multishot'
            : usesStart && sourceId ? 'video_start'
              : selected?.family === 'ltx25' || selected?.family === 'ltx23' ? 'video_sound' : 'video'

  const expandPrompt = async () => {
    if (expanding || busy || !prompt.trim()) return
    setExpanding(true)
    setError(null)
    try {
      const refs = expandTarget === 'image' && maxRefs > 0 ? refIds
        : expandTarget === 'video_start' ? [sourceId] : []
      const r = await api.expandPrompt({
        prompt, width: imgSize.w, height: imgSize.h, target: expandTarget,
        ...(refs.length ? { reference_asset_ids: refs } : {}),
      })
      setPromptBefore(prompt)
      setPrompt(r.expanded)
      setExpandSecs(r.seconds)
      // Schon ausgebaut: FLUX 3 soll ihn nicht ein zweites Mal umschreiben.
      if (mode === 'image' && feat?.upsampler) setUpsample(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setExpanding(false)
    }
  }

  const undoExpand = () => {
    if (promptBefore === null) return
    setPrompt(promptBefore)
    setPromptBefore(null)
    setExpandSecs(null)
    if (mode === 'image' && feat?.upsampler) setUpsample(true)
  }

  // 3D aus Text: erst ein Bild mit dem aktiven Bildmodell, das dann als Quellbild dient.
  const imageModel = models.find((m) => m.kind === 'image' && m.runnable && m.id === modelId.image)
  const meshImage = async () => {
    if (busy || !prompt.trim()) return
    setError(null)
    setResults([])
    setProgress(0)
    setStage(t('in der Warteschlange', 'queued'))
    // Ein für 3D ausgebauter Prompt enthält die Angaben schon.
    const full = promptBefore !== null ? prompt : `${prompt.trim().replace(/[ .,]+$/, '')}. ${MESH_SUFFIX}`
    try {
      const job = await api.generateImage({
        prompt: full,
        negative_prompt: imageModel?.features?.negative_prompt === false ? '' : MESH_NEGATIVE,
        model_id: imageModel?.id ?? null,
        steps: null, seed: seed ? Number(seed) : null,
        width: 1024, height: 1024, batch_size: 1,
      })
      setJobId(job.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Person aus einem Foto: FLUX 3 nimmt das gewählte Startbild als Referenz, behält das Gesicht und
  // erzeugt vier Startbilder im Videoformat. Gemessen 24.10.: ~95 s für vier Bilder bei 1280 × 704;
  // das Gesicht trifft FLUX besser, wenn das Foto nur Kopf und Schultern zeigt.
  const refModel = models
    .filter((m) => m.kind === 'image' && m.runnable && (m.features?.references ?? 0) > 0)
    .sort((a, b) => Number(b.recommended) - Number(a.recommended) || Number(b.family === 'flux3') - Number(a.family === 'flux3'))[0]
  const personImages = async () => {
    if (busy || !roleText.trim() || !sourceId || !refModel) return
    setError(null)
    setResults([])
    setProgress(0)
    setStage(t('in der Warteschlange', 'queued'))
    const role = roleText.trim().replace(/[ .]+$/, '')
    try {
      const job = await api.generateImage({
        prompt: `Cinematic film still. The person from the first image, with exactly the same face, eyes, nose, `
          + `mouth and hair color: ${role}. Medium shot from the waist up, the face clearly visible, `
          + `free space above the head.`,
        negative_prompt: '', model_id: refModel.id, steps: null, seed: seed ? Number(seed) : null,
        width: vidSize.w, height: vidSize.h, batch_size: 4, reference_asset_ids: [sourceId],
      })
      setJobId(job.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Der Hinweis zum Prompt steht im leeren Feld selbst, nicht als Absatz darunter.
  const promptHint = mode === 'image' ? feat?.prompt_hint || '' : (isLtx25 && vfeat?.prompt_hint) || HINT[mode]
  const placeholder = [promptHint, `${t('z. B.', 'e.g.')} ${feat?.placeholder
    || (isLtx25 && vfeat?.placeholder) || PLACEHOLDER[mode]}`]
    .filter(Boolean).join('\n\n')

  const expandRow = () => (
    <div className="expand-row">
      <button
        className="btn small"
        onClick={expandPrompt}
        disabled={!canExpand || expanding || busy || !prompt.trim()}
        title={canExpand
          ? EXPAND_TIP[mode]
          : t('Braucht den Upsampler von FLUX 3 Image Klein — das Modell unter „Modelle“ laden',
            'Needs the FLUX 3 Image Klein upsampler — download that model under “Models”')}
      >
        {expanding ? t('Baut aus …', 'Expanding …') : t('✨ Prompt ausbauen', '✨ Expand prompt')}
      </button>
      {promptBefore !== null && !expanding && (
        <button className="btn small ghost" onClick={undoExpand}>
          {t('Zurück zum eigenen Prompt', 'Back to my prompt')}
        </button>
      )}
      {(expanding || promptBefore !== null || !canExpand) && (
        <span className="muted small">
          {expanding
            ? t('meist 3–40 s', 'usually 3–40 s')
            : promptBefore !== null
              ? t(`ausgebaut in ${expandSecs} s — lesen und streichen, was nicht stimmt`,
                `expanded in ${expandSecs} s — read it and remove what is wrong`)
              : t('Braucht FLUX 3 Image Klein (Upsampler).', 'Needs FLUX 3 Image Klein (upsampler).')}
        </span>
      )}
    </div>
  )

  // 3D: Nur TRELLIS.2 liefert Texturen. Fehlt es, steht das gut sichtbar oben, mit Download.
  const trellis = models.find((m) => m.kind === '3d' && m.workflow === 'trellis2')
  const trellisDl = trellis ? downloads.active[trellis.id] : undefined
  const [dlError, setDlError] = useState<string | null>(null)

  const textureNotice = () => {
    if (!trellis) return null
    if (trellis.installed && trellis.runnable) {
      if (modelId['3d'] === trellis.id) return null
      return (
        <div className="texture-note">
          <strong>{t('Ohne Texturen: ', 'No textures: ')}</strong>
          {t('das gewählte Modell baut nur die Form, das Mesh bleibt grau. ',
            'the selected model only builds the shape, the mesh stays grey. ')}
          <button className="link-btn" onClick={() => setModelId((c) => ({ ...c, '3d': trellis.id }))}>
            {t('Auf TRELLIS.2 mit Texturen wechseln', 'Switch to TRELLIS.2 with textures')}
          </button>
        </div>
      )
    }
    const pct = trellisDl ? Math.round(trellisDl.progress * 100) : 0
    return (
      <div className="texture-note important">
        <p>
          <strong>{t('Wichtig: Texturen gibt es nur mit TRELLIS.2.', 'Important: textures only come with TRELLIS.2.')}</strong>{' '}
          {t(
            'TripoSG baut nur die Form, das Mesh ist grau und muss selbst texturiert werden. TRELLIS.2 '
              + '(MIT-Lizenz) legt Farbe, Metall und Rauheit als PBR-Texturen (2048²) mit UVs an, '
              + 'fertig für Unity, Blender und Co. Rund 2,5 Minuten pro Modell, ~14 GB VRAM.',
            'TripoSG only builds the shape: the mesh is grey and has to be textured by hand. TRELLIS.2 '
              + '(MIT license) creates color, metal and roughness as PBR textures (2048²) with UVs, '
              + 'ready for Unity, Blender and the like. About 2.5 minutes per model, ~14 GB VRAM.',
          )}
        </p>
        {trellisDl ? (
          <div className="dl">
            <div className="progress">
              <div className="bar" style={{ width: `${pct}%` }} />
            </div>
            <span className="muted small">
              {trellisDl.status === 'queued'
                ? t('wartet auf den laufenden Download', 'waiting for the running download')
                : `${pct} % · ${trellisDl.stage}`}
            </span>
          </div>
        ) : (
          <div className="row-gap">
            <button
              className="btn small primary"
              onClick={async () => {
                setDlError(null)
                try {
                  await downloads.start(trellis.id)
                } catch (e) {
                  setDlError(e instanceof Error ? e.message : String(e))
                }
              }}
            >
              {t(`⬇ TRELLIS.2 herunterladen (${trellis.size_gb} GB)`, `⬇ Download TRELLIS.2 (${trellis.size_gb} GB)`)}
            </button>
            <button className="link-btn" onClick={onShowModels}>
              {t('Alle 3D-Modelle ansehen', 'See all 3D models')}
            </button>
          </div>
        )}
        {dlError && <p className="hint warn small">{dlError}</p>}
      </div>
    )
  }

  const generate = async () => {
    if (busy || !canGenerate) return
    setError(null)
    setResults([])
    setProgress(0)
    setStage(t('in der Warteschlange', 'queued'))

    const common = {
      prompt,
      negative_prompt: negative,
      model_id: modelId[mode] || null,
      steps: steps ? Number(steps) : null,
      seed: seed ? Number(seed) : null,
    }
    try {
      let job
      if (mode === 'image') {
        job = await api.generateImage({
          ...common,
          width: imgSize.w, height: imgSize.h, batch_size: batch,
          cfg: cfg ? Number(cfg) : null,
          sampler: sampler || null,
          scheduler: scheduler || null,
          hires: hires && canHires, hires_scale: hiresScale, hires_denoise: hiresDenoise,
          slg, slg_scale: slgScale,
          image_asset_id: useSource && (canImg2img || outpainting) && sourceId ? sourceId : null,
          denoise: outpainting ? 1.0 : useSource && canImg2img ? denoise : 1.0,
          outpaint: outpainting ? [pad.left, pad.top, pad.right, pad.bottom] : null,
          reference_asset_ids: maxRefs > 0 && !outpainting ? refIds.filter((id) => sourceImages.some((a) => a.id === id)) : [],
          upsample_prompt: feat?.upsampler ? upsample : null,
          controlnet_model_id: cnId || null,
          controlnet_image_asset_id: cnId ? cnImageId || null : null,
          controlnet_strength: cnStrength,
          controlnet_end: cnEnd,
          controlnet_preprocess: cnPre,
          loras: activeLoras,
        })
      } else if (mode === 'audio') {
        job = await api.generateAudio({ ...common, seconds, lyrics })
      } else if (mode === 'video') {
        job = await api.generateVideo({
          ...common, width: vidSize.w, height: vidSize.h,
          frames: isLtx25 ? ltxFrames : frames, fps: isLtx25 ? ltxFps : fps,
          image_asset_id: usesStart ? sourceId || null : null,
          loras: activeLoras,
          ...(isLtx25 ? {
            loop: loop && !!sourceId && quality !== 'dfr',
            end_image_asset_id: !loop && quality !== 'dfr' && endId ? endId : null,
            quality,
            temporal_upscale: quality === 'dfr' && temporal,
            auto_duration: autoDuration && !audioId,
            audio_asset_id: audioId || null,
            motion_speed: motionSpeed,
          } : {}),
        })
      } else {
        job = await api.generate3D({
          image_asset_id: sourceId,
          model_id: modelId['3d'] || null,
          steps: steps ? Number(steps) : 50,
          seed: seed ? Number(seed) : null,
          faces: faces ? Number(faces) : isTextured ? 100000 : -1,
          remove_background: bgMode !== 'alpha',
          background_mode: bgMode,
          ...(isTextured
            ? { resolution: 512, texture_size: textureSize, clean_specks: cleanSpecks }
            : {}),
        })
      }
      setJobId(job.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const est = mode === 'video' ? (frames / Math.max(fps, 1)).toFixed(1) : null

  // Quellbild-Auswahl. Identisch fuer 3D und Bild-zu-Video -- nur dass Video
  // ohne Startbild auskommen darf, wenn das Modell auch Text-zu-Video kann.
  const sourcePicker = (allowNone: boolean) => (
    <>
      <h3>{mode === 'video' ? t('Startbild', 'Start image') : t('Quellbild', 'Source image')}</h3>
      {sourceImages.length === 0 ? (
        <p className="hint warn">
          {t(
            'Noch keine Bilder da. Erst eines generieren oder hochladen.',
            'No images yet. Generate or upload one first.',
          )}
        </p>
      ) : (
        <>
          <div className="source-grid">
            {allowNone && (
              <button
                className={sourceId ? 'source none' : 'source none selected'}
                title={t('Ohne Startbild — reines Text-zu-Video', 'No start image — pure text-to-video')}
                onClick={() => setSourceId('')}
              >
                {t('ohne', 'none')}
              </button>
            )}
            {sourceImages.map((a) => (
              <div
                key={a.id}
                className={sourceId === a.id ? 'source selected' : 'source'}
                title={a.prompt || a.filename}
              >
                <img src={a.url} alt={a.prompt} loading="lazy" onClick={() => setSourceId(a.id)} />
                <button
                  className="source-del"
                  title={t('Dieses Quellbild löschen', 'Delete this source image')}
                  onClick={(e) => {
                    e.stopPropagation()
                    removeSource(a)
                  }}
                >
                  ×
                </button>
              </div>
            ))}
          </div>
          <div className="row-between source-actions">
            <span className="muted small">
              {t(`${sourceImages.length} Bilder`, `${sourceImages.length} images`)}
            </span>
            {confirmClearSources ? (
              <span className="confirm">
                <span className="muted small">
                  {t('Alle Quellbilder löschen?', 'Delete all source images?')}
                </span>
                <button className="btn small danger" onClick={clearSources}>{t('Ja', 'Yes')}</button>
                <button className="btn small ghost" onClick={() => setConfirmClearSources(false)}>
                  {t('Nein', 'No')}
                </button>
              </span>
            ) : (
              <button
                className="btn small ghost danger-text"
                onClick={() => setConfirmClearSources(true)}
              >
                {t('Alle löschen', 'Delete all')}
              </button>
            )}
          </div>
        </>
      )}
      <button className="btn small ghost full" onClick={() => fileInput.current?.click()}>
        {t('Bild hochladen', 'Upload image')}
      </button>
    </>
  )

  return (
    <div className="split">
      <section className="panel controls">
        {/* Einmal für alle Auswahlen: Quellbild, Startbild und Referenzbilder. */}
        <input
          ref={fileInput}
          type="file"
          accept="image/*"
          style={{ display: 'none' }}
          onChange={(e) => {
            const f = e.target.files?.[0]
            if (f) upload(f)
            e.target.value = ''
          }}
        />
        <div className="mode-switch four">
          {MODES.map((m) => (
            <button
              key={m.id}
              className={mode === m.id ? 'mode active' : 'mode'}
              onClick={() => setMode(m.id)}
              disabled={busy}
            >
              <span className="icon">{m.icon}</span>
              {m.label}
            </button>
          ))}
        </div>

        {mode === '3d' ? (
          <>
            {textureNotice()}
            <details className="mesh-from-text" open={!!prompt.trim() || sourceImages.length === 0}>
              <summary>{t('Objekt aus Text (optional)', 'Object from text (optional)')}</summary>
              <textarea
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder={placeholder}
                rows={3}
              />
              {expandRow()}
              <button
                className="btn small full"
                onClick={meshImage}
                disabled={busy || !prompt.trim() || !imageModel}
                title={imageModel
                  ? t(`Erzeugt mit ${imageModel.name} ein Quellbild; danach unten das Mesh bauen`,
                    `Creates a source image with ${imageModel.name}; then build the mesh below`)
                  : t('Kein Bildmodell installiert', 'No image model installed')}
              >
                {t('Quellbild erzeugen', 'Create source image')}
              </button>
            </details>
            {sourcePicker(false)}
          </>
        ) : (
          <>
            {usesStart && (
              <>
                {sourcePicker(!needsStart)}
                <p className="hint small">
                  {needsStart
                    ? t(
                        'Dieses Modell belebt ein Standbild — Startbild ist Pflicht. Im Prompt nur die Bewegung beschreiben.',
                        'This model animates a still image — a start image is required. Describe only the motion in the prompt.',
                      )
                    : t(
                        'Optional: mit Startbild wird daraus Bild-zu-Video, ohne reines Text-zu-Video.',
                        'Optional: with a start image this becomes image-to-video, without one pure text-to-video.',
                      )}
                </p>
                <details className="mesh-from-text" open={!!roleText.trim()}>
                  <summary>{t('Person aus einem Foto (optional)', 'Person from a photo (optional)')}</summary>
                  <p className="hint small">
                    {t('Das Foto oben als Startbild wählen oder hochladen, am besten nur Kopf und Schultern. Hier '
                      + 'beschreiben, wer die Person sein soll: Stil, Kleidung, Ort. FLUX 3 behält das Gesicht und '
                      + 'erzeugt vier Startbilder im Videoformat. Das ähnlichste oben auswählen, dann unten Bewegung '
                      + 'und Gesprochenes beschreiben.',
                    'Pick or upload the photo as the start image above, head and shoulders work best. Describe here '
                      + 'who the person should be: style, clothing, place. FLUX 3 keeps the face and creates four start '
                      + 'images in the video format. Pick the most similar one above, then describe the motion and what '
                      + 'is said below.')}
                  </p>
                  <textarea
                    value={roleText}
                    onChange={(e) => setRoleText(e.target.value)}
                    rows={3}
                    placeholder={t(
                      'z. B. als Superheldin in Blau und Grün mit langem Umhang, die bei Sonnenuntergang über einer Stadt schwebt',
                      'e.g. as a superheroine in blue and green with a long cape, floating above a city at sunset',
                    )}
                  />
                  <button
                    className="btn small full"
                    onClick={personImages}
                    disabled={busy || !roleText.trim() || !sourceId || !refModel}
                    title={!refModel
                      ? t('Braucht FLUX 3 Image Klein', 'Needs FLUX 3 Image Klein')
                      : !sourceId
                        ? t('Erst oben das Foto als Startbild wählen', 'First pick the photo as the start image above')
                        : t(`Vier Bilder mit ${refModel.name}, rund 1,5 Minuten`, `Four images with ${refModel.name}, about 1.5 minutes`)}
                  >
                    {t('Vier Startbilder erzeugen', 'Create four start images')}
                  </button>
                  {!refModel && (
                    <p className="hint small warn">
                      {t('Braucht FLUX 3 Image Klein: unter „Modelle“ laden.',
                        'Needs FLUX 3 Image Klein: download it under “Models”.')}
                    </p>
                  )}
                </details>
                {isLtx25 && vfeat?.end_image && sourceImages.length > 0 && (
                  <>
                    <h3>
                      {t('Endbild', 'End image')}{' '}
                      <span className="muted small">{t('optional', 'optional')}</span>
                    </h3>
                    <label className="check">
                      <input type="checkbox" checked={loop} disabled={!sourceId || quality === 'dfr'}
                        onChange={(e) => setLoop(e.target.checked)} />
                      {t('Schleife: das Startbild ist auch das Endbild (nahtloser Loop)',
                        'Loop: the start image is also the end image (seamless loop)')}
                    </label>
                    {loop && (
                      <p className="hint small">
                        {t('Die Kamera ruhig lassen und eine wiederkehrende Bewegung beschreiben (Flammen, Wasser, Atem). '
                          + 'Mit Kamerafahrt zerfiel im Test der Schluss.',
                        'Keep the camera still and describe a repeating motion (flames, water, breathing). '
                          + 'With a camera move the ending fell apart in the test.')}
                      </p>
                    )}
                    {!loop && (
                      <div className="source-grid">
                        <button className={endId ? 'source none' : 'source none selected'}
                          title={t('Ohne Endbild', 'No end image')} onClick={() => setEndId('')}>
                          {t('ohne', 'none')}
                        </button>
                        {sourceImages.map((a) => (
                          <div key={a.id} className={endId === a.id ? 'source selected' : 'source'}
                            title={a.prompt || a.filename}>
                            <img src={a.url} alt={a.prompt} loading="lazy"
                              onClick={() => quality !== 'dfr' && setEndId(a.id)} />
                          </div>
                        ))}
                      </div>
                    )}
                    <p className="hint small">
                      {quality === 'dfr'
                        ? t('Start- und Endbild gehen nur ohne „Höchste Qualität (DFR)“.',
                          'Start and end image only work without “Best quality (DFR)”.')
                        : t('Mit Endbild läuft das Video vom Startbild zum Endbild (Übergang). Eine Stufe in '
                            + 'voller Auflösung, deshalb langsamer als ohne.',
                          'With an end image the video runs from the start image to the end image (a '
                            + 'transition). One stage at full resolution, so slower than without.')}
                    </p>
                  </>
                )}
              </>
            )}
            <h3>{mode === 'audio' && isAce ? t('Genre-Tags', 'Genre tags') : 'Prompt'}</h3>
            <textarea
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder={placeholder}
              rows={feat?.upsampler ? 4 : 6}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) generate()
              }}
            />
            {expandRow()}

            {mode === 'audio' && isAce && (
              <>
                <h3>{t('Songtext (leer = instrumental)', 'Lyrics (empty = instrumental)')}</h3>
                <textarea
                  value={lyrics}
                  onChange={(e) => setLyrics(e.target.value)}
                  rows={3}
                  placeholder="[verse]&#10;Steel and shadow, dawn is breaking…"
                />
              </>
            )}

            <h3>{t('Negativ', 'Negative')}</h3>
            <textarea
              value={negWorks ? negative : ''}
              onChange={(e) => setNegative(e.target.value)}
              rows={2}
              disabled={!negWorks}
              placeholder={
                !negWorks
                  ? t(
                      'wirkt bei diesem Modell nicht (cfg 1) — Ausschlüsse im Prompt positiv formulieren',
                      'has no effect with this model (cfg 1) — phrase exclusions positively in the prompt',
                    )
                  : mode === 'video'
                    ? t('leer = sinnvoller Standard', 'empty = sensible default')
                    : feat?.default_negative
                      ? t(
                          'leer = der empfohlene Negativprompt aus der Modellkarte',
                          'empty = the recommended negative prompt from the model card',
                        )
                      : 'blurry, low quality'
              }
            />
          </>
        )}

        <h3>{t('Modell', 'Model')}</h3>
        <select
          value={modelId[mode]}
          onChange={(e) => setModelId({ ...modelId, [mode]: e.target.value })}
          disabled={noModel}
        >
          {noModel && <option>{t(`— kein ${modeLabel}-Modell —`, `— no ${modeLabel} model —`)}</option>}
          {available.map((m) => (
            <option key={m.id} value={m.id}>
              {m.favorite ? '★ ' : ''}
              {m.name}
            </option>
          ))}
        </select>
        {selected && <p className="hint small">{selected.best_for}</p>}
        {selected && (mode === 'image' || mode === 'video') && (
          <div className="feature-chips"><ContentBadge model={selected} /></div>
        )}
        {chips.length > 0 && (
          <div className="feature-chips">
            {chips.map((c) => (
              <span key={c.text} className={c.ok ? 'badge ok' : 'badge warn'}>{c.text}</span>
            ))}
          </div>
        )}
        {mode === 'image' && selected?.warning && (
          <p className="hint small warn">{selected.warning}</p>
        )}
        {(mode === 'image' || mode === 'video') && (selected?.lora_bases?.length ?? 0) > 0 && (
          <details className="lora-picker">
            <summary>
              LoRAs{' '}
              <span className="muted small">
                {activeLoras.length > 0
                  ? t(`${activeLoras.length} aktiv`, `${activeLoras.length} active`)
                  : t(`${loraChoices.length} verfügbar`, `${loraChoices.length} available`)}
              </span>
            </summary>
            {loraChoices.length === 0 ? (
              <p className="hint small">
                {t('Keine passende LoRA geladen. ', 'No matching LoRA downloaded. ')}
                <button className="link-btn" onClick={onShowModels}>
                  {t('Unter „Modelle“ suchen', 'Search under “Models”')}
                </button>
              </p>
            ) : (
              loraChoices.map((l) => {
                const pick = loraPicks.find((p) => p.model_id === l.id)
                return (
                  <div key={l.id} className="lora-row">
                    <label title={l.source_url || l.name}>
                      <input type="checkbox" checked={!!pick} onChange={() => toggleLora(l.id)} />
                      <span className="lora-name">{l.name.replace(/^.*\//, '').replace(/\.safetensors$/, '')}</span>
                    </label>
                    {pick && (
                      <>
                        <input type="range" min={0} max={1.5} step={0.05} value={pick.strength}
                          onChange={(e) => setLoraStrength(l.id, Number(e.target.value))} />
                        <span className="muted small">{pick.strength.toFixed(2)}</span>
                        {l.trigger && !prompt.includes(l.trigger) && (
                          <button className="btn small ghost" title={l.trigger}
                            onClick={() => setPrompt((p) => (p.trim() ? `${l.trigger}, ${p}` : l.trigger!))}>
                            {t('+ Trigger', '+ trigger')}
                          </button>
                        )}
                      </>
                    )}
                  </div>
                )
              })
            )}
          </details>
        )}
        {mode === 'video' && recLoras.length > 0 && (
          <details className="lora-picker rec-loras">
            <summary>
              {t(`Empfohlene LoRAs für ${selected?.name.split(' (')[0]}`,
                `Recommended LoRAs for ${selected?.name.split(' (')[0]}`)}{' '}
              <span className="muted small">
                {t(`${recLoras.filter((l) => l.installed).length} von ${recLoras.length} geladen`,
                  `${recLoras.filter((l) => l.installed).length} of ${recLoras.length} downloaded`)}
              </span>
            </summary>
            <p className="hint small">
              {t('Geladene LoRAs erscheinen auch oben in der Auswahl. Trigger-Wörter gehören in den Prompt. '
                  + 'LTX-2.3-LoRAs laufen laut Lightricks meist auch auf LTX-2.5.',
                'Downloaded LoRAs also appear in the list above. Trigger words go into the prompt. '
                  + 'According to Lightricks, LTX-2.3 LoRAs mostly run on LTX-2.5 too.')}
            </p>
            {recLoras.map((l) => {
              const dl = downloads.active[l.id]
              const pick = loraPicks.find((p) => p.model_id === l.id)
              const use = l.features?.use
              const useHint = use === 'start_image' ? t('mit Startbild', 'with a start image')
                : use === 'end_image' ? t('mit Start- und Endbild', 'with a start and end image')
                  : use === 'audio_input' ? t('mit „Ton vorgeben“', 'with “Given sound”')
                    : use === 'motion_speed' ? t('mit Startbild und „Zeitlupe“', 'with a start image and “Slow motion”')
                      : ''
              return (
                <div key={l.id} className="rec-lora">
                  <div className="row-between">
                    <span className="lora-name">{l.name}</span>
                    <span className="muted small">{dec(l.size_gb, 2)} GB · {l.license}</span>
                  </div>
                  <p className="hint small">
                    {l.best_for}
                    {useHint ? ` · ${useHint}` : ''}
                    {l.trigger ? ` · Trigger: ${l.trigger}` : ''}
                    {` · ${t('Stärke', 'strength')} ${dec(l.features?.strength ?? 1, 1)}`}
                  </p>
                  {l.features?.tested && <p className="hint small tested">{l.features.tested}</p>}
                  {l.warning && <p className="hint small warn">{l.warning}</p>}
                  <div className="row">
                    {l.installed ? (
                      <button className={pick ? 'btn small primary' : 'btn small'}
                        onClick={() => toggleLora(l.id, l.features?.strength ?? 1)}>
                        {pick ? t('✓ aktiv', '✓ active') : t('Aktivieren', 'Activate')}
                      </button>
                    ) : dl ? (
                      <span className="muted small">{dl.stage || t('wartet', 'queued')}</span>
                    ) : (
                      <button className="btn small" onClick={() => downloads.start(l.id)}>
                        {t(`Laden (${dec(l.size_gb, 2)} GB)`, `Download (${dec(l.size_gb, 2)} GB)`)}
                      </button>
                    )}
                    {l.source_url && (
                      <a className="small" href={l.source_url} target="_blank" rel="noreferrer">
                        {t('Quelle', 'Source')}
                      </a>
                    )}
                  </div>
                </div>
              )
            })}
          </details>
        )}

        {mode === 'image' && (
          <>
            <h3>{t('Format', 'Size')}</h3>
            {outpainting ? (
              <p className="hint small">
                {t('Beim Erweitern ergibt sich das Format aus Bild und Rand',
                  'When extending, the size follows from image and border')}
                {padTo ? ` (${padTo.w} × ${padTo.h}).` : '.'}
              </p>
            ) : (
              <>
                <select
                  value={imgSize.label}
                  onChange={(e) => setImgSize(sizes.find((s) => s.label === e.target.value)!)}
                >
                  {sizes.map((s) => (
                    <option key={s.label}>{s.label}</option>
                  ))}
                </select>
                <p className="hint small">
                  {t(
                    'Stehende Figuren im Hochformat — im Quadrat fehlen ihnen oft die Beine.',
                    'Standing figures in portrait format — in a square they often lose their legs.',
                  )}
                  {feat?.sizes?.length
                    ? t(
                        ' Die modelleigenen Formate unten in der Liste geben mehr Detail und kosten mehr Zeit.',
                        ' The model-specific sizes at the end of the list give more detail and take longer.',
                      )
                    : ''}
                </p>
              </>
            )}

            {feat?.upsampler && (
              <label className="check">
                <input type="checkbox" checked={upsample} onChange={(e) => setUpsample(e.target.checked)} />
                {/* Ein Textblock statt Text + span: sonst quetscht Flex die Beschriftung schmal. */}
                <span>
                  {t('Prompt ausbauen lassen', 'Expand the prompt')}{' '}
                  <span className="muted small">
                    {t(
                      '— der mitgelieferte Upsampler schreibt daraus die lange Bildbeschreibung, '
                        + 'auf die das Modell trainiert ist. Nur abschalten, wenn der Prompt schon '
                        + 'eine volle Beschreibung ist.',
                      '— the bundled upsampler turns it into the long image description the model '
                        + 'was trained on. Only switch this off if the prompt already is a full '
                        + 'description.',
                    )}
                  </span>
                </span>
              </label>
            )}

            {maxRefs > 0 && (
              <>
                <h3>
                  {t('Referenzbilder', 'Reference images')}{' '}
                  <span className="muted small">
                    {t(`— ${refIds.length} von ${maxRefs}`, `— ${refIds.length} of ${maxRefs}`)}
                  </span>
                </h3>
                {sourceImages.length === 0 ? (
                  <p className="hint small">
                    {t(
                      'Noch keine Bilder da. Erst eines generieren oder hochladen.',
                      'No images yet. Generate or upload one first.',
                    )}
                  </p>
                ) : (
                  <div className="source-grid">
                    {sourceImages.map((a) => {
                      const idx = refIds.indexOf(a.id)
                      return (
                        <div
                          key={a.id}
                          className={idx >= 0 ? 'source selected' : 'source'}
                          title={a.prompt || a.filename}
                        >
                          <img src={a.url} alt={a.prompt} loading="lazy" onClick={() => toggleRef(a.id)} />
                          {idx >= 0 && <span className="ref-no">{idx + 1}</span>}
                        </div>
                      )
                    })}
                  </div>
                )}
                <p className="hint small">
                  {t(
                    'Optional. Im Prompt heißen sie „the first image“, „the second image“ … in der '
                      + 'Reihenfolge der Nummern. Mit einem Bild wird bearbeitet: sagen, was sich ändert '
                      + 'und was gleich bleibt. Mehrere kombinieren Figuren, Objekte und Stil.',
                    'Optional. In the prompt they are called “the first image”, “the second image” … '
                      + 'in the order of their numbers. With one image you edit it: say what changes '
                      + 'and what stays the same. Several images combine figures, objects and style.',
                  )}
                </p>
                <div className="row-between source-actions">
                  <button className="btn small ghost" onClick={() => fileInput.current?.click()}>
                    {t('Bild hochladen', 'Upload image')}
                  </button>
                  {refIds.length > 0 && (
                    <button className="btn small ghost" onClick={() => setRefIds([])}>
                      {t('Auswahl leeren', 'Clear selection')}
                    </button>
                  )}
                </div>
              </>
            )}

            {canHires && (
              <label className="check">
                <input type="checkbox" checked={hires} onChange={(e) => setHires(e.target.checked)} />
                {t('Zweiter Durchgang', 'Second pass')}{' '}
                <span className="muted small">
                  {t(
                    '— rechnet Hände, Gesichter und feine Technik nach. Dauert etwa die Hälfte länger.',
                    '— re-renders hands, faces and fine technical detail. Takes about 50 % longer.',
                  )}
                </span>
              </label>
            )}
            {canHires && hires && (
              <div className="row">
                <label>
                  {t('Vergrößerung', 'Upscale')}
                  <input type="number" min={1.05} max={2} step={0.05} value={hiresScale}
                    onChange={(e) => setHiresScale(Number(e.target.value))} />
                </label>
                <label>
                  {t('Stärke', 'Strength')}
                  <input type="number" min={0.1} max={1} step={0.05} value={hiresDenoise}
                    onChange={(e) => setHiresDenoise(Number(e.target.value))} />
                </label>
              </div>
            )}

            {isSD3 && (
              <>
                <label className="check">
                  <input type="checkbox" checked={slg} onChange={(e) => setSlg(e.target.checked)} />
                  Skip Layer Guidance{' '}
                  <span className="muted small">
                    {t(
                      '— Stabilitys Eingriff für stabilere Anatomie, kostet ~7 % Zeit.',
                      '— Stability’s tweak for more stable anatomy, costs ~7 % more time.',
                    )}
                  </span>
                </label>
                {slg && (
                  <div className="row">
                    <label>
                      {t('Stärke', 'Strength')}
                      <input type="number" min={0} max={10} step={0.1} value={slgScale}
                        onChange={(e) => setSlgScale(Number(e.target.value))} />
                    </label>
                  </div>
                )}
              </>
            )}

            {canImg2img && (
              <label className="check">
                <input type="checkbox" checked={useSource}
                  onChange={(e) => setUseSource(e.target.checked)} />
                {t('Vorhandenes Bild überarbeiten', 'Rework an existing image')}{' '}
                <span className="muted small">
                  {t('— statt neu zu würfeln.', '— instead of rolling a new one.')}
                </span>
              </label>
            )}
            {!canImg2img && canOutpaint && (
              <label className="check">
                <input type="checkbox" checked={useSource && outpaintOn}
                  onChange={(e) => { setUseSource(e.target.checked); setOutpaintOn(e.target.checked) }} />
                {t('Vorhandenes Bild erweitern (Outpainting)', 'Extend an existing image (outpainting)')}
              </label>
            )}
            {(canImg2img || canOutpaint) && useSource && (
              <>
                {sourcePicker(false)}
                {canImg2img && canOutpaint && (
                  <label className="check">
                    <input type="checkbox" checked={outpaintOn}
                      onChange={(e) => setOutpaintOn(e.target.checked)} />
                    {t('Über den Rand hinaus erweitern (Outpainting)', 'Extend beyond the edges (outpainting)')}
                  </label>
                )}
                {canOutpaint && outpaintOn ? (
                  <div className="outpaint">
                    <div className="row">
                      {([
                        ['left', t('Links', 'Left')],
                        ['top', t('Oben', 'Top')],
                        ['right', t('Rechts', 'Right')],
                        ['bottom', t('Unten', 'Bottom')],
                      ] as const).map(([side, label]) => (
                        <label key={side}>
                          {label}
                          <input type="number" min={0} max={1024} step={64} value={pad[side]}
                            onChange={(e) => setPad((p) => ({
                              ...p, [side]: Math.max(0, Math.min(1024, Number(e.target.value) || 0)),
                            }))} />
                        </label>
                      ))}
                    </div>
                    <div className="outpaint-presets">
                      <button className="btn small ghost" onClick={() => padPreset(256, 0, 256, 0)}>
                        {t('↔ breiter', '↔ wider')}
                      </button>
                      <button className="btn small ghost" onClick={() => padPreset(0, 256, 0, 256)}>
                        {t('↕ höher', '↕ taller')}
                      </button>
                      <button className="btn small ghost" onClick={() => padPreset(0, 0, 0, 384)}>
                        {t('↓ nach unten', '↓ downwards')}
                      </button>
                      <button className="btn small ghost" onClick={() => padPreset(128, 128, 128, 128)}>
                        {t('rundum', 'all around')}
                      </button>
                    </div>
                    <p className="hint small">
                      {srcDims && padTo && (
                        <>{srcDims.w} × {srcDims.h} → <b>{padTo.w} × {padTo.h}</b>
                          {(padTo.w > 2560 || padTo.h > 2560) && (
                            <span className="warn-text"> {t('(zu groß, höchstens 2560)', '(too large, at most 2560)')}</span>
                          )}
                          {' · '}</>
                      )}
                      {t(
                        'Das Bild bleibt, nur der neue Rand wird gemalt. Der Prompt beschreibt das ganze erweiterte Bild.',
                        'The image stays; only the new border is painted. The prompt describes the whole extended picture.',
                      )}
                      {!outpaintByRef && (
                        <span className="warn-text">
                          {t(
                            ' Dieses Modell malt den Rand oft als eigene Szene an; nahtloser wird es mit FLUX 3.',
                            ' This model often paints the border as a separate scene; FLUX 3 gives seamless transitions.',
                          )}
                        </span>
                      )}
                    </p>
                  </div>
                ) : canImg2img && (
                  <>
                    <div className="row">
                      <label>
                        {t('Änderungsgrad', 'Denoise')}
                        <input type="number" min={0.1} max={1} step={0.05} value={denoise}
                          onChange={(e) => setDenoise(Number(e.target.value))} />
                      </label>
                    </div>
                    <p className="hint small">
                      {t(
                        '0,3 behutsam · 0,5 deutlich · 1,0 verwirft die Vorlage',
                        '0.3 gentle · 0.5 noticeable · 1.0 discards the source',
                      )}
                    </p>
                  </>
                )}
              </>
            )}

            <button className="btn small ghost full" onClick={() => setAdvanced((v) => !v)}>
              {advanced
                ? t('Feineinstellung ausblenden', 'Hide advanced settings')
                : t('Feineinstellung', 'Advanced settings')}
            </button>

            {advanced && (
              <div className="advanced">
                <div className="row">
                  <label>
                    CFG
                    <input value={cfg} onChange={(e) => setCfg(e.target.value)}
                      placeholder={feat?.cfg !== undefined ? String(feat.cfg) : 'auto'} inputMode="decimal" />
                  </label>
                  <label>
                    Sampler
                    <select value={sampler} onChange={(e) => setSampler(e.target.value)}>
                      <option value="">{t('Standard', 'Default')}</option>
                      {SAMPLERS.map((s) => <option key={s}>{s}</option>)}
                    </select>
                  </label>
                  <label>
                    Scheduler
                    <select value={scheduler} onChange={(e) => setScheduler(e.target.value)}>
                      <option value="">{t('Standard', 'Default')}</option>
                      {SCHEDULERS.map((s) => <option key={s}>{s}</option>)}
                    </select>
                  </label>
                </div>
                <p className="hint small">
                  {t(
                    'Leer lassen = Modellstandard. Eine höhere CFG gibt verbrannte Farben, keine besseren Formen',
                    'Leave empty = model default. A higher CFG gives burnt colors, not better shapes',
                  )}
                  {feat?.cfg === 1
                    ? t('; dieses Modell ist auf CFG 1 destilliert', '; this model is distilled to CFG 1')
                    : ''}
                  {t(
                    '. karras und exponential stehen bewusst nicht zur Wahl.',
                    '. karras and exponential are deliberately not offered.',
                  )}
                </p>

                <h3>{t('Form vorgeben (ControlNet)', 'Guide the shape (ControlNet)')}</h3>
                {controlnets.length === 0 ? (
                  <p className="hint small">
                    {t(
                      `Für ${selected?.name ?? 'dieses Modell'} ist kein passendes ControlNet `
                        + 'installiert. ControlNets gelten immer nur für die Architektur, für die sie '
                        + 'trainiert wurden.',
                      `No matching ControlNet is installed for ${selected?.name ?? 'this model'}. `
                        + 'ControlNets only ever work with the architecture they were trained for.',
                    )}
                  </p>
                ) : (
                  <>
                    <select value={cnId} onChange={(e) => setCnId(e.target.value)}>
                      <option value="">{t('— aus —', '— off —')}</option>
                      {controlnets.map((m) => (
                        <option key={m.id} value={m.id}>{m.name}</option>
                      ))}
                    </select>
                    {cnId && (
                      <>
                        <p className="hint small">{t('Vorlage wählen:', 'Choose a template:')}</p>
                        <div className="source-grid">
                          {sourceImages.map((a) => (
                            <div key={a.id}
                              className={cnImageId === a.id ? 'source selected' : 'source'}
                              title={a.prompt || a.filename}>
                              <img src={a.url} alt={a.prompt} loading="lazy"
                                onClick={() => setCnImageId(a.id)} />
                            </div>
                          ))}
                        </div>
                        <div className="row">
                          <label>
                            {t('Stärke', 'Strength')}
                            <input type="number" min={0} max={2} step={0.05} value={cnStrength}
                              onChange={(e) => setCnStrength(Number(e.target.value))} />
                          </label>
                          <label>
                            {t('Loslassen ab', 'Release at')}
                            <input type="number" min={0} max={1} step={0.05} value={cnEnd}
                              onChange={(e) => setCnEnd(Number(e.target.value))} />
                          </label>
                          <label>
                            {t('Vorlage', 'Template')}
                            <select value={cnPre}
                              onChange={(e) => setCnPre(e.target.value as 'none' | 'canny')}>
                              <option value="none">{t('unverändert', 'unchanged')}</option>
                              <option value="canny">{t('Kanten daraus', 'extract edges')}</option>
                            </select>
                          </label>
                        </div>
                        <p className="hint small">
                          {t(
                            '„unverändert" für fertige Tiefenkarten, „Kanten daraus" für Fotos und Skizzen.',
                            '“unchanged” for finished depth maps, “extract edges” for photos and sketches.',
                          )}
                        </p>
                      </>
                    )}
                  </>
                )}
              </div>
            )}
          </>
        )}

        {mode === 'video' && (
          <>
            <h3>{t('Format', 'Size')}</h3>
            <select
              value={vidSize.label}
              onChange={(e) => setVidSize(videoSizes.find((s) => s.label === e.target.value)!)}
            >
              {videoSizes.map((s) => (
                <option key={s.label}>{s.label}</option>
              ))}
            </select>
            {isLtx25 ? (
              <>
                <h3>{t('Länge', 'Length')}</h3>
                <div className="row">
                  <label>
                    {t('Sekunden', 'Seconds')}
                    <input type="number" min={1} max={ltxMaxSeconds} step={1} value={ltxSeconds}
                      disabled={autoDuration || !!audioId}
                      onChange={(e) => setLtxSeconds(Number(e.target.value))} />
                  </label>
                  <label>
                    fps
                    <select value={ltxFps} onChange={(e) => setLtxFps(Number(e.target.value))}>
                      {[24, 25, 30].map((f) => <option key={f} value={f}>{f}</option>)}
                    </select>
                  </label>
                </div>
                <label className="check">
                  <input type="checkbox" checked={autoDuration} disabled={!vfeat?.auto_duration || !!audioId}
                    onChange={(e) => setAutoDuration(e.target.checked)} />
                  {t('Länge automatisch aus der beschriebenen Handlung (1–20 s)',
                    'Automatic length from the described action (1–20 s)')}
                </label>
                <p className="hint small">
                  {audioId
                    ? t('Mit vorgegebenem Ton bestimmt der Ton die Länge.', 'With a given sound, the sound sets the length.')
                    : autoDuration
                      ? t('Pausen ausschreiben („a beat of silence“), sonst wird der Clip kurz.',
                        'Write pauses out (“a beat of silence”), otherwise the clip gets short.')
                      : t(`${ltxFrames} Frames ≈ ${dec(ltxFrames / ltxFps, 1)} s`,
                        `${ltxFrames} frames ≈ ${dec(ltxFrames / ltxFps, 1)} s`)}
                  {!vfeat?.auto_duration && missingNote('auto_duration')}
                </p>

                <h3>{t('Qualität', 'Quality')}</h3>
                {/* row-gap statt row: .row stellt Beschriftungen über das Feld, hier gehören sie daneben */}
                <div className="row-gap">
                  <label className="check">
                    <input type="radio" checked={quality === 'standard'} onChange={() => setQuality('standard')} />
                    {t('Standard', 'Standard')}
                  </label>
                  <label className="check">
                    <input type="radio" checked={quality === 'dfr'} disabled={!vfeat?.dfr}
                      onChange={() => setQuality('dfr')} />
                    {t('Höchste Qualität (DFR)', 'Best quality (DFR)')}
                  </label>
                </div>
                {quality === 'dfr' && (
                  <label className="check">
                    <input type="checkbox" checked={temporal} disabled={!vfeat?.temporal_upscale}
                      onChange={(e) => setTemporal(e.target.checked)} />
                    {t('48 fps (zeitlich verdoppelt, langsamer)', '48 fps (temporal upscale, slower)')}
                  </label>
                )}
                <p className="hint small">
                  {t('DFR rechnet Detail-Keyframes mit und eine zweite Stufe mit einem Detail-IC-LoRA: '
                      + 'schärfer, aber deutlich langsamer.',
                    'DFR computes detail keyframes and a second stage with a detail IC-LoRA: sharper, '
                      + 'but much slower.')}
                  {!vfeat?.dfr && missingNote('dfr')}
                </p>

                {vfeat?.audio_input && (
                  <>
                    <h3>
                      {t('Ton vorgeben', 'Given sound')}{' '}
                      <span className="muted small">{t('optional', 'optional')}</span>
                    </h3>
                    <select value={audioId} onChange={(e) => setAudioId(e.target.value)}>
                      <option value="">{t('— keiner, LTX-2.5 erzeugt den Ton —', '— none, LTX-2.5 creates the sound —')}</option>
                      {audioAssets.map((a) => (
                        <option key={a.id} value={a.id}>
                          {(a.prompt || a.filename).slice(0, 60)}
                          {a.meta?.seconds ? ` (${a.meta.seconds} s)` : ''}
                        </option>
                      ))}
                    </select>
                    <p className="hint small">
                      {t('Der Ton bleibt unverändert im Video, das Bild richtet sich nach ihm. Höchstens 20 s.',
                        'The sound stays unchanged in the video and the picture follows it. At most 20 s.')}
                    </p>
                  </>
                )}

                {vfeat?.motion_speed && (
                  <>
                    <h3>{t('Zeitlupe', 'Slow motion')}</h3>
                    <select value={motionSpeed} onChange={(e) => setMotionSpeed(Number(e.target.value))}>
                      {([[1, t('aus (Echtzeit)', 'off (real time)')], [0.5, '2×'], [0.2, '5×'], [0.1, '10×'],
                        [0.05, '20×'], [0.025, '40×']] as [number, string][]).map(([v, label]) => (
                        <option key={v} value={v}>{label}</option>
                      ))}
                    </select>
                    {motionSpeed < 1 && (
                      <p className="hint small">
                        {t('Wirkt verlässlich mit der LoRA „Slow Motion Control“ (empfohlene LoRAs) und einem Startbild.',
                          'Reliable with the “Slow Motion Control” LoRA (recommended LoRAs) and a start image.')}
                      </p>
                    )}
                  </>
                )}

                {vfeat?.multishot && (
                  <label className="check">
                    <input type="checkbox" checked={multishot} onChange={(e) => setMultishot(e.target.checked)} />
                    {t('Mehrere Einstellungen (Multishot): „Prompt ausbauen“ schreibt 2–4 Einstellungen mit Schnitten',
                      'Several shots (multi-shot): “Expand prompt” writes 2–4 shots with cuts')}
                  </label>
                )}
              </>
            ) : (
              <>
                <div className="row">
                  <label>
                    Frames
                    <input type="number" min={9} max={201} step={4} value={frames}
                      onChange={(e) => setFrames(Number(e.target.value))} />
                  </label>
                  <label>
                    fps
                    <input type="number" min={1} max={60} value={fps}
                      onChange={(e) => setFps(Number(e.target.value))} />
                  </label>
                </div>
                <p className="hint small">
                  {t(
                    `≈ ${est} s Clip · Frames werden auf 4n+1 gerundet`,
                    `≈ ${est} s clip · frames are rounded to 4n+1`,
                  )}
                </p>
              </>
            )}
          </>
        )}

        {mode === 'audio' && (
          <>
            <h3>{t('Länge', 'Length')}</h3>
            <div className="row">
              <label>
                {t('Sekunden', 'Seconds')}
                <input type="number" min={1} max={300} value={seconds}
                  onChange={(e) => setSeconds(Number(e.target.value))} />
              </label>
            </div>
          </>
        )}

        {mode === '3d' && (
          <>
            <h3>Mesh</h3>
            <div className="row">
              <label>
                {t('Max. Faces', 'Max faces')}
                <input value={faces} onChange={(e) => setFaces(e.target.value)}
                  placeholder={isTextured ? '100000' : t('alle', 'all')} inputMode="numeric" />
              </label>
              {isTextured && (
                <label>
                  {t('Textur', 'Texture')}
                  <select value={textureSize} onChange={(e) => setTextureSize(Number(e.target.value))}>
                    <option value={1024}>1024²</option>
                    <option value={2048}>2048²</option>
                    <option value={4096}>4096²</option>
                  </select>
                </label>
              )}
            </div>
            {isTextured && (
              <p className="hint small">
                {t(
                  'Erzeugt PBR-Texturen (Albedo, Normal, Roughness/Metallic) bei 512³ Voxeln.',
                  'Creates PBR textures (albedo, normal, roughness/metallic) at 512³ voxels.',
                )}
              </p>
            )}

            <h3>{t('Freistellen', 'Background removal')}</h3>
            <select value={bgMode} onChange={(e) => setBgMode(e.target.value as typeof bgMode)}>
              <option value="birefnet">
                {t('BiRefNet — sauberste Kanten (empfohlen)', 'BiRefNet — cleanest edges (recommended)')}
              </option>
              <option value="flood">
                {t(
                  'Randfarben-Füllung — schnell, nur bei ruhigem Hintergrund',
                  'Edge color fill — fast, only for plain backgrounds',
                )}
              </option>
              <option value="alpha">
                {t('Bild bringt Alphakanal mit', 'Image has its own alpha channel')}
              </option>
            </select>
            <p className="hint small">
              {t(
                'Bleibt Hintergrund stehen, baut das Modell ihn als Geometrie mit — daher '
                  + 'die typischen Striche und Bodenplatten.',
                'Any background left in the image gets built into the geometry — hence '
                  + 'the typical stray strokes and ground plates.',
              )}
            </p>

            {isTextured && (
              <label className="check">
                <input type="checkbox" checked={cleanSpecks}
                  onChange={(e) => setCleanSpecks(e.target.checked)} />
                {t(
                  'Lose Fragmente entfernen (freischwebende Striche)',
                  'Remove loose fragments (floating strokes)',
                )}
              </label>
            )}
          </>
        )}

        <div className="row">
          <label>
            Steps
            <input value={steps} onChange={(e) => setSteps(e.target.value)}
              placeholder={mode === '3d' ? '50' : feat?.steps ? String(feat.steps) : 'auto'}
              inputMode="numeric" />
          </label>
          <label>
            Seed
            <input value={seed} onChange={(e) => setSeed(e.target.value)}
              placeholder={t('zufällig', 'random')} inputMode="numeric" />
          </label>
          {mode === 'image' && (
            <label>
              {t('Anzahl', 'Count')}
              <input type="number" min={1} max={8} value={batch}
                onChange={(e) => setBatch(Number(e.target.value))} />
            </label>
          )}
        </div>

        <button className="btn primary" onClick={generate} disabled={busy || noModel || !canGenerate}>
          {busy
            ? t('Generiert…', 'Generating…')
            : mode === '3d'
              ? t('Mesh erzeugen', 'Create mesh')
              : t('Generieren', 'Generate')}
          {mode !== '3d' && <kbd>{t('Strg+Enter', 'Ctrl+Enter')}</kbd>}
        </button>

        {noModel && (
          <p className="hint warn">
            {t(
              `Kein ${modeLabel}-Modell installiert — unter `,
              `No ${modeLabel} model installed — download one under `,
            )}
            <strong>{t('Modelle', 'Models')}</strong>
            {t(' eines herunterladen.', '.')}
          </p>
        )}
        {mode === '3d' && selected && meshWorker && !meshWorker.ready && (
          <p className="hint warn">
            {t(
              `${meshWorker.name}-Worker nicht eingerichtet: `,
              `${meshWorker.name} worker not set up: run `,
            )}
            <code>scripts\setup_{selected.workflow}.ps1</code>
            {t(' ausführen.', '.')}
          </p>
        )}
        {selected && selected.vram_gb > 13 && (
          <p className="hint warn">
            {t(
              `${selected.vram_gb} GB VRAM: eng auf 16 GB. Vorher „VRAM leeren“ drücken.`,
              `${selected.vram_gb} GB VRAM: tight on 16 GB. Press “Free VRAM” first.`,
            )}
          </p>
        )}
      </section>

      <section className="panel output">
        {busy && (
          <div className="progress-wrap">
            <div className="progress">
              <div className="bar" style={{ width: `${Math.round(progress * 100)}%` }} />
            </div>
            <div className="muted small progress-line">
              <span>
                {stage} · {Math.round(progress * 100)} %
                {mode === 'video' && t(' · Video dauert mehrere Minuten', ' · video takes several minutes')}
                {mode === '3d' && t(' · erster Lauf lädt das Modell', ' · the first run loads the model')}
              </span>
              <button className="btn small ghost danger-text" onClick={cancelJob}>
                {t('Abbrechen', 'Cancel')}
              </button>
            </div>
          </div>
        )}

        {error && <div className="error">{error}</div>}

        {results.length > 0 ? (
          <div className={results[0].kind === 'image' ? 'grid' : 'stack'}>
            {results.map((a) => (
              <figure key={a.id} className="card result">
                <AssetView asset={a} />
                <figcaption className="muted small">
                  {a.kind === 'mesh' ? a.model_id : `seed ${String(a.meta.seed ?? '?')} · ${a.model_id}`}
                  {' · '}
                  <a href={a.url} download>Download</a>
                  {typeof a.meta.caption === 'string' && (
                    <details className="caption">
                      <summary>{t('Beschreibung vom Upsampler', 'Description from the upsampler')}</summary>
                      <p>{a.meta.caption}</p>
                    </details>
                  )}
                </figcaption>
              </figure>
            ))}
          </div>
        ) : (
          !busy && <div className="placeholder">{t('Ergebnisse erscheinen hier.', 'Results appear here.')}</div>
        )}
      </section>
    </div>
  )
}
