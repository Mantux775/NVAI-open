import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { api, fileUrl, type Asset, type ModelInfo, type ServerEvent, type VhsAiSize, type VhsAnalysis, type VhsAspect, type VhsDeinterlace, type VhsDenoise, type VhsInfo, type VhsChroma, type VhsSettings, type VhsSharpen } from '../api'
import { Recommendations } from '../components/Recommendations'
import type { Downloads } from '../downloads'
import { t } from '../i18n'

// VHS-Bereich (seit 0.5.16, Nutzer 28.10.2026: „einen neuen Bereich, der das VHS-Video mit der KI entrauscht,
// stabilisiert und aufbessert“, „es braucht nur Aufwertungswerkzeuge“). Server: server/nvai/vhs.py, vhs_tools.py.

interface Props {
  event: ServerEvent | null
  downloads: Downloads
  onShowModels: () => void
}

// Gemessen 28.10. (RTX 5060 Ti, künstlicher VHS-Clip 768 × 576, 50 Bilder/s), wie vhs.estimate im Server
const CLASSIC_FPS: Record<VhsDenoise, number> = { off: 900, light: 700, medium: 46, strong: 18 }
const AI_SECONDS_PER_FRAME: Record<VhsAiSize, number> = { '720': 1.2, '1080': 2.0, original: 0.8 }
const PREVIEW_SECONDS = 10
const VIDEO_EXT = /\.(mp4|m4v|mov|mkv|avi|mpg|mpeg|m2v|vob|ts|m2ts|mts|dv|wmv|webm)$/i

function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  if (s < 90) return `${s} s`
  const m = Math.round(s / 60)
  if (m < 90) return `${m} min`
  const h = Math.floor(m / 60)
  return t(`${h} h ${String(m % 60).padStart(2, '0')} min`, `${h} h ${String(m % 60).padStart(2, '0')} min`)
}

