import { useEffect, useMemo, useRef, useState } from 'react'
import { api, type Asset, type GenKind, type Health, type ModelInfo, type ServerEvent } from '../api'
import { AssetView } from '../components/AssetView'
import type { Downloads } from '../downloads'
import { t } from '../i18n'

type Mode = GenKind

const MODES: { id: Mode; label: string; icon: string }[] = [
  { id: 'image', label: t('Bild', 'Image'), icon: '▣' },
  { id: 'audio', label: 'Audio', icon: '♪' },
  { id: 'video', label: 'Video', icon: '▶' },
  { id: '3d', label: '3D', icon: '◈' },
]

// Video-Workflows, die ohne Startbild nicht laufen (siehe workflows.py).
const I2V_WORKFLOWS = new Set(['wan_i2v', 'wan22_i2v', 'hunyuan15_i2v'])

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
  { label: t('640 × 640 (quadratisch)', '640 × 640 (square)'), w: 640, h: 640 },
  { label: t('480 × 832 (Hochformat)', '480 × 832 (portrait)'), w: 480, h: 832 },
  { label: t('1280 × 720 (720p, langsam)', '1280 × 720 (720p, slow)'), w: 1280, h: 720 },
]

const PLACEHOLDER: Record<Mode, string> = {
  image: 'stylized fantasy sword, game asset, orthographic, clean background',
  audio: 'footsteps on gravel, close mic, dry, no music',
  video: 'a torch flickering in a dark stone corridor, slow camera push in',
  '3d': '',
}

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
  const [cnId, setCnId] = useState('')
  const [cnImageId, setCnImageId] = useState('')
  const [cnStrength, setCnStrength] = useState(0.7)
  const [cnEnd, setCnEnd] = useState(0.8)
  const [cnPre, setCnPre] = useState<'none' | 'canny'>('none')
  const [advanced, setAdvanced] = useState(false)
  // FLUX 3: Upsampler und Referenzbilder (Reihenfolge = "the first image", ...)
  const [upsample, setUpsample] = useState(true)
  const [refIds, setRefIds] = useState<string[]>([])
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
      api.jobAssets(event.job_id).then(setResults)
      setJobId(null)
      setProgress(1)
      setStage(t('fertig', 'done'))
      if (mode === 'image') loadSources()
    } else if (event.type === 'job.error') {
      setError(event.error)
      setJobId(null)
    }
  }, [event, mode])

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
  const usesStart = needsStart || (mode === 'video' && selected?.workflow === 'wan22_ti2v')
  const meshWorker = selected?.workflow ? health?.mesh_workers?.[selected.workflow] : undefined

  // Was das gewählte Bildmodell kann (registry.features_for). Fehlt ein Eintrag, gilt
  // das alte Verhalten: alles anbieten.
  const feat = mode === 'image' ? selected?.features : undefined
  const negWorks = feat?.negative_prompt !== false
  const canImg2img = feat?.img2img !== false
  const canHires = feat?.hires !== false
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

  const canGenerate =
    mode === '3d'
      ? !!sourceId
      : needsStart
        ? !!prompt.trim() && !!sourceId
        : mode === 'image' && useSource && canImg2img
          ? !!prompt.trim() && !!sourceId
          : mode === 'image' && cnId
            ? !!prompt.trim() && !!cnImageId
            : !!prompt.trim()

  // Prompt ausbauen geht mit jedem Bildmodell, braucht aber die Upsampler-Datei von FLUX 3.
  const canExpand = models.some((m) => m.files.some((f) => f.installed && f.file.includes('upsampler')))

  const expandPrompt = async () => {
    if (expanding || busy || !prompt.trim()) return
    setExpanding(true)
    setError(null)
    try {
      const r = await api.expandPrompt({
        prompt, width: imgSize.w, height: imgSize.h,
        ...(maxRefs > 0 && refIds.length ? { reference_asset_ids: refIds } : {}),
      })
      setPromptBefore(prompt)
      setPrompt(r.expanded)
      setExpandSecs(r.seconds)
      // Schon ausgebaut: FLUX 3 soll ihn nicht ein zweites Mal umschreiben.
      if (feat?.upsampler) setUpsample(false)
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
    if (feat?.upsampler) setUpsample(true)
  }

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
          image_asset_id: useSource && canImg2img && sourceId ? sourceId : null,
          denoise: useSource && canImg2img ? denoise : 1.0,
          reference_asset_ids: maxRefs > 0 ? refIds.filter((id) => sourceImages.some((a) => a.id === id)) : [],
          upsample_prompt: feat?.upsampler ? upsample : null,
          controlnet_model_id: cnId || null,
          controlnet_image_asset_id: cnId ? cnImageId || null : null,
          controlnet_strength: cnStrength,
          controlnet_end: cnEnd,
          controlnet_preprocess: cnPre,
        })
      } else if (mode === 'audio') {
        job = await api.generateAudio({ ...common, seconds, lyrics })
      } else if (mode === 'video') {
        job = await api.generateVideo({
          ...common, width: vidSize.w, height: vidSize.h, frames, fps,
          image_asset_id: usesStart ? sourceId || null : null,
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
            {sourcePicker(false)}
            <p className="hint small">{HINT['3d']}</p>
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
              </>
            )}
            <h3>{mode === 'audio' && isAce ? t('Genre-Tags', 'Genre tags') : 'Prompt'}</h3>
            <textarea
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder={feat?.placeholder || PLACEHOLDER[mode]}
              rows={feat?.upsampler ? 4 : 6}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) generate()
              }}
            />
            {mode === 'image' && (
              <div className="expand-row">
                <button
                  className="btn small"
                  onClick={expandPrompt}
                  disabled={!canExpand || expanding || busy || !prompt.trim()}
                  title={canExpand
                    ? t('Macht aus wenigen Worten eine volle Bildbeschreibung, für jedes Bildmodell',
                      'Turns a few words into a full image description, for every image model')
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
                <span className="muted small">
                  {expanding
                    ? t('meist 10–40 s', 'usually 10–40 s')
                    : promptBefore !== null
                      ? t(`ausgebaut in ${expandSecs} s — jetzt lesen und streichen, was nicht stimmt`,
                        `expanded in ${expandSecs} s — now read it and remove what is wrong`)
                      : canExpand
                        ? t('Aus „a medieval blacksmith“ wird eine ganze Schmiede: Esse, Amboss, Funken, Licht.',
                          'Turns “a medieval blacksmith” into a whole forge: hearth, anvil, sparks, light.')
                        : t('Braucht FLUX 3 Image Klein (Upsampler).', 'Needs FLUX 3 Image Klein (upsampler).')}
                </span>
              </div>
            )}
            {(feat?.prompt_hint || HINT[mode]) && (
              <p className="hint small">{feat?.prompt_hint || HINT[mode]}</p>
            )}

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

        {mode === 'image' && (
          <>
            <h3>{t('Format', 'Size')}</h3>
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
            {canImg2img && useSource && (
              <>
                {sourcePicker(false)}
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
              onChange={(e) => setVidSize(VIDEO_SIZES.find((s) => s.label === e.target.value)!)}
            >
              {VIDEO_SIZES.map((s) => (
                <option key={s.label}>{s.label}</option>
              ))}
            </select>
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
            <div className="muted small">
              {stage} · {Math.round(progress * 100)} %
              {mode === 'video' && t(' · Video dauert mehrere Minuten', ' · video takes several minutes')}
              {mode === '3d' && t(' · erster Lauf lädt das Modell', ' · the first run loads the model')}
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
