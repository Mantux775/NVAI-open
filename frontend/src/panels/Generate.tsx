import { LinkText } from '../components/LinkText'
import { useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react'

/** Bildraster mit eigenem Scrollbereich: Ist es am Ende, scrollt das Mausrad die Seite weiter. Sonst hält Chrome die
 *  Geste im Raster fest, und mit vielen Bildern ging es nicht nach unten zum Knopf (Nutzer 22.11.2026: „ich kann nicht
 *  nach unten scrollen um es zu bestätigen“; gemessen: 5 Rastungen bewegten die Seite nur 120 px, der Rest ins Raster). */
const chained = new WeakSet<HTMLElement>()
function chainWheel(el: HTMLDivElement | null) {
  if (!el || chained.has(el)) return
  chained.add(el)
  el.addEventListener('wheel', (e) => {
    const down = e.deltaY > 0
    const atEnd = down ? el.scrollTop + el.clientHeight >= el.scrollHeight - 1 : el.scrollTop <= 0
    const page = el.closest('main.content') as HTMLElement | null
    if (!atEnd || !page || e.deltaY === 0) return
    e.preventDefault()
    page.scrollBy({ top: e.deltaY * (e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? page.clientHeight : 1) })
  }, { passive: false })
}
import { api, LORA_BASE_LABEL, SPEECH_LANGUAGES, type SpeechLanguage, type ExpandTarget, type LoraRef, type LoraUploadResult, type Asset, type GenKind, type Health, type Job, type Mesh3DParams, type ModelInfo, type RestoreMode, type ServerEvent, type SparseAttention, type StudioProjectInfo } from '../api'
import { LoraUpload } from '../components/LoraFile'
import { AssetView } from '../components/AssetView'
import type { Downloads } from '../downloads'
import { ContentBadge } from '../components/ContentBadge'
import { LicenseBadge, OutputBadge, licenseBlocked } from '../components/LicenseBadge'
import { ModelTip, Recommendations } from '../components/Recommendations'
import { ModelEstimate } from '../components/HardwareInfo'
import { Lightbox } from '../components/Lightbox'
import { PhotoCrop } from '../components/PhotoCrop'
import { locale, t } from '../i18n'
import { I2V_WORKFLOWS, OPTIONAL_START_WORKFLOWS, startImageUse } from '../videoStart'
// Konzept „NVAI im Fluss“ (seit 0.5.42), Bildschirme B und C: Weg statt Klappen, Modell-Chip, Knopf mit Zeit, Phasen,
// nächste Schritte unter dem Ergebnis
import { sourceText, totalSeconds, useEstimates, type Estimate } from '../flow/estimate'
import { isActive, trackJob, useJob } from '../flow/jobs'
import { JobPhases } from '../flow/JobPhases'
import { ModelNeed } from '../flow/ModelNeed'
import { fmtClock, fmtEta } from '../flow/time'
import { MODE_FAMILIES, MODE_OF_KIND, fitsMode, missingChoices, pickMissing, pickRunnable, type GenMode } from '../flow/generate/models'
import { ChipNumber, ChipSelect, NextSteps, RunningEta, SeedCopy, Slot, type NextStep, type SlotAsset } from '../flow/generate/parts'
import { estimateItem, finalPlan, rerunPlan, sendPlan, type Plan } from '../flow/generate/plan'
import {
  aspectDiffers, closestSize, ltxFramesFor, padToAspect, videoWays, wayDetail, wayLabel, wayNote, wayRules,
  type VideoWay,
} from '../flow/generate/ways'
import '../flow/generate.css'

// Dezimalzahl im Format der gewählten Sprache (Deutsch mit Komma)
const dec = (n: number, digits: number) =>
  n.toLocaleString(locale(), { minimumFractionDigits: digits, maximumFractionDigits: digits })

// Modellname ohne die Fassung: „Qwen-Image-2512 (NVFP4, volle 50 Schritte)“ → „Qwen-Image-2512“,
// „Kandinsky 6 Pro, destilliert (INT8, mit Ton)“ → „Kandinsky 6 Pro“
const shortName = (m: ModelInfo) => m.name.split(' (')[0].split(', ')[0]

// "restore" (seit 0.5.11) erzeugt nichts Neues, sondern bessert ein Foto aus: eigener Reiter, eigener Endpunkt.
type Mode = GenKind | 'restore'

const MODES: { id: Mode; label: string; icon: string }[] = [
  { id: 'image', label: t('Bild', 'Image'), icon: '▣' },
  { id: 'audio', label: t('Audio', 'Audio'), icon: '♪' },
  { id: 'speech', label: t('Sprache', 'Speech'), icon: '❝' },
  { id: 'video', label: t('Video', 'Video'), icon: '▶' },
  { id: '3d', label: '3D', icon: '◈' },
  { id: 'restore', label: t('Restaurieren', 'Restore'), icon: '✦' },
]

// Bildauswahl: so viele Bilder und Uploads zeigen und je Klick auf „Weitere laden“ dazunehmen.
const SOURCE_PAGE = 50

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

// Person aus einem Foto: Ergebnisse erkennt man am festen Anfang des Prompts, ihr Gesicht stammt aus
// meta.reference_asset_ids[0]. Neue Versuche nehmen immer dieses Foto und nie ein Ergebnis (Nutzer 23.11.2026: „jedes
// weitere Versuch macht er nur schlimmer“: das erste Ergebnis wurde Startbild und damit Vorlage, FLUX malte jedes Mal
// die Runde davor nach, das Gesicht verlor mit jedem Durchgang, zuerst die Augen).
// Unter Bild (seit 23.11.2026) ohne „Cinematic film still.“: Dort bestimmt die Rolle den Stil, ohne Angabe wird es bei
// FLUX 3 ein Foto. Erkannt werden beide Anfänge.
const PERSON_IMAGE_HEAD = 'The person from the first image'
const PERSON_HEAD = `Cinematic film still. ${PERSON_IMAGE_HEAD}`
const isPersonResult = (a?: Asset | null) => !!a && a.kind === 'image'
  && (a.prompt || '').replace(/^Cinematic film still\. /, '').startsWith(PERSON_IMAGE_HEAD)

// Personen brauchen Pixel: In 864 × 480 ist der Kopf in einer Halbtotalen nur ~150 px hoch, die Augen verformen sich.
// Startbilder für kleine Videoformate deshalb mit mindestens ~0,9 MP im selben Seitenverhältnis;
// die Videomodelle ziehen das Startbild selbst auf ihr Format (ImageScale, lanczos).
function personSize(w: number, h: number): { w: number; h: number } {
  if (w * h >= 880_000) return { w, h }
  for (const k of [1.25, 1.5, 1.75, 2, 2.5, 3]) {
    const W = w * k
    const H = h * k
    if (Number.isInteger(W / 16) && Number.isInteger(H / 16) && W * H >= 880_000) return { w: W, h: H }
  }
  const k = Math.sqrt(921_600 / (w * h))
  return { w: Math.round((w * k) / 16) * 16, h: Math.round((h * k) / 16) * 16 }
}

const PLACEHOLDER: Record<Mode, string> = {
  image: 'stylized fantasy sword, game asset, orthographic, clean background',
  audio: 'footsteps on gravel, close mic, dry, no music',
  video: 'a torch flickering in a dark stone corridor, slow camera push in',
  '3d': 'a weathered stone gargoyle',
  speech: t('Willkommen in der alten Mühle. Hier wurde früher Korn gemahlen, heute erzählt sie Geschichten.',
    'Welcome to the old mill. Grain used to be ground here, today it tells stories.'),
  restore: '',
}

// Was "Prompt ausbauen" je Reiter daraus macht -- steht im Tooltip des Knopfs.
const EXPAND_TIP: Record<Mode, string> = {
  image: t('Aus „a medieval blacksmith“ wird eine ganze Schmiede: Esse, Amboss, Funken, Licht.',
    'Turns “a medieval blacksmith” into a whole forge: hearth, anvil, sparks, light.'),
  video: t('Ergänzt Bewegung, Kamerafahrt, Ort und Licht; bei LTX-2.5 auch den Ton, mit Startbild nur die Bewegung.',
    'Adds motion, camera move, setting and light; with LTX-2.5 also the sound, with a start image only the motion.'),
  audio: t('Stable Audio: Klang-Tags (Quelle, Material, Raum, Mikrofon). Stable Audio 3: ein Satz mit Gattung, Instrumenten, Stimmung und BPM.',
    'Stable Audio: sound tags (source, material, room, microphone). Stable Audio 3: one sentence with genre, instruments, mood and BPM.'),
  '3d': t('Beschreibt ein einzelnes, geschlossenes Objekt ohne Boden und Schatten, so wie die 3D-Modelle es brauchen.',
    'Describes a single closed object without floor or shadow, the way the 3D models need it.'),
  speech: '',
  restore: '',
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
    'Stable Audio: Klang beschreiben (SFX). Stable Audio 3: Musik in einem Satz, ohne Gesang.',
    'Stable Audio: describe the sound (SFX). Stable Audio 3: music in one sentence, no vocals.',
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
  speech: t('Der Text wird so gesprochen, wie er dasteht; Satzzeichen setzen Pausen.',
    'The text is spoken as written; punctuation sets the pauses.'),
  restore: '',
}

interface Props {
  health: Health | null
  event: ServerEvent | null
  downloads: Downloads
  /** zählt hoch, wenn eine LoRA hinzukam, zugeordnet oder gelöscht wurde (auch per MCP): Modellliste neu laden */
  modelsVersion?: number
  onShowModels: () => void
  /** Auftragsleiste „Zeigen“ (Konzept „NVAI im Fluss“, Bildschirm F): diesen Auftrag samt Ergebnis zeigen, den Reiter
   *  passend umschalten; n zählt bei jedem Klick hoch */
  focus?: { jobId: string; n: number } | null
  /** Willkommen-Bildschirm: mit diesem Reiter anfangen; n zählt bei jedem Klick hoch */
  preset?: { mode: Mode; n: number } | null
  /** „Ins Studio“ unter einem Ergebnis: das Projekt öffnen, die neue Szene gewählt */
  onOpenStudio?: (projectId: string, sceneId?: string | null) => void
}

// Was nach dem ersten Auftrag nur noch rechnet (JobPhases: „… braucht nur die Rechenzeit“), je Reiter schon übersetzt
const NEXT_TEXT: Record<Mode, string> = {
  image: t('das nächste Bild', 'the next image'),
  video: t('das nächste Video', 'the next video'),
  audio: t('der nächste Ton', 'the next sound'),
  speech: t('der nächste Satz', 'the next line'),
  '3d': t('das nächste Mesh', 'the next mesh'),
  restore: t('das nächste Foto', 'the next photo'),
}

/** Kurzer Titel für eine Szene im Studio: die ersten Wörter des Prompts */
function sceneTitle(a: Asset): string {
  const text = String(a.meta?.text || a.prompt || a.meta?.original_name || a.filename)
    .replace(/^Cinematic film still\. /, '').replace(/\s+/g, ' ').trim()
  const words = text.split(' ').slice(0, 6).join(' ')
  return words.length > 48 ? `${words.slice(0, 46)}…` : words
}

/** Kurzer Name eines Assets für einen Platz („Startbild: Holzfass …“) */
function assetName(a: Asset): string {
  const text = String(a.prompt || a.meta?.original_name || a.filename).replace(/^Cinematic film still\. /, '')
  return text.length > 60 ? `${text.slice(0, 58)}…` : text
}

/** Holt ein Element in den sichtbaren Bereich, wenn sein Anfang nicht schon gut zu sehen ist */
function bringIntoView(el: Element | null | undefined) {
  if (!el) return
  const r = el.getBoundingClientRect()
  if (!r.width && !r.height) return // ausgeblendet (anderer Reiter)
  const box = (el.closest('main.content') as HTMLElement | null)?.getBoundingClientRect()
  const top = box?.top ?? 0
  const bottom = box?.bottom ?? window.innerHeight
  if (r.top >= top && r.top <= bottom - Math.min(r.height, 220)) return
  let smooth = true
  try {
    smooth = !window.matchMedia('(prefers-reduced-motion: reduce)').matches
  } catch {
    /* alter Browser: weich scrollen */
  }
  el.scrollIntoView({ block: 'start', behavior: smooth ? 'smooth' : 'auto' })
}

/** Hochgeladene Dateien, die als Quellbild taugen */
const IMAGE_FILE = /\.(png|jpe?g|webp|bmp|gif|tiff?)$/i

// Bild erweitern ohne eigenen Prompt (Nutzer 22.11.2026: „wenn ich nur extend will dann lieber neuen button
// einblenden“): neutral, damit nichts erfunden wird; FLUX 3 ergaenzt die Beschreibung aus dem Vorlagenbild selbst
const EXTEND_PROMPT = 'The same scene continues seamlessly beyond the edges, in the same style, with the same lighting '
  + 'and the same perspective.'

export function GeneratePanel({ health, event, downloads, modelsVersion = 0, onShowModels, focus, preset, onOpenStudio }: Props) {
  const [mode, setMode] = useState<Mode>('image')
  const [models, setModels] = useState<ModelInfo[]>([])
  const [modelId, setModelId] = useState<Record<Mode, string>>({
    image: '', audio: '', speech: '', video: '', '3d': '', restore: '',
  })

  const [prompt, setPrompt] = useState('')
  const [negative, setNegative] = useState('')
  // Kandinsky 6 (seit 0.5.25): was zu hören ist, getrennt von der Bildbeschreibung (features.audio_prompt)
  const [audioPrompt, setAudioPrompt] = useState('')
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
  // Konzept „NVAI im Fluss“, Bildschirm B: der Weg (Nur Text, Mit Startbild, Start und Ende, Schleife, Layout-Video,
  // Verlängern) statt einzelner Klappen; was nicht zum Weg passt, wirkt nicht (flow/generate/ways.ts). Die Schleife ist
  // seitdem ein Weg und kein eigener Schalter mehr.
  const [way, setWay] = useState<VideoWay>('text')
  // Welche Auswahl unter den Plätzen des Wegs offen ist
  const [slotOpen, setSlotOpen] = useState<'start' | 'end' | 'layout' | 'extend' | null>(null)
  const [quality, setQuality] = useState<'standard' | 'dfr'>('standard')
  // DFR ist die Vorgabe, sobald das Detail-LoRA installiert ist (Nutzer, 24.10.: "die höhere Qualität
  // immer bevorzugen, aber darauf hinweisen"), bis jemand die Qualität selbst umstellt.
  const qualityTouched = useRef(false)
  const chooseQuality = (q: 'standard' | 'dfr') => {
    qualityTouched.current = true
    setQuality(q)
  }
  const [temporal, setTemporal] = useState(false)
  const [audioId, setAudioId] = useState('')
  const [audioAssets, setAudioAssets] = useState<Asset[]>([])
  // Sprecherstimme (seit 0.5.21): Stimme beschreiben oder aus einer Aufnahme übernehmen
  const [voiceMode, setVoiceMode] = useState<'design' | 'clone'>('design')
  const [voiceDesc, setVoiceDesc] = useState('')
  const [voiceAsset, setVoiceAsset] = useState('')
  const [voiceText, setVoiceText] = useState('')
  const [speechLang, setSpeechLang] = useState<SpeechLanguage>('auto')
  const [voiceRefs, setVoiceRefs] = useState<Asset[]>([])
  const voiceFileRef = useRef<HTMLInputElement>(null)
  // Video verlängern (seit 0.5.10): ein vorhandenes Video fortsetzen, sein letzter Frame wird Startbild
  const [extendId, setExtendId] = useState('')
  // Layout-To-Render (seit 0.5.36): Layout-Video (erzeugt oder hochgeladen)
  const [guideId, setGuideId] = useState('')
  const [layoutUploads, setLayoutUploads] = useState<Asset[]>([])
  const videoInput = useRef<HTMLInputElement>(null)
  // Endbild des Wegs „Start und Ende“ hochladen
  const endFileRef = useRef<HTMLInputElement>(null)
  // Breite der Einstellungen ziehen wie die Spalten im Studio (Nutzer 22.11.2026: „den abstand zwischen linken und
  // rechten bereich im generieren … verschieben können wie in studio fenstern“); Doppelklick stellt sie zurück
  const splitRef = useRef<HTMLDivElement>(null)
  const [leftWidth, setLeftWidth] = useState<number | null>(() => {
    try {
      const v = Number(localStorage.getItem('nvai-generate-left'))
      return v >= 320 ? v : null
    } catch {
      return null
    }
  })
  const dragSplit = (e: RPointerEvent) => {
    const box = splitRef.current?.getBoundingClientRect()
    if (!box) return
    e.preventDefault()
    ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
    const move = (ev: PointerEvent) => {
      const w = Math.round(Math.min(box.width - 340, Math.max(340, ev.clientX - box.left - 4)))
      setLeftWidth(w)
      try { localStorage.setItem('nvai-generate-left', String(w)) } catch { /* privates Fenster: nur diese Sitzung */ }
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  const resetSplit = () => {
    setLeftWidth(null)
    try { localStorage.removeItem('nvai-generate-left') } catch { /* egal */ }
  }
  const [videoAssets, setVideoAssets] = useState<Asset[]>([])
  const [motionSpeed, setMotionSpeed] = useState(1)
  // Verlustfreie Kopie jedes Videos (FFV1/MKV) für Schnitt und Studio-Export; kostet Platz, deshalb abschaltbar
  const [master, setMasterState] = useState(() => {
    try {
      return localStorage.getItem('nvai-video-master') !== '0'
    } catch {
      return true
    }
  })
  const setMaster = (on: boolean) => {
    setMasterState(on)
    try {
      localStorage.setItem('nvai-video-master', on ? '1' : '0')
    } catch {
      /* privates Fenster */
    }
  }
  // Ablegen in (seit 0.5.15, Nutzer 27.10.2026: „neu generierte Assets für das Projekt wie Referenzbilder gleich im
  // Projektordner“): Verlauf oder der Ordner eines Studio-Projekts, gemerkt im Browser; ein gelöschtes Projekt fällt
  // auf den Verlauf zurück
  const [projects, setProjects] = useState<StudioProjectInfo[]>([])
  const [target, setTarget] = useState(() => {
    try {
      return localStorage.getItem('nvai-generate-project') ?? ''
    } catch {
      return ''
    }
  })
  const refreshProjects = () => {
    api.studioProjects().then(setProjects).catch(() => {})
  }
  useEffect(() => {
    refreshProjects()
  }, [])
  const projectId = projects.some((x) => x.id === target) ? target : ''
  const chooseProject = (id: string) => {
    setTarget(id)
    try {
      localStorage.setItem('nvai-generate-project', id)
    } catch {
      /* privates Fenster */
    }
  }
  const [multishot, setMultishot] = useState(false)
  // Person aus einem Foto (seit 0.5.8): Rolle, in der FLUX 3 die Person aus dem Startbild zeigen soll
  const [roleText, setRoleText] = useState('')
  // Modell dafür (seit 23.11.2026 wählbar, Nutzer: „auch andere modelle als flux3 auswählen können“), das Foto mit dem
  // Gesicht (aufgelöst aus dem Startbild) und der Dialog zum Zuschneiden
  const [personModelId, setPersonModelId] = useState(() => {
    try {
      return localStorage.getItem('nvai-person-model') || ''
    } catch {
      return ''
    }
  })
  const [facePhoto, setFacePhoto] = useState<{ id: string; asset: Asset | null } | null>(null)
  const [cropOpen, setCropOpen] = useState(false)
  // Unter Bild hat der Abschnitt eine eigene Fotoauswahl: Das Quellbild dort gehört zum Überarbeiten (img2img)
  const [personPhotoId, setPersonPhotoId] = useState('')
  const personFileRef = useRef<HTMLInputElement>(null)
  const [steps, setSteps] = useState('')
  const [seed, setSeed] = useState('')
  const [batch, setBatch] = useState(1)
  // Foto restaurieren: Schritte (Schäden, Farbe, Schärfe) und Hinweise an FLUX 3
  const [restoreRepair, setRestoreRepair] = useState(true)
  const [restoreMode, setRestoreMode] = useState<RestoreMode>('auto')
  const [restoreColorize, setRestoreColorize] = useState(false)
  const [restoreSharpen, setRestoreSharpen] = useState(false)
  const [restoreScale, setRestoreScale] = useState(2)
  const [restoreNotes, setRestoreNotes] = useState('')

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
  // Für loadSources, das auch aus älteren Effekten heraus läuft: die aktuelle Auswahl
  const refIdsRef = useRef(refIds)
  refIdsRef.current = refIds
  const [loraPicks, setLoraPicks] = useState<LoraRef[]>([])
  // Beschleuniger für Videomodelle, die sie kennen (MiniMax H3); beim Wechsel aufs Modell mit dessen Empfehlung belegt
  const [sparse, setSparse] = useState<SparseAttention | ''>('')
  const [int8, setInt8] = useState(false)
  // "Prompt ausbauen": vorheriger Prompt zum Zurücknehmen, Laufzeit der letzten Runde
  const [expanding, setExpanding] = useState(false)
  const [promptBefore, setPromptBefore] = useState<string | null>(null)
  const [expandSecs, setExpandSecs] = useState<number | null>(null)

  // 3D
  const [sourceImages, setSourceImages] = useState<Asset[]>([])
  const [sourceId, setSourceId] = useState<string>('')
  // Vom Laden vorgewählt (neuestes Bild), nicht vom Nutzer: Unter Video gilt das nicht als Startbild (Nutzer 23.11.2026
  // nach dem Neuladen: „Nichts vorauswählen“; sonst stand bei „Person aus einem Foto“ schon ein Foto)
  const sourceAuto = useRef(false)
  const pickSource = (id: string) => {
    sourceAuto.current = false
    setSourceId(id)
  }
  const [faces, setFaces] = useState('')
  const [textureSize, setTextureSize] = useState(2048)
  const [bgMode, setBgMode] = useState<'birefnet' | 'flood' | 'alpha'>('birefnet')
  const [cleanSpecks, setCleanSpecks] = useState(true)
  const [projectFront, setProjectFront] = useState(false)
  const [confirmClearSources, setConfirmClearSources] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)

  const [jobId, setJobId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [results, setResults] = useState<Asset[]>([])
  // Große Ansicht eines Ergebnisbildes (Index in results), siehe components/Lightbox.tsx
  const [preview, setPreview] = useState<number | null>(null)
  const imageResults = useMemo(() => results.filter((r) => r.kind === 'image'), [results])
  useEffect(() => setPreview(null), [results])
  const busy = jobId !== null

  const jobRef = useRef<string | null>(null)
  jobRef.current = jobId
  // Konzept „NVAI im Fluss“, Bildschirm C: Welcher Auftrag rechts zu sehen ist (der eigene, oder einer aus der
  // Auftragsleiste über „Zeigen“), samt Phasen, Ergebnis und nächsten Schritten
  const [viewId, setViewId] = useState<string | null>(null)
  const viewRef = useRef<string | null>(null)
  viewRef.current = viewId
  // Der Auftrag hinter dem Ergebnis, wie der Server ihn kennt: Dauer, Parameter für „4 Varianten“
  const [viewJob, setViewJob] = useState<Job | null>(null)
  // Ergebnisse schon geladen für diesen Auftrag (sonst lüde jedes Ereignis sie neu)
  const loadedFor = useRef<string | null>(null)
  // Was beim Abschicken feststand: Titel, Modell für „Modell lädt (…)“, geschätzte Rechenzeit für die Restzeit
  const [run, setRun] = useState<{ id: string; title: string; modelName?: string; modelGb?: number;
    expected: number | null; next: string } | null>(null)
  // Reiter des eigenen Auftrags beim Abschicken: Das Ergebnis wird danach eingeordnet, auch wenn inzwischen ein anderer
  // Reiter offen ist (etwa nach „Zeigen“ in der Auftragsleiste)
  const jobModeRef = useRef<Mode>('image')
  // Das Ergebnis, mit dem die nächsten Schritte weitergehen (bei mehreren Bildern wählbar, Vorgabe das erste)
  const [pickedId, setPickedId] = useState<string | null>(null)
  // Ein nächster Schritt braucht ein Modell, das noch fehlt: dann steht ModelNeed unter den Schritten
  const [nextNeed, setNextNeed] = useState<{ step: string; model: ModelInfo; alternative?: ModelInfo; alt?: () => void } | null>(null)
  const [studioNote, setStudioNote] = useState<string | null>(null)
  const [studioBusy, setStudioBusy] = useState(false)
  // Zählt hoch: Phasen bzw. Ergebnis ins Bild holen; Prompt fokussieren nach einem vorbereitenden Schritt
  const [reveal, setReveal] = useState(0)
  const [focusPrompt, setFocusPrompt] = useState(0)
  const outputRef = useRef<HTMLElement>(null)
  const resultRef = useRef<HTMLDivElement>(null)
  // Ein Auftrag ist unterwegs zum Server (noch ohne Antwort): ein zweiter Klick schickt ihn nicht doppelt
  const sending = useRef(false)
  const controlsRef = useRef<HTMLElement>(null)
  const promptRef = useRef<HTMLTextAreaElement>(null)

  // Nur neu laden, wenn sich die aktiven Modelle wirklich ändern: health kommt alle 5 s als neues Objekt, und jedes Mal
  // die ganze Modellliste (samt Fragen an Hugging Face) zu holen belastete den Server
  const activeKey = JSON.stringify(health?.active_models ?? {})
  useEffect(() => {
    api.models().then((all) => {
      setModels(all)
      setModelId((cur) => {
        const next = { ...cur }
        for (const m of MODES) {
          if (next[m.id]) continue
          if (m.id === 'restore') {
            // Wie der Server ohne eigene Wahl: FLUX 3 (destilliert) zum Bearbeiten.
            next.restore = all.find((x) => x.kind === 'image' && x.runnable && x.workflow === 'flux3_klein')?.id ?? ''
            continue
          }
          next[m.id] = health?.active_models?.[m.id] ?? all.find((x) => x.kind === m.id && x.runnable)?.id ?? ''
        }
        return next
      })
    }).catch((e) => setError(String((e as Error).message ?? e)))
    // eslint-disable-next-line react-hooks/exhaustive-deps -- activeKey steht für health.active_models
  }, [activeKey, downloads.finished, modelsVersion])

  // Bildauswahl (Quell-, Start-, Referenzbild, Foto): die neuesten Bilder und Uploads, mit „Weitere 50 laden“
  // wie der Verlauf (Nutzerwunsch 25.10.2026, vorher fest 40 Bilder und 20 Uploads). Die Grenze steht in einem
  // Ref, damit auch die Effekte unten mit der aktuellen nachladen.
  const sourceLimit = useRef(SOURCE_PAGE)
  const [sourceMore, setSourceMore] = useState(false)
  const loadSources = () => {
    const limit = sourceLimit.current
    Promise.all([api.assets('image', limit + 1), api.assets('upload', limit + 1)]).then(([imgs, ups]) => {
      // Uploads sind auch Videos und Töne (VHS-Bänder, Studio-Material): als Quellbild nur Bilder
      const pics = ups.filter((a) => IMAGE_FILE.test(a.filename))
      const merged = [...imgs, ...pics].sort((a, b) => b.created_at - a.created_at)
      const all = merged.slice(0, limit)
      setSourceMore(merged.length > limit)
      setSourceImages(all)
      // Unter Video ohne eigene Wahl kein Startbild (reines Text-zu-Video, „Person aus einem Foto“ leer); sonst das
      // neueste Bild als automatische Wahl
      setSourceId((cur) => {
        if (cur || mode === 'video') return cur
        sourceAuto.current = !!all[0]
        return all[0]?.id || ''
      })
      // Gewählte Referenzen, die aus den neuesten Bildern gefallen sind, bleiben sichtbar und gewählt (vorher fielen sie
      // nach ein paar Läufen still aus dem Auftrag); gelöschte fallen aus der Auswahl
      const outside = refIdsRef.current.filter((id) => !all.some((a) => a.id === id))
      if (!outside.length) return
      Promise.all(outside.map((id) => api.asset(id).catch(() => null))).then((found) => {
        const kept = found.filter((a): a is Asset => !!a)
        if (kept.length) setSourceImages((list) => [...list, ...kept.filter((a) => !list.some((x) => x.id === a.id))])
        const gone = outside.filter((id) => !kept.some((a) => a.id === id))
        if (gone.length) setRefIds((list) => list.filter((id) => !gone.includes(id)))
      })
    }).catch(() => { /* die Auswahl bleibt, wie sie war; der nächste Abgleich holt sie */ })
  }
  const loadMoreSources = () => {
    sourceLimit.current += SOURCE_PAGE
    loadSources()
  }
  const moreSourcesButton = sourceMore && (
    <button className="btn small ghost" onClick={loadMoreSources}>
      {t(`Weitere ${SOURCE_PAGE} laden`, `Load ${SOURCE_PAGE} more`)}
    </button>
  )

  // Bilder werden überall gebraucht: als Mesh-Quelle, als Video-Startbild, als
  // Vorlage zum Überarbeiten und als ControlNet-Referenz.
  useEffect(() => {
    // Ein in einem anderen Modus automatisch vorgewähltes Bild ist unter Video kein Startbild
    if (mode === 'video' && sourceAuto.current) {
      sourceAuto.current = false
      setSourceId('')
    }
    loadSources()
  }, [mode])

  // Ergebnis eines Auftrags rechts zeigen und ins Bild holen (Konzept, Bildschirm C: „Das Ergebnis rückt ins Bild“;
  // vorher erschien es oben rechts außer Sicht, während die Seite unten beim Knopf stand)
  const showResults = (id: string, assets: Asset[]) => {
    if (viewRef.current !== id) return
    loadedFor.current = id
    setResults(assets)
    setPickedId(assets[0]?.id ?? null)
    setReveal((n) => n + 1)
    api.job(id).then((j) => { if (viewRef.current === id) setViewJob(j) }).catch(() => {})
  }

  const applyDone = (id: string) => {
    const jobMode = jobModeRef.current
    // Schon hier: Die gemeinsame Auftragsliste meldet das Ende auch, das Ergebnis soll aber nur einmal kommen
    if (viewRef.current === id) loadedFor.current = id
    api.jobAssets(id).then((assets) => {
      showResults(id, assets)
      // 3D aus Text und Person aus einem Foto: das frische Bild gleich als Quell- bzw. Startbild auswählen.
      if ((jobMode === '3d' || jobMode === 'video') && assets[0]?.kind === 'image') {
        pickSource(assets[0].id)
        if (jobMode === 'video') setWay((w) => (w === 'text' || w === 'refs' || w === 'extend' ? 'start' : w))
        loadSources()
      }
    })
    setJobId(null)
    if (jobMode === 'image') loadSources()
  }

  // Rückfall, wenn das Ende-Ereignis verpasst wurde (der Auftrag scheiterte schon vor der Antwort auf das Absenden,
  // der Live-Feed verband neu, ein Folgeereignis überschrieb es): den Auftrag selbst nachsehen, gleich und alle 5 s.
  // Sonst blieb Generieren gesperrt, bis man die Seite neu lud.
  useEffect(() => {
    if (!jobId) return
    let alive = true
    const check = () =>
      api
        .job(jobId)
        .then((j) => {
          if (!alive || jobRef.current !== jobId) return
          if (j.status === 'done') applyDone(jobId)
          else if (j.status === 'error') {
            setError(j.error ?? t('Fehler', 'Error'))
            endOwn(jobId)
          } else if (j.status === 'cancelled') {
            endOwn(jobId)
          }
        })
        .catch(() => {})
    check()
    const timer = setInterval(check, 5000)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [jobId])

  // Eigener Auftrag ohne Ergebnis zu Ende (Fehler, abgebrochen): Knopf frei, die Phasen verschwinden
  const endOwn = (id: string) => {
    setJobId(null)
    if (viewRef.current === id) {
      viewRef.current = null
      setViewId(null)
    }
  }

  // Fortschritt und Phasen zeigt JobPhases aus der gemeinsamen Auftragsliste (flow/jobs.ts); hier nur das Ende
  useEffect(() => {
    if (!event || !('job_id' in event) || event.job_id !== jobRef.current) return
    if (event.type === 'job.done') {
      applyDone(event.job_id)
    } else if (event.type === 'job.error') {
      setError(event.error)
      endOwn(event.job_id)
    } else if (event.type === 'job.cancelled') {
      // Auch ein Stopp über die Kopfleiste oder aus dem PhotoCraft-Add-on landet hier.
      endOwn(event.job_id)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- applyDone liest den Reiter des Auftrags aus jobModeRef
  }, [event])

  const cancelJob = async () => {
    if (!jobId) return
    const id = jobId
    try {
      const res = await api.cancelJob(id)
      if (!res.ok) {
        // „schon beendet“: dann den Endstand übernehmen, statt gesperrt zu bleiben
        const j = await api.job(id).catch(() => null)
        if (j?.status === 'done') {
          applyDone(id)
        } else if (j && ['error', 'cancelled'].includes(j.status)) {
          endOwn(id)
          if (j.status === 'error') setError(j.error ?? res.reason ?? null)
        } else if (res.reason) setError(res.reason)
      } else {
        endOwn(id)
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Der gezeigte Auftrag, wie die gemeinsame Auftragsliste ihn kennt (Phasen, Ende eines fremden Auftrags). Sind seine
  // Ergebnisse schon da, läuft er nicht mehr, auch wenn die Liste das Ende noch nicht kennt.
  const viewTracked = useJob(viewId)
  const viewActive = !!viewId && (viewId === jobId
    || (loadedFor.current !== viewId && !!viewTracked && isActive(viewTracked)))
  // Abbrechen gilt dem gezeigten Auftrag: dem eigenen wie bisher, sonst dem aus der Auftragsleiste
  const cancelView = async () => {
    if (!viewId) return
    if (viewId === jobId) {
      await cancelJob()
      return
    }
    try {
      const res = await api.cancelJob(viewId)
      if (!res.ok && res.reason) setError(res.reason)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  // Ein fremder gezeigter Auftrag (Studio, Claude per MCP) wird fertig: sein Ergebnis zeigen
  useEffect(() => {
    if (!viewId || viewId === jobId || !viewTracked) return
    if (viewTracked.status === 'done' && loadedFor.current !== viewId) {
      loadedFor.current = viewId
      const id = viewId
      api.jobAssets(id).then((assets) => showResults(id, assets)).catch(() => {})
    } else if (viewTracked.status === 'error' && viewTracked.error) {
      setError(viewTracked.error)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- nur beim Wechsel des Zustands
  }, [viewId, jobId, viewTracked?.status])

  // Phasen bzw. Ergebnis ins Bild holen, nachdem sie gerendert sind
  useEffect(() => {
    if (!reveal) return
    const id = window.requestAnimationFrame(() => bringIntoView(resultRef.current ?? outputRef.current))
    return () => window.cancelAnimationFrame(id)
  }, [reveal])

  // Nach einem vorbereitenden Schritt (Video daraus, Überarbeiten, Verlängern): Weg und Prompt ins Bild, der Prompt
  // markiert, damit man gleich die Bewegung bzw. die Änderung schreibt (Strg+Z holt den alten Text zurück)
  useEffect(() => {
    if (!focusPrompt) return
    const id = window.requestAnimationFrame(() => {
      bringIntoView(controlsRef.current)
      const el = promptRef.current
      if (el) {
        el.focus({ preventScroll: true })
        el.select()
      }
    })
    return () => window.cancelAnimationFrame(id)
  }, [focusPrompt])

  /** Ein abgeschickter Auftrag: in die gemeinsame Auftragsliste, rechts mit seinen Phasen zeigen (Konzept, Bildschirm C) */
  const startJob = (job: Job, info: { mode: Mode; title: string; model?: ModelInfo | null; est?: Estimate | null }) => {
    trackJob(job, info.est)
    jobModeRef.current = info.mode
    loadedFor.current = null
    setRun({
      id: job.id, title: info.title, modelName: info.model ? shortName(info.model) : undefined,
      modelGb: info.model?.vram_gb || undefined, expected: info.est?.seconds ?? null, next: NEXT_TEXT[info.mode],
    })
    setViewId(job.id)
    setViewJob(null)
    setResults([])
    setPickedId(null)
    setNextNeed(null)
    setStudioNote(null)
    setJobId(job.id)
    setReveal((n) => n + 1)
  }

  // Restaurieren nimmt Bildmodelle, die per Referenzbild bearbeiten (FLUX 3); Stilvorlagen (Krea 2) zählen nicht.
  const available = useMemo(
    () => mode === 'restore'
      ? models.filter((m) => m.kind === 'image' && m.runnable && (m.features?.references ?? 0) > 0
        && m.features?.reference_kind !== 'style')
      // nur, was auf dieser Karte rechnet (usable, seit 0.5.35; auf NVIDIA alles)
      : models.filter((m) => m.kind === mode && m.runnable && m.usable !== false),
    [models, mode],
  )
  const selected = available.find((m) => m.id === modelId[mode])
  const noModel = available.length === 0
  const modeLabel = MODES.find((m) => m.id === mode)?.label ?? ''
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
  // Ein gelöschtes oder hier nicht lauffähiges Modell bleibt nicht gewählt (die Auswahl zeigte sonst ein anderes, der
  // Auftrag ging aber an das alte): dann das aktive, sonst das empfohlene, sonst das erste geladene
  useEffect(() => {
    if (!available.length || available.some((m) => m.id === modelId[mode])) return
    const activeId = mode === 'restore' ? undefined : health?.active_models?.[mode]
    const pick = available.find((m) => m.id === activeId)
      ?? available.find((m) => (mode === 'restore' ? m.workflow === 'flux3_klein' : m.recommended))
      ?? available[0]
    setModelId((cur) => ({ ...cur, [mode]: pick.id }))
    // eslint-disable-next-line react-hooks/exhaustive-deps -- activeKey steht für health.active_models
  }, [available, mode, modelId, activeKey])
  // Ein ControlNet, das nicht zum gewählten Modell passt (andere Familie, gelöscht), fällt weg; es wirkte sonst unsichtbar
  // weiter, und der Auftrag scheiterte
  useEffect(() => {
    if (mode === 'image' && cnId && !controlnets.some((m) => m.id === cnId)) setCnId('')
  }, [mode, cnId, controlnets])
  // Eigene CFG, Sampler und Scheduler gehören zum Modell, für das sie eingestellt wurden: Beim Wechsel gelten wieder die
  // Vorgaben des neuen, solange die Feineinstellung zugeklappt ist (sonst wirkten sie dort ungesehen weiter)
  const tunedFor = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (mode !== 'image' || !selected) return
    if (tunedFor.current && tunedFor.current !== selected.id && !advanced) {
      setCfg('')
      setSampler('')
      setScheduler('')
    }
    tunedFor.current = selected.id
    // eslint-disable-next-line react-hooks/exhaustive-deps -- nur beim Wechsel des Modells
  }, [mode, selected?.id])
  // Bild-zu-Video: diese Modelle brauchen zwingend ein Startbild, Wan 2.2 TI2V
  // kann beides. Reine Text-zu-Video-Modelle bekommen die Auswahl gar nicht erst.
  const needsStart = mode === 'video' && I2V_WORKFLOWS.has(selected?.workflow ?? '')
  const usesStart = needsStart || (mode === 'video' && (OPTIONAL_START_WORKFLOWS.has(selected?.workflow ?? '')
    || selected?.features?.start_image === 'optional'))
  const meshWorker = selected?.workflow ? health?.mesh_workers?.[selected.workflow] : undefined

  // LoRAs, die zum gewählten Modell passen (Basis in lora_bases). Die Auswahl gilt je Modell;
  // was nicht passt, fällt beim Wechsel weg.
  const loraChoices = useMemo(
    () => models.filter((m) => m.kind === 'lora' && m.installed
      && (selected?.lora_bases ?? []).includes(m.family)),
    [models, selected],
  )
  const activeLoras = loraPicks.filter((p) => loraChoices.some((l) => l.id === p.model_id))
  // Nimmt das gewählte Modell keine LoRAs, nennt der LoRA-Bereich die eigenen Modelle dieser Art, die welche nehmen
  // (je Familie einmal, mit der Zahl geladener LoRAs), sonst einen Vorschlag aus dem Katalog. Die Turbo-LoRAs von
  // MiniMax H3 zählen dafür nicht: Sie beschleunigen nur, einen Stil bringen sie nicht (Nutzer 12.11.2026: „wenn für
  // das gewählte model keine loras hat oder nicht kompaktibel ist da wo loras stehen dann lieber ein Hinweiss“).
  const loraModels = useMemo(() => {
    const openBases = (m: ModelInfo) => (m.lora_bases ?? []).filter((b) => !b.startsWith('minimax_'))
    const seen = new Set<string>()
    return available
      .filter((m) => m.id !== selected?.id && openBases(m).length > 0)
      .map((m) => ({
        model: m,
        count: models.filter((l) => l.kind === 'lora' && l.installed && openBases(m).includes(l.family)).length,
      }))
      .sort((a, b) => b.count - a.count)
      .filter((x) => !seen.has(shortName(x.model)) && seen.add(shortName(x.model)))
      .slice(0, 3)
  }, [available, models, selected])
  const loraSuggestion = useMemo(() => {
    if (loraModels.length > 0) return undefined
    const takes = (m: ModelInfo) => m.kind === mode && !m.runnable
      && (m.lora_bases ?? []).some((b) => !b.startsWith('minimax_'))
    return models.find((m) => takes(m) && m.recommended) ?? models.find(takes)
  }, [loraModels, models, mode])
  const toggleLora = (id: string, strength = 0.8) =>
    setLoraPicks((list) => (list.some((p) => p.model_id === id)
      ? list.filter((p) => p.model_id !== id)
      : [...list, { model_id: id, strength }]))
  // LoRAs mit features.use "loop" (Cinemagraph) wirken nur mit Schleife: gemessen 25.10. bewegten sich
  // ohne Schleife 82–89 % des Bildes, mit Schleife 6 %. Beim Einschalten deshalb den Weg „Schleife“ wählen (DFR,
  // Endbild und Layout gelten dort nicht).
  const pickLora = (l: ModelInfo, strength?: number) => {
    const on = !loraPicks.some((p) => p.model_id === l.id)
    if (on && l.features?.use === 'loop' && sourceId && ways.includes('loop')) setWay('loop')
    // Turbo-LoRAs (MiniMax H3) legen Schritte und Shift fest: immer nur eine
    if (on && l.features?.turbo) {
      setLoraPicks((list) => list.filter((p) => !models.find((m) => m.id === p.model_id)?.features?.turbo))
    }
    toggleLora(l.id, strength)
  }

  // Eigene LoRA-Datei direkt in der Auswahl hinzufügen (seit 0.5.24); passt sie zum gewählten Modell, gleich anhaken
  const [loraUploadOpen, setLoraUploadOpen] = useState(false)
  const [loraNote, setLoraNote] = useState<string | null>(null)
  const loraAdded = (r: LoraUploadResult) => {
    const m = r.model
    setModels((list) => [...list.filter((x) => x.id !== m.id), m])
    setLoraUploadOpen(false)
    const fits = (selected?.lora_bases ?? []).includes(m.family)
    if (fits && !loraPicks.some((p) => p.model_id === m.id)) toggleLora(m.id)
    const base = LORA_BASE_LABEL[m.family] ?? m.family
    setLoraNote(
      (r.existing
        ? t(`Diese Datei war schon da („${m.name}“), ihre Angaben sind aktualisiert. `,
          `This file was already there (“${m.name}”); its details were updated. `)
        : '')
      + (fits
        ? (r.existing ? t(`„${m.name}“ ist angehakt.`, `“${m.name}” is ticked.`)
          : t(`„${m.name}“ ist hinzugefügt und angehakt.`, `“${m.name}” was added and ticked.`))
          + (m.trigger ? t(` Trigger-Wörter: ${m.trigger}`, ` Trigger words: ${m.trigger}`) : '')
        : (r.existing ? '' : t(`„${m.name}“ ist hinzugefügt. `, `“${m.name}” was added. `))
          + t(`Sie gehört zu ${base} und erscheint bei den Modellen dafür.`,
            `It belongs to ${base} and shows up with the models for it.`))
      + (r.warning ? ` ${r.warning}` : ''),
    )
  }

  // LTX-2.5 (seit 0.5.8): eigene Formate, Länge in Sekunden, Zusatzwege laut features.
  const vfeat = mode === 'video' ? selected?.features : undefined
  const isLtx25 = mode === 'video' && selected?.family === 'ltx25'
  const dfrReady = !!vfeat?.dfr
  // Konzept „NVAI im Fluss“, Bildschirm B: Der Weg bestimmt, welche Felder, Qualitäten und Zusätze gelten. Was nicht
  // zum Weg passt, bleibt eingestellt (zurück auf den Weg ist es wieder da), wirkt aber nicht und geht nicht in den
  // Auftrag; vorher löste die Oberfläche Konflikte still oder der Server lehnte den Auftrag ab.
  const ways = useMemo(() => (mode === 'video' ? videoWays(selected) : []), [mode, selected])
  const rules = wayRules(way)
  const wayStart = mode === 'video' && usesStart && rules.start !== 'none'
  const effStart = wayStart ? sourceId : ''
  const effEnd = isLtx25 && way === 'ends' ? endId : ''
  const effLoop = isLtx25 && way === 'loop' && !!sourceId
  const effGuide = isLtx25 && way === 'layout' && vfeat?.layout ? guideId : ''
  const effExtend = isLtx25 && way === 'extend' ? extendId : ''
  const effAudio = isLtx25 && vfeat?.audio_input && rules.audio ? audioId : ''
  const dfrWay = isLtx25 && rules.dfr
  const effQuality: 'standard' | 'dfr' = dfrWay && dfrReady && quality === 'dfr' ? 'dfr' : 'standard'
  const effTemporal = effQuality === 'dfr' && temporal && !!vfeat?.temporal_upscale
  const effAuto = isLtx25 && !!vfeat?.auto_duration && rules.auto && autoDuration && !effAudio
  const effMultishot = isLtx25 && !!vfeat?.multishot && rules.multishot && multishot
  const effMotion = isLtx25 && vfeat?.motion_speed && rules.motion ? motionSpeed : 1
  // DFR ist die Vorgabe, sobald das Detail-LoRA da ist, bis jemand die Qualität selbst umstellt; ob der Weg DFR
  // erlaubt, entscheidet effQuality. Nur unter Video: sonst fiel eine eigene DFR-Wahl bei jedem Reiterwechsel weg.
  useEffect(() => {
    if (mode !== 'video') return
    if (!dfrReady) {
      if (quality === 'dfr') setQuality('standard')
    } else if (!qualityTouched.current && quality !== 'dfr') {
      setQuality('dfr')
    }
  }, [mode, dfrReady, quality])
  // Ein Weg, den das gewählte Modell nicht kann, fällt auf den naheliegenden zurück: mit gewähltem Startbild (oder bei
  // reinen Bild-zu-Video-Modellen) „Mit Startbild“, sonst den ersten
  useEffect(() => {
    if (mode !== 'video' || !ways.length || ways.includes(way)) return
    setWay(ways.includes('start') && (sourceId || !ways.includes('text')) ? 'start' : ways[0])
  }, [mode, ways, way, sourceId])
  const chooseWay = (w: VideoWay) => {
    setWay(w)
    // Was der Weg noch braucht, gleich zur Auswahl öffnen
    const r = wayRules(w)
    setSlotOpen(r.start === 'required' && !sourceId ? 'start'
      : w === 'ends' && !endId ? 'end'
        : w === 'layout' && !guideId ? 'layout'
          : w === 'extend' && !extendId ? 'extend' : null)
  }
  const videoSizes = vfeat?.sizes?.length ? vfeat.sizes : VIDEO_SIZES
  // Andere Videomodelle mit festen Angaben im Katalog (features.fps, default_frames): Bildrate und Länge des Modells
  // statt der Wan-Vorgaben, sobald es gewählt wird.
  useEffect(() => {
    if (isLtx25) return
    if (vfeat?.fps) setFps(vfeat.fps)
    if (vfeat?.default_frames) setFrames(vfeat.default_frames)
  }, [isLtx25, vfeat?.fps, vfeat?.default_frames])
  // 8n+1 Frames, der nächste Wert zu ltxSeconds (wie workflows.ltx_frames_for_seconds: 5 s = 121).
  // Höchstens 481 Frames (API-Grenze): 20 s bei 24 fps, 19 s bei 25, 16 s bei 30.
  const ltxMaxSeconds = Math.min(vfeat?.max_seconds ?? 20, Math.floor(480 / ltxFps))
  const ltxFrames = ltxFramesFor(ltxSeconds, ltxFps, vfeat?.max_seconds ?? 20)
  // Empfohlene LoRAs für die gewählte Videofamilie (catalog.LORA_MODELS, features.recommended_for)
  const recLoras = useMemo(
    () => models.filter((m) => m.kind === 'lora'
      && (m.features?.recommended_for ?? []).includes(selected?.family ?? '-')),
    [models, selected],
  )
  // Vorwahl für das bestmögliche Ergebnis (features.recommended, gemessen oder laut Hersteller) beim Wechsel aufs
  // Modell: Format (Bild, Video), Länge (Musik, Video), DFR bei LTX-2.5, bei MiniMax H3 Turbo-LoRA (wenn geladen),
  // Sparse Attention und INT8-Attention. Danach gilt, was der Nutzer einstellt; Video-Aufträge schicken alles
  // ausdrücklich mit (recommended: false). Der Server nimmt auf älteren Karten und AMD aus, was dort nicht läuft.
  const recFor = selected && (mode === 'image' || mode === 'audio' || mode === 'video') ? `${mode}:${selected.id}` : ''
  // Je Reiter das zuletzt vorgewählte Modell: Kehrt man nur aus einem anderen Reiter zurück, bleibt, was man eingestellt
  // hatte (vorher kamen Format, Länge und DFR wieder, der nächste Lauf dauerte dann 13 statt gut 1 Minute)
  const presetFor = useRef<Record<string, string>>({})
  useEffect(() => {
    if (!recFor || !selected) return
    if (presetFor.current[mode] === selected.id) return
    presetFor.current[mode] = selected.id
    const rec = selected.features?.recommended
    const [w, h] = rec?.size ?? [0, 0]
    if (mode === 'image') {
      const size = sizes.find((s) => s.w === w && s.h === h)
      if (size) setImgSize(size)
      return
    }
    if (mode === 'audio') {
      if (rec?.seconds) setSeconds(rec.seconds)
      return
    }
    const size = videoSizes.find((s) => s.w === w && s.h === h)
    if (size) setVidSize(size)
    if (rec?.seconds) setLtxSeconds(rec.seconds)
    if (rec?.quality && !qualityTouched.current) setQuality(rec.quality === 'dfr' && dfrReady ? 'dfr' : 'standard')
    setSparse(rec?.sparse_attention ?? '')
    setInt8(!!rec?.int8_attention)
    const picks = (rec?.loras ?? []).filter((r) => loraChoices.some((l) => l.id === r.model_id))
    if (picks.length) {
      setLoraPicks((list) => [
        ...list.filter((p) => !models.find((m) => m.id === p.model_id)?.features?.turbo
          && !picks.some((r) => r.model_id === p.model_id)),
        ...picks,
      ])
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- nur beim Wechsel des Modells
  }, [recFor])
  useEffect(() => {
    if (videoSizes.some((s) => s.label === vidSize.label)) return
    const [w, h] = vfeat?.recommended?.size ?? [0, 0]
    setVidSize(videoSizes.find((s) => s.w === w && s.h === h) ?? videoSizes[0])
  }, [videoSizes, vidSize.label])
  // „Das Format folgt dem Startbild“ (Konzept, Weg „Mit Startbild“; CLAUDE.md: Seitenverhältnis des Startbilds treffen):
  // Wird ein Startbild gewählt, stellt sich das Format auf das nächste passende Seitenverhältnis, bei gleich gutem auf
  // die Größe nahe der bisherigen. Einmal je Startbild; ein danach selbst gewähltes Format bleibt.
  const videoSizesRef = useRef(videoSizes)
  videoSizesRef.current = videoSizes
  const startAspectFor = useRef('')
  useEffect(() => {
    if (!wayStart || !sourceId || startAspectFor.current === sourceId) return
    const url = sourceImages.find((a) => a.id === sourceId)?.url
    if (!url) return
    let alive = true
    const img = new Image()
    img.onload = () => {
      if (!alive || !img.naturalWidth || !img.naturalHeight) return
      startAspectFor.current = sourceId
      const aspect = img.naturalWidth / img.naturalHeight
      setVidSize((cur) => (aspectDiffers(cur, aspect) ? closestSize(videoSizesRef.current, aspect, cur) ?? cur : cur))
    }
    img.src = url
    return () => {
      alive = false
    }
  }, [wayStart, sourceId, sourceImages])
  useEffect(() => {
    if (isLtx25) api.assets('audio', 30).then(setAudioAssets).catch(() => setAudioAssets([]))
    if (isLtx25) api.assets('video', 30).then(setVideoAssets).catch(() => setVideoAssets([]))
    if (isLtx25) {
      api.assets('upload', 60)
        .then((up) => setLayoutUploads(up.filter((a) => /\.(mp4|mov|mkv|webm|avi)$/i.test(a.filename))))
        .catch(() => setLayoutUploads([]))
    }
  }, [isLtx25, results])
  // Aufnahmen, aus denen sich eine Stimme übernehmen lässt: Ton (auch eigene Sprecherzeilen), Videos mit Ton, Uploads
  useEffect(() => {
    if (mode !== 'speech') return
    Promise.all([api.assets('audio', 60), api.assets('video', 30), api.assets('upload', 60)])
      .then(([aud, vid, up]) => setVoiceRefs([...aud, ...vid,
        ...up.filter((a) => /\.(wav|mp3|flac|ogg|m4a|aac|opus|mp4|mov|mkv|webm)$/i.test(a.filename))]))
      .catch(() => setVoiceRefs([]))
  }, [mode, results])
  // Fehlt eine optionale Datei (eigene Freigabe auf Hugging Face), nennt der Weg sie mit „Zusätze laden“ (extrasLine)
  const setLoraStrength = (id: string, strength: number) =>
    setLoraPicks((list) => list.map((p) => (p.model_id === id ? { ...p, strength } : p)))

  // Was das gewählte Bildmodell kann (registry.features_for). Fehlt ein Eintrag, gilt
  // das alte Verhalten: alles anbieten.
  const feat = mode === 'image' ? selected?.features : undefined
  // Bildmodelle melden es über features.negative_prompt, destillierte Videomodelle (Kandinsky 6) ebenso
  const negWorks = (feat ?? vfeat)?.negative_prompt !== false
  const canImg2img = feat?.img2img !== false
  const canHires = feat?.hires !== false
  // Erweitern geht über Masken (Qwen) oder über ein Referenzbild (FLUX 3 und andere
  // Bearbeitungsmodelle; dort deutlich nahtloser). Stil-Referenzen (Krea 2) bearbeiten nichts.
  const styleRefs = feat?.reference_kind === 'style'
  const outpaintByRef = (feat?.references ?? 0) > 0 && feat?.outpaint === 'reference'
  const canOutpaint = (canImg2img && feat?.mask !== false) || outpaintByRef
  const outpainting = mode === 'image' && useSource && canOutpaint && outpaintOn
    && pad.left + pad.top + pad.right + pad.bottom > 0
  const maxRefs = (mode === 'image' ? feat?.references : vfeat?.references) ?? 0
  // MiniMax H3 Referenz: Referenzbilder statt Startbild, mindestens eins (im Prompt <Picture 1> …); seit dem Konzept
  // „NVAI im Fluss“ der Weg „Mit Referenzbildern“ (videoWays)
  const videoRefs = mode === 'video' ? refIds.slice(0, maxRefs) : []
  // Nimmt das neue Modell weniger Referenzen, gilt seine Grenze auch in der Auswahl (sonst „5 von 4“, und der Auftrag
  // scheiterte mit „höchstens 4 Referenzbilder“)
  useEffect(() => {
    if (maxRefs > 0) setRefIds((list) => (list.length > maxRefs ? list.slice(0, maxRefs) : list))
  }, [maxRefs])
  /** Die gewählten Referenzen, die es noch gibt (anderswo gelöschte fallen aus der Auswahl), höchstens so viele, wie
   *  das Modell nimmt; auch solche, die nicht mehr unter den neuesten Bildern stehen */
  const liveRefs = async (): Promise<string[]> => {
    const ids = refIds.slice(0, maxRefs)
    const ok = await Promise.all(ids.map((id) => api.asset(id).then(() => true, () => false)))
    const gone = ids.filter((_, i) => !ok[i])
    if (gone.length) setRefIds((list) => list.filter((id) => !gone.includes(id)))
    return ids.filter((_, i) => ok[i])
  }
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
        text: feat.reference_kind === 'style'
          ? t(`bis ${feat.references} Stil-Referenzen`, `up to ${feat.references} style references`)
          : t(`bis ${feat.references} Referenzbilder`, `up to ${feat.references} reference images`),
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
  // Lizenzhinweis ohne harte Grenze (etwa FLUX Kommunity): steht im Klappmenü „Modell-Infos“
  const infoWarning = selected && !selected.license_badge
    && (mode === 'image' || (mode === 'video' && selected.commercial_ok === false))
    ? selected.warning ?? '' : ''

  // Ein modelleigenes Format gilt nach dem Wechsel nicht mehr -- zurück auf die Vorwahl des neuen Modells, sonst das
  // erste. Läuft nach dem Vorwahl-Effekt oben und darf ihn nicht überschreiben (FLUX 3 1440² -> Qwen stand sonst auf 832 × 1216).
  useEffect(() => {
    if (sizes.some((s) => s.label === imgSize.label)) return
    const [w, h] = feat?.recommended?.size ?? [0, 0]
    setImgSize(sizes.find((s) => s.w === w && s.h === h) ?? sizes[0])
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
        // War das ausgewählte Bild dabei, rückt das nächste nach (unter Video keins: dort nichts vorauswählen).
        if (sourceId === asset.id) {
          const next = mode === 'video' ? '' : rest[0]?.id ?? ''
          sourceAuto.current = !!next
          setSourceId(next)
        }
        return rest
      })
      setRefIds((list) => list.filter((id) => id !== asset.id))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const clearSources = async () => {
    setConfirmClearSources(false)
    setError(null)
    try {
      // Nur Bilder und Uploads des allgemeinen Verlaufs: Meshes und alles in Projektordnern (Studio) bleiben.
      const gone = sourceImages.filter((a) => !a.folder)
      // Was als Clip im Studio-Schnitt liegt, lehnt der Server ab (409): das bleibt, der Rest geht
      const done = await Promise.allSettled(gone.map((a) => api.deleteAsset(a.id)))
      const deleted = new Set(gone.filter((_, i) => done[i].status === 'fulfilled').map((a) => a.id))
      const rest = sourceImages.filter((a) => !deleted.has(a.id))
      setSourceImages(rest)
      setSourceId((cur) => (rest.some((a) => a.id === cur) ? cur : ''))
      setRefIds((list) => list.filter((id) => !deleted.has(id)))
      const kept = gone.length - deleted.size
      if (kept) {
        setError(t(`${kept} Bild(er) liegen als Clip im Studio-Schnitt und bleiben.`,
          `${kept} image(s) are clips in a Studio edit and stay.`))
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  const upload = async (file: File) => {
    setError(null)
    try {
      const asset = await api.upload(file)
      setSourceImages((s) => [asset, ...s])
      pickSource(asset.id)
      // Bei FLUX 3 und der Referenz-Fassung von MiniMax ist ein hochgeladenes Bild fast immer als Referenz gemeint.
      if ((mode === 'image' || mode === 'video') && maxRefs > 0) {
        setRefIds((r) => (r.length < maxRefs ? [...r, asset.id] : r))
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Foto für „Person aus einem Foto“ unter Bild: nur im Abschnitt auswählen, nicht als Quell- oder Referenzbild
  const uploadPerson = async (file: File) => {
    setError(null)
    try {
      const asset = await api.upload(file)
      setSourceImages((s) => [asset, ...s])
      setPersonPhotoId(asset.id)
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

  // Schärfen beim Restaurieren: SeedVR2 (Art "upscale"), die für die Karte empfohlene Fassung zuerst.
  const upscalers = models.filter((m) => m.kind === 'upscale' && m.runnable)
  const upscaler = upscalers.find((m) => m.recommended) ?? upscalers[0]
  const seedvr2 = models.find((m) => m.kind === 'upscale' && m.recommended) ?? models.find((m) => m.kind === 'upscale')
  const restoreEdits = restoreRepair || restoreColorize
  const restoreReady = !!sourceId && (restoreEdits ? available.length > 0 : restoreSharpen && !!upscaler)
  // Hat der Video-Weg, was er braucht (Startbild, Endbild, Layout-Video, Video zum Verlängern, Referenzbilder)?
  const wayReady = mode !== 'video' ? true
    : way === 'refs' ? videoRefs.length > 0
      : way === 'start' || way === 'loop' ? !!sourceId
        : way === 'ends' ? !!endId
          : way === 'layout' ? !!guideId && !!vfeat?.layout
            : way === 'extend' ? !!extendId
              : true
  const canGenerate =
    mode === 'speech'
      ? !!prompt.trim() && (voiceMode === 'design' || !!voiceAsset)
      : mode === 'restore'
      ? restoreReady
      : mode === '3d'
      ? !!sourceId
      : mode === 'video'
        ? !!prompt.trim() && wayReady
        : mode === 'image' && outpainting
          ? !!sourceId
          : mode === 'image' && useSource && (canImg2img || outpainting)
          ? !!prompt.trim() && !!sourceId
          : mode === 'image' && cnId
            ? !!prompt.trim() && !!cnImageId
            : !!prompt.trim()
  // Warum „Generieren“ gesperrt ist (oder nicht erweitert), wenn es sonst nirgends zu sehen ist, etwa bei zugeklappter
  // Feineinstellung
  const blockedHint = busy ? null
    : mode === 'image' && cnId && !cnImageId
      ? t('ControlNet ist an, aber ohne Vorlage: unter „Feineinstellung“ eine wählen oder das ControlNet ausschalten.',
        'ControlNet is on but has no template: choose one under “Advanced settings” or switch it off.')
      : mode === 'image' && useSource && canOutpaint && outpaintOn && !outpainting
        ? t('Zum Erweitern erst einen Rand angeben, etwa „↔ breiter“.', 'To extend, set a border first, for example “↔ wider”.')
        : mode === 'restore' && !restoreEdits && !(restoreSharpen && upscaler)
          ? t('Mindestens einen Schritt wählen.', 'Choose at least one step.')
          : mode === 'video' && !wayReady
            ? (way === 'refs' ? t('Für diesen Weg fehlt noch: mindestens ein Referenzbild.', 'This path still needs: at least one reference image.')
              : way === 'ends' ? t('Für diesen Weg fehlt noch: das Endbild.', 'This path still needs: the end image.')
                : way === 'layout' ? (vfeat?.layout
                  ? t('Für diesen Weg fehlt noch: das Layout-Video.', 'This path still needs: the layout video.')
                  : t('Für Layout-Videos fehlt noch die Layout-To-Render-LoRA (oben bei „Weg“).',
                    'Layout videos still need the Layout-To-Render LoRA (see “Path” above).'))
                  : way === 'extend' ? t('Für diesen Weg fehlt noch: das Video zum Verlängern.', 'This path still needs: the video to extend.')
                    : t('Für diesen Weg fehlt noch: das Startbild.', 'This path still needs: the start image.'))
            : null

  // Prompt ausbauen geht mit jedem Modell, braucht aber die Upsampler-Datei von FLUX 3.
  const canExpand = models.some((m) => m.files.some((f) => f.installed && f.file.includes('upsampler')))
  const expandTarget: ExpandTarget =
    mode === 'image' ? 'image'
      : mode === '3d' ? '3d'
        : mode === 'audio' ? (selected?.family === 'stable_audio3' ? 'music_sa3' : 'sfx')
          : effMultishot ? 'video_multishot'
            : effStart ? 'video_start'
              : selected?.family === 'ltx25' || selected?.family === 'ltx23' ? 'video_sound' : 'video'

  const expandPrompt = async () => {
    if (expanding || busy || !prompt.trim()) return
    setExpanding(true)
    setError(null)
    try {
      const refs = expandTarget === 'image' && maxRefs > 0 ? await liveRefs()
        : expandTarget === 'video_start' ? [effStart] : []
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
  // Der Auftrag „Quellbild erzeugen“ (auch für seine Zeit am Knopf)
  const meshImagePlan = (): Plan => ({
    kind: 'txt2img',
    params: {
      // Ein für 3D ausgebauter Prompt enthält die Angaben schon.
      prompt: promptBefore !== null ? prompt : `${prompt.trim().replace(/[ .,]+$/, '')}. ${MESH_SUFFIX}`,
      negative_prompt: imageModel?.features?.negative_prompt === false ? '' : MESH_NEGATIVE,
      model_id: imageModel?.id ?? null,
      steps: null, seed: seed ? Number(seed) : null,
      width: 1024, height: 1024, batch_size: 1,
    },
  })
  const meshImage = async () => {
    if (busy || !prompt.trim()) return
    setError(null)
    try {
      const job = await sendPlan(meshImagePlan())
      startJob(job, { mode: '3d', title: t('Quellbild erzeugen', 'Create source image'), model: imageModel, est: meshEst })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Person aus einem Foto: ein Bildmodell mit Referenzbildern nimmt das Foto als Vorlage, behält das Gesicht und
  // erzeugt vier Startbilder im Videoformat (kleine Formate größer, siehe personSize). Gemessen 24.10. mit FLUX 3:
  // ~95 s für vier Bilder bei 1280 × 704, 242–247 s bei 1920 × 1088 (mit zwei Referenzen); das Gesicht trifft es
  // besser, wenn das Foto nur Kopf und Schultern zeigt (dafür „Zuschneiden“). Stilvorlagen (Krea 2) halten kein Gesicht.
  const personModels = models
    .filter((m) => m.kind === 'image' && m.runnable && (m.features?.references ?? 0) > 0
      && m.features?.reference_kind !== 'style')
    .sort((a, b) => Number(b.recommended) - Number(a.recommended) || Number(b.family === 'flux3') - Number(a.family === 'flux3'))
  const personModel = personModels.find((m) => m.id === personModelId) ?? personModels[0]
  const choosePersonModel = (id: string) => {
    setPersonModelId(id)
    try {
      localStorage.setItem('nvai-person-model', id)
    } catch {
      /* privates Fenster */
    }
  }
  // Weitere geeignete Modelle, die noch fehlen: je Familie eines, als Hinweis auf „Modelle“
  const morePersonModels = [...new Map(models
    .filter((m) => m.kind === 'image' && !m.installed && (m.features?.references ?? 0) > 0
      && m.features?.reference_kind !== 'style' && !personModels.some((p) => p.family === m.family))
    .map((m) => [m.family, m.name.replace(/\s*\(.*\)\s*$/, '')])).values()]
  // Zielformat: unter Video das Videoformat, unter Bild das gewählte Bildformat
  const personTarget = mode === 'image' ? imgSize : vidSize
  const personWork = personSize(personTarget.w, personTarget.h)
  const personMinutes = personModel?.family === 'flux3'
    ? (personWork.w * personWork.h > 1_500_000 ? 4 : 1.5)
    : personModel?.family === 'qwenimageedit' ? (personWork.w * personWork.h > 1_500_000 ? 5 : 2.5) : null
  // Das Gesicht kommt aus dem Startbild (unter Bild aus dem Foto des Abschnitts); ist das ein Ergebnis dieser Funktion,
  // aus dessen Vorlage (bis zum Foto zurück). asset=null: Das Foto ist inzwischen gelöscht.
  const personSrc = mode === 'image' ? personPhotoId : sourceId
  useEffect(() => {
    let alive = true
    const find = async (id: string) => sourceImages.find((a) => a.id === id) ?? await api.asset(id).catch(() => null)
    ;(async () => {
      if (!personSrc) {
        setFacePhoto(null)
        return
      }
      let id = personSrc
      let a = await find(id)
      for (let i = 0; i < 20 && isPersonResult(a); i++) {
        const ref = a?.meta?.reference_asset_ids?.[0]
        if (typeof ref !== 'string' || !ref) break
        id = ref
        a = await find(ref)
      }
      if (alive) setFacePhoto({ id, asset: a ?? null })
    })()
    return () => {
      alive = false
    }
  }, [personSrc, sourceImages])
  // Der Auftrag „Vier Bilder“ bzw. „Vier Startbilder“ (auch für seine Zeit am Knopf)
  const personPlan = (): Plan | null => {
    if (!personModel) return null
    const role = roleText.trim().replace(/[ .]+$/, '')
    // Unter Video ein Filmstandbild mit Luft über dem Kopf (die Kamera bewegt sich noch), unter Bild bestimmt die
    // Rolle den Stil; halbnah in beiden, damit das Gesicht genug Pixel hat
    const tail = `, with exactly the same face, eyes, nose, mouth and hair color: ${role}. `
      + 'Medium shot from the waist up, the face clearly visible'
    return {
      kind: 'txt2img',
      params: {
        prompt: mode === 'video' ? `${PERSON_HEAD}${tail}, free space above the head.` : `${PERSON_IMAGE_HEAD}${tail}.`,
        negative_prompt: '', model_id: personModel.id, steps: null, seed: seed ? Number(seed) : null,
        width: personWork.w, height: personWork.h, batch_size: 4,
        reference_asset_ids: [facePhoto?.id ?? personSrc ?? 'ref'],
        project_id: projectId || null,
      },
    }
  }
  const personImages = async () => {
    if (busy || !roleText.trim() || !facePhoto?.asset || !personModel) return
    setError(null)
    const p = personPlan()
    if (!p) return
    try {
      const job = await sendPlan(p)
      startJob(job, {
        mode,
        title: mode === 'video' ? t('Vier Startbilder erzeugen', 'Create four start images') : t('Vier Bilder erzeugen', 'Create four images'),
        model: personModel, est: personEst,
      })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }

  // Abschnitt „Person aus einem Foto“: unter Video bei den Startbildern (Foto = gewähltes Startbild, vier Startbilder im
  // Videoformat), seit 23.11.2026 auch unter Bild (Nutzer: „baue die szene aus dem foto auch unter fotos ein, es ist
  // zwar redundant aber stört nicht“) mit eigener Fotoauswahl und vier Bildern im gewählten Format. Modell, Zuschneiden
  // und die Regel „Vorlage immer das Foto“ sind dieselben.
  const personSection = () => {
    const forVideo = mode === 'video'
    return (
      <>
        <details className="mesh-from-text" open={!!roleText.trim()}>
          <summary>{t('Person aus einem Foto (optional)', 'Person from a photo (optional)')}</summary>
          <p className="hint small">
            {forVideo ? t('Das Foto oben als Startbild wählen oder hochladen und hier auf Kopf und Schultern '
              + 'zuschneiden. Dann beschreiben, wer die Person sein soll: Stil, Kleidung, Ort. Das Modell behält '
              + 'das Gesicht und erzeugt vier Startbilder im Videoformat. Die vier in voller Größe vergleichen '
              + '(anklicken), das ähnlichste oben auswählen, dann unten Bewegung und Gesprochenes beschreiben.',
            'Pick or upload the photo as the start image above and crop it to head and shoulders here. Then '
              + 'describe who the person should be: style, clothing, place. The model keeps the face and creates '
              + 'four start images in the video format. Compare the four at full size (click them), pick the '
              + 'most similar one above, then describe the motion and what is said below.')
            : t('Das Foto hier wählen oder hochladen und auf Kopf und Schultern zuschneiden. Dann beschreiben, '
              + 'wer die Person sein soll und wo: Stil, Kleidung, Ort. Das Modell behält das Gesicht und erzeugt '
              + 'vier Bilder im gewählten Format, halbnah, damit das Gesicht genug Pixel hat. Die vier in voller '
              + 'Größe vergleichen (anklicken).',
            'Pick or upload the photo here and crop it to head and shoulders. Then describe who the person '
              + 'should be and where: style, clothing, place. The model keeps the face and creates four images in '
              + 'the chosen size, as a medium shot so the face gets enough pixels. Compare the four at full size '
              + '(click them).')}
          </p>
          {!forVideo && (
            <>
              {sourceImages.length > 0 && (
                <div className="source-grid" ref={chainWheel}>
                  {sourceImages.map((a) => (
                    <div key={a.id} className={personPhotoId === a.id ? 'source selected' : 'source'}
                      title={a.prompt || a.filename}>
                      <img src={a.url} alt={a.prompt} loading="lazy"
                        onClick={() => setPersonPhotoId((cur) => (cur === a.id ? '' : a.id))} />
                    </div>
                  ))}
                </div>
              )}
              {moreSourcesButton}
              <button className="btn small ghost full" onClick={() => personFileRef.current?.click()}>
                {t('Foto hochladen', 'Upload photo')}
              </button>
              <input ref={personFileRef} type="file" accept="image/*" style={{ display: 'none' }}
                onChange={(e) => {
                  const f = e.target.files?.[0]
                  e.target.value = ''
                  if (f) uploadPerson(f)
                }} />
            </>
          )}
          {facePhoto && (
            <div className="person-photo">
              {facePhoto.asset
                ? <img src={facePhoto.asset.thumb_url || facePhoto.asset.url} alt="" />
                : <span className="person-photo-gone">?</span>}
              <div>
                <span className="small">{t('Gesicht aus diesem Foto', 'Face from this photo')}</span>
                {!facePhoto.asset ? (
                  <p className="hint small warn">
                    {forVideo
                      ? t('Das Foto zu diesem Startbild ist gelöscht. Oben dein Foto wählen oder neu hochladen.',
                        'The photo behind this start image was deleted. Pick your photo above or upload it again.')
                      : t('Das Foto zu diesem Bild ist gelöscht. Hier dein Foto wählen oder neu hochladen.',
                        'The photo behind this image was deleted. Pick your photo here or upload it again.')}
                  </p>
                ) : facePhoto.id !== personSrc && (
                  <p className="muted small">
                    {/* Je ein ganzer Satz, damit die Sprachpakete (zh, fr) ihn finden */}
                    {forVideo
                      ? t('Neue Versuche nehmen immer dieses Foto, nicht das gewählte Startbild: sonst malt das Modell '
                        + 'jedes Mal das letzte Ergebnis nach, und das Gesicht wird von Runde zu Runde schlechter.',
                      'New attempts always use this photo, not the selected start image: otherwise the model repaints '
                        + 'the last result each time and the face gets worse with every round.')
                      : t('Neue Versuche nehmen immer dieses Foto, nicht das gewählte Ergebnis: sonst malt das Modell '
                        + 'jedes Mal das letzte Ergebnis nach, und das Gesicht wird von Runde zu Runde schlechter.',
                      'New attempts always use this photo, not the selected result: otherwise the model repaints '
                        + 'the last result each time and the face gets worse with every round.')}
                  </p>
                )}
                <button className="btn small ghost" disabled={!facePhoto.asset || busy}
                  onClick={() => setCropOpen(true)}
                  title={t('Ausschnitt mit Kopf und Schultern wählen, mit Beispielkontur',
                    'Choose a head-and-shoulders crop, with an example outline')}>
                  {t('Zuschneiden', 'Crop')}
                </button>
              </div>
            </div>
          )}
          {personModels.length > 0 && (
            <label className="person-model">
              <span className="small">{t('Modell', 'Model')}</span>
              <select value={personModel?.id ?? ''} onChange={(e) => choosePersonModel(e.target.value)}>
                {personModels.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.name}{m.commercial_ok ? '' : t(' – nicht kommerziell', ' – non-commercial')}
                  </option>
                ))}
              </select>
            </label>
          )}
          {personModel && (
            <p className="hint small">
              {personModel.family === 'flux3'
                ? t('FLUX 3 hielt im Test vom 24.10. das Gesicht. Lizenz: kommerziell nur unter 5 Mio. US-$ '
                  + 'Umsatz, jedes Bild vor dem Veröffentlichen prüfen.',
                'FLUX 3 kept the face in the test of 24 Oct. License: commercial use only below US$5M '
                  + 'revenue, review every image before publishing.')
                : personModel.family === 'qwenimageedit'
                  ? t('Qwen-Image-Edit-2511 (Apache-2.0, ohne Umsatzgrenze): Im Test vom 23.11. waren die '
                    + 'Augen sauber, das Gesicht aber weniger getroffen als mit FLUX 3, eher eine ähnliche Person. '
                    + 'Gut für Figuren; für echte Personen FLUX 3.',
                  'Qwen-Image-Edit-2511 (Apache-2.0, no revenue limit): in the test of 23 Nov the eyes were clean, '
                    + 'but the face was matched less well than with FLUX 3, more of a similar-looking person. Good for '
                    + 'characters; for real people use FLUX 3.')
                  : t(`${personModel.name}: mit echten Gesichtern hier nicht gemessen.`,
                    `${personModel.name}: not measured here with real faces.`)}
              {personWork.w !== personTarget.w && (forVideo
                ? t(` Gerechnet in ${personWork.w} × ${personWork.h}, damit das Gesicht genug Pixel hat; das Video `
                  + 'zieht es auf sein Format.',
                ` Rendered at ${personWork.w} × ${personWork.h} so the face gets enough pixels; the video scales it `
                  + 'to its format.')
                : t(` Gerechnet in ${personWork.w} × ${personWork.h}, damit das Gesicht genug Pixel hat.`,
                  ` Rendered at ${personWork.w} × ${personWork.h} so the face gets enough pixels.`))}
            </p>
          )}
          {morePersonModels.length > 0 && (
            <p className="muted small">
              {t(`Weitere mit Referenzbildern unter „Modelle“: ${morePersonModels.join(', ')}.`,
                `More with reference images under “Models”: ${morePersonModels.join(', ')}.`)}
            </p>
          )}
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
            disabled={busy || !roleText.trim() || !facePhoto?.asset || !personModel}
            title={!personModel
              ? t('Braucht ein Bildmodell mit Referenzbildern', 'Needs an image model with reference images')
              : !facePhoto?.asset
                ? (forVideo ? t('Erst oben das Foto als Startbild wählen', 'First pick the photo as the start image above')
                  : t('Erst hier ein Foto wählen oder hochladen', 'First pick or upload a photo here'))
                : personMinutes
                  ? t(`Vier Bilder mit ${personModel.name} in ${personWork.w} × ${personWork.h}, rund `
                    + `${String(personMinutes).replace('.', ',')} Minuten`,
                  `Four images with ${personModel.name} at ${personWork.w} × ${personWork.h}, about ${personMinutes} minutes`)
                  : t(`Vier Bilder mit ${personModel.name} in ${personWork.w} × ${personWork.h}`,
                    `Four images with ${personModel.name} at ${personWork.w} × ${personWork.h}`)}
          >
            {forVideo ? t('Vier Startbilder erzeugen', 'Create four start images')
              : t('Vier Bilder erzeugen', 'Create four images')}
            {/* Ehrliche Zeit auch hier (Konzept „NVAI im Fluss“) */}
            {personEst && <span className="flow-eta">{fmtEta(totalSeconds(personEst))}</span>}
          </button>
          {!personModel && (
            <p className="hint small warn">
              {t('Braucht ein Bildmodell mit Referenzbildern, z. B. FLUX 3 Image Klein:',
                'Needs an image model with reference images, e.g. FLUX 3 Image Klein:')}{' '}
              <button className="link-btn" onClick={onShowModels}>{t('unter „Modelle“ laden', 'download it under “Models”')}</button>
            </p>
          )}
        </details>
        {cropOpen && facePhoto?.asset && (
          <PhotoCrop url={facePhoto.asset.url}
            name={String(facePhoto.asset.meta?.original_name || facePhoto.asset.filename)}
            onDone={async (file) => {
              // Der Zuschnitt wird das neue Foto: unter Video als Startbild, unter Bild im Abschnitt
              await (forVideo ? upload(file) : uploadPerson(file))
              setCropOpen(false)
            }}
            onClose={() => setCropOpen(false)} />
        )}
      </>
    )
  }

  // Der Hinweis zum Prompt steht im leeren Feld selbst, nicht als Absatz darunter. Videomodelle mit eigenem Hinweis
  // (LTX-2.5, MiniMax H3) zeigen ihren statt des allgemeinen.
  const promptHint = mode === 'image' ? feat?.prompt_hint || '' : vfeat?.prompt_hint || HINT[mode]
  const placeholder = [promptHint, `${t('z. B.', 'e.g.')} ${feat?.placeholder
    || vfeat?.placeholder || PLACEHOLDER[mode]}`]
    .filter(Boolean).join('\n\n')

  // Sprecherstimme: Text, Stimme (beschreiben oder aus einer Aufnahme), Sprache. Eine eigene Aufnahme kommt über
  // „Hochladen“ dazu und steht dann gleich in der Liste.
  const pickVoice = (id: string) => {
    setVoiceAsset(id)
    const ref = voiceRefs.find((a) => a.id === id)
    // Eine eigene Sprecherzeile kennt ihren Text: dann wortgenau übernehmen
    if (ref?.meta?.speech && typeof ref.meta.text === 'string') setVoiceText(ref.meta.text)
  }
  const speechControls = () => (
    <>
      <h3>{t('Text', 'Text')}</h3>
      <textarea
        ref={promptRef}
        value={prompt}
        onChange={(e) => setPrompt(e.target.value)}
        placeholder={`${t('z. B.', 'e.g.')} ${PLACEHOLDER.speech}`}
        rows={5}
        maxLength={1500}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) generate()
        }}
      />
      <p className="hint small">{HINT.speech} {prompt.length > 1200 ? `(${prompt.length}/1500)` : ''}</p>

      <h3>{t('Stimme', 'Voice')}</h3>
      <div className="voice-mode">
        <label>
          <input type="radio" checked={voiceMode === 'design'} onChange={() => setVoiceMode('design')} />
          {t('beschreiben', 'describe')}
        </label>
        <label>
          <input type="radio" checked={voiceMode === 'clone'} onChange={() => setVoiceMode('clone')} />
          {t('aus einer Aufnahme', 'from a recording')}
        </label>
      </div>
      {voiceMode === 'design' ? (
        <>
          <textarea
            value={voiceDesc}
            onChange={(e) => setVoiceDesc(e.target.value)}
            rows={3}
            maxLength={600}
            placeholder={t('z. B. eine ruhige, tiefe Männerstimme, etwa fünfzig, warm und leicht rau',
              'e.g. a calm, deep male voice, about fifty, warm and slightly rough')}
          />
          <p className="hint small">
            {t('Geschlecht, Alter, Tonlage, Tempo und Stimmung in einem Satz; leer wählt das Modell selbst. Jeder Seed '
              + 'klingt etwas anders: Für dieselbe Stimme in weiteren Sätzen eine gelungene Aufnahme unter „aus einer '
              + 'Aufnahme“ als Vorlage wählen.',
              'Gender, age, pitch, pace and mood in one sentence; empty lets the model choose. Every seed sounds a '
              + 'little different: for the same voice in further sentences, choose a good recording under “from a '
              + 'recording” as the reference.')}
          </p>
        </>
      ) : (
        <>
          <div className="voice-ref">
            <select value={voiceAsset} onChange={(e) => pickVoice(e.target.value)}>
              <option value="">{t('Aufnahme wählen …', 'Choose a recording …')}</option>
              {voiceRefs.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.kind === 'video' ? '▶ ' : '♪ '}
                  {(a.prompt || String(a.meta?.original_name || '') || a.filename).slice(0, 60)}
                  {a.meta?.seconds ? ` (${a.meta.seconds} s)` : ''}
                </option>
              ))}
            </select>
            <button className="btn small" onClick={() => voiceFileRef.current?.click()} disabled={busy}>
              {t('Hochladen …', 'Upload …')}
            </button>
            <input ref={voiceFileRef} type="file" accept="audio/*,video/*" hidden onChange={async (e) => {
              const f = e.target.files?.[0]
              e.target.value = ''
              if (!f) return
              try {
                const a = await api.upload(f)
                setVoiceRefs((list) => [a, ...list])
                setVoiceAsset(a.id)
              } catch (err) {
                setError(String(err))
              }
            }} />
          </div>
          <textarea
            value={voiceText}
            onChange={(e) => setVoiceText(e.target.value)}
            rows={2}
            maxLength={2000}
            placeholder={t('Was in der Aufnahme gesagt wird, wortgenau (optional)',
              'What is said in the recording, word for word (optional)')}
          />
          <p className="hint small">
            {t('Genutzt werden die ersten 20 s, drei Sekunden reichen. Mit dem Text übernimmt das Modell auch '
              + 'Sprechweise und Betonung, ohne ihn nur den Stimmklang. Nur Aufnahmen, deren Sprecher zugestimmt haben.',
              'The first 20 s are used, three seconds are enough. With the text the model also takes over the way of '
              + 'speaking, without it only the sound of the voice. Only recordings whose speakers agreed.')}
          </p>
        </>
      )}

      <h3>{t('Sprache', 'Language')}</h3>
      <select value={speechLang} onChange={(e) => setSpeechLang(e.target.value as SpeechLanguage)}>
        {SPEECH_LANGUAGES.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
      </select>
    </>
  )

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
      {!canExpand && !expanding && promptBefore === null && (
        <button className="link-btn small" onClick={onShowModels}>{t('unter „Modelle“ laden', 'download it under “Models”')}</button>
      )}
    </div>
  )

  // 3D: Nur TRELLIS.2 liefert Texturen. Fehlt es, steht das gut sichtbar oben, mit Download.
  const trellis = models.find((m) => m.kind === '3d' && m.workflow === 'trellis2')
  const trellisDl = trellis ? downloads.active[trellis.id] : undefined
  const [dlError, setDlError] = useState<string | null>(null)

  const textureNotice = () => {
    // Auf AMD läuft 3D nicht (TripoSG und TRELLIS.2 brauchen CUDA-Erweiterungen, das Setup lässt es weg):
    // dann keine Werbung für 16 GB TRELLIS.2, sondern ein kurzer Hinweis.
    if (health?.gpus?.some((g) => g.vendor === 'amd') && !health.gpus.some((g) => g.vendor === 'nvidia')) {
      return (
        <div className="texture-note important">
          <p>
            <strong>{t('3D braucht derzeit eine NVIDIA-Karte.', '3D currently needs an NVIDIA card.')}</strong>{' '}
            {t('TripoSG und TRELLIS.2 nutzen CUDA-Erweiterungen, auf AMD Radeon laufen sie nicht.',
              'TripoSG and TRELLIS.2 use CUDA extensions; they do not run on AMD Radeon.')}
          </p>
        </div>
      )
    }
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

  // Mesh-Auftrag für ein Bild mit den Einstellungen unter „Mesh“ und „Freistellen“ (großer Knopf und „◈ 3D-Modell“)
  const meshParams = (m: ModelInfo | undefined, imageId: string): Mesh3DParams => {
    const textured = m?.workflow === 'trellis2'
    return {
      image_asset_id: imageId,
      model_id: m?.id ?? (modelId['3d'] || null),
      steps: steps ? Number(steps) : 50,
      seed: seed ? Number(seed) : null,
      faces: faces ? Number(faces) : textured ? 100000 : -1,
      remove_background: bgMode !== 'alpha',
      background_mode: bgMode,
      project_front: projectFront,
      ...(textured ? { resolution: 512, texture_size: textureSize, clean_specks: cleanSpecks } : {}),
    }
  }

  /** Der Auftrag des großen Knopfs mit genau den Parametern, die abgeschickt werden; dieselben gehen in die Schätzung.
   *  refs: beim Abschicken die noch vorhandenen Referenzbilder, für die Schätzung die gewählten. */
  const plan = (refs: string[]): Plan => {
    const common = {
      // Bild erweitern ohne eigenen Prompt (Nutzer 22.11.2026): ein neutraler Satz; FLUX 3 beschreibt das Vorlagenbild
      // dazu selbst (Upsampler), die Maskenmodelle bekommen wenigstens Stil, Licht und Perspektive vorgegeben
      prompt: mode === 'image' && outpainting && !prompt.trim() ? EXTEND_PROMPT : prompt,
      negative_prompt: negative,
      model_id: modelId[mode] || null,
      steps: steps ? Number(steps) : null,
      seed: seed ? Number(seed) : null,
      project_id: projectId || null,
    }
    if (mode === 'image') {
      return {
        kind: 'txt2img',
        params: {
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
          reference_asset_ids: !outpainting ? refs : [],
          upsample_prompt: feat?.upsampler ? upsample : null,
          controlnet_model_id: cnId || null,
          controlnet_image_asset_id: cnId ? cnImageId || null : null,
          controlnet_strength: cnStrength,
          controlnet_end: cnEnd,
          controlnet_preprocess: cnPre,
          loras: activeLoras,
        },
      }
    }
    if (mode === 'restore') {
      return {
        kind: 'restore',
        params: {
          image_asset_id: sourceId,
          repair: restoreRepair,
          repair_mode: restoreMode,
          colorize: restoreColorize,
          sharpen: restoreSharpen && !!upscaler,
          scale: restoreScale,
          notes: restoreNotes,
          batch_size: Math.min(4, batch),
          model_id: restoreEdits ? modelId.restore || null : null,
          upscale_model_id: restoreSharpen && upscaler ? upscaler.id : null,
          seed: seed ? Number(seed) : null,
          project_id: projectId || null,
        },
      }
    }
    if (mode === 'speech') {
      return {
        kind: 'tts',
        params: {
          text: prompt,
          voice: voiceMode === 'design' ? voiceDesc : '',
          voice_asset_id: voiceMode === 'clone' ? voiceAsset || null : null,
          voice_text: voiceMode === 'clone' ? voiceText : '',
          language: speechLang,
          model_id: common.model_id, seed: common.seed, project_id: common.project_id,
        },
      }
    }
    if (mode === 'audio') return { kind: 'txt2audio', params: { ...common, seconds } }
    if (mode === 'video') {
      return {
        kind: 'txt2video',
        params: {
          ...common, width: vidSize.w, height: vidSize.h,
          frames: isLtx25 ? ltxFrames : frames, fps: isLtx25 ? ltxFps : fps,
          // Nur, was zum Weg gehört (Konzept, Bildschirm B); der Rest bleibt eingestellt, wirkt aber nicht
          image_asset_id: effStart || null,
          reference_asset_ids: way === 'refs' ? refs : [],
          loras: activeLoras,
          sparse_attention: sparse && vfeat?.sparse_attention?.includes(sparse) ? sparse : null,
          int8_attention: vfeat?.int8_attention ? int8 : null,
          // Alles steht ausdrücklich da (die Empfehlung ist oben vorgewählt), der Server ergänzt nichts
          recommended: false,
          master,
          ...(vfeat?.audio_prompt ? { audio_prompt: audioPrompt } : {}),
          ...(isLtx25 ? {
            loop: effLoop,
            end_image_asset_id: effEnd || null,
            quality: effQuality,
            temporal_upscale: effTemporal,
            auto_duration: effAuto,
            audio_asset_id: effAudio || null,
            motion_speed: effMotion,
            extend_asset_id: effExtend || null,
            guide_asset_id: effGuide || null,
          } : {}),
        },
      }
    }
    return { kind: 'img23d', params: meshParams(selected, sourceId) }
  }

  // Was der große Knopf tut, in Worten (Konzept „NVAI im Fluss“: „Ein Knopf nennt Aktion und Zeit“)
  const actionLabel = mode === 'image'
    ? (outpainting ? t('Bild erweitern', 'Extend image')
      : useSource && canImg2img && sourceId ? t('Bild überarbeiten', 'Rework image')
        : batch > 1 ? t(`${batch} Bilder erzeugen`, `Create ${batch} images`) : t('Bild erzeugen', 'Create image'))
    : mode === 'video' ? (way === 'extend' ? t('Video verlängern', 'Extend video') : t('Video erzeugen', 'Create video'))
      : mode === 'audio' ? (selected?.family === 'stable_audio3' ? t('Musik erzeugen', 'Create music') : t('Ton erzeugen', 'Create sound'))
        : mode === 'speech' ? t('Text sprechen', 'Speak the text')
          : mode === '3d' ? t('Mesh erzeugen', 'Create mesh')
            : t('Foto restaurieren', 'Restore photo')

  // ---------------------------------------------- Fehlendes Modell an Ort und Stelle (Konzept „NVAI im Fluss“)
  // Ein noch nicht geladenes Modell lässt sich in der Modellwahl vormerken; geladen wird erst nach dem Klick auf „Laden“
  // (ModelNeed), danach ist es gewählt. Ohne geladenes Modell der Art steht das empfohlene da. Vorher stand „Kein
  // Bild-Modell installiert“ unter dem Knopf außer Sicht und führte nirgends hin.
  const [want, setWant] = useState<Partial<Record<Mode, string>>>({})
  // Auf Radeon allein läuft 3D nicht (CUDA-Erweiterungen): dann kein Laden anbieten, textureNotice sagt es
  const amdOnly = !!health?.gpus?.some((g) => g.vendor === 'amd') && !health?.gpus?.some((g) => g.vendor === 'nvidia')
  const missing = useMemo(() => (mode === '3d' && amdOnly ? [] : missingChoices(models, mode)), [models, mode, amdOnly])
  const wantModel = want[mode] ? models.find((m) => m.id === want[mode] && !available.some((a) => a.id === m.id)) : undefined
  const need = mode === 'restore' && !restoreEdits ? undefined : wantModel ?? (noModel ? missing[0] : undefined)
  // Das empfohlene Modell fehlt, gewählt ist eins außerhalb der empfohlenen Familien (etwa Wan statt LTX-2.5): ModelNeed
  // bietet es an, ohne das Erzeugen zu sperren; „Lieber … (geladen)“ blendet den Hinweis für diesen Reiter aus (gemerkt)
  const [recDismissed, setRecDismissed] = useState<Partial<Record<Mode, boolean>>>(() => {
    try {
      return JSON.parse(localStorage.getItem('nvai-generate-rec-ok') || '{}') as Partial<Record<Mode, boolean>>
    } catch {
      return {}
    }
  })
  const recMissing = !need && selected && !recDismissed[mode] && !MODE_FAMILIES[mode].includes(selected.family)
    && !(mode === '3d' && amdOnly) && (mode !== 'restore' || restoreEdits)
    ? pickMissing(models, (m) => fitsMode(m, mode as GenMode), MODE_FAMILIES[mode].slice(0, 1)) : undefined
  // Hier geladen: danach gleich dieses Modell wählen
  const recLoading = useRef<Partial<Record<Mode, string>>>({})
  useEffect(() => {
    if (recMissing && downloads.active[recMissing.id]) recLoading.current[mode] = recMissing.id
  }, [recMissing, downloads.active, mode])
  useEffect(() => {
    const id = recLoading.current[mode]
    if (id && available.some((m) => m.id === id)) {
      recLoading.current[mode] = undefined
      setModelId((cur) => ({ ...cur, [mode]: id }))
    }
  }, [available, mode])
  const dismissRec = () => {
    const next = { ...recDismissed, [mode]: true }
    setRecDismissed(next)
    try {
      localStorage.setItem('nvai-generate-rec-ok', JSON.stringify(next))
    } catch {
      /* privates Fenster: nur diese Sitzung */
    }
  }
  useEffect(() => {
    const id = want[mode]
    if (id && available.some((m) => m.id === id)) {
      setModelId((cur) => ({ ...cur, [mode]: id }))
      setWant((w) => ({ ...w, [mode]: undefined }))
    }
  }, [available, mode, want])
  const chooseModel = (id: string) => {
    if (!id) return
    if (available.some((m) => m.id === id)) {
      setModelId((cur) => ({ ...cur, [mode]: id }))
      setWant((w) => ({ ...w, [mode]: undefined }))
    } else {
      setWant((w) => ({ ...w, [mode]: id }))
    }
  }
  const NEED_WHY: Record<Mode, string> = {
    image: t('für Bilder', 'for images'),
    video: t('für Video mit Ton', 'for video with sound'),
    audio: t('für Musik und Geräusche', 'for music and sound effects'),
    speech: t('für die Sprecherstimme', 'for the narrator voice'),
    '3d': t('für 3D aus Bildern', 'for 3D from images'),
    restore: t('zum Restaurieren', 'for restoring'),
  }
  /** Chip mit Zustand: „LTX-2.5 · bereit“, „· lädt 42 %“, „· fehlt“ */
  const modelChip = (m: ModelInfo | undefined, isMissing: boolean, key = 'model') => {
    if (!m) return null
    const dl = downloads.active[m.id]
    const worker = mode === '3d' && !isMissing && m.workflow ? health?.mesh_workers?.[m.workflow] : undefined
    const [cls, text] = dl
      ? ['info', dl.status === 'queued' ? t(`${shortName(m)} · wartet auf den Download`, `${shortName(m)} · waiting to download`)
        : t(`${shortName(m)} · lädt ${Math.round(dl.progress * 100)} %`, `${shortName(m)} · downloading ${Math.round(dl.progress * 100)} %`)]
      : isMissing ? ['warn', t(`${shortName(m)} · fehlt`, `${shortName(m)} · missing`)]
        : worker && !worker.ready ? ['warn', t(`${shortName(m)} · nicht eingerichtet`, `${shortName(m)} · not set up`)]
          : ['ok', t(`${shortName(m)} · bereit`, `${shortName(m)} · ready`)]
    return <span key={key} className={`flow-chip ${cls}`} title={m.name}>{text}</span>
  }

  // ---------------------------------------------- Zeit am Knopf (Konzept „NVAI im Fluss“: „Ehrliche Zeit“)
  const mainPlan = plan(mode === 'image' ? refIds.slice(0, maxRefs) : mode === 'video' && way === 'refs' ? videoRefs : [])
  // Video: dieselbe Einstellung mit der anderen Qualität, für „Standard · DFR ≈ 13 min“
  const altPlan: Plan | null = mainPlan.kind === 'txt2video' && dfrWay && dfrReady
    ? { kind: 'txt2video', params: { ...mainPlan.params, quality: effQuality === 'dfr' ? 'standard' : 'dfr', temporal_upscale: false } }
    : null
  const meshPlanNow = mode === '3d' && imageModel ? meshImagePlan() : null
  const personPlanNow = mode === 'image' || wayStart ? personPlan() : null
  const estItems = [estimateItem(mainPlan), estimateItem(altPlan), estimateItem(meshPlanNow), estimateItem(personPlanNow)]
  const ests = useEstimates(estItems, JSON.stringify(estItems))
  // Eine Antwort für ein anderes Modell (die Anfrage zum neuen Reiter läuft noch) zeigt keine falsche Zeit
  const fitEst = (e: Estimate | undefined, p: Plan | null): Estimate | null => {
    if (!e || !p) return null
    const wanted = (p.params as { model_id?: string | null }).model_id
    return wanted && e.model_id && e.model_id !== wanted ? null : e
  }
  const mainEst = fitEst(ests?.[0], mainPlan)
  const altEst = fitEst(ests?.[1], altPlan)
  const meshEst = fitEst(ests?.[2], meshPlanNow)
  const personEst = fitEst(ests?.[3], personPlanNow)

  const generate = async () => {
    if (busy || !canGenerate || need || sending.current) return
    sending.current = true
    setError(null)
    try {
      // Referenzen auch dann, wenn sie nicht mehr unter den neuesten Bildern stehen; gelöschte fallen weg
      const refs = maxRefs > 0 && (mode === 'image' || (mode === 'video' && way === 'refs')) ? await liveRefs() : []
      const job = await sendPlan(plan(refs))
      startJob(job, {
        mode, title: actionLabel, model: mode === 'restore' && !restoreEdits ? upscaler : selected, est: mainEst,
      })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      sending.current = false
    }
  }

  // ---------------------------------------------- Willkommen und Auftragsleiste
  // Willkommen-Bildschirm: mit diesem Reiter anfangen
  useEffect(() => {
    if (preset) setMode(preset.mode)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- nur bei einem neuen Klick
  }, [preset?.n])
  // Auftragsleiste „Zeigen“ (Bildschirm F): diesen Auftrag samt Ergebnis zeigen, den Reiter passend umschalten; läuft er
  // noch, stehen rechts seine Phasen
  useEffect(() => {
    if (!focus) return
    let alive = true
    const id = focus.jobId
    api.job(id).then((j) => {
      if (!alive) return
      trackJob(j)
      const m = MODE_OF_KIND[j.kind] as Mode | undefined
      if (m) setMode(m)
      viewRef.current = j.id
      setViewId(j.id)
      setViewJob(j)
      setNextNeed(null)
      setStudioNote(null)
      if (j.id !== jobRef.current) {
        const known = models.find((x) => x.id === j.params?.model_id)
        const label = MODES.find((x) => x.id === m)?.label ?? t('Auftrag', 'Job')
        setRun({
          id: j.id, title: known ? `${label} · ${shortName(known)}` : label,
          modelName: known ? shortName(known) : undefined, modelGb: known?.vram_gb || undefined, expected: null,
          next: NEXT_TEXT[m ?? 'image'],
        })
      }
      if (j.status === 'done') {
        api.jobAssets(j.id).then((assets) => { if (alive) showResults(j.id, assets) }).catch(() => {})
      } else {
        loadedFor.current = null
        setResults([])
        setPickedId(null)
        setError(j.status === 'error' ? j.error ?? t('Fehler', 'Error') : null)
        setReveal((n) => n + 1)
      }
    }).catch((e) => { if (alive) setError(e instanceof Error ? e.message : String(e)) })
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- nur bei einem neuen Klick
  }, [focus?.n])

  // ---------------------------------------------- Nächste Schritte unter dem Ergebnis (Konzept, Bildschirm C)
  const picked = results.find((a) => a.id === pickedId) ?? results[0]
  // Größe des gewählten Ergebnisses (für „ins Videoformat“ und das passende Format); ohne Angabe aus dem Bild selbst
  const [pickedDims, setPickedDims] = useState<{ id: string; w: number; h: number } | null>(null)
  useEffect(() => {
    if (!picked || (picked.kind !== 'image' && picked.kind !== 'video')) return
    const w = Number(picked.meta?.width)
    const h = Number(picked.meta?.height)
    if (w > 0 && h > 0) {
      setPickedDims({ id: picked.id, w, h })
      return
    }
    if (picked.kind !== 'image') return
    let alive = true
    const img = new Image()
    img.onload = () => { if (alive) setPickedDims({ id: picked.id, w: img.naturalWidth, h: img.naturalHeight }) }
    img.src = picked.url
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- je Ergebnis einmal
  }, [picked?.id])
  const dims = picked && pickedDims?.id === picked.id ? pickedDims : null
  // Originalfoto über die Herkunft des Ergebnisses (Person aus einem Foto, Startbild, Standbild) für „☺ Gesicht
  // nachrechnen“: je Ergebnis einmal gefragt
  const [lineagePhoto, setLineagePhoto] = useState<{ id: string; photo: string | null } | null>(null)
  useEffect(() => {
    if (!picked || (picked.kind !== 'image' && picked.kind !== 'video')) return
    let alive = true
    api.facePhoto(picked.id).then((r) => { if (alive) setLineagePhoto({ id: picked.id, photo: r.photo }) }).catch(() => {})
    return () => {
      alive = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- je Ergebnis einmal
  }, [picked?.id])
  // Ein fertig geladenes Modell für einen Schritt: Der Hinweis darunter erledigt sich
  useEffect(() => {
    if (nextNeed && models.some((m) => m.id === nextNeed.model.id && m.runnable)) setNextNeed(null)
  }, [models, nextNeed])

  /** Format, Länge und Qualität, mit denen der Reiter Video für dieses Modell rechnen würde: die Vorwahl des Modells,
   *  solange sie noch nicht gesetzt ist, sonst die eigene Einstellung */
  const videoSetupFor = (m: ModelInfo) => {
    const f = m.features ?? {}
    const sizes = f.sizes?.length ? f.sizes : VIDEO_SIZES
    const applied = presetFor.current.video === m.id
    const rec = f.recommended ?? {}
    const rs = rec.size
    const recSize = rs ? sizes.find((s) => s.w === rs[0] && s.h === rs[1]) : undefined
    const size = (applied && sizes.some((s) => s.label === vidSize.label) ? vidSize : recSize) ?? sizes[0]
    const ltx = m.family === 'ltx25'
    const secs = applied ? ltxSeconds : rec.seconds ?? ltxSeconds
    const wantDfr = qualityTouched.current ? quality === 'dfr' : (rec.quality ?? 'dfr') === 'dfr'
    return {
      size, sizes, ltx,
      quality: (ltx && f.dfr && wantDfr ? 'dfr' : 'standard') as 'standard' | 'dfr',
      fps: ltx ? ltxFps : f.fps ?? fps,
      frames: ltx ? ltxFramesFor(secs, ltxFps, f.max_seconds ?? 20) : f.default_frames ?? frames,
    }
  }
  const addSource = (a: Asset) => setSourceImages((list) => (list.some((x) => x.id === a.id) ? list : [a, ...list]))
  const curVideoModel = models.find((m) => m.id === modelId.video && m.runnable && m.usable !== false)
  const takesStart = (m: ModelInfo) => m.kind === 'video' && !!startImageUse(m)
  // ▶ Video daraus: das gewählte Videomodell, wenn es ein Startbild nimmt, sonst LTX-2.5
  const startModel = curVideoModel && startImageUse(curVideoModel) ? curVideoModel : pickRunnable(models, takesStart, ['ltx25'])
  const startNeed = startModel ? undefined : pickMissing(models, takesStart, ['ltx25'])
  const startTarget = startModel ?? startNeed
  const videoFromPlan: Plan | null = picked?.kind === 'image' && startTarget ? (() => {
    const s = videoSetupFor(startTarget)
    const size = dims && aspectDiffers(s.size, dims.w / dims.h) ? closestSize(s.sizes, dims.w / dims.h, s.size) ?? s.size : s.size
    return {
      kind: 'txt2video' as const,
      params: {
        prompt: '', model_id: startTarget.id, width: size.w, height: size.h, frames: s.frames, fps: s.fps,
        image_asset_id: picked.id, recommended: false, ...(s.ltx ? { quality: s.quality } : {}),
      },
    }
  })() : null
  // ◈ 3D-Modell: das gewählte 3D-Modell, sonst TripoSG; auf Radeon gibt es kein 3D
  const meshOnly = (m: ModelInfo) => m.kind === '3d'
  const meshNext = models.find((m) => m.id === modelId['3d'] && m.runnable && m.usable !== false)
    ?? pickRunnable(models, meshOnly, ['triposg', 'trellis2'])
  const meshNeed = meshNext ? undefined : pickMissing(models, meshOnly, ['triposg', 'trellis2'])
  const meshNextPlan: Plan | null = picked?.kind === 'image' && !amdOnly && (meshNext ?? meshNeed)
    ? { kind: 'img23d', params: meshParams(meshNext ?? meshNeed, picked.id) } : null
  // ⤢ Erweitern ins Videoformat: per Referenz (FLUX 3), nahtloser als über eine Maske
  const outByRef = (m: ModelInfo) => m.kind === 'image' && m.features?.outpaint === 'reference' && (m.features?.references ?? 0) > 0
  const outModel = pickRunnable(models, outByRef, ['flux3'])
  const outNeed = outModel ? undefined : pickMissing(models, outByRef, ['flux3'])
  const outMask = outModel ? undefined : pickRunnable(models, (m) => m.kind === 'image' && m.features?.img2img !== false
    && m.features?.mask !== false, ['qwenimage'])
  const outSize = startTarget ? videoSetupFor(startTarget).size : vidSize
  const outPad = picked?.kind === 'image' && dims ? padToAspect(dims.w, dims.h, outSize.w / outSize.h) : null
  const outPlanFor = (m: ModelInfo | undefined): Plan | null => (outPad && dims && picked ? {
    kind: 'txt2img',
    params: {
      prompt: EXTEND_PROMPT, negative_prompt: '', model_id: m?.id ?? null, steps: null, seed: null, batch_size: 1,
      width: Math.round((dims.w + outPad[0] + outPad[2]) / 16) * 16,
      height: Math.round((dims.h + outPad[1] + outPad[3]) / 16) * 16,
      image_asset_id: picked.id, denoise: 1.0, outpaint: [...outPad], reference_asset_ids: [],
      upsample_prompt: m?.features?.upsampler ? true : null, project_id: projectId || null,
    },
  } : null)
  const outPlan = outPlanFor(outModel ?? outNeed)
  // ⟳ Varianten: derselbe Auftrag noch einmal, neuer Seed (Bilder und Fotos zu viert)
  const variantPlan: Plan | null = viewJob?.status === 'done' && results.length > 0 ? rerunPlan(viewJob, 4) : null
  // ✎ Überarbeiten: Bearbeiten mit diesem Bild als Referenz (FLUX 3), im Format des Bildes
  const editByRef = (m: ModelInfo) => m.kind === 'image' && (m.features?.references ?? 0) > 0 && m.features?.reference_kind !== 'style'
  const editModel = pickRunnable(models, editByRef, ['flux3'])
  const editNeed = editModel ? undefined : pickMissing(models, editByRef, ['flux3'])
  const editImg2img = editModel ? undefined : pickRunnable(models, (m) => m.kind === 'image' && m.features?.img2img !== false, ['qwenimage'])
  const editSizeFor = (m: ModelInfo) => {
    const list = [...IMAGE_SIZES, ...(m.features?.sizes ?? [])]
    const rs = m.features?.recommended?.size
    const near = rs ? { w: rs[0], h: rs[1] } : imgSize
    return (dims ? closestSize(list, dims.w / dims.h, near) : undefined)
      ?? list.find((s) => s.w === near.w && s.h === near.h) ?? list[0]
  }
  const editTarget = editModel ?? editNeed
  const editPlan: Plan | null = picked?.kind === 'image' && editTarget ? {
    kind: 'txt2img',
    params: {
      prompt: '', model_id: editTarget.id, width: editSizeFor(editTarget).w, height: editSizeFor(editTarget).h,
      batch_size: 1, reference_asset_ids: [picked.id],
    },
  } : null
  // Video: ⇥ Verlängern (LTX-2.5) und ⤡ Hochskalieren (RelayVSR, Eingang bis 1920 × 1088)
  const ltxOnly = (m: ModelInfo) => m.kind === 'video' && m.family === 'ltx25'
  const ltxNext = (curVideoModel?.family === 'ltx25' ? curVideoModel : undefined) ?? pickRunnable(models, ltxOnly, ['ltx25'])
  const ltxNeed = ltxNext ? undefined : pickMissing(models, ltxOnly, ['ltx25'])
  const extendPlan: Plan | null = picked?.kind === 'video' && (ltxNext ?? ltxNeed) ? (() => {
    const m = (ltxNext ?? ltxNeed)!
    const s = videoSetupFor(m)
    const w = Number(picked.meta?.width) || s.size.w
    const h = Number(picked.meta?.height) || s.size.h
    // Ein 48-fps-Video lässt sich nur mit DFR und 48 fps fortsetzen (jobs._prepare_extension)
    const fast = Number(picked.meta?.fps) > 30
    return {
      kind: 'txt2video' as const,
      params: {
        prompt: '', model_id: m.id, width: Math.max(256, Math.floor(w / 64) * 64), height: Math.max(256, Math.floor(h / 64) * 64),
        frames: s.frames, fps: 24, extend_asset_id: picked.id, quality: fast ? 'dfr' as const : s.quality,
        temporal_upscale: fast, recommended: false,
      },
    }
  })() : null
  const vupOnly = (m: ModelInfo) => m.kind === 'video_upscale'
  const vupModel = pickRunnable(models, vupOnly)
  const vupNeed = vupModel ? undefined
    : models.find((m) => vupOnly(m) && !m.installed && m.recommended && m.usable !== false)
      ?? models.find((m) => vupOnly(m) && !m.installed && m.usable !== false)
  const vw = Number(picked?.meta?.width) || 0
  const vh = Number(picked?.meta?.height) || 0
  const upscalable = picked?.kind === 'video' && vw > 0 && Math.max(vw, vh) <= 1920 && Math.min(vw, vh) <= 1088
  const upscalePlan: Plan | null = upscalable && picked && (vupModel ?? vupNeed)
    ? { kind: 'video_upscale', params: { asset_id: picked.id, model_id: (vupModel ?? vupNeed)!.id, project_id: projectId || null } }
    : null
  // ⇧ Final: derselbe Auftrag im Finalformat, gleicher Seed (erst Entwurf, dann Final; Nutzer 27.11.2026)
  const finalModel = picked?.kind === 'video' ? models.find((m) => m.id === picked.model_id) : undefined
  const final = viewJob?.status === 'done' && picked?.kind === 'video'
    ? finalPlan(viewJob, picked, finalModel, health?.gpu?.vram_total_mb ?? 0) : null
  // ☺ Gesicht nachrechnen (Nutzer 28.11.2026): Bild oder Video mit Person, das Gesicht neu aus dem Originalfoto
  // (Referenz des Auftrags, sonst das Foto unter „Person aus einem Foto“)
  // Vorrang hat die Herkunft des Ergebnisses (der Server folgt Startbild und Standbild bis zum Foto), dann die
  // Referenzen des Auftrags (außer Stilvorlagen; das Gesicht steht zuletzt), dann das Foto unter „Person aus einem Foto“
  const jobModel = models.find((m) => m.id === viewJob?.params?.model_id)
  const jobRefs = jobModel?.features?.reference_kind === 'style'
    ? [] : (viewJob?.params?.reference_asset_ids ?? []) as string[]
  const fromLineage = picked && lineagePhoto?.id === picked.id ? lineagePhoto.photo : null
  const faceRef = fromLineage || jobRefs[jobRefs.length - 1] || personPhotoId || ''
  const faceRefName = sourceImages.find((a) => a.id === faceRef)?.filename.split('/').pop()
  const facePlan: Plan | null = picked && (picked.kind === 'image' || picked.kind === 'video') && faceRef && faceRef !== picked.id
    ? { kind: 'face_fix', params: { asset_id: picked.id, reference_asset_id: faceRef, project_id: projectId || null } }
    : null
  const nextPlans = [videoFromPlan, meshNextPlan, outPlan, variantPlan, editPlan, extendPlan, upscalePlan,
    final?.plan ?? null, facePlan]
  const nextItems = results.length ? nextPlans.map(estimateItem) : null
  const nextEsts = useEstimates(nextItems, JSON.stringify(nextItems))
  const nextEta = (i: number) => fmtEta(totalSeconds(fitEst(nextEsts?.[i], nextPlans[i])))
  const nextTitle = (i: number) => sourceText(fitEst(nextEsts?.[i], nextPlans[i]))

  // Ins Studio: das gewählte Zielprojekt, sonst das zuletzt bearbeitete, sonst ein neues
  const studioTarget = projects.find((p) => p.id === projectId) ?? [...projects].sort((a, b) => b.updated_at - a.updated_at)[0]
  const toStudio = async (a: Asset) => {
    if (studioBusy) return
    setStudioBusy(true)
    setError(null)
    setStudioNote(null)
    try {
      let pid = studioTarget?.id
      let name = studioTarget?.name ?? ''
      if (!pid) {
        const p = await api.studioCreate(sceneTitle(a) || t('Neues Projekt', 'New project'))
        pid = p.id
        name = p.name
        refreshProjects()
      }
      const title = sceneTitle(a)
      const secs = Number(a.meta?.duration_s ?? a.meta?.seconds) || undefined
      const family = models.find((m) => m.id === a.model_id)?.family
      const taken = { takes: [a.id], take: a.id, ...(secs ? { duration_s: secs } : {}) }
      // Ein Bild wird das Startbild einer Videoszene (die Bewegung beschreibt man dort); Video, Ton und Stimme kommen als
      // Take und gleich in den Schnitt
      const add: Record<string, unknown> = a.kind === 'image'
        ? { lane: 'video', kind: 'video', title, prompt: '', params: { image_asset_id: a.id } }
        : a.kind === 'video'
          ? { lane: 'video', kind: 'video', title, prompt: a.prompt, model_id: a.model_id || null, ...taken }
          : a.meta?.speech
            ? { lane: 'voice', title, prompt: String(a.meta?.text ?? a.prompt), model_id: a.model_id || null, ...taken,
              params: { voice: String(a.meta?.voice ?? ''), language: String(a.meta?.language ?? 'auto') } }
            : { lane: family === 'stable_audio3' ? 'music' : 'sfx', kind: 'audio', title, prompt: a.prompt,
              model_id: a.model_id || null, ...taken }
      const r = await api.studioCommand(pid, 'scene.add', add)
      const sceneId: string | null = r.result?.id ?? null
      if (sceneId && a.kind !== 'image') await api.studioCommand(pid, 'edit.conform', { scenes: [sceneId] }).catch(() => null)
      setStudioNote(a.kind === 'image'
        ? t(`Als Szene mit diesem Startbild im Studio-Projekt „${name}“; dort die Bewegung beschreiben.`,
          `Added as a scene with this start image to the Studio project “${name}”; describe the motion there.`)
        : t(`Als Szene im Studio-Projekt „${name}“ und im Schnitt.`, `Added as a scene to the Studio project “${name}” and to the edit.`))
      onOpenStudio?.(pid, sceneId)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setStudioBusy(false)
    }
  }

  /** Schritt mit fehlendem Modell: ModelNeed darunter zeigen, statt etwas zu starten (geladen wird erst nach „Laden“) */
  const needOr = (step: string, model: ModelInfo | undefined, missingModel: ModelInfo | undefined, run: () => void,
    alternative?: ModelInfo, alt?: () => void) => () => {
    if (!model && missingModel) {
      setNextNeed({ step, model: missingModel, alternative, alt })
      return
    }
    setNextNeed(null)
    run()
  }
  /** Ein Schritt, der gleich rechnet: abschicken und rechts mit Phasen zeigen */
  const runNext = async (p: Plan | null, m: Mode, title: string, model: ModelInfo | undefined, i: number) => {
    if (!p || busy || sending.current) return
    sending.current = true
    setError(null)
    try {
      const job = await sendPlan(p)
      startJob(job, { mode: m, title, model, est: fitEst(nextEsts?.[i], p) })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      sending.current = false
    }
  }

  const nextSteps: NextStep[] = []
  // Unter 3D (Quellbild aus Text) ist das Mesh der naheliegende Schritt, sonst das Video
  const meshFirst = mode === '3d'
  if (picked && !viewActive) {
    if (picked.kind === 'image' && startTarget) {
      nextSteps.push({
        key: 'video', icon: '▶', label: t('Video daraus', 'Video from it'), primary: !meshFirst,
        small: [t('Startbild', 'start image'), shortName(startTarget) + (startModel ? '' : t(' fehlt', ' missing')), nextEta(0)]
          .filter(Boolean).join(', '),
        title: nextTitle(0),
        onClick: needOr('video', startModel, startNeed, () => {
          const m = startModel!
          addSource(picked)
          setMode('video')
          setModelId((c) => ({ ...c, video: m.id }))
          setWay('start')
          setSlotOpen(null)
          pickSource(picked.id)
          setFocusPrompt((n) => n + 1)
        }),
      })
    }
    // Für restaurierte Fotos gibt es kein 3D (ein Mesh braucht ein freigestelltes Objekt)
    if (meshNextPlan && viewJob?.kind !== 'restore') {
      const m = meshNext ?? meshNeed!
      nextSteps.push({
        key: '3d', icon: '◈', label: t('3D-Modell', '3D model'), primary: meshFirst,
        small: [shortName(m) + (meshNext ? '' : t(' fehlt', ' missing')), nextEta(1)].filter(Boolean).join(', '),
        title: nextTitle(1), disabled: busy,
        onClick: needOr('3d', meshNext, meshNeed, () => {
          addSource(picked)
          setMode('3d')
          setModelId((c) => ({ ...c, '3d': m.id }))
          pickSource(picked.id)
          runNext(meshNextPlan, '3d', t('Mesh erzeugen', 'Create mesh'), m, 1)
        }),
      })
    }
    if (outPlan && outPad && dims) {
      const m = outModel ?? outNeed
      const run = (use: ModelInfo) => {
        const p = outPlanFor(use)
        addSource(picked)
        setMode('image')
        setModelId((c) => ({ ...c, image: use.id }))
        setUseSource(true)
        setOutpaintOn(true)
        pickSource(picked.id)
        setPad({ left: outPad[0], top: outPad[1], right: outPad[2], bottom: outPad[3] })
        runNext(p, 'image', t('Bild erweitern', 'Extend image'), use, 2)
      }
      if (m) {
        nextSteps.push({
          key: 'outpaint', icon: '⤢', label: t('Erweitern', 'Extend'),
          small: [shortName(m) + (outModel ? '' : t(' fehlt', ' missing')),
            t(`ins Videoformat ${outSize.w} × ${outSize.h}`, `to the video format ${outSize.w} × ${outSize.h}`), nextEta(2)]
            .filter(Boolean).join(', '),
          title: nextTitle(2), disabled: busy,
          onClick: needOr('outpaint', outModel, outNeed, () => run(outModel!), outMask, outMask ? () => run(outMask) : undefined),
        })
      }
    }
    if (variantPlan && viewJob) {
      const four = variantPlan.kind === 'txt2img' || variantPlan.kind === 'restore'
      const vm = (MODE_OF_KIND[viewJob.kind] ?? mode) as Mode
      nextSteps.push({
        key: 'variants', icon: '⟳', label: four ? t('4 Varianten', '4 variants') : t('Noch eine Variante', 'One more variant'),
        small: [variantPlan.kind === 'tts' ? t('gleicher Text, neuer Seed', 'same text, new seed')
          : variantPlan.kind === 'restore' ? t('gleiches Foto, neuer Seed', 'same photo, new seed')
            : t('gleicher Prompt', 'same prompt'), nextEta(3)].filter(Boolean).join(', '),
        title: nextTitle(3), disabled: busy,
        onClick: () => {
          setNextNeed(null)
          if (vm !== mode) setMode(vm)
          const known = models.find((x) => x.id === (variantPlan.params as { model_id?: string | null }).model_id)
          runNext(variantPlan, vm, four ? t('4 Varianten', '4 variants') : t('Noch eine Variante', 'One more variant'), known, 3)
        },
      })
    }
    if (picked.kind === 'image' && editTarget) {
      const run = (use: ModelInfo) => {
        addSource(picked)
        setMode('image')
        setModelId((c) => ({ ...c, image: use.id }))
        // Format wie das Bild, sonst schnitte das Bearbeiten es neu zu; die Vorwahl des Modells gilt damit als gesetzt
        presetFor.current.image = use.id
        setImgSize(editSizeFor(use))
        setUseSource(false)
        setOutpaintOn(false)
        setRefIds([picked.id])
        setFocusPrompt((n) => n + 1)
      }
      // Ohne Bearbeitungsmodell: „Vorhandenes Bild überarbeiten“ mit dem geladenen Bildmodell
      const viaImg2img = editImg2img ? () => {
        const use = editImg2img
        addSource(picked)
        setMode('image')
        setModelId((c) => ({ ...c, image: use.id }))
        setOutpaintOn(false)
        setUseSource(true)
        pickSource(picked.id)
        setFocusPrompt((n) => n + 1)
      } : undefined
      nextSteps.push({
        key: 'edit', icon: '✎', label: t('Überarbeiten', 'Rework'),
        small: [t('mit Referenz', 'with reference'), shortName(editTarget) + (editModel ? '' : t(' fehlt', ' missing'))].join(', '),
        title: nextTitle(4),
        onClick: needOr('edit', editModel, editNeed, () => run(editModel!), editImg2img, viaImg2img),
      })
    }
    if (extendPlan) {
      const m = ltxNext ?? ltxNeed!
      nextSteps.push({
        key: 'extend', icon: '⇥', label: t('Verlängern', 'Extend'), primary: true,
        small: [shortName(m) + (ltxNext ? '' : t(' fehlt', ' missing')), t('die letzte Sekunde trägt über', 'the last second carries over'),
          nextEta(5)].filter(Boolean).join(', '),
        title: nextTitle(5),
        onClick: needOr('extend', ltxNext, ltxNeed, () => {
          setVideoAssets((list) => (list.some((x) => x.id === picked.id) ? list : [picked, ...list]))
          setMode('video')
          setModelId((c) => ({ ...c, video: m.id }))
          setWay('extend')
          setSlotOpen(null)
          setExtendId(picked.id)
          // 48 fps fortsetzen geht nur mit DFR und 48 fps: gleich so einstellen
          if (Number(picked.meta?.fps) > 30) {
            chooseQuality('dfr')
            setTemporal(true)
          }
          setFocusPrompt((n) => n + 1)
        }),
      })
    }
    if (final) {
      const fp = final.plan.params as { width?: number; height?: number }
      nextSteps.push({
        key: 'final', icon: '⇧', label: t('Final rechnen', 'Render final'), primary: true,
        small: [`${fp.width} × ${fp.height}`, t('gleicher Seed', 'same seed'),
          final.capped ? t(`${(final.capped / 24).toFixed(1)} s (mehr ist auf dieser Karte nicht gemessen)`,
            `${(final.capped / 24).toFixed(1)} s (more is not measured on this card)`) : '',
          nextEta(7)].filter(Boolean).join(', '),
        title: t('Erst schnell als Entwurf prüfen, dann den besten Take final rechnen. Kleine Gesichter brauchen das '
          + 'Finalformat: in 768p fehlten die Pupillen schon im ersten Bild. Das Ergebnis ist ähnlich, nicht bildgleich.',
        'Check quickly as a draft first, then render the best take as final. Small faces need the final size: at 768p '
          + 'the pupils were missing from the first frame. The result is similar, not identical.'),
        disabled: busy,
        onClick: () => runNext(final.plan, 'video', t('Final rechnen', 'Render final'), finalModel, 7),
      })
    }
    // Nur, wenn ein Foto der Person bekannt ist: sonst stünde der Schritt unter jedem Bild ohne Person
    if (facePlan) {
      nextSteps.push({
        key: 'face', icon: '☺', label: t('Gesicht nachrechnen', 'Recompute face'),
        small: faceRefName ? t(`aus ${faceRefName}, neues Ergebnis`, `from ${faceRefName}, a new result`)
          : t('aus dem Originalfoto, neues Ergebnis', 'from the original photo, a new result'),
        title: t('Das Gesicht kommt neu aus dem Originalfoto (FLUX 3), im Video auf jedes Bild gelegt. Für kleine Gesichter (unter rund 150 px fehlen die Pupillen) und Gesichter, die vom Foto abweichen. Im Video nur für Clips ohne Sprechen: Mund und Lider bewegen sich danach nicht.',
          'The face is redrawn from the original photo (FLUX 3), in a video placed on every frame. For small faces (under about 150 px the pupils go missing) and faces that drift from the photo. In a video only for clips without speech: the mouth and eyelids no longer move afterwards.'),
        disabled: busy,
        onClick: () => runNext(facePlan, picked.kind === 'video' ? 'video' : 'image', t('Gesicht nachrechnen', 'Recompute face'), undefined, 8),
      })
    }
    if (upscalePlan) {
      const m = vupModel ?? vupNeed!
      nextSteps.push({
        key: 'upscale', icon: '⤡', label: t('Hochskalieren', 'Upscale'),
        small: [`${shortName(m)}${vupModel ? '' : t(' fehlt', ' missing')}`, `${vw * 2} × ${vh * 2}`, nextEta(6)].filter(Boolean).join(', '),
        title: nextTitle(6), disabled: busy,
        onClick: needOr('upscale', vupModel, vupNeed, () => runNext(upscalePlan, 'video', t('Video hochskalieren', 'Upscale video'), m, 6)),
      })
    }
    if (picked.kind === 'audio' && picked.meta?.speech) {
      nextSteps.push({
        key: 'voice', icon: '◎', label: t('Als Stimmvorlage', 'As voice template'),
        small: t('gleiche Stimme für den nächsten Satz', 'same voice for the next line'),
        onClick: () => {
          setNextNeed(null)
          setMode('speech')
          setVoiceRefs((list) => (list.some((x) => x.id === picked.id) ? list : [picked, ...list]))
          setVoiceMode('clone')
          setVoiceAsset(picked.id)
          setVoiceText(String(picked.meta?.text ?? picked.prompt ?? ''))
          setFocusPrompt((n) => n + 1)
        },
      })
    }
    if (picked.kind !== 'mesh') {
      nextSteps.push({
        key: 'studio', icon: '➜', label: t('Ins Studio', 'To the Studio'), disabled: studioBusy,
        small: studioTarget ? t(`als Szene in „${studioTarget.name}“`, `as a scene in “${studioTarget.name}”`)
          : t('als Szene in ein neues Projekt', 'as a scene in a new project'),
        onClick: () => {
          setNextNeed(null)
          toStudio(picked)
        },
      })
    }
  }
  const nextHeading = picked?.kind === 'video' ? t('Weiter mit diesem Video', 'Continue with this video')
    : picked?.kind === 'audio' ? (picked.meta?.speech ? t('Weiter mit diesem Satz', 'Continue with this line')
      : t('Weiter mit diesem Ton', 'Continue with this sound'))
      : t('Weiter mit diesem Bild', 'Continue with this image')
  const NEXT_WHY: Record<string, string> = {
    video: t('für ein Video aus diesem Bild', 'for a video from this image'),
    '3d': t('für 3D aus diesem Bild', 'for 3D from this image'),
    outpaint: t('zum Erweitern ins Videoformat', 'to extend to the video format'),
    edit: t('zum Überarbeiten mit Referenz', 'to rework with a reference'),
    extend: t('zum Verlängern', 'to extend'),
    upscale: t('zum Hochskalieren', 'to upscale'),
  }
  // Kopf über dem Ergebnis: „Fertig nach 3:38“, Modell · Größe, Seed genau zum Kopieren (Konzept, Bildschirm C)
  const resultSeeds = [...new Set(results.map((a) => a.meta?.seed).filter((s) => s !== undefined && s !== null).map(String))]
  const resultHead = () => {
    const j = viewJob && viewJob.id === viewId ? viewJob : null
    const secs = j?.finished_at && j.created_at ? j.finished_at - j.created_at : null
    const first = picked ?? results[0]
    const known = first ? models.find((m) => m.id === first.model_id) : undefined
    const modelName = known ? shortName(known) : String(first?.meta?.model_name ?? first?.model_id ?? '').split(' (')[0]
    const w = Number(first?.meta?.width)
    const h = Number(first?.meta?.height)
    const size = w > 0 && h > 0 ? `${w} × ${h}`
      : first?.kind === 'audio' && first.meta?.seconds ? `${dec(Number(first.meta.seconds), 1)} s` : ''
    return (
      <div className="gen-result-head">
        <b>{secs != null ? t(`Fertig nach ${fmtClock(secs)}`, `Done after ${fmtClock(secs)}`) : t('Fertig', 'Done')}</b>
        <span className="muted small">
          {[modelName, size, results.length > 1 ? t(`${results.length} Ergebnisse`, `${results.length} results`) : '']
            .filter(Boolean).join(' · ')}
        </span>
        {resultSeeds.length === 1 && <SeedCopy seed={resultSeeds[0]} />}
      </div>
    )
  }

  // Quellbild-Auswahl. Identisch fuer 3D und Bild-zu-Video -- nur dass Video
  // ohne Startbild auskommen darf, wenn das Modell auch Text-zu-Video kann. Unter Video steht sie im Platz des Wegs
  // (ohne eigene Überschrift) und schließt sich nach der Wahl.
  const sourcePicker = (allowNone: boolean, opts: { heading?: boolean; onPicked?: () => void } = {}) => (
    <>
      {opts.heading !== false && (
        <h3>{mode === 'video' ? t('Startbild', 'Start image') : mode === 'restore' ? t('Foto', 'Photo') : t('Quellbild', 'Source image')}</h3>
      )}
      {sourceImages.length === 0 ? (
        <p className="hint warn">
          {t(
            'Noch keine Bilder da. Erst eines generieren oder hochladen.',
            'No images yet. Generate or upload one first.',
          )}
        </p>
      ) : (
        <>
          <div className="source-grid" ref={chainWheel}>
            {allowNone && (
              <button
                className={sourceId ? 'source none' : 'source none selected'}
                title={t('Ohne Startbild — reines Text-zu-Video', 'No start image — pure text-to-video')}
                onClick={() => pickSource('')}
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
                <img src={a.url} alt={a.prompt} loading="lazy" onClick={() => {
                  pickSource(a.id)
                  opts.onPicked?.()
                }} />
                {/* Bilder in Projektordnern gehören dem Studio (Startbilder, Takes): hier nicht löschbar */}
                {!a.folder && (
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
                )}
              </div>
            ))}
          </div>
          <div className="row-between source-actions">
            <span className="muted small">
              {sourceImages.length === 1 ? t('1 Bild', '1 image')
                : t(`${sourceImages.length} Bilder`, `${sourceImages.length} images`)} {moreSourcesButton}
            </span>
            {confirmClearSources ? (
              <span className="confirm">
                <span className="muted small">
                  {t('Alle Quellbilder des Verlaufs löschen? Bilder in Projektordnern bleiben.',
                    'Delete all source images of the History? Images in project folders stay.')}
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

  // Referenzbilder: FLUX 3 und andere Bearbeitungsmodelle, Stilvorlage bei Krea 2, Figur und Gesicht bei der
  // Referenz-Fassung von MiniMax H3 (Video)
  // Als Klappmenue wie die LoRA-Auswahl, bei Bildern standardmaessig zu (Nutzer 22.11.2026: „reference images sollte
  // als klapp menü standart mässig zugeklappt sein“); beim Referenz-Video sind sie Pflicht und deshalb offen
  const refPicker = () => (
    <details className="lora-picker ref-picker" open={mode === 'video' || undefined}>
      <summary>
        {styleRefs ? t('Stil-Referenz', 'Style reference') : t('Referenzbilder', 'Reference images')}{' '}
        <span className="muted small">
          {t(`— ${refIds.length} von ${maxRefs}`, `— ${refIds.length} of ${maxRefs}`)}
        </span>
      </summary>
      {sourceImages.length === 0 ? (
        <p className="hint small">
          {t(
            'Noch keine Bilder da. Erst eines generieren oder hochladen.',
            'No images yet. Generate or upload one first.',
          )}
        </p>
      ) : (
        <div className="source-grid" ref={chainWheel}>
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
        {mode === 'video'
          ? t(
            'Mindestens eins, bis zu neun: Figur, Gesicht oder Stil. Im Prompt als <Picture 1>, <Picture 2> … in '
              + 'der Reihenfolge der Nummern ansprechen und sagen, was jedes vorgibt („the man from <Picture 1>, with '
              + 'exactly his face“). Die Szene entsteht aus dem Text, ohne Startbild.',
            'At least one, up to nine: a character, a face or a style. Address them in the prompt as <Picture 1>, '
              + '<Picture 2> … in the order of their numbers and say what each one sets (“the man from <Picture 1>, '
              + 'with exactly his face”). The scene comes from the text, without a start image.',
          )
          : styleRefs
          ? t(
            'Optional, ein oder zwei Bilder: Krea übernimmt ihren Stil (Malweise, Farben, Licht), '
              + 'nicht ihren Inhalt. Was zu sehen sein soll, beschreibt der Prompt.',
            'Optional, one or two images: Krea takes over their style (technique, colors, light), '
              + 'not their content. What should be in the picture is up to the prompt.',
          )
          : t(
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
        {moreSourcesButton}
        {refIds.length > 0 && (
          <button className="btn small ghost" onClick={() => setRefIds([])}>
            {t('Auswahl leeren', 'Clear selection')}
          </button>
        )}
      </div>
    </details>
  )

  // Foto restaurieren: Quellfoto, Schritte, Hinweise. Zeiten gemessen auf der RTX 5060 Ti (25.10.2026).
  const restoreControls = () => (
    <>
      {sourcePicker(false)}
      <h3>{t('Schritte', 'Steps')}</h3>
      <div className="restore-steps">
        <label className="check">
          <input type="checkbox" checked={restoreRepair} onChange={(e) => setRestoreRepair(e.target.checked)} />
          {t('Schäden entfernen', 'Remove damage')}{' '}
          <span className="muted small">{t('(Kratzer, Staub, Risse, Flecken)', '(scratches, dust, tears, stains)')}</span>
        </label>
        {restoreRepair && (
          <div className="restore-sub">
            <span className="seg">
              {([
                ['auto', t('Automatisch', 'Automatic')],
                ['thorough', t('Gründlich', 'Thorough')],
                ['gentle', t('Schonend', 'Gentle')],
              ] as const).map(([id, label]) => (
                <button key={id} className={restoreMode === id ? 'on' : ''} onClick={() => setRestoreMode(id)}>
                  {label}
                </button>
              ))}
            </span>
            <span className="muted small">
              {restoreMode === 'auto'
                ? t('das Bildmodell sieht sich das Foto an: Wasserflecken oder Rissnetze → gründlich, sonst schonend (bei 20 von 21 Testfotos die bessere Wahl)',
                  'the image model looks at the photo: water stains or crack networks → thorough, otherwise gentle (the better choice on 20 of 21 test photos)')
                : restoreMode === 'thorough'
                ? t('für flächige Alterung (Wasserflecken, Craquelé, Korn, Ausbleichen): rechnet das ganze Foto neu; Gesichter können sich je Variante leicht ändern',
                  'for overall aging (water stains, crack networks, grain, fading): redraws the whole photo; faces may change slightly from variant to variant')
                : t('für einzelne Schäden auf einem sonst guten Foto (Staub, Kratzer, Streifen, Risse, Lichteinfall): ersetzt nur diese Stellen, Schärfe und Gesichter bleiben original',
                  'for separate damage on an otherwise good photo (dust, scratches, stripes, tears, light leaks): replaces only those spots, sharpness and faces stay original')}
            </span>
          </div>
        )}
        <label className="check">
          <input type="checkbox" checked={restoreColorize} onChange={(e) => setRestoreColorize(e.target.checked)} />
          {t('Einfärben', 'Colorize')}{' '}
          <span className="muted small">
            {t('(Farbe von FLUX 3, Helligkeit und Gesichter vom Foto)', '(color from FLUX 3, brightness and faces from the photo)')}
          </span>
        </label>
        <label className="check" title={upscaler ? '' : t('Braucht SeedVR2', 'Needs SeedVR2')}>
          <input type="checkbox" checked={restoreSharpen && !!upscaler} disabled={!upscaler}
            onChange={(e) => setRestoreSharpen(e.target.checked)} />
          {t('Schärfen und vergrößern', 'Sharpen and enlarge')}{' '}
          <span className="muted small">(SeedVR2)</span>
        </label>
        {restoreSharpen && upscaler && (
          <div className="restore-sub">
            <span className="seg">
              {[1, 2, 4].map((f) => (
                <button key={f} className={restoreScale === f ? 'on' : ''} onClick={() => setRestoreScale(f)}>{f}×</button>
              ))}
            </span>
            <span className="muted small">
              {restoreScale === 1 ? t('gleiche Größe, nur schärfen', 'same size, sharpen only')
                : t(`${restoreScale}× so groß, höchstens 16 Megapixel`, `${restoreScale}× the size, at most 16 megapixels`)}
            </span>
          </div>
        )}
        {!upscaler && seedvr2 && (
          <div className="restore-sub">
            <button className="btn small" onClick={() => downloads.start(seedvr2.id).catch((e) => setError(String(e)))}>
              {t(`⬇ SeedVR2 laden (${seedvr2.size_gb} GB) zum Schärfen`, `⬇ Download SeedVR2 (${seedvr2.size_gb} GB) for sharpening`)}
            </button>
          </div>
        )}
      </div>
      <h3>
        {t('Hinweise', 'Hints')} <span className="muted small">{t('optional, am besten englisch', 'optional')}</span>
      </h3>
      <textarea
        value={restoreNotes}
        onChange={(e) => setRestoreNotes(e.target.value)}
        rows={3}
        placeholder={t('z. B. „her dress is dark red with white dots, the car is pale turquoise“',
          'e.g. “her dress is dark red with white dots, the car is pale turquoise”')}
      />
      <p className="hint small">
        {t('Bekannte Farben treffen genauer: Bei einem Foto mit bekannten Farben sank die Farbabweichung damit um 40 %. '
          + 'Dauer je Variante: Schäden rund 35–75 s, Einfärben rund 40 s, Schärfen 6–20 s.',
        'Known colors come out more accurately: on a photo with known colors the color error fell by 40 %. '
          + 'Time per variant: damage about 35–75 s, colorizing about 40 s, sharpening 6–20 s.')}
      </p>
    </>
  )

  // ---------------------------------------------- Konzept „NVAI im Fluss“, Bildschirm B: Weg, Plätze, Zusätze, Chips
  const slotImage = (id: string): SlotAsset | null => {
    if (!id) return null
    const a = sourceImages.find((x) => x.id === id) ?? results.find((x) => x.id === id)
    return a ? { url: a.url, thumb: a.thumb_url, name: assetName(a) } : { url: '', name: t('gewählt', 'selected') }
  }
  const slotVideo = (id: string): SlotAsset | null => {
    if (!id) return null
    const a = [...layoutUploads, ...videoAssets].find((x) => x.id === id) ?? results.find((x) => x.id === id)
    if (!a) return { url: '', video: true, name: t('gewählt', 'selected') }
    const secs = a.meta?.seconds ?? a.meta?.duration_s
    const name = String(a.meta?.original_name || a.prompt || a.filename).slice(0, 60)
    return { url: a.url, thumb: a.thumb_url, video: true, name: secs ? `${name} (${secs} s)` : name }
  }
  // Ein Bild aus der Auswahl oder vom Rechner auf einen Platz ziehen
  const uploadImage = async (f: File): Promise<Asset | null> => {
    setError(null)
    try {
      const a = await api.upload(f)
      setSourceImages((s) => [a, ...s])
      return a
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      return null
    }
  }
  const dropImage = (set: (id: string) => void) => ({
    onDropFile: (f: File) => { uploadImage(f).then((a) => a && set(a.id)) },
    onDropUrl: (url: string) => {
      const a = sourceImages.find((x) => url === x.url || url.endsWith(x.url) || (!!x.thumb_url && url.endsWith(x.thumb_url)))
      if (a) set(a.id)
      return !!a
    },
  })
  const imageGrid = (selectedId: string, onPick: (id: string) => void) => (
    sourceImages.length === 0 ? (
      <p className="hint small">{t('Noch keine Bilder da. Erst eines generieren oder hochladen.', 'No images yet. Generate or upload one first.')}</p>
    ) : (
      <div className="source-grid" ref={chainWheel}>
        {sourceImages.map((a) => (
          <div key={a.id} className={selectedId === a.id ? 'source selected' : 'source'} title={a.prompt || a.filename}>
            <img src={a.url} alt={a.prompt} loading="lazy" onClick={() => onPick(a.id)} />
          </div>
        ))}
      </div>
    )
  )
  // Fehlende Zusätze von LTX-2.5, die dieser Weg nutzen würde: an Ort und Stelle nachladen (lädt nur, was fehlt)
  const extrasMissing = !isLtx25 || !selected ? [] : [
    rules.dfr && vfeat?.missing?.dfr ? t('Höchste Qualität (DFR)', 'Best quality (DFR)') : '',
    rules.dfr && vfeat?.missing?.temporal_upscale ? '48 fps' : '',
    rules.auto && vfeat?.missing?.auto_duration ? t('Länge automatisch', 'Automatic length') : '',
    way === 'layout' && vfeat?.missing?.layout ? t('Layout-Video (Layout to Render)', 'Layout video (layout to render)') : '',
  ].filter(Boolean)
  const extrasLine = () => {
    if (!selected || !extrasMissing.length) return null
    const dl = downloads.active[selected.id]
    const url = vfeat?.missing?.[way === 'layout' && vfeat?.missing?.layout ? 'layout' : 'dfr']
      ?? Object.values(vfeat?.missing ?? {})[0]
    return (
      <p className="gen-muted-line">
        {t(`Noch nicht geladen: ${extrasMissing.join(', ')}.`, `Not downloaded yet: ${extrasMissing.join(', ')}.`)}{' '}
        {dl ? (
          <span>{dl.status === 'queued' ? t('wartet auf den Download', 'waiting to download') : `${Math.round(dl.progress * 100)} %`}</span>
        ) : (
          <>
            {url && (
              <><a href={url} target="_blank" rel="noreferrer">{t('Freigabe auf Hugging Face', 'access on Hugging Face')}</a>{', '}</>
            )}
            <button type="button" className="link-btn"
              title={t('Lädt nur die fehlenden Zusatzdateien von LTX-2.5; gesperrte Repos brauchen vorher die Freigabe.',
                'Downloads only the missing extra files of LTX-2.5; gated repos need access first.')}
              onClick={() => downloads.start(selected.id).catch((e) => setError(e instanceof Error ? e.message : String(e)))}>
              {t('Zusätze laden', 'Download extras')}
            </button>
          </>
        )}
      </p>
    )
  }

  const videoWaySection = () => {
    const startSlot = (label: string, required: boolean) => (
      <Slot key="start" label={label} asset={slotImage(sourceId)} required={required} accept="image"
        empty={required ? t('wählen oder hierher ziehen', 'choose or drag here') : t('optional, wählen oder hierher ziehen', 'optional, choose or drag here')}
        open={slotOpen === 'start'} onToggle={() => setSlotOpen((o) => (o === 'start' ? null : 'start'))}
        onClear={() => pickSource('')} {...dropImage((id) => pickSource(id))} />
    )
    const slots: React.ReactNode[] = []
    if (way === 'start') slots.push(startSlot(t('Startbild', 'Start image'), true))
    if (way === 'ends') {
      slots.push(startSlot(t('Startbild', 'Start image'), false))
      slots.push(
        <Slot key="end" label={t('Endbild', 'End image')} asset={slotImage(endId)} required accept="image"
          empty={t('wählen oder hierher ziehen', 'choose or drag here')}
          open={slotOpen === 'end'} onToggle={() => setSlotOpen((o) => (o === 'end' ? null : 'end'))}
          onClear={() => setEndId('')} {...dropImage((id) => setEndId(id))} />,
      )
    }
    if (way === 'loop') slots.push(startSlot(t('Startbild = Endbild', 'Start image = end image'), true))
    if (way === 'layout' && vfeat?.layout) {
      slots.push(
        <Slot key="layout" label={t('Layout-Video', 'Layout video')} asset={slotVideo(guideId)} required accept="video"
          empty={t('grobe Animation wählen oder hochladen', 'choose or upload a rough animation')}
          open={slotOpen === 'layout'} onToggle={() => setSlotOpen((o) => (o === 'layout' ? null : 'layout'))}
          onClear={() => setGuideId('')}
          onDropFile={async (f) => {
            try {
              const a = await api.upload(f)
              setLayoutUploads((list) => [a, ...list])
              setGuideId(a.id)
            } catch (e) {
              setError(e instanceof Error ? e.message : String(e))
            }
          }} />,
      )
      slots.push(startSlot(t('Erstes Bild', 'First image'), false))
    }
    if (way === 'extend') {
      slots.push(
        <Slot key="extend" label={t('Video', 'Video')} asset={slotVideo(extendId)} required
          empty={t('das Video wählen, das weitergehen soll', 'choose the video to continue')}
          open={slotOpen === 'extend'} onToggle={() => setSlotOpen((o) => (o === 'extend' ? null : 'extend'))}
          onClear={() => setExtendId('')} />,
      )
    }
    return (
      <div className="gen-way">
        <span className="flow-label">{t('Weg', 'Path')}</span>
        {ways.length > 1 && (
          <div className="flow-seg" role="group" aria-label={t('Weg', 'Path')}>
            {ways.map((w) => (
              <button key={w} type="button" aria-pressed={way === w} onClick={() => chooseWay(w)}>{wayLabel(w)}</button>
            ))}
          </div>
        )}
        {ways.length === 1 && <span className="flow-chip">{wayLabel(ways[0])}</span>}
        {way === 'refs' ? refPicker() : slots.length > 0 ? (
          <div className="gen-slots">{slots}</div>
        ) : way === 'text' && (
          <span className="muted small">{t('Kein Bild nötig.', 'No image needed.')}</span>
        )}
        {slotOpen === 'start' && rules.start !== 'none' && (
          <div className="gen-pick">
            {sourcePicker(rules.start === 'optional', { heading: false, onPicked: () => setSlotOpen(null) })}
          </div>
        )}
        {slotOpen === 'end' && way === 'ends' && (
          <div className="gen-pick">
            {imageGrid(endId, (id) => {
              setEndId(id)
              setSlotOpen(null)
            })}
            <button type="button" className="btn small ghost full" onClick={() => endFileRef.current?.click()}>
              {t('Bild hochladen', 'Upload image')}
            </button>
          </div>
        )}
        {slotOpen === 'layout' && way === 'layout' && vfeat?.layout && (
          <div className="gen-pick">
            <div className="row">
              <select value={guideId} onChange={(e) => {
                setGuideId(e.target.value)
                if (e.target.value) setSlotOpen(null)
              }}>
                <option value="">{t('— kein Layout —', '— no layout —')}</option>
                {[...layoutUploads, ...videoAssets].map((a) => (
                  <option key={a.id} value={a.id}>{String(a.meta?.original_name || a.prompt || a.filename).slice(0, 60)}</option>
                ))}
              </select>
              <button type="button" className="btn small ghost" onClick={() => videoInput.current?.click()}>
                {t('Video hochladen', 'Upload video')}
              </button>
            </div>
          </div>
        )}
        {slotOpen === 'extend' && way === 'extend' && (
          <div className="gen-pick">
            <select value={extendId} onChange={(e) => {
              setExtendId(e.target.value)
              if (e.target.value) setSlotOpen(null)
            }}>
              <option value="">{t('Video wählen …', 'Choose a video …')}</option>
              {videoAssets.map((a) => (
                <option key={a.id} value={a.id}>
                  {(a.prompt || a.filename).slice(0, 60)}
                  {a.meta?.seconds || a.meta?.duration_s ? ` (${a.meta?.seconds ?? a.meta?.duration_s} s)` : ''}
                </option>
              ))}
            </select>
            {videoAssets.length === 0 && (
              <p className="hint small">{t('Noch kein Video da. Erst eines erzeugen.', 'No video yet. Create one first.')}</p>
            )}
          </div>
        )}
        {way === 'layout' && !vfeat?.layout ? (
          <p className="flow-note warn small">
            {t('Das Layout-Video braucht die Layout-To-Render-LoRA, einen Zusatz von LTX-2.5.',
              'The layout video needs the Layout-To-Render LoRA, an extra for LTX-2.5.')}
          </p>
        ) : (
          <p className="flow-note small" title={wayDetail(way) || undefined}>{wayNote(way, { ltx: isLtx25, dfr: dfrReady })}</p>
        )}
        {way === 'layout' && vfeat?.layout && (
          <p className="gen-muted-line">
            {t('Der erste Auftrag lädt zwei Knoten von Lightricks (LTX-2 Community License) von GitHub.',
              'The first job downloads two nodes by Lightricks (LTX-2 Community License) from GitHub.')}
          </p>
        )}
        {extrasLine()}
        {wayStart && personSection()}
      </div>
    )
  }

  // Zusätze, die zum Weg passen (LTX-2.5): Zeitlupe, Ton vorgeben, Länge automatisch, mehrere Einstellungen
  const videoExtras = () => {
    if (!isLtx25) return null
    const chips: React.ReactNode[] = []
    const lines: string[] = []
    if (vfeat?.motion_speed && rules.motion) {
      const speeds: [number, string][] = [[1, t('aus (Echtzeit)', 'off (real time)')], [0.5, '2×'], [0.2, '5×'], [0.1, '10×'],
        [0.05, '20×'], [0.025, '40×']]
      const slow = speeds.find(([v]) => v === motionSpeed)?.[1] ?? ''
      chips.push(
        <ChipSelect key="motion" className={motionSpeed < 1 ? 'ok' : ''} label={t('Zeitlupe', 'Slow motion')}
          value={String(motionSpeed)} options={speeds.map(([v, l]) => ({ value: String(v), label: l }))}
          onChange={(v) => setMotionSpeed(Number(v))}
          display={motionSpeed < 1 ? t(`Zeitlupe ${slow}`, `Slow motion ${slow}`) : t('Zeitlupe aus', 'Slow motion off')} />,
      )
      if (motionSpeed < 1) {
        lines.push(t('Zeitlupe mit der LoRA „Slow Motion Control“ (empfohlene LoRAs) und einem Startbild. Gemessen bei 1080p '
          + 'und 5×: Gischt sank über 5 s statt in 1,5 s; ohne LoRA stand sie als milchiger Schleier.',
        'Slow motion with the “Slow Motion Control” LoRA (recommended LoRAs) and a start image. Measured at 1080p and 5×: '
          + 'spray fell over 5 s instead of 1.5 s; without the LoRA it stood still as a milky veil.'))
      }
    }
    if (vfeat?.audio_input && rules.audio) {
      const given = audioAssets.find((a) => a.id === audioId)
      chips.push(
        <ChipSelect key="audio" className={audioId ? 'ok' : ''} label={t('Ton vorgeben', 'Given sound')} value={audioId}
          options={[{ value: '', label: t('— keiner, LTX-2.5 erzeugt den Ton —', '— none, LTX-2.5 creates the sound —') },
            ...audioAssets.map((a) => ({
              value: a.id, label: `${(a.prompt || a.filename).slice(0, 60)}${a.meta?.seconds ? ` (${a.meta.seconds} s)` : ''}`,
            }))]}
          onChange={setAudioId}
          display={audioId ? t(`Ton: ${(given?.prompt || given?.filename || '').slice(0, 24)}`, `Sound: ${(given?.prompt || given?.filename || '').slice(0, 24)}`)
            : t('Ton vorgeben', 'Given sound')} />,
      )
      if (effAudio) {
        lines.push(t('Der Ton bleibt unverändert im Video, das Bild richtet sich nach ihm; er bestimmt die Länge (höchstens 20 s).',
          'The sound stays unchanged in the video and the picture follows it; it sets the length (at most 20 s).'))
      }
    }
    if (vfeat?.auto_duration && rules.auto && !effAudio) {
      chips.push(
        <button key="auto" type="button" className="flow-chip" aria-pressed={autoDuration}
          onClick={() => setAutoDuration((v) => !v)}
          title={t('Länge automatisch aus der beschriebenen Handlung (1–20 s)', 'Automatic length from the described action (1–20 s)')}>
          {t('Länge automatisch', 'Automatic length')}
        </button>,
      )
      if (effAuto) {
        lines.push(t('Pausen ausschreiben („a beat of silence“), sonst wird der Clip kurz.',
          'Write pauses out (“a beat of silence”), otherwise the clip gets short.'))
      }
    }
    if (vfeat?.multishot && rules.multishot) {
      chips.push(
        <button key="multishot" type="button" className="flow-chip" aria-pressed={multishot}
          onClick={() => setMultishot((v) => !v)}
          title={t('Mehrere Einstellungen (Multishot): „Prompt ausbauen“ schreibt 2–4 Einstellungen mit Schnitten',
            'Several shots (multi-shot): “Expand prompt” writes 2–4 shots with cuts')}>
          {t('Mehrere Einstellungen', 'Several shots')}
        </button>,
      )
      if (effMultishot) {
        lines.push(t('„Prompt ausbauen“ schreibt 2–4 Einstellungen mit Schnitten.', '“Expand prompt” writes 2–4 shots with cuts.'))
      }
    }
    if (!chips.length) return null
    return (
      <div className="gen-extras">
        <span className="flow-label">{t('Zusätze', 'Extras')}</span>
        <div className="gen-chips">{chips}</div>
        {lines.map((l) => <p key={l} className="gen-muted-line">{l}</p>)}
      </div>
    )
  }

  // Chips über dem großen Knopf: Modell mit Zustand, Format, Länge bzw. Anzahl, Qualität (Konzept, Bildschirm B)
  const chipRow = () => {
    const chips: React.ReactNode[] = []
    if (mode === 'restore') {
      if (restoreEdits) chips.push(modelChip(need ?? selected, !!need, 'edit'))
      if (restoreSharpen) chips.push(modelChip(upscaler ?? seedvr2, !upscaler, 'sharp'))
    } else {
      chips.push(modelChip(need ?? selected, !!need))
    }
    if (mode === 'image') {
      chips.push(outpainting ? (
        <span key="size" className="flow-chip" title={t('Beim Erweitern ergibt sich das Format aus Bild und Rand',
          'When extending, the size follows from image and border')}>
          {padTo ? `${padTo.w} × ${padTo.h}` : t('Format aus Bild und Rand', 'size from image and border')}
        </span>
      ) : (
        <ChipSelect key="size" label={t('Format', 'Size')} value={imgSize.label}
          options={sizes.map((s) => ({ value: s.label, label: s.label }))}
          onChange={(v) => setImgSize(sizes.find((s) => s.label === v) ?? sizes[0])}
          display={`${imgSize.w} × ${imgSize.h}`}
          title={t('Stehende Figuren im Hochformat — im Quadrat fehlen ihnen oft die Beine.',
            'Standing figures in portrait format — in a square they often lose their legs.')
            + (feat?.sizes?.length ? t(' Die modelleigenen Formate unten in der Liste geben mehr Detail und kosten mehr Zeit.',
              ' The model-specific sizes at the end of the list give more detail and take longer.') : '')} />
      ))
      chips.push(
        <ChipNumber key="count" label={t('Anzahl', 'Count')} value={batch} min={1} max={8}
          onChange={setBatch}
          unit={batch === 1 ? t('Bild', 'image') : t('Bilder', 'images')} />,
      )
    }
    if (mode === 'restore') {
      chips.push(
        <ChipNumber key="count" label={t('Varianten', 'Variants')} value={Math.min(4, batch)} min={1} max={4}
          onChange={setBatch}
          unit={Math.min(4, batch) === 1 ? t('Variante', 'variant') : t('Varianten', 'variants')} />,
      )
    }
    if (mode === 'audio') {
      chips.push(
        <ChipNumber key="len" label={t('Länge in Sekunden', 'Length in seconds')} value={seconds} min={1} max={300}
          onChange={setSeconds} unit="s" />,
      )
    }
    if (mode === 'video') {
      chips.push(way === 'extend' ? (
        <span key="size" className="flow-chip" title={t('Format und Bildrate kommen vom Video.', 'Size and frame rate come from the video.')}>
          {t('Format wie das Video', 'Size as the video')}
        </span>
      ) : (
        <ChipSelect key="size" label={t('Format', 'Size')} value={vidSize.label}
          options={videoSizes.map((s) => ({ value: s.label, label: s.label }))}
          onChange={(v) => setVidSize(videoSizes.find((s) => s.label === v) ?? videoSizes[0])}
          display={`${vidSize.w} × ${vidSize.h}`} />
      ))
      if (isLtx25) {
        chips.push(effAudio ? (
          <span key="len" className="flow-chip" title={t('Mit vorgegebenem Ton bestimmt der Ton die Länge.', 'With a given sound, the sound sets the length.')}>
            {t('Länge wie der Ton', 'Length as the sound')}
          </span>
        ) : effAuto ? (
          <span key="len" className="flow-chip">{t('Länge automatisch', 'Automatic length')}</span>
        ) : (
          <ChipNumber key="len" label={t('Länge in Sekunden', 'Length in seconds')} value={ltxSeconds} min={1} max={ltxMaxSeconds}
            onChange={setLtxSeconds} unit="s"
            title={t(`${ltxFrames} Frames ≈ ${dec(ltxFrames / ltxFps, 1)} s`, `${ltxFrames} frames ≈ ${dec(ltxFrames / ltxFps, 1)} s`)
              + (way === 'extend' ? t('; gilt für das neue Stück', '; applies to the new part')
                : way === 'layout' ? t('; höchstens so lang wie das Layout', '; at most as long as the layout') : '')} />
        ))
      } else {
        chips.push(
          <ChipNumber key="len" label={t('Frames', 'Frames')} value={frames} min={vfeat?.min_frames ?? 9}
            max={vfeat?.max_frames ?? 201} step={vfeat?.frame_step ?? 4} onChange={setFrames}
            unit={t(`Frames ≈ ${dec(frames / Math.max(fps, 1), 1)} s`, `frames ≈ ${dec(frames / Math.max(fps, 1), 1)} s`)}
            title={t(`Frames werden auf ${vfeat?.frame_rule ?? '4n+1'} gerundet`, `frames are rounded to ${vfeat?.frame_rule ?? '4n+1'}`)} />,
        )
      }
      if (dfrWay) {
        const value = effQuality === 'dfr' ? (effTemporal ? 'dfr48' : 'dfr') : 'standard'
        const options = [
          { value: 'standard', label: t('Standard', 'Standard') },
          { value: 'dfr', label: t('Höchste Qualität (DFR)', 'Best quality (DFR)'), disabled: !dfrReady },
          ...(vfeat?.temporal_upscale ? [{ value: 'dfr48', label: t('DFR mit 48 fps (zeitlich verdoppelt, langsamer)', 'DFR at 48 fps (temporal upscale, slower)'), disabled: !dfrReady }] : []),
        ]
        const altTime = fmtEta(totalSeconds(altEst))
        chips.push(
          <ChipSelect key="quality" label={t('Qualität', 'Quality')} value={value} options={options}
            onChange={(v) => {
              chooseQuality(v === 'standard' ? 'standard' : 'dfr')
              setTemporal(v === 'dfr48')
            }}
            className={effQuality === 'dfr' ? 'ok' : ''}
            title={t('DFR rechnet Detail-Keyframes mit und eine zweite Stufe mit einem Detail-IC-LoRA: Gesicht und Stoffe '
              + 'bleiben über die ganze Länge scharf (gemessen 5 s in 1080p: 13 statt 4 Minuten).',
            'DFR computes detail keyframes and a second stage with a detail IC-LoRA: faces and fabric stay sharp over the '
              + 'whole clip (measured 5 s at 1080p: 13 instead of 4 minutes).')
              + (dfrReady ? '' : t(' Das Detail-IC-LoRA fehlt noch (oben „Zusätze laden“).', ' The detail IC-LoRA is still missing (“Download extras” above).'))}
            display={<>
              {effQuality === 'dfr' ? (effTemporal ? 'DFR · 48 fps' : 'DFR') : t('Standard', 'Standard')}
              {altTime && <span className="gen-chip-alt"> · {effQuality === 'dfr' ? t('Standard', 'Standard') : 'DFR'} {altTime}</span>}
            </>} />,
        )
      } else if (isLtx25) {
        chips.push(
          <span key="quality" className="flow-chip" title={t('DFR entfällt bei diesem Weg.', 'DFR is not available on this path.')}>
            {t('Standard', 'Standard')}
          </span>,
        )
      }
    }
    return <div className="gen-chips">{chips}</div>
  }

  // Bild: CFG, Sampler, Scheduler und ControlNet (vorher eigener Knopf „Feineinstellung“ im Bild-Reiter)
  const imageFine = () => (
    <>
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
              <div className="source-grid" ref={chainWheel}>
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
    </>
  )

  // Feineinstellung (Konzept: „Schritte, Seed, Sampler und Formate bleiben unter „Feineinstellung“, nur nicht mehr im
  // Weg“); die Zeile sagt, was davon gesetzt ist
  const fineSet = [
    steps && mode !== 'restore' && mode !== 'speech' ? t(`${steps} Schritte`, `${steps} steps`) : '',
    seed ? `Seed ${seed}` : '',
    mode === 'image' && cfg ? `CFG ${cfg}` : '',
    mode === 'image' && sampler ? sampler : '',
    mode === 'image' && scheduler ? scheduler : '',
    mode === 'image' && cnId ? 'ControlNet' : '',
    mode === 'video' && isLtx25 && ltxFps !== 24 ? `${ltxFps} fps` : '',
    mode === 'video' && !master ? t('ohne verlustfreie Kopie', 'no lossless copy') : '',
  ].filter(Boolean)
  const fineSettings = () => (
    <details className="flow-fine" open={advanced} onToggle={(e) => setAdvanced(e.currentTarget.open)}>
      <summary>
        {t('Feineinstellung', 'Advanced settings')}
        {fineSet.length > 0 && <span className="gen-fine-set"> · {fineSet.join(', ')}</span>}
      </summary>
      <div className="advanced">
        <div className="row">
          {mode !== 'restore' && mode !== 'speech' && (
            <label>
              {t('Schritte', 'Steps')}
              <input value={steps} onChange={(e) => setSteps(e.target.value)}
                placeholder={mode === '3d' ? '50' : feat?.steps ? String(feat.steps) : 'auto'}
                inputMode="numeric" />
            </label>
          )}
          <label>
            {t('Seed', 'Seed')}
            <input value={seed} onChange={(e) => setSeed(e.target.value)}
              placeholder={t('zufällig', 'random')} inputMode="numeric" />
          </label>
          {mode === 'video' && (
            <label>
              fps
              {isLtx25 ? (
                <select value={ltxFps} onChange={(e) => setLtxFps(Number(e.target.value))}>
                  {[24, 25, 30].map((f) => <option key={f} value={f}>{f}</option>)}
                </select>
              ) : (
                <input type="number" min={1} max={60} value={fps} onChange={(e) => setFps(Number(e.target.value))} />
              )}
            </label>
          )}
        </div>
        {mode === 'image' && imageFine()}
        {mode === 'video' && ((vfeat?.sparse_attention?.length ?? 0) > 0 || vfeat?.int8_attention) && (
          <div className="accel-row">
            <span className="muted small">{t('Beschleuniger', 'Speed-up')}</span>
            {(vfeat?.sparse_attention?.length ?? 0) > 0 && (
              <select value={sparse} onChange={(e) => setSparse(e.target.value as SparseAttention | '')}
                title={t('Sparse Attention lässt unwichtige Teile der Attention aus',
                  'Sparse attention skips unimportant parts of the attention')}>
                <option value="">{t('Sparse Attention aus', 'Sparse attention off')}</option>
                {vfeat?.sparse_attention?.map((m) => (
                  <option key={m} value={m}>{m === 'veda' ? t('Veda (springt evtl. am Ende)', 'Veda (may jump near the end)') : 'sol-attn'}</option>
                ))}
              </select>
            )}
            {vfeat?.int8_attention && (
              <label className="check">
                <input type="checkbox" checked={int8} onChange={(e) => setInt8(e.target.checked)} />
                {t('INT8-Attention', 'INT8 attention')}
              </label>
            )}
          </div>
        )}
        {mode === 'video' && (
          <label className="check" title={t('Speichert das Video zusätzlich Bild für Bild ohne Kompression (FFV1, Ton als Float-PCM). Das Studio schneidet und exportiert daraus: gemessen 42,3 statt 37,7 dB PSNR beim YouTube-Export, Anschluss-Startbilder pixelgenau. Kostet Platz: rund 32 MB je Sekunde bei 1080p, 16 MB bei 720p (5 s 1080p: 162 statt 10 MB).',
              'Also stores the video frame by frame without compression (FFV1, sound as float PCM). The Studio cuts and exports from it: measured 42.3 instead of 37.7 dB PSNR for the YouTube export, chain start images pixel-exact. Costs space: about 32 MB per second at 1080p, 16 MB at 720p (5 s at 1080p: 162 instead of 10 MB).')}>
            <input type="checkbox" checked={master} onChange={(e) => setMaster(e.target.checked)} />
            <span>
              {t('Verlustfreie Kopie für den Schnitt (MKV)', 'Lossless copy for editing (MKV)')}{' '}
              <span className="muted small">{t('— bessere Exporte, rund 32 MB je Sekunde', '— better exports, about 32 MB per second')}</span>
            </span>
          </label>
        )}
      </div>
    </details>
  )

  return (
    <div className="split split-resizable" ref={splitRef}
      style={leftWidth ? { gridTemplateColumns: `${leftWidth}px 9px minmax(0, 1fr)` } : undefined}>
      <section className="panel controls" ref={controlsRef}>
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
        {/* Endbild und Layout-Video des Video-Wegs hochladen */}
        <input ref={endFileRef} type="file" accept="image/*" style={{ display: 'none' }}
          onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (f) uploadImage(f).then((a) => {
              if (!a) return
              setEndId(a.id)
              setSlotOpen(null)
            })
          }} />
        <input ref={videoInput} type="file" accept="video/*" style={{ display: 'none' }}
          onChange={async (e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (!f) return
            try {
              const a = await api.upload(f)
              setLayoutUploads((list) => [a, ...list])
              setGuideId(a.id)
              setSlotOpen(null)
            } catch (err) {
              setError(err instanceof Error ? err.message : String(err))
            }
          }} />
        <div className={(MODES.length === 6 ? 'mode-switch six' : MODES.length === 5 ? 'mode-switch five' : 'mode-switch four')
          + (leftWidth && leftWidth < 600 ? ' narrow' : '')}>
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

        <Recommendations mode={mode} />

        {mode === 'restore' ? restoreControls() : mode === 'speech' ? speechControls() : mode === '3d' ? (
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
                {meshEst && <span className="flow-eta">{fmtEta(totalSeconds(meshEst))}</span>}
              </button>
            </details>
            {sourcePicker(false)}
          </>
        ) : (
          <>
            {/* Konzept „NVAI im Fluss“, Bildschirm B: ein Weg statt der Klappen für Endbild, Schleife, Layout-Video und
                Verlängern; die Plätze und der Hinweis gehören zum gewählten Weg */}
            {mode === 'video' && videoWaySection()}
            <h3>{t('Prompt', 'Prompt')}</h3>
            <textarea
              ref={promptRef}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder={placeholder}
              rows={feat?.upsampler ? 4 : 6}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) generate()
              }}
            />
            {expandRow()}
            {mode === 'video' && videoExtras()}

            {mode === 'video' && vfeat?.audio_prompt && (
              <>
                <h3>{t('Ton', 'Sound')}</h3>
                <textarea
                  value={audioPrompt}
                  onChange={(e) => setAudioPrompt(e.target.value)}
                  rows={2}
                  placeholder={vfeat.audio_placeholder || t('Was zu hören ist', 'What can be heard')}
                />
                <p className="hint small">
                  {t('Was zu hören ist: Geräusche, Musik, Art der Stimme; laute Quellen ausdrücklich nennen. '
                      + 'Gesprochene Sätze stehen im Prompt als <S>…<E>.',
                    'What can be heard: sounds, music, the kind of voice; name loud sources explicitly. '
                      + 'Spoken lines go into the prompt as <S>…<E>.')}
                </p>
              </>
            )}

            {/* Nur, wenn er beim gewählten Modell wirkt; sonst sagt es die Plakette in den Modell-Infos (kompakter,
                Nutzer 22.11.2026) */}
            {negWorks && (<>
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
            </>)}
          </>
        )}

        <h3>{t('Modell', 'Model')}</h3>
        {/* Noch nicht geladene Modelle stehen mit Größe darunter: gewählt, erscheint unten „Laden“ (ModelNeed), geladen
            wird erst nach dem Klick (Konzept „NVAI im Fluss“: „Fehlendes an Ort und Stelle“) */}
        <select
          value={wantModel?.id ?? (noModel ? need?.id ?? '' : modelId[mode])}
          onChange={(e) => chooseModel(e.target.value)}
          disabled={noModel && missing.length === 0}
        >
          {noModel && missing.length === 0 && <option>{t(`— kein ${modeLabel}-Modell —`, `— no ${modeLabel} model —`)}</option>}
          {available.map((m) => (
            <option key={m.id} value={m.id}>
              {m.favorite ? '★ ' : ''}
              {licenseBlocked(m) ? '⚠ ' : ''}
              {m.name}
            </option>
          ))}
          {missing.length > 0 && (
            <optgroup label={t('Noch nicht geladen', 'Not downloaded yet')}>
              {missing.map((m) => (
                <option key={m.id} value={m.id}>{m.name} · {dec(m.size_gb, 1)} GB</option>
              ))}
            </optgroup>
          )}
        </select>
        {(need ?? selected) && <p className="hint small">{(need ?? selected)?.best_for}</p>}
        {(need ?? selected)?.features?.tested && <p className="hint small tested">{(need ?? selected)?.features?.tested}</p>}
        <ModelTip mode={mode} model={need ?? selected} />
        <ModelEstimate id={need?.id ?? selected?.id} />
        {/* Merkmale und Lizenz als Klappmenü unter dem Tipp, kompakt und standardmäßig zu (Nutzer 22.11.2026: „sollte als
            aufklappmenü unter tip sein (auch kompakter) mit icon model infos“); die harte Lizenzgrenze bleibt sichtbar */}
        {selected && ((mode === 'image' || mode === 'video') || chips.length > 0 || !!infoWarning) && (
          <details className="model-info">
            <summary>
              <span className="model-info-icon" aria-hidden="true">ⓘ</span> {t('Modell-Infos', 'Model info')}
              {/* Lizenzhinweis auch zugeklappt erkennbar (FLUX 3, Krea 2: jedes Bild vor der Veröffentlichung prüfen) */}
              {infoWarning && <span className="model-info-warn"> · {t('Lizenzhinweis', 'license note')}</span>}
            </summary>
            <div className="feature-chips">
              {(mode === 'image' || mode === 'video') && <><ContentBadge model={selected} /><LicenseBadge model={selected} /></>}
              {chips.map((c) => (
                <span key={c.text} className={c.ok ? 'badge ok' : 'badge warn'}>{c.text}</span>
              ))}
            </div>
            {infoWarning && <p className="hint small warn">{infoWarning}</p>}
          </details>
        )}
        {/* Harte Lizenzgrenze: roter Kasten, bis der Nutzer unter „Modelle“ eine Genehmigung bestätigt; danach keiner */}
        {selected?.license_badge && licenseBlocked(selected) && selected.warning && (
          <p className="warn-banner"><LinkText text={selected.warning} /></p>
        )}
        {mode === 'image' && feat?.missing?.style_reference && (
          <p className="hint small">
            {t('Stil-Referenz (Bilder als Stilvorlage): ', 'Style reference (images as a style template): ')}
            <a href={feat.missing.style_reference} target="_blank" rel="noreferrer">
              {t('Stil-LoRA von ostris', 'style LoRA by ostris')}
            </a>
            {t(', 0,46 GB. Laden: unter „Modelle“ bei Krea 2 „Zusätze laden“.',
              ', 0.46 GB. To get it: “Download extras” for Krea 2 under “Models”.')}
          </p>
        )}
        {/* LoRA-Bereich: immer sichtbar wie „Modell“ und „Format“ (Nutzer 12.11.2026: „loras auswahl soll besser
            zu sehen sein“); nimmt das Modell keine oder ist keine passende geladen, steht hier ein Hinweis */}
        {(mode === 'image' || mode === 'video') && selected && (
          <div className="lora-section">
            {(selected.lora_bases?.length ?? 0) === 0 ? (
              <>
              <h3>LoRAs</h3>
              <p className="lora-box lora-none hint small">
                {t(`${shortName(selected)} nimmt keine LoRAs.`, `${shortName(selected)} does not take LoRAs.`)}{' '}
                {loraModels.length > 0 ? (
                  <>
                    {t('LoRAs gehen mit ', 'LoRAs work with ')}
                    {loraModels.map((x, i) => (
                      <span key={x.model.id}>
                        {i > 0 && ', '}
                        <button className="link-btn" title={x.model.name}
                          onClick={() => setModelId({ ...modelId, [mode]: x.model.id })}>
                          {shortName(x.model)}
                        </button>
                        {x.count > 0 && t(` (${x.count} geladen)`, ` (${x.count} downloaded)`)}
                      </span>
                    ))}
                    .
                  </>
                ) : loraSuggestion ? (
                  <>
                    {t(`Von deinen Modellen nimmt keines LoRAs; ${shortName(loraSuggestion)} zum Beispiel schon: `,
                      `None of your models takes LoRAs; ${shortName(loraSuggestion)} does, for example: `)}
                    <button className="link-btn" onClick={onShowModels}>
                      {t('unter „Modelle“ laden', 'download it under “Models”')}
                    </button>
                    .
                  </>
                ) : (
                  t('Von deinen Modellen nimmt keines LoRAs.', 'None of your models takes LoRAs.')
                )}
              </p>
              </>
            ) : (
              // Aufklappbar, standardmäßig zu (Nutzer 22.11.2026: „loras "xx available" sollte auch zugeklappt sein,
              // aufklapbar“); die Zeile sagt, wie viele da und aktiv sind
              <details className="lora-picker lora-fold">
              <summary>
                LoRAs{' '}
                <span className={activeLoras.length > 0 ? 'h3-note on' : 'h3-note'}>
                  {activeLoras.length > 0
                    ? t(`${activeLoras.length} von ${loraChoices.length} aktiv`,
                      `${activeLoras.length} of ${loraChoices.length} active`)
                    : loraChoices.length > 0
                      ? t(`${loraChoices.length} verfügbar`, `${loraChoices.length} available`)
                      : t('keine geladen', 'none downloaded')}
                </span>
              </summary>
              <div className="lora-box">
                {loraChoices.length === 0 ? (
                  <p className="hint small">
                    {t(`Für ${shortName(selected)} ist noch keine LoRA geladen`,
                      `No LoRA for ${shortName(selected)} downloaded yet`)}
                    {/* Familie nur nennen, wenn sie mehr sagt als der Modellname (LTX-2.5 nimmt LTX-2/2.3-LoRAs) */}
                    {(() => {
                      const fit = (selected.lora_bases ?? []).map((b) => LORA_BASE_LABEL[b] ?? b)
                        .filter((l) => l !== shortName(selected))
                      return fit.length > 0 ? t(` (passend: ${fit.join(', ')})`, ` (fitting: ${fit.join(', ')})`) : ''
                    })()}
                    {'. '}
                    <button className="link-btn" onClick={onShowModels}>
                      {t('Unter „Modelle“ suchen', 'Search under “Models”')}
                    </button>
                    {t(' oder unten eine eigene Datei hinzufügen.', ' or add your own file below.')}
                  </p>
                ) : (
                  <div className="lora-list">
                    {loraChoices.map((l) => {
                      const pick = loraPicks.find((p) => p.model_id === l.id)
                      return (
                        <div key={l.id} className={pick ? 'lora-row on' : 'lora-row'}>
                          <label title={l.source_url || l.name}>
                            <input type="checkbox" checked={!!pick} onChange={() => pickLora(l)} />
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
                    })}
                  </div>
                )}
                <div className="lora-own">
                  <button className="link-btn" onClick={() => {
                    setLoraUploadOpen((o) => !o)
                    setLoraNote(null)
                  }}>
                    {loraUploadOpen
                      ? t('Eigene LoRA-Datei: schließen', 'Own LoRA file: close')
                      : t('+ Eigene LoRA-Datei hinzufügen', '+ Add your own LoRA file')}
                  </button>
                  {loraUploadOpen && (
                    <LoraUpload compact catalog={models} preferBase={selected?.lora_bases} onDone={loraAdded} />
                  )}
                  {loraNote && <p className="ok-text small">{loraNote}</p>}
                </div>
              </div>
              </details>
            )}
          </div>
        )}
        {/* Die Beschleuniger (MiniMax H3) stehen unter „Feineinstellung“ */}
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
                      : use === 'loop' ? t('mit Startbild und „Schleife“', 'with a start image and “Loop”')
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
                  {l.warning && !(l.license_badge && l.license_confirmed) && <p className="hint small warn">{l.warning}</p>}
                  <div className="row">
                    {l.installed ? (
                      <button className={pick ? 'btn small primary' : 'btn small'}
                        onClick={() => pickLora(l, l.features?.strength ?? 1)}>
                        {pick ? t('✓ aktiv', '✓ active') : t('Aktivieren', 'Activate')}
                      </button>
                    ) : dl ? (
                      <span className="muted small">{dl.stage || t('wartet', 'queued')}</span>
                    ) : (
                      <button className="btn small" onClick={() => downloads.start(l.id).catch((e) => setError(String((e as Error).message ?? e)))}>
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
            {/* Format und Anzahl stehen als Chips über dem Knopf (Konzept „NVAI im Fluss“, Bildschirm B) */}
            {feat?.upsampler && (
              <label className="check" title={t(
                'Der mitgelieferte Upsampler schreibt aus dem Prompt die lange Bildbeschreibung, auf die das Modell '
                  + 'trainiert ist. Abschalten, wenn der Prompt schon eine volle Beschreibung ist oder Bauweise, Anzahl '
                  + 'und Blickrichtung genau stimmen müssen: Bei FLUX 3 kam mit Ausbauer in 4 von 6 Bildern eine zweite '
                  + 'Angelschnur dazu, ohne in 0 von 2.',
                'The bundled upsampler turns the prompt into the long image description the model was trained on. '
                  + 'Switch it off if the prompt already is a full description or construction, counts and gaze have '
                  + 'to be exact: with FLUX 3 a second fishing line appeared in 4 of 6 images with the upsampler, in 0 '
                  + 'of 2 without.')}>
                <input type="checkbox" checked={upsample} onChange={(e) => setUpsample(e.target.checked)} />
                {/* Ein Textblock statt Text + span: sonst quetscht Flex die Beschriftung schmal. */}
                <span>
                  {t('Prompt ausbauen lassen', 'Expand the prompt')}{' '}
                  <span className="muted small">
                    {t('— aus für genaue Bauweise, Anzahl und Blickrichtung', '— off for exact construction, counts and gaze')}
                  </span>
                </span>
              </label>
            )}

            {maxRefs > 0 && refPicker()}

            {personSection()}

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
                <input type="checkbox" checked={useSource && !outpaintOn}
                  onChange={(e) => { setUseSource(e.target.checked); setOutpaintOn(false) }} />
                {t('Vorhandenes Bild überarbeiten', 'Rework an existing image')}{' '}
                <span className="muted small">
                  {t('— statt neu zu würfeln.', '— instead of rolling a new one.')}
                </span>
              </label>
            )}
            {/* Erweitern als eigener Haken (Nutzer 22.11.2026: „die steuerungselemente sollten nicht zu sehen sein
                solange ich nicht den checkbox für extend image ausgewählt habe“): Bildauswahl und Rand erst danach */}
            {canOutpaint && (
              <label className="check">
                <input type="checkbox" checked={useSource && outpaintOn}
                  onChange={(e) => { setUseSource(e.target.checked); setOutpaintOn(e.target.checked) }} />
                {t('Bild erweitern (Outpainting)', 'Extend an image (outpainting)')}{' '}
                <span className="muted small">
                  {t('— über den Rand hinaus, ein Prompt ist nicht nötig.', '— beyond its edges, no prompt needed.')}
                </span>
              </label>
            )}
            {(canImg2img || canOutpaint) && useSource && (
              <>
                {sourcePicker(false)}
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
                        'Das Bild bleibt, nur der neue Rand wird gemalt. Ein Prompt ist freiwillig; wenn, beschreibt er das ganze erweiterte Bild.',
                        'The image stays; only the new border is painted. A prompt is optional; if given, it describes the whole extended picture.',
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
          </>
        )}

        {/* Video und Ton: Format, Länge und Qualität stehen als Chips über dem Knopf, Layout-Video und Verlängern
            als Weg, Ton vorgeben, Zeitlupe und Multishot unter „Zusätze“, Bildrate und verlustfreie Kopie unter
            „Feineinstellung“ (Konzept „NVAI im Fluss“, Bildschirm B) */}

        {mode === '3d' && (
          <>
            <h3>{t('Mesh', 'Mesh')}</h3>
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
            {/* BiRefNet hat nur der TRELLIS.2-Worker; TripoSG stellt immer per Randfarben-Füllung frei */}
            <select value={!isTextured && bgMode === 'birefnet' ? 'flood' : bgMode}
              onChange={(e) => setBgMode(e.target.value as typeof bgMode)}>
              {isTextured && (
                <option value="birefnet">
                  {t('BiRefNet — sauberste Kanten (empfohlen)', 'BiRefNet — cleanest edges (recommended)')}
                </option>
              )}
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
            <label className="check">
              <input type="checkbox" checked={projectFront}
                onChange={(e) => setProjectFront(e.target.checked)} />
              {t('Vorderseite aus dem Bild übernehmen', 'Take the front from the image')}{' '}
              <span className="muted small">
                {isTextured
                  ? t('— legt das Quellbild auf die sichtbare Vorderseite, damit Schrift und Aufkleber lesbar '
                      + 'bleiben; der Rest behält die Textur von TRELLIS.2.',
                    '— puts the source image onto the visible front so lettering and stickers stay readable; '
                      + 'the rest keeps the TRELLIS.2 texture.')
                  : t('— legt das Quellbild auf die sichtbare Vorderseite, damit Schrift und Aufkleber lesbar '
                      + 'bleiben; der Rest bekommt Farben aus dem Bild.',
                    '— puts the source image onto the visible front so lettering and stickers stay readable; '
                      + 'the rest gets colors from the image.')}
              </span>
            </label>
          </>
        )}

        {/* Schritte, Seed, Sampler, Bildrate … unter einer Klappe (Konzept: „nur nicht mehr im Weg“) */}
        {fineSettings()}

        {mode !== '3d' && projects.length > 0 && (
          <label className="gen-target"
            title={t('Verlauf oder der Ordner eines Studio-Projekts: Was du für ein Projekt erzeugst (etwa Start- oder '
              + 'Referenzbilder), liegt dann gleich in seinem Ordner, im Studio wie im Verlauf.',
              'History or the folder of a Studio project: what you make for a project (start or reference images, '
              + 'say) goes straight into its folder, in the Studio and in the history.')}>
            {t('Ablegen in', 'Save to')}
            <select value={projectId} onPointerDown={refreshProjects} onChange={(e) => chooseProject(e.target.value)}>
              <option value="">{t('Verlauf', 'History')}</option>
              {projects.map((p) => (
                <option key={p.id} value={p.id}>{t('Studio-Projekt', 'Studio project')}: {p.name}</option>
              ))}
            </select>
          </label>
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
        {/* Nur, wenn gerade ein anderes Modell den Grafikspeicher belegt (dieselbe Angabe wie oben in der Leiste); liegt
            genau dieses schon dort, gibt es nichts zu leeren */}
        {selected && selected.vram_gb > 13
          && (health?.vram_loaded ?? []).some((l) => l.model !== selected.name) && (
          <p className="hint warn">
            {t(
              `${selected.vram_gb} GB VRAM: eng auf 16 GB. Vorher „VRAM leeren“ drücken.`,
              `${selected.vram_gb} GB VRAM: tight on 16 GB. Press “Free VRAM” first.`,
            )}
          </p>
        )}

        {/* Klebt unten an der linken Spalte: Knopf ohne Scrollen erreichbar, auch wenn Erweitern, Referenzen oder die
            Video-Teile aufgeklappt sind (Nutzer 22.11.2026: „kann nicht nach unten scrollen um es zu bestätigen“). Seit
            dem Konzept „NVAI im Fluss“ (Bildschirm B) darüber die Chips mit Modell, Format, Länge und Qualität und, wenn
            ein Modell fehlt, „Laden“ an Ort und Stelle; der Knopf nennt Aktion und Zeit. */}
        <div className="gen-submit">
          {chipRow()}
          {need && (
            <ModelNeed model={need} why={NEED_WHY[mode]} downloads={downloads}
              alternative={wantModel ? selected ?? null : null}
              onUseAlternative={() => setWant((w) => ({ ...w, [mode]: undefined }))}
              onShowModels={onShowModels} />
          )}
          {recMissing && selected && (
            <ModelNeed model={recMissing} why={NEED_WHY[mode]} downloads={downloads} compact
              alternative={selected} onUseAlternative={dismissRec} onShowModels={onShowModels} />
          )}
          {!need && noModel && (mode !== 'restore' || restoreEdits) && (
            <p className="hint warn small">
              {mode === 'restore'
                ? t('Schäden entfernen und Einfärben brauchen FLUX 3 Image Klein:', 'Removing damage and colorizing need FLUX 3 Image Klein:')
                : t(`Kein ${modeLabel}-Modell installiert:`, `No ${modeLabel} model installed:`)}{' '}
              <button className="link-btn" onClick={onShowModels}>{t('unter „Modelle“ laden', 'download it under “Models”')}</button>
            </p>
          )}
          <button className="btn primary flow-big" onClick={generate}
            disabled={busy || !!need || (mode === 'restore' ? false : noModel) || !canGenerate}
            title={[sourceText(mainEst), mode !== '3d' ? t('Strg+Enter', 'Ctrl+Enter') : ''].filter(Boolean).join(' · ') || undefined}>
            <span>{busy ? t('Läuft …', 'Running …') : actionLabel}</span>
            {busy && jobId
              ? <RunningEta jobId={jobId} expected={run?.id === jobId ? run.expected : null} />
              : <span className="flow-eta">{fmtEta(totalSeconds(mainEst))}</span>}
          </button>
          {blockedHint && <p className="hint warn small">{blockedHint}</p>}
        </div>
      </section>

      <div className="gen-vsplit" onPointerDown={dragSplit} onDoubleClick={resetSplit}
        title={t('Ziehen: Breite der Einstellungen · Doppelklick: zurücksetzen',
          'Drag: width of the settings · double-click: reset')} />

      <section className="panel output" ref={outputRef}>
        {/* Konzept „NVAI im Fluss“, Bildschirm C: Phasen mit Restzeit statt „generiert · 2 %“ */}
        {viewActive && viewId && (
          <div className="gen-run">
            <div className="gen-run-head">
              <span className="flow-label">{run?.id === viewId ? run.title : t('Auftrag', 'Job')}</span>
              <button className="btn small ghost danger-text" onClick={cancelView}>
                {t('Abbrechen', 'Cancel')}
              </button>
            </div>
            <JobPhases jobId={viewId}
              modelName={run?.id === viewId ? run.modelName : undefined}
              modelGb={run?.id === viewId ? run.modelGb : undefined}
              expected={run?.id === viewId ? run.expected : null}
              next={run?.id === viewId ? run.next : undefined} />
          </div>
        )}

        {error && <div className="error">{error}</div>}

        {results.length > 0 ? (
          <div className="gen-result" ref={resultRef}>
            {resultHead()}
            <div className={results[0].kind === 'image' ? 'grid' : 'stack'}>
              {results.map((a) => {
                const isPicked = results.length > 1 && picked?.id === a.id
                return (
                  <figure key={a.id} className={isPicked ? 'card result picked' : 'card result'}>
                    {a.kind === 'image' ? (
                      <div className="result-open" role="button" tabIndex={0} title={t('Groß ansehen', 'View large')}
                        onClick={() => setPreview(imageResults.indexOf(a))}
                        onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), setPreview(imageResults.indexOf(a)))}>
                        <AssetView asset={a} />
                      </div>
                    ) : (
                      <AssetView asset={a} />
                    )}
                    <figcaption className="muted small">
                      <OutputBadge model={models.find((m) => m.id === a.model_id && m.output_badge)
                        ?? models.find((m) => m.id === a.meta?.badge_model)} />{' '}
                      {resultSeeds.length > 1 && a.meta.seed != null && <><SeedCopy seed={a.meta.seed} />{' · '}</>}
                      <a href={a.url} download>{t('Download', 'Download')}</a>
                      {/* Mehrere Bilder: Mit welchem es weitergeht, wählt man hier (Vorgabe das erste) */}
                      {results.length > 1 && a.kind === 'image' && (
                        <button type="button" className={isPicked ? 'btn small primary gen-pick-btn' : 'btn small ghost gen-pick-btn'}
                          aria-pressed={isPicked} onClick={() => {
                            setPickedId(a.id)
                            setNextNeed(null)
                          }}>
                          {isPicked ? t('✓ weiter damit', '✓ continue with this') : t('weiter damit', 'continue with this')}
                        </button>
                      )}
                      {typeof a.meta.caption === 'string' && (
                        <details className="caption">
                          <summary>{t('Beschreibung vom Upsampler', 'Description from the upsampler')}</summary>
                          <p>{a.meta.caption}</p>
                        </details>
                      )}
                    </figcaption>
                  </figure>
                )
              })}
            </div>
            {/* Jedes Ergebnis führt weiter: die naheliegenden nächsten Schritte mit Modell und Zeit */}
            <NextSteps heading={nextHeading} steps={nextSteps}>
              {nextNeed && (
                <ModelNeed model={models.find((m) => m.id === nextNeed.model.id) ?? nextNeed.model}
                  why={NEXT_WHY[nextNeed.step]} downloads={downloads}
                  alternative={nextNeed.alternative ?? null}
                  onUseAlternative={nextNeed.alt ? () => {
                    const go = nextNeed.alt
                    setNextNeed(null)
                    go?.()
                  } : undefined}
                  onShowModels={onShowModels} />
              )}
              {studioNote && <p className="ok-text small gen-studio-note">{studioNote}</p>}
            </NextSteps>
          </div>
        ) : (
          !viewActive && <div className="placeholder">{t('Ergebnisse erscheinen hier.', 'Results appear here.')}</div>
        )}
        {preview !== null && imageResults[preview] && (
          <Lightbox assets={imageResults} index={preview} onIndex={setPreview} onClose={() => setPreview(null)} />
        )}
      </section>
    </div>
  )
}