function fmtClock(seconds: number | null | undefined): string {
  if (seconds == null) return '?'
  const s = Math.round(seconds)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`
}

function estimate(a: VhsAnalysis, s: VhsSettings, seconds: number): { classic: number; ai: number } {
  let fps = a.info.out_fps[0] / a.info.out_fps[1]
  if (s.deinterlace === 'single' && a.info.interlaced) fps /= 2
  if (s.deinterlace === 'off' && a.info.interlaced) fps /= 2
  const frames = seconds * fps
  const classic = frames / CLASSIC_FPS[s.denoise] + (s.stabilize ? frames / 92 : 0) + (chromaOf(s.chroma_denoise) === 'clean' ? frames / 40 : chromaOf(s.chroma_denoise) === 'strong' ? frames / 110 : 0)
  // Takt glätten je Eingangsbild wie vhs.SMOOTH_SECONDS_PER_FRAME: ohne KI 0,3 s, mit KI 0,05 s dazu (gemessen)
  return { classic, ai: (s.ai ? frames * AI_SECONDS_PER_FRAME[s.ai_size] : 0) + (s.smooth ? frames * (s.ai ? 0.05 : 0.3) : 0) }
}

/** Ausgabegröße wie vhs.out_size im Server: PAL/NTSC in voller Höhe, sonst Ausschnitt; 4:3/16:9 erzwingt das Verhältnis. */
function outSize(info: VhsInfo, crop: number[], aspect: VhsAspect): [number, number] {
  const a = aspect === 'auto' ? info.suggest_aspect ?? 'source' : aspect
  let oh: number
  let dar: number
  if (info.standard !== 'other') {
    oh = info.square_size[1]
    dar = info.aspect === '16:9' ? 16 / 9 : 4 / 3
  } else {
    const sar = info.sar ?? [1, 1]
    oh = Math.max(2, info.height - crop[1] - crop[3])
    dar = (Math.max(2, info.width - crop[0] - crop[2]) * sar[0]) / sar[1] / oh
  }
  if (a === '4:3') dar = 4 / 3
  else if (a === '16:9') dar = 16 / 9
  return [Math.round((oh * dar) / 2) * 2, Math.floor(oh / 2) * 2]
}

/** Farbflecken wie vhs._chroma im Server: true = sauber (neue Farbstufe) */
function chromaOf(v: boolean | VhsChroma | undefined): VhsChroma {
  return v === true ? 'clean' : v === 'clean' || v === 'strong' ? v : 'off'
}

function isVideo(a: Asset): boolean {
  return a.kind === 'video' || (a.kind === 'upload' && VIDEO_EXT.test(a.filename))
}

/** Vorher/nachher nebeneinander, gemeinsam abgespielt; der Ton kommt wahlweise von einer Seite. */
function Compare({ before, after }: { before: string; after: string }) {
  const a = useRef<HTMLVideoElement>(null)
  const b = useRef<HTMLVideoElement>(null)
  const [sound, setSound] = useState<'after' | 'before'>('after')
  const sync = () => {
    if (a.current && b.current && Math.abs(a.current.currentTime - b.current.currentTime) > 0.05) {
      a.current.currentTime = b.current.currentTime
    }
  }
  return (
    <div className="vhs-compare">
      <div className="vhs-compare-pair">
        <figure>
          <video ref={a} src={before} muted={sound !== 'before'} playsInline preload="metadata" />
          <figcaption className="muted small">{t('Vorher (nur entflochten)', 'Before (deinterlaced only)')}</figcaption>
        </figure>
        <figure>
          <video ref={b} src={after} controls muted={sound !== 'after'} playsInline preload="metadata"
            onPlay={() => { sync(); a.current?.play().catch(() => undefined) }}
            onPause={() => a.current?.pause()}
            onSeeked={sync}
            onRateChange={() => { if (a.current && b.current) a.current.playbackRate = b.current.playbackRate }} />
          <figcaption className="muted small">{t('Nachher', 'After')}</figcaption>
        </figure>
      </div>
      <span className="seg small">
        <button className={sound === 'after' ? 'on' : ''} onClick={() => setSound('after')}>{t('Ton nachher', 'Sound after')}</button>
        <button className={sound === 'before' ? 'on' : ''} onClick={() => setSound('before')}>{t('Ton vorher', 'Sound before')}</button>
      </span>
    </div>
  )
}

export function VhsPanel({ event, downloads, onShowModels }: Props) {
  const [videos, setVideos] = useState<Asset[]>([])
  const [sourceId, setSourceId] = useState<string>(() => {
    try { return localStorage.getItem('nvai-vhs-source') ?? '' } catch { return '' }
  })
  const [analysis, setAnalysis] = useState<VhsAnalysis | null>(null)
  const [analyzing, setAnalyzing] = useState(false)
  const [s, setS] = useState<VhsSettings | null>(null)
  const [start, setStart] = useState(0)
  const [upscalers, setUpscalers] = useState<ModelInfo[]>([])
  const [interps, setInterps] = useState<ModelInfo[]>([])
  const [jobId, setJobId] = useState<string | null>(null)
  const [progress, setProgress] = useState(0)
  const [stage, setStage] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [results, setResults] = useState<Asset[]>([])
  const [uploading, setUploading] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)

  const loadVideos = useCallback(async () => {
    const all = await api.assetPage({ media: 'video', limit: 200, offset: 0 })
    setVideos(all.filter((a) => isVideo(a) && !a.meta?.vhs))
  }, [])
  const loadResults = useCallback(async () => {
    const all = await api.assetPage({ media: 'video', q: 'VHS', limit: 30, offset: 0 })
    setResults(all.filter((a) => a.meta?.vhs))
  }, [])

  useEffect(() => {
    loadVideos().catch((e) => setError(String(e)))
    loadResults().catch(() => undefined)
    api.models('upscale').then(setUpscalers).catch(() => undefined)
    api.models('interpolate').then(setInterps).catch(() => undefined)
  }, [loadVideos, loadResults, downloads.finished])

  useEffect(() => {
    if (!sourceId) return
    try { localStorage.setItem('nvai-vhs-source', sourceId) } catch { /* ohne Speicher geht es auch */ }
    setAnalyzing(true)
    setAnalysis(null)
    setError(null)
    api.vhsAnalyze(sourceId)
      .then((a) => { setAnalysis(a); setS(a.defaults); setStart(0) })
      .catch((e) => setError(String(e)))
      .finally(() => setAnalyzing(false))
  }, [sourceId])

  useEffect(() => {
    if (!event || !jobId || !('job_id' in event) || event.job_id !== jobId) return
    if (event.type === 'job.progress') {
      setProgress(event.progress)
      setStage(event.stage)
    } else if (event.type === 'job.done') {
      setJobId(null)
      loadResults().catch(() => undefined)
    } else if (event.type === 'job.error') {
      setJobId(null)
      setError(event.error)
    } else if (event.type === 'job.cancelled') {
      setJobId(null)
    }
  }, [event, jobId, loadResults])

  const installedUpscaler = upscalers.find((m) => m.installed)
  const seedvr2 = upscalers.find((m) => m.id === 'seedvr2-7b-nvfp4') ?? upscalers[0]
  const rife = interps.find((m) => m.id === 'rife-4.26') ?? interps[0]
  const seconds = analysis?.info.seconds ?? 0
  const est = useMemo(() => (analysis && s ? estimate(analysis, s, seconds) : null), [analysis, s, seconds])
  const estPreview = useMemo(() => (analysis && s ? estimate(analysis, s, Math.min(PREVIEW_SECONDS, seconds)) : null),
    [analysis, s, seconds])

  const set = <K extends keyof VhsSettings>(k: K, v: VhsSettings[K]) => setS((old) => (old ? { ...old, [k]: v } : old))

  const run = async (preview: boolean) => {
    if (!analysis || !s) return
    setError(null)
    setProgress(0)
    setStage(t('wartet', 'queued'))
    try {
      const job = await api.vhsProcess({
        ...s, ai: s.ai && !!installedUpscaler, smooth: s.smooth && !!rife?.installed && canSmooth,
        asset_id: analysis.asset_id, preview,
        start: preview ? start : 0, duration: preview ? PREVIEW_SECONDS : null,
      })
      setJobId(job.id)
    } catch (e) {
      setError(String(e))
    }
  }

  const cancel = () => { if (jobId) api.cancelJob(jobId).catch((e) => setError(String(e))) }

  const upload = async (files: FileList | null) => {
    if (!files?.length) return
    setUploading(true)
    setError(null)
    try {
      const asset = await api.upload(files[0])
      await loadVideos()
      setSourceId(asset.id)
    } catch (e) {
      setError(String(e))
    } finally {
      setUploading(false)
      if (fileInput.current) fileInput.current.value = ''
    }
  }

  const info = analysis?.info
  const fps = info ? info.fps[0] / info.fps[1] : 25
  const outFps = info ? info.out_fps[0] / info.out_fps[1] : 50
  const crop = s?.crop ?? [0, 0, 0, 0]
  const size = info && s ? outSize(info, crop, s.aspect) : null
  // Vorschaubild im Seitenverhältnis des Ergebnisses: So sieht man beim Entzerren, ob Gesichter rund werden
  const ratio = size && info ? (size[0] / size[1]) * ((info.height - crop[1] - crop[3]) / info.height)
    / ((info.width - crop[0] - crop[2]) / info.width) : null
  const cropMax = info && info.standard === 'other' ? Math.floor(info.width / 4) : 64
  const canSmooth = !!info && !info.interlaced && info.cadence?.kind === '50to30'

  return (
    <div className="split">
      <section className="panel controls">
        <input ref={fileInput} type="file" accept="video/*,.mpg,.mpeg,.vob,.ts,.m2ts,.mts,.dv,.avi,.mkv,.mov"
          style={{ display: 'none' }} onChange={(e) => upload(e.target.files)} />
        <h3>{t('Digitalisiertes Video', 'Digitized video')}</h3>
        <div className="vhs-source">
          <select value={sourceId} onChange={(e) => setSourceId(e.target.value)}>
            <option value="">{t('— Video wählen —', '— choose a video —')}</option>
            {videos.map((v) => (
              <option key={v.id} value={v.id}>
                {String(v.meta?.original_name ?? v.prompt ?? v.filename).slice(0, 80)}
              </option>
            ))}
          </select>
          <button className="btn small" disabled={uploading} onClick={() => fileInput.current?.click()}>
            {uploading ? t('lädt hoch …', 'uploading …') : t('⬆ Video hochladen', '⬆ Upload video')}
          </button>
        </div>
        {analyzing && <p className="muted small">{t('Analysiert das Video …', 'Analyzing the video …')}</p>}
        {info && (
          <div className="vhs-info">
            <div className="vhs-thumb" style={ratio ? { width: `min(100%, ${Math.round(260 * ratio)}px)` } : undefined}>
              <img src={analysis.thumb_url} alt=""
                style={ratio ? { width: '100%', height: 'auto', maxHeight: 'none', aspectRatio: String(ratio), objectFit: 'fill' } : undefined} />
              <div className="vhs-crop" style={{
                left: `${(crop[0] / info.width) * 100}%`, top: `${(crop[1] / info.height) * 100}%`,
                right: `${(crop[2] / info.width) * 100}%`, bottom: `${(crop[3] / info.height) * 100}%`,
              }} />
            </div>
            <p className="muted small">
              {info.standard !== 'other' ? `${info.standard} · ` : ''}{info.width} × {info.height}
              {' · '}{info.interlaced
                ? t(`interlaced, ${info.parity === 'tff' ? 'oberes' : 'unteres'} Halbbild zuerst`,
                  `interlaced, ${info.parity === 'tff' ? 'top' : 'bottom'} field first`)
                : t('progressiv', 'progressive')}
              {' · '}{fps.toFixed(fps % 1 ? 2 : 0)} {t('Bilder/s', 'fps')} · {info.aspect} · {fmtClock(info.seconds)}
              {' · '}{info.codec}{info.audio ? t(`, Ton ${info.audio.codec}`, `, sound ${info.audio.codec}`) : t(', ohne Ton', ', no sound')}
            </p>
            {(info.cadence?.kind === '50to30' || info.cadence?.kind === '25to30') && (
              <p className="hint small">
                {info.cadence.kind === '50to30'
                  ? t('Takt: Der Wandler hat das 50-Hz-Band mit 30 Bildern/s aufgenommen (Abstände 40, 40, 20 ms), Schwenks ruckeln deshalb leicht. Beim nächsten Band besser mit 50 oder 25 Bildern/s aufnehmen.',
                    'Cadence: the converter recorded the 50 Hz tape at 30 fps (steps of 40, 40, 20 ms), so pans judder slightly. For the next tape, record at 50 or 25 fps instead.')
                  : t('Takt: 25 Vollbilder/s mit 30 Bildern/s aufgenommen, jedes sechste Bild ist doppelt.',
                    'Cadence: 25 full frames per second recorded at 30 fps, every sixth frame is doubled.')}
              </p>
            )}
          </div>
        )}

        {analysis && s && (
          <>
            <h3>{t('Schritte', 'Steps')}</h3>
            <div className="restore-steps">
              <div className="vhs-row">
                <span className="vhs-label">{t('Entflechten', 'Deinterlace')}</span>
                <span className="seg">
                  {([
                    ['double', t(`${outFps.toFixed(outFps % 1 ? 2 : 0)} Bilder/s`, `${outFps.toFixed(outFps % 1 ? 2 : 0)} fps`)],
                    ['single', t(`${fps.toFixed(fps % 1 ? 2 : 0)} Bilder/s`, `${fps.toFixed(fps % 1 ? 2 : 0)} fps`)],
                    ['off', t('aus', 'off')],
                  ] as [VhsDeinterlace, string][]).map(([id, label]) => (
                    <button key={id} className={s.deinterlace === id ? 'on' : ''} onClick={() => set('deinterlace', id)}>{label}</button>
                  ))}
                </span>
              </div>
              <p className="hint small vhs-hint">
                {s.deinterlace === 'double'
                  ? t('jedes Halbbild ein Bild: flüssige Bewegung wie auf dem Fernseher', 'every field becomes a frame: smooth motion like on TV')
                  : s.deinterlace === 'single'
                  ? t('halb so viele Bilder: halbe Rechenzeit für die KI, Bewegung etwas ruckeliger', 'half the frames: half the AI time, motion a little choppier')
                  : info && !info.interlaced
                  ? t('Die Datei ist schon progressiv, das Aufnahmegerät hat entflochten.', 'The file is already progressive, the capture device deinterlaced it.')
                  : t('nur für schon progressive Aufnahmen; VHS ist interlaced', 'only for recordings that are already progressive; VHS is interlaced')}
              </p>

              <div className="vhs-row">
                <span className="vhs-label">{t('Ränder abschneiden', 'Crop edges')}</span>
                {(['links', 'oben', 'rechts', 'unten'] as const).map((side, k) => (
                  <label key={side} className="vhs-num">
                    <span className="muted small">{t(side, ['left', 'top', 'right', 'bottom'][k])}</span>
                    <input type="number" min={0} max={cropMax} value={crop[k]}
                      onChange={(e) => {
                        const c = [...crop] as [number, number, number, number]
                        c[k] = Math.max(0, Math.min(cropMax, Number(e.target.value) || 0))
                        set('crop', c)
                      }} />
                  </label>
                ))}
              </div>
              <p className="hint small vhs-hint">
                {t('Unten sitzt bei VHS die Kopfumschalt-Störung (einige Zeilen), seitlich oft ein schwarzer Rand der Aufnahmekarte. Vorgeschlagen aus dem Video; der Kasten im Bild zeigt, was bleibt.',
                  'At the bottom VHS has head-switching noise (a few lines), at the sides often a black border from the capture card. Suggested from the video; the box in the picture shows what stays.')}
              </p>

              <div className="vhs-row">
                <span className="vhs-label">{t('Seitenverhältnis', 'Aspect ratio')}</span>
                <span className="seg">
                  {([
                    ['source', t(`wie Datei (${info?.aspect ?? '?'})`, `as file (${info?.aspect ?? '?'})`)],
                    ['4:3', t('4:3 entzerren', 'correct to 4:3')],
                    ['16:9', '16:9'],
                  ] as [VhsAspect, string][]).map(([id, label]) => (
                    <button key={id} className={(s.aspect === 'auto' ? info?.suggest_aspect ?? 'source' : s.aspect) === id ? 'on' : ''}
                      onClick={() => set('aspect', id)}>{label}</button>
                  ))}
                </span>
                {size && <span className="muted small">{t(`Ergebnis ${size[0]} × ${size[1]}`, `result ${size[0]} × ${size[1]}`)}</span>}
              </div>
              <p className="hint small vhs-hint">
                {info?.stretched
                  ? t('VHS ist fast immer 4:3. Diese 16:9-Datei hat keine Säulen an den Seiten, der Wandler hat das Bild also vermutlich in die Breite gezogen. Am Vorschaubild prüfen: Gesichter und runde Dinge sollen rund aussehen.',
                    'VHS is almost always 4:3. This 16:9 file has no pillars at the sides, so the converter probably stretched the picture. Check the thumbnail: faces and round things should look round.')
                  : t('Das Vorschaubild zeigt das Ergebnis im gewählten Verhältnis.', 'The thumbnail shows the result in the chosen ratio.')}
              </p>

              <div className="vhs-row">
                <span className="vhs-label">{t('Entrauschen', 'Denoise')}</span>
                <span className="seg">
                  {([
                    ['off', t('aus', 'off')], ['light', t('leicht', 'light')],
                    ['medium', t('mittel', 'medium')], ['strong', t('stark', 'strong')],
                  ] as [VhsDenoise, string][]).map(([id, label]) => (
                    <button key={id} className={s.denoise === id ? 'on' : ''} onClick={() => set('denoise', id)}>{label}</button>
                  ))}
                </span>
              </div>
              <p className="hint small vhs-hint">
                {s.denoise === 'light' ? t('zeitlich, stärker in der Farbe; sehr schnell', 'temporal, stronger in the color; very fast')
                  : s.denoise === 'medium' ? t('dazu FFT-Filter; gemessen rund 46 Bilder/s', 'plus an FFT filter; measured about 46 fps')
                  : s.denoise === 'strong' ? t('Non-local Means; rund 18 Bilder/s, für eine Stunde Band etwa 3 h', 'non-local means; about 18 fps, about 3 h for an hour of tape')
                  : t('nichts entrauschen (die KI entrauscht auch selbst)', 'no denoising (the AI denoises by itself too)')}
              </p>

              <div className="vhs-row">
                <span className="vhs-label">{t('Nachschärfen', 'Sharpen')}</span>
                <span className="seg">
                  {([
                    ['off', t('aus', 'off')], ['light', t('leicht', 'light')],
                    ['medium', t('mittel', 'medium')], ['strong', t('stark', 'strong')],
                  ] as [VhsSharpen, string][]).map(([id, label]) => (
                    <button key={id} className={(s.sharpen ?? 'off') === id ? 'on' : ''} onClick={() => set('sharpen', id)}>{label}</button>
                  ))}
                </span>
              </div>
              <p className="hint small vhs-hint">
                {t('Verstärkt vorhandene Kanten, erfindet nichts dazu (anders als die KI, die bei unscharfen Stellen Splitter malen kann). Am echten Band Schärfe im Gesicht: leicht fast doppelt, mittel 2,6-fach, stark 3,8-fach; stark wird etwas körnig.',
                  'Strengthens existing edges, invents nothing (unlike the AI, which can paint shards into blurry areas). On a real tape sharpness in faces: light almost twice, medium 2.6 times, strong 3.8 times; strong gets a little grainy.')}
              </p>

              <div className="vhs-row">
                <span className="vhs-label">{t('Farbe', 'Color')}</span>
                <label className="vhs-num">
                  <span className="muted small">{t('Farbversatz', 'Color shift')}</span>
                  <input type="number" min={-8} max={8} value={s.chroma_shift}
                    onChange={(e) => set('chroma_shift', Math.max(-8, Math.min(8, Number(e.target.value) || 0)))} />
                </label>
                <span className="seg" title={t('Farbflecken mindern', 'Reduce color blotches')}>
                  {([
                    ['off', t('Flecken: aus', 'Blotches: off')], ['clean', t('sauber', 'clean')], ['strong', t('kräftig', 'strong')],
                  ] as [VhsChroma, string][]).map(([id, label]) => (
                    <button key={id} className={chromaOf(s.chroma_denoise) === id ? 'on' : ''} onClick={() => set('chroma_denoise', id)}>{label}</button>
                  ))}
                </span>
                <label className="check" title={info?.blockiness ? t(`Blockkanten gemessen: ${info.blockiness.toFixed(2)}`, `block edges measured: ${info.blockiness.toFixed(2)}`) : ''}>
                  <input type="checkbox" checked={!!s.deblock} onChange={(e) => set('deblock', e.target.checked)} />
                  {t('Blockkanten glätten', 'Smooth block edges')}
                </label>
                <label className="check">
                  <input type="checkbox" checked={s.levels} onChange={(e) => set('levels', e.target.checked)} />
                  {t('Pegel automatisch', 'Auto levels')}
                </label>
                <label className="check">
                  <input type="checkbox" checked={s.deflicker} onChange={(e) => set('deflicker', e.target.checked)} />
                  {t('Flackern mindern', 'Reduce flicker')}
                </label>
              </div>
              <p className="hint small vhs-hint">
                {chromaOf(s.chroma_denoise) === 'strong' && t('Farbflecken kräftig: der Filter vom ersten Test, glättet die Farbe über 15 Bilder stärker und gleichmäßiger; bei Bewegung kann die Farbe etwas nachziehen. ', 'Color blotches strong: the filter of the first test, smooths the color over 15 frames more strongly and evenly; with motion the color can trail a little. ')}
                {chromaOf(s.chroma_denoise) === 'clean' && t('Farbflecken: VHS zeichnet die Farbe grob und verrauscht auf. Geglättet wird nur die Farbe, über die Zeit nur dort, wo das Bild ruht (so zieht nichts nach), und an die Kanten der Helligkeit gelegt (gegen Ausbluten und Säume). Am echten Band Farbunruhe 1,27 → 0,18, rund 35 Bilder/s. ',
                  'Color blotches: VHS records color coarse and noisy. Only the color is smoothed, over time only where the picture is still (so nothing trails) and aligned to the brightness edges (against bleeding and fringes). On a real tape color unrest 1.27 → 0.18, about 35 fps. ')}
                {s.deblock && t('Blockkanten: glättet die 8-Pixel-Kanten der Kompression, bevor geschärft oder vergrößert wird. ', 'Block edges: smooths the 8-pixel edges of the compression before anything is sharpened or enlarged. ')}
                {t('Farbversatz: Die Farbe liegt bei VHS oft ein paar Pixel neben dem Bild; negative Werte schieben sie nach links.',
                  'Color shift: on VHS the color often sits a few pixels next to the picture; negative values move it to the left.')}
              </p>

              <label className="check">
                <input type="checkbox" checked={s.stabilize} onChange={(e) => set('stabilize', e.target.checked)} />
                {t('Stabilisieren', 'Stabilize')}{' '}
                <span className="muted small">{t('(Verwackeln aus der Hand mindern, rund 90 Bilder/s)', '(reduce handheld shake, about 90 fps)')}</span>
              </label>

              {canSmooth && (
                <>
                  <label className="check" title={rife?.installed ? '' : t('Braucht RIFE 4.26', 'Needs RIFE 4.26')}>
                    <input type="checkbox" checked={s.smooth && !!rife?.installed} disabled={!rife?.installed}
                      onChange={(e) => set('smooth', e.target.checked)} />
                    {t('Takt glätten (50 Bilder/s)', 'Smooth cadence (50 fps)')}{' '}
                    <span className="muted small">(RIFE)</span>
                  </label>
                  {!rife?.installed && rife && (
                    <div className="restore-sub">
                      <button className="btn small" onClick={() => downloads.start(rife.id).catch((e) => setError(String(e)))}>
                        {t(`⬇ RIFE laden (${Math.round(rife.size_gb * 1000)} MB)`, `⬇ Download RIFE (${Math.round(rife.size_gb * 1000)} MB)`)}
                      </button>
                    </div>
                  )}
                  <p className="hint small vhs-hint">
                    {t('Das Aufnahmegerät hat das 50-Hz-Band mit 30 Bildern/s aufgenommen, die Bilder liegen 40, 40 und 20 ms auseinander. RIFE rechnet die fehlenden Zwischenbilder, so entstehen wieder gleichmäßige 50 Bilder/s, drei von fünf sind echte Bilder. Läuft auf der Grafikkarte, ohne KI rund 0,3 s je Bild (33 min Band etwa 5 h).',
                      'The capture device recorded the 50 Hz tape at 30 fps, frames are 40, 40 and 20 ms apart. RIFE computes the missing in-between frames, giving even 50 fps again, three of five are real frames. Runs on the GPU, without AI about 0.3 s per frame (33 min of tape about 5 h).')}
                  </p>
                </>
              )}

              <label className="check" title={installedUpscaler ? '' : t('Braucht SeedVR2', 'Needs SeedVR2')}>
                <input type="checkbox" checked={s.ai && !!installedUpscaler} disabled={!installedUpscaler}
                  onChange={(e) => set('ai', e.target.checked)} />
                {t('Mit KI aufbessern', 'Enhance with AI')}{' '}
                <span className="muted small">(SeedVR2)</span>
              </label>
              {s.ai && installedUpscaler && (
                <div className="restore-sub">
                  <span className="seg">
                    {([['720', '720p'], ['1080', '1080p'], ['original', t('Originalgröße', 'Original size')]] as [VhsAiSize, string][])
                      .map(([id, label]) => (
                        <button key={id} className={s.ai_size === id ? 'on' : ''} onClick={() => set('ai_size', id)}>{label}</button>
                      ))}
                  </span>
                  <span className="muted small">
                    {t(`rund ${AI_SECONDS_PER_FRAME[s.ai_size]} s je Bild`, `about ${AI_SECONDS_PER_FRAME[s.ai_size]} s per frame`)}
                  </span>
                </div>
              )}
              {!installedUpscaler && seedvr2 && (
                <div className="restore-sub">
                  <button className="btn small" onClick={() => downloads.start(seedvr2.id).catch((e) => setError(String(e)))}>
                    {t(`⬇ SeedVR2 laden (${seedvr2.size_gb} GB) für die KI`, `⬇ Download SeedVR2 (${seedvr2.size_gb} GB) for the AI`)}
                  </button>
                  <button className="btn small ghost" onClick={onShowModels}>{t('Modelle', 'Models')}</button>
                </div>
              )}

              {info?.audio && (
                <div className="vhs-row">
                  <span className="vhs-label">{t('Ton', 'Sound')}</span>
                  <label className="check">
                    <input type="checkbox" checked={s.audio_denoise} onChange={(e) => set('audio_denoise', e.target.checked)} />
                    {t('Bandrauschen mindern', 'Reduce tape hiss')}
                  </label>
                  <label className="check">
                    <input type="checkbox" checked={s.loudnorm} onChange={(e) => set('loudnorm', e.target.checked)} />
                    {t('Lautheit angleichen', 'Even out loudness')}
                  </label>
                </div>
              )}
            </div>

            <h3>{t('Ausprobieren und aufwerten', 'Try out and enhance')}</h3>
            <div className="vhs-row">
              <label className="vhs-num">
                <span className="muted small">{t('Vorschau ab', 'Preview from')}</span>
                <input type="number" min={0} max={Math.max(0, Math.floor(seconds - 1))} step={1} value={start}
                  onChange={(e) => setStart(Math.max(0, Number(e.target.value) || 0))} />
                <span className="muted small">s</span>
              </label>
              <button className="btn" disabled={!!jobId} onClick={() => run(true)}>
                {t(`Vorschau ${PREVIEW_SECONDS} s`, `${PREVIEW_SECONDS} s preview`)}
              </button>
              {estPreview && <span className="muted small">≈ {fmtDuration(estPreview.classic + estPreview.ai + 10)}</span>}
            </div>
            <div className="vhs-row">
              <button className="btn primary" disabled={!!jobId} onClick={() => run(false)}>
                {t('Ganzes Video aufwerten', 'Enhance the whole video')}
              </button>
              {est && (
                <span className={est.ai > 6 * 3600 ? 'small warn-text' : 'muted small'}>
                  {t(`geschätzt ${fmtDuration(est.classic + est.ai)}`, `estimated ${fmtDuration(est.classic + est.ai)}`)}
                  {est.ai > 6 * 3600 && t(' · mit KI lange: erst die Vorschau prüfen, oder nur die besten Stellen',
                    ' · long with AI: check the preview first, or do only the best parts')}
                </span>
              )}
            </div>
          </>
        )}
        <Recommendations mode="vhs" />
      </section>

      <section className="panel output">
        {jobId && (
          <div className="progress-wrap">
            <div className="progress"><div className="bar" style={{ width: `${Math.round(progress * 100)}%` }} /></div>
            <div className="muted small progress-line">
              <span>{stage} · {Math.round(progress * 100)} %</span>
              <button className="btn small ghost danger-text" onClick={cancel}>{t('Abbrechen', 'Cancel')}</button>
            </div>
          </div>
        )}
        {error && <div className="error">{error}</div>}
        {results.length > 0 ? (
          <div className="stack">
            {results.map((r) => (
              <figure key={r.id} className="card result">
                {typeof r.meta.vhs_before === 'string' ? (
                  <Compare before={fileUrl(r.meta.vhs_before)} after={r.url} />
                ) : (
                  <video src={r.url} controls preload="metadata" className="vhs-single" />
                )}
                <figcaption className="muted small">
                  {r.prompt}
                  {' · '}{r.meta.width} × {r.meta.height} · {fmtClock(r.meta.seconds)}
                  {r.meta.preview_clip ? t(' · Vorschau', ' · preview') : ''}
                  {typeof r.meta.seconds_taken === 'number' ? t(` · gerechnet in ${fmtDuration(r.meta.seconds_taken)}`, ` · took ${fmtDuration(r.meta.seconds_taken)}`) : ''}
                  {' · '}<a href={r.url} download>Download</a>
                </figcaption>
              </figure>
            ))}
          </div>
        ) : (
          !jobId && <div className="placeholder">{t('Vorschau und Ergebnisse erscheinen hier.', 'Previews and results appear here.')}</div>
        )}
      </section>
    </div>
  )
}
