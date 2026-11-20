import { useEffect, useRef, useState } from 'react'
import { api, type AudioMarker, type AudioProject, type AudioTrack, type TranscriptDoc } from '../api'
import { fmtClock } from '../audio/Timeline'
import { getLang, t } from '../i18n'
import { isReview } from '../review/mode'
import { logEntry, reviewPackage } from '../review/local'
import { saveFile, saveText } from '../review/save'
import { srtForVideo, videoWithSound } from '../review/videoexport'
import { exportWav } from '../review/wav'
import { clockAt } from './Lanes'
import { exportNotes } from './Notes'
import { exportTranscript } from './Transcript'

// Export der Ton-Forensik (Nutzer 17.11.: „oben ein Export button um audio zu exportieren mit ausgewählten spuren …
// erkannte und übersetzte sprache exportieren“ und „video zu exportieren mit ausgewählten spuren (die visualisierung
// wie ich es sehe unten) und angekreuzten einzeln mitlesen, radar … ereignisse, über die ausgewählten spuren läuft der
// vertikale zeit marker und die zeitstempel sind zu sehen“). Derselbe Inhalt im Fenster (Knopf oben) und im Reiter.

/** Zeit eintippen: „hh:mm:ss(.s)“, „mm:ss“ oder Sekunden. Mit Zeitbezug (Schiffsschreiber) ist es Uhrzeit UTC am Tag
 * der Aufnahme; „+…“ zählt immer ab Beginn der Aufnahme. */
export function parseClock(text: string, origin: number | null | undefined, duration: number): number | null {
  const s = text.trim().replace(',', '.')
  if (!s) return null
  const rel = s.startsWith('+')
  const parts = s.replace(/^\+/, '').split(':').map((x) => Number(x))
  if (parts.some((x) => !Number.isFinite(x)) || parts.length > 3) return null
  const secs = parts.reduce((acc, x) => acc * 60 + x, 0)
  if (rel || !origin || parts.length === 1) return Math.max(0, Math.min(duration, secs))
  const day = Math.floor(origin / 86400) * 86400
  let x = day + secs - origin
  if (x < -3600) x += 86400
  return Math.max(0, Math.min(duration, x))
}

type Section = 'audio' | 'video' | 'picture' | 'speech' | 'notes' | 'package' | 'wav'
export type ExportSection = Section

/** Größe des Lagebild-Videos: gemessen 8,6 MB je Minute (1080p, 10 Bilder/s, Radarbild, NVENC; 17.11.) */
function fmtSize(seconds: number): string {
  const mb = (seconds / 60) * 8.6
  return mb >= 1000 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.max(1, Math.round(mb))} MB`
}

export function ExportPanel({ proj, tracks, doc, markers, selection, view, lanesView, imageSources, spec, busy, onError, onNotice, onReload, compact, initial, onBusy }: {
  proj: AudioProject
  tracks: AudioTrack[]
  doc: TranscriptDoc
  markers: AudioMarker[]
  selection: [number, number] | null
  /** sichtbarer Ausschnitt des Zeitstrahls */
  view: [number, number]
  /** Darstellung je Spur im Zeitstrahl (Welle/Spektrogramm) */
  lanesView: Record<string, string>
  /** Bildquellen des Schiffsschreibers (Radar, ECDIS …) */
  imageSources: { id: string; label: string; count: number }[]
  /** Spektrogramm-Fenster wie im Zeitstrahl */
  spec: { lo: number; hi: number; fmax: number }
  busy: (kind: string) => boolean
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
  compact?: boolean
  /** Abschnitt beim Öffnen (z. B. „video“ aus dem Videoabgleich) */
  initial?: Section
  /** Prüf-App: ein Export läuft im Browser (der Dialog bleibt dann offen) */
  onBusy?: (busy: boolean) => void
}) {
  const origin = proj.time_origin
  const duration = proj.duration ?? 0
  const isVdr = proj.source.kind === 'vdr'
  const anySolo = tracks.some((x) => x.solo)
  const audibleIds = tracks.filter((x) => (anySolo ? x.solo : !x.mute)).map((x) => x.id)
  const review = isReview()
  const [sec, setSec] = useState<Section>(initial ?? (review ? 'wav' : 'audio'))
  const [chosen, setChosen] = useState<string[]>(audibleIds)
  const [range, setRange] = useState<'all' | 'selection' | 'view' | 'custom'>(selection ? 'selection' : 'all')
  const [from, setFrom] = useState(selection ? clockAt(selection[0], origin, true) : '')
  const [to, setTo] = useState(selection ? clockAt(selection[1], origin, true) : '')
  const [fmt, setFmt] = useState('wav')
  const [mono, setMono] = useState(false)
  const [name, setName] = useState('')
  const [subs, setSubs] = useState<'none' | 'original' | 'translation'>(doc.segments.length ? 'translation' : 'none')
  // Untertitel ins Bild einbrennen (Nutzer 20.11.2026: „die untertitel werden nicht in das video eingebaut“); ohne Haken
  // bleibt das Bild bytegleich und die Untertitel liegen als SRT daneben
  const [burn, setBurn] = useState(true)
  const burnNow = burn && subs !== 'none'
  const [checkedOnly, setCheckedOnly] = useState(false)
  const [panels, setPanels] = useState<string[]>(() => ['tracks', 'text', ...(imageSources[0] ? [`img:${imageSources[0].id}`] : []), ...(isVdr ? ['conning'] : [])])
  // Was sich zeigen lässt: Spuren, Mitlesen, je Bildquelle ein Kästchen, Fahrstand, Karte, Ereignisse, Live-Player-Bild
  const panelChoices: [string, string][] = [
    ['tracks', t('Spuren mit Zeitmarker (wie im Zeitstrahl)', 'Tracks with time marker (as in the timeline)')],
    ['text', t('Mitlesen (Original und Übersetzung)', 'Read along (original and translation)')],
    ...imageSources.map((x) => [`img:${x.id}`, `${x.label} (${x.count} ${t('Bilder', 'pictures')})`] as [string, string]),
    ...(isVdr ? [['conning', t('Fahrstand', 'Conning')], ['map', t('Karte', 'Map')]] as [string, string][] : []),
    ['events', t('Ereignisse', 'Events')],
    ...(proj.video ? [['video', t('Live-Player-Bild (zugeordnetes Video)', 'Live Player picture (linked video)')]] as [string, string][] : []),
  ]
  const upper = panels.filter((x) => x !== 'tracks' && panelChoices.some(([k]) => k === x)).length
  const [fps, setFps] = useState(10)
  // Speicherort (Nutzer 18.11.: „ich sollte auch auswählen können wohin ich die audio oder video files speichere“):
  // Verlauf oder ein Ordner auf diesem Rechner; der zuletzt gewählte Ordner bleibt gemerkt
  const DEST_KEY = 'nvai.forensic.exportDir'
  const [destDir, setDestDir] = useState(() => { try { return localStorage.getItem(DEST_KEY) ?? '' } catch { return '' } })
  const [toFolder, setToFolder] = useState(() => !!destDir)
  const rememberDir = (d: string) => { setDestDir(d); try { if (d.trim()) localStorage.setItem(DEST_KEY, d.trim()) } catch { /* ohne Speicher */ } }
  const dest = toFolder && destDir.trim() ? destDir.trim() : null
  const destMissing = toFolder && !destDir.trim()
  const where = dest ? t(`nach ${dest}`, `to ${dest}`) : t('in den Verlauf', 'into the History')
  const destPick = (
    <div className="fx-exp-dest">
      <span className="small">{t('Speichern in', 'Save to')}</span>
      <label className="check small"><input type="radio" checked={!toFolder} onChange={() => setToFolder(false)} />{t('Verlauf', 'History')}</label>
      <label className="check small"><input type="radio" checked={toFolder} onChange={() => setToFolder(true)} />{t('Ordner', 'Folder')}</label>
      {toFolder && (
        <>
          <input className="au-path" value={destDir} onChange={(e) => rememberDir(e.target.value)} placeholder={t('Ordner auf diesem Rechner', 'Folder on this computer')} />
          <button className="btn small" onClick={() => api.browseFolder(destDir).then((r) => { if (r.path) rememberDir(r.path) }).catch((e) => onError(String(e.message ?? e)))}>
            {t('Ordner wählen …', 'Choose folder …')}</button>
        </>
      )}
    </div>
  )
  const region: [number, number] | null = range === 'selection' && selection ? selection
    : range === 'view' ? view
      : range === 'custom' ? (() => {
        const a = parseClock(from, origin, duration)
        const b = parseClock(to, origin, duration)
        return a != null && b != null && b > a ? [a, b] : null
      })() : null
  const len = region ? region[1] - region[0] : duration
  const tr = (id: string) => tracks.find((x) => x.id === id)
  const chosenTracks = chosen.map(tr).filter(Boolean) as AudioTrack[]
  const sizeMb = (() => {
    const per = fmt === 'wav' ? 2 * 48000 : fmt === 'flac' ? 1.2 * 48000 : fmt === 'mp3' ? 24000 : 32000
    return Math.round((len * per * (mono || fmt === 'mp3' ? 1 : 2)) / 1024 ** 2)
  })()
  const trackPick = (
    <div className="fx-exp-tracks">
      {tracks.map((x) => (
        <label key={x.id} className="check small"><input type="checkbox" checked={chosen.includes(x.id)}
          onChange={(e) => setChosen(e.target.checked ? [...chosen, x.id] : chosen.filter((y) => y !== x.id))} />
          <span className="au-swatch" style={{ background: x.color }} />{x.name}{x.gain_db ? <span className="muted small"> {x.gain_db > 0 ? '+' : ''}{x.gain_db.toFixed(1)} dB</span> : null}</label>
      ))}
      <span className="lt-toolbar">
        <button className="linklike small" onClick={() => setChosen(tracks.map((x) => x.id))}>{t('alle', 'all')}</button>
        <button className="linklike small" onClick={() => setChosen(audibleIds)}>{t('wie zu hören', 'as audible')}</button>
        <button className="linklike small" onClick={() => setChosen([])}>{t('keine', 'none')}</button>
      </span>
    </div>
  )
  const rangePick = (
    <div className="fx-exp-range">
      <label className="check small"><input type="radio" checked={range === 'all'} onChange={() => setRange('all')} />{t(`ganze Aufnahme (${fmtClock(duration)})`, `whole recording (${fmtClock(duration)})`)}</label>
      <label className="check small"><input type="radio" checked={range === 'selection'} disabled={!selection} onChange={() => setRange('selection')} />
        {selection ? t(`Auswahl ${clockAt(selection[0], origin)} – ${clockAt(selection[1], origin)}`, `selection ${clockAt(selection[0], origin)} – ${clockAt(selection[1], origin)}`) : t('Auswahl (erst im Zeitstrahl ziehen)', 'selection (drag in the timeline first)')}</label>
      <label className="check small"><input type="radio" checked={range === 'view'} onChange={() => setRange('view')} />{t(`sichtbarer Ausschnitt ${clockAt(view[0], origin)} – ${clockAt(view[1], origin)}`, `visible part ${clockAt(view[0], origin)} – ${clockAt(view[1], origin)}`)}</label>
      <label className="check small"><input type="radio" checked={range === 'custom'} onChange={() => setRange('custom')} />{t('von', 'from')}
        <input className="fx-timein" value={from} onChange={(e) => { setFrom(e.target.value); setRange('custom') }} placeholder={origin ? 'hh:mm:ss UTC' : 'h:mm:ss'} />
        {t('bis', 'to')}<input className="fx-timein" value={to} onChange={(e) => { setTo(e.target.value); setRange('custom') }} placeholder={origin ? 'hh:mm:ss UTC' : 'h:mm:ss'} /></label>
      {range === 'custom' && !region && <span className="hint small warn">{t('Zeiten prüfen', 'check the times')}</span>}
    </div>
  )
  const pkg = review ? reviewPackage() : null
  const sections: [Section, string][] = review ? [
    ['wav', t('Ton (WAV)', 'Audio (WAV)')],
    ...((pkg?.manifest.video && proj.video) ? [['video', t('Video mit Ton', 'Video with sound')] as [Section, string]] : []),
    ['speech', t('Sprache', 'Speech')],
    ['notes', t('Notizen', 'Notes')],
  ] : [
    ['audio', t('Ton', 'Audio')],
    ...((proj.video || proj.source.has_video) ? [['video', t('Video mit Ton', 'Video with sound')] as [Section, string]] : []),
    ['picture', t('Lagebild-Video', 'Situation video')],
    ['speech', t('Sprache', 'Speech')],
    ['notes', t('Notizen', 'Notes')],
    ['package', t('Prüfpaket', 'Review package')],
  ]
  // Prüf-App: WAV aus dem Originalton im Paket (bitgenau bei einer Spur ohne Pegeländerung)
  const originals = pkg?.manifest.originals ?? {}
  const [wavBusy, setWavBusy] = useState<number | null>(null)
  const wavTracks = chosenTracks.filter((x) => originals[x.id])
  const runWav = async () => {
    if (!pkg) return
    const a = region ? region[0] : 0
    const b = region ? region[1] : duration
    const files = await Promise.all(wavTracks.map(async (x) => ({ name: x.name, file: await pkg.source.lazy(`fall/original/${originals[x.id].file}`), gainDb: x.gain_db || 0 })))
    if (files.some((f) => !f.file)) throw new Error(t('Originalton fehlt im Paket.', 'Original audio missing in the package.'))
    setWavBusy(0)
    try {
      const base = (name || `${proj.name} ${clockAt(a, origin)}-${clockAt(b, origin)}`).replace(/[<>:"/\\|?*]+/g, '_')
      const r = await exportWav(files as { name: string; file: Blob; gainDb: number }[], a, b, mono, `${base}.wav`, (f) => setWavBusy(f))
      await logEntry(pkg, 'export_wav', { spuren: wavTracks.map((x) => x.id), von: a, bis: b, bitgenau: r.exact, bytes: r.bytes })
      onNotice(r.exact ? t('WAV gespeichert, bitgenau aus dem Original.', 'WAV saved, bit-exact from the original.')
        : t('WAV gespeichert, verlustfrei gemischt (32 Bit).', 'WAV saved, mixed losslessly (32 bit).'))
    } finally {
      setWavBusy(null)
    }
  }
  // Prüf-App: Video mit Ton im Browser (Bild unverändert, Ton aus dem Originalton über die Zuordnung, AAC)
  const [vBusy, setVBusy] = useState<number | null>(null)
  const vAbort = useRef<AbortController | null>(null)
  const [srtReady, setSrtReady] = useState<{ text: string; name: string; cues: number } | null>(null)
  useEffect(() => { onBusy?.(wavBusy !== null || vBusy !== null) }, [wavBusy, vBusy]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => vAbort.current?.abort(), [])
  const runVideo = async () => {
    const fit = proj.video?.fit
    if (!pkg || !fit || !pkg.manifest.video) return
    const a = region ? region[0] : 0
    const b = region ? region[1] : duration
    // lazy: ein Ordner liefert File, die Mac-App eine Datei ihres Servers, die erst beim Lesen eines Ausschnitts geholt wird
    const video = await pkg.source.lazy(`fall/video/${pkg.manifest.video}`) as Blob | null
    const files = await Promise.all(wavTracks.map(async (x) => ({ file: await pkg.source.lazy(`fall/original/${originals[x.id].file}`), gainDb: x.gain_db || 0 })))
    if (!video) throw new Error(t('Das Video fehlt im Paket.', 'The video is missing in the package.'))
    if (files.some((f) => !f.file)) throw new Error(t('Originalton fehlt im Paket.', 'Original audio missing in the package.'))
    const base = (name || `${proj.name} ${clockAt(a, origin)}-${clockAt(b, origin)} ${t('mit Ton', 'with sound')}`).replace(/[<>:"/\\|?*]+/g, '_')
    const out = await saveFile(`${base}.mp4`, 'MP4', 'video/mp4', '.mp4')
    const ctl = new AbortController()
    vAbort.current = ctl
    setVBusy(0)
    setSrtReady(null)
    try {
      const r = await videoWithSound({ video, fit, tracks: files as { file: Blob; gainDb: number }[], region: [a, b], mono, sink: out, progress: (f) => setVBusy(f), signal: ctl.signal,
        burn: burnNow ? { segments: doc.segments, mode: subs, lang: doc.target_lang || 'de' } : undefined })
      await out.close()
      await logEntry(pkg, 'export_video', { datei: out.name, spuren: wavTracks.map((x) => x.id), von: a, bis: b, video_start: r.videoStart, video_ende: r.videoEnd,
        aufnahme_start: r.recordStart, bilder: r.packets, spitze: r.peak, bytes: r.bytes, vorlauf: r.priming, untertitel: subs,
        eingebrannt: r.burned ? { kodierer: r.burned } : null })
      if (subs !== 'none') {
        const s = srtForVideo(doc.segments, subs, doc.target_lang || 'de', fit, r.videoStart, r.videoEnd)
        setSrtReady({ ...s, name: `${base}.srt` })
      }
      onNotice(r.burned
        ? t(`Video gespeichert: ${out.name} (${(r.bytes / 1024 ** 2).toFixed(0)} MB, Untertitel eingebrannt, ab ${clockAt(r.recordStart, origin)}).`,
          `Video saved: ${out.name} (${(r.bytes / 1024 ** 2).toFixed(0)} MB, subtitles burned in, from ${clockAt(r.recordStart, origin)}).`)
        : t(`Video gespeichert: ${out.name} (${(r.bytes / 1024 ** 2).toFixed(0)} MB, Bild unverändert ab ${clockAt(r.recordStart, origin)}).`,
          `Video saved: ${out.name} (${(r.bytes / 1024 ** 2).toFixed(0)} MB, picture unchanged from ${clockAt(r.recordStart, origin)}).`))
    } catch (e) {
      await out.abort().catch(() => undefined)
      throw e
    } finally {
      setVBusy(null)
      vAbort.current = null
    }
  }
  // NVAI-open: Prüfpaket
  const [est, setEst] = useState<Awaited<ReturnType<typeof api.audioPackageEstimate>> | null>(null)
  const [pkgImages, setPkgImages] = useState(true)
  const [pkgVideo, setPkgVideo] = useState(false)
  const [pkgOrig, setPkgOrig] = useState<string[]>([])
  const gb = (bytes: number) => `${(bytes / 1024 ** 3).toLocaleString(undefined, { maximumFractionDigits: 1 })} GB`
  const pkgSize = est ? est.base + (pkgImages ? est.images : 0) + (pkgVideo ? est.video : 0) + pkgOrig.reduce((s, id) => s + (est.originals[id] ?? 0), 0) : 0
  return (
    <div className={`fx-export${compact ? ' compact' : ''}`}>
      <div className="lr-tabs">
        {sections.map(([k, l]) => <button key={k} className={`lr-tab${sec === k ? ' on' : ''}`} onClick={() => setSec(k)}>{l}</button>)}
      </div>
      {sec === 'audio' && (
        <div className="au-tool">
          <h4>{t('Spuren', 'Tracks')}</h4>
          {trackPick}
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <div className="lt-toolbar">
            <select value={fmt} onChange={(e) => setFmt(e.target.value)}>
              <option value="wav">WAV (16 bit)</option><option value="flac">FLAC (24 bit)</option>
              <option value="mp3">MP3 192 kbit/s</option><option value="m4a">M4A (AAC)</option>
            </select>
            <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('mono', 'mono')}</label>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Dateiname (optional)', 'file name (optional)')} />
            <span className="muted small">{t(`rund ${sizeMb} MB`, `about ${sizeMb} MB`)}</span>
          </div>
          <p className="hint small">{t('Gemischt werden die angekreuzten Spuren mit ihrem Pegel aus dem Zeitstrahl. Der Export steht mit Pfad im Protokoll.', 'The ticked tracks are mixed at their timeline level. The export is listed with its path in the log.')}</p>
          {destPick}
          <button className="btn primary" disabled={!chosen.length || busy('audio_export') || (range === 'custom' && !region) || destMissing}
            onClick={() => api.audioExport(proj.id, { tracks: chosenTracks.map((x) => ({ id: x.id, gain_db: x.gain_db })), format: fmt, into_video: false, name, mono, region, dest_dir: dest })
              .then(() => { onNotice(t(`Ton wird exportiert, ${where}; er steht danach im Protokoll.`, `Exporting the audio ${where}; it is then listed in the log.`)); onReload() })
              .catch((e) => onError(String(e.message ?? e)))}>{t(`Ton exportieren (${fmtClock(len)})`, `Export audio (${fmtClock(len)})`)}</button>
        </div>
      )}
      {sec === 'video' && !review && (
        <div className="au-tool">
          <p className="hint small">{t('Das zugeordnete Video (z. B. die Live-Player-Aufnahme) mit neuem Ton aus den angekreuzten Spuren. Untertitel kommen als SRT daneben; „ins Bild einbrennen“ schreibt sie fest ins Video, dann zeigt sie jeder Player, und das Bild wird dafür neu kodiert. Ohne Einbrennen bleibt das Bild unverändert.',
            'The linked video (e.g. the Live Player recording) with new sound from the ticked tracks. Subtitles come as an SRT next to it; “burn into the picture” writes them into the video itself, so every player shows them, and the picture is re-encoded for that. Without burning in, the picture stays unchanged.')}</p>
          {!proj.video && <p className="hint small warn">{t('Erst ein Video zuordnen (Reiter „Videoabgleich“ rechts).', 'Link a video first (“Video sync” tab on the right).')}</p>}
          <h4>{t('Spuren', 'Tracks')}</h4>
          {trackPick}
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <div className="lt-toolbar">
            <select value={subs} onChange={(e) => setSubs(e.target.value as 'none' | 'original' | 'translation')}>
              <option value="none">{t('ohne Untertitel', 'no subtitles')}</option>
              <option value="original">{t('Untertitel: Original', 'subtitles: original')}</option>
              <option value="translation">{t('Untertitel: Übersetzung', 'subtitles: translation')}</option>
            </select>
            {subs !== 'none' && <label className="check small" title={t('Fest im Bild, in jedem Player sichtbar; das Bild wird neu kodiert. Die SRT kommt trotzdem daneben.', 'Fixed in the picture, visible in every player; the picture is re-encoded. The SRT still comes next to it.')}>
              <input type="checkbox" checked={burn} onChange={(e) => setBurn(e.target.checked)} />{t('ins Bild einbrennen', 'burn into the picture')}</label>}
            <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('Ton mono', 'mono sound')}</label>
          </div>
          {destPick}
          <button className="btn primary" disabled={!proj.video || !chosen.length || busy('audio_vexport') || destMissing}
            onClick={() => api.audioVideoExport(proj.id, { tracks: chosenTracks.map((x) => ({ id: x.id, gain_db: x.gain_db })), region, subtitles: subs, burn: burnNow, mono, dest_dir: dest })
              .then(() => { onNotice(t(`Video wird exportiert, ${where}.`, `Exporting the video ${where}.`)); onReload() })
              .catch((e) => onError(String(e.message ?? e)))}>{t('Video mit Ton exportieren', 'Export video with sound')}</button>
        </div>
      )}
      {sec === 'picture' && (
        <div className="au-tool">
          <p className="hint small">{t('Ein neues Video aus dem, was du hier siehst: oben die angekreuzten Ansichten, unten die gewählten Spuren, über die der Zeitmarker läuft, mit Uhrzeit. Ton aus den angekreuzten Spuren. Gut für die Prüfung einzelner Abschnitte.',
            'A new video of what you see here: the ticked views at the top, the chosen tracks below with the moving time marker and the clock. Sound from the ticked tracks. Good for reviewing single sections.')}</p>
          <h4>{t('Zu sehen', 'Visible')}</h4>
          <div className="fx-exp-tracks">
            {panelChoices.map(([k, label]) => (
              <label key={k} className="check small"><input type="checkbox" checked={panels.includes(k)}
                onChange={(e) => setPanels(e.target.checked ? [...panels, k] : panels.filter((x) => x !== k))} />{label}</label>
            ))}
          </div>
          {upper > 4 && <p className="hint small warn">{t(`${upper} Ansichten nebeneinander werden schmal; drei oder vier sind gut lesbar.`, `${upper} views side by side get narrow; three or four read well.`)}</p>}
          <h4>{t('Spuren (Bild und Ton)', 'Tracks (picture and sound)')}</h4>
          {trackPick}
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <div className="lt-toolbar">
            <label className="lr-inline small">{t('Bilder je Sekunde', 'Frames per second')}
              <select value={fps} onChange={(e) => setFps(Number(e.target.value))}>
                <option value={5}>5</option><option value={10}>10</option><option value={25}>25</option>
              </select></label>
            <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('Ton mono', 'mono sound')}</label>
            <span className="muted small">{t(`${fmtClock(len)} Video, 1920 × 1080, rund ${fmtSize(len)}, Rechenzeit rund ${fmtClock(len / 5)}`, `${fmtClock(len)} of video, 1920 × 1080, about ${fmtSize(len)}, computing time about ${fmtClock(len / 5)}`)}</span>
          </div>
          {len > 3600 && <p className="hint small warn">{t('Gemessen: rund 2 min Rechenzeit je 10 min Video, mit Live-Player-Bild länger. Für die Prüfung besser Abschnitte wählen.', 'Measured: about 2 min of computing per 10 min of video, longer with the Live Player picture. Better choose sections for review.')}</p>}
          {destPick}
          <button className="btn primary" disabled={!panels.length || busy('audio_render') || (range === 'custom' && !region) || destMissing}
            onClick={() => api.audioRenderVideo(proj.id, { panels: panels.filter((x) => panelChoices.some(([k]) => k === x)), tracks: chosenTracks.map((x) => ({ id: x.id, gain_db: x.gain_db, view: lanesView[x.id] ?? 'wave' })), region, fps, mono, lang: getLang(), spec, dest_dir: dest })
              .then(() => { onNotice(t(`Lagebild-Video wird gerechnet, ${where}.`, `Rendering the situation video ${where}.`)); onReload() })
              .catch((e) => onError(String(e.message ?? e)))}>{t('Lagebild-Video exportieren', 'Export situation video')}</button>
        </div>
      )}
      {sec === 'wav' && (
        <div className="au-tool">
          <p className="hint small">{t('Ton aus dem Originalton im Paket. Eine einzelne Spur ohne Pegeländerung wird bitgenau übernommen, mehrere Spuren werden verlustfrei gemischt (32 Bit). Gespeichert wird über „Speichern unter“.',
            'Audio from the original audio in the package. A single track without level change is copied bit-exactly, several tracks are mixed losslessly (32 bit). Saved via “Save as”.')}</p>
          {Object.keys(originals).length === 0 && <p className="hint small warn">{t('Dieses Paket enthält keinen Originalton; beim Exportieren des Prüfpakets in NVAI-open „Originalton als WAV“ für die gewünschten Spuren ankreuzen.',
            'This package contains no original audio; when exporting the review package in NVAI-open, tick “original audio as WAV” for the tracks you need.')}</p>}
          <h4>{t('Spuren', 'Tracks')}</h4>
          {trackPick}
          {chosenTracks.some((x) => !originals[x.id]) && <p className="muted small">{t('Ohne Originalton im Paket (werden übergangen): ', 'Without original audio in the package (skipped): ')}{chosenTracks.filter((x) => !originals[x.id]).map((x) => x.name).join(', ')}</p>}
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <div className="lt-toolbar">
            <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('mono', 'mono')}</label>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Dateiname (optional)', 'file name (optional)')} />
          </div>
          <button className="btn primary" disabled={!wavTracks.length || wavBusy !== null || (range === 'custom' && !region)}
            onClick={() => { runWav().catch((e) => { if ((e as DOMException)?.name !== 'AbortError') onError(String((e as Error).message ?? e)) }) }}>
            {wavBusy !== null ? t(`Speichert … ${Math.round(wavBusy * 100)} %`, `Saving … ${Math.round(wavBusy * 100)} %`) : t(`WAV speichern (${fmtClock(len)}) …`, `Save WAV (${fmtClock(len)}) …`)}</button>
        </div>
      )}
      {sec === 'video' && review && (
        <div className="au-tool">
          <p className="hint small">{t('Das Video aus dem Paket mit neuem Ton aus dem Originalton der angekreuzten Spuren; der Ton liegt über die Zuordnung zeitgenau darauf (AAC). „Ins Bild einbrennen“ schreibt die Untertitel fest ins Video, dann zeigt sie jeder Player, und das Bild wird dafür neu kodiert. Ohne Einbrennen bleibt das Bild unverändert (ab dem Schlüsselbild vor dem Anfang). Gespeichert wird über „Speichern unter“, die Untertitel danach auch als SRT daneben.',
            'The video from the package with new sound from the original audio of the ticked tracks; the sound is placed exactly via the sync (AAC). “Burn into the picture” writes the subtitles into the video itself, so every player shows them, and the picture is re-encoded for that. Without burning in, the picture stays unchanged (from the key frame before the start). Saved via “Save as”, the subtitles afterwards also as an SRT next to it.')}</p>
          {Object.keys(originals).length === 0 && <p className="hint small warn">{t('Dieses Paket enthält keinen Originalton; beim Exportieren des Prüfpakets in NVAI-open „Originalton als WAV“ für die gewünschten Spuren ankreuzen.',
            'This package contains no original audio; when exporting the review package in NVAI-open, tick “original audio as WAV” for the tracks you need.')}</p>}
          <h4>{t('Spuren', 'Tracks')}</h4>
          {trackPick}
          {chosenTracks.some((x) => !originals[x.id]) && <p className="muted small">{t('Ohne Originalton im Paket (werden übergangen): ', 'Without original audio in the package (skipped): ')}{chosenTracks.filter((x) => !originals[x.id]).map((x) => x.name).join(', ')}</p>}
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <div className="lt-toolbar">
            <select value={subs} onChange={(e) => setSubs(e.target.value as 'none' | 'original' | 'translation')}>
              <option value="none">{t('ohne Untertitel', 'no subtitles')}</option>
              <option value="original">{t('Untertitel: Original', 'subtitles: original')}</option>
              <option value="translation">{t('Untertitel: Übersetzung', 'subtitles: translation')}</option>
            </select>
            {subs !== 'none' && <label className="check small" title={t('Fest im Bild, in jedem Player sichtbar; das Bild wird neu kodiert. Die SRT gibt es trotzdem.', 'Fixed in the picture, visible in every player; the picture is re-encoded. The SRT is still offered.')}>
              <input type="checkbox" checked={burn} onChange={(e) => setBurn(e.target.checked)} />{t('ins Bild einbrennen', 'burn into the picture')}</label>}
            <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('Ton mono', 'mono sound')}</label>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Dateiname (optional)', 'file name (optional)')} />
          </div>
          {vBusy === null ? (
            <button className="btn primary" disabled={!wavTracks.length || (range === 'custom' && !region)}
              onClick={() => { runVideo().catch((e) => { if ((e as DOMException)?.name !== 'AbortError') onError(String((e as Error).message ?? e)) }) }}>
              {t(`Video mit Ton speichern (${fmtClock(len)}) …`, `Save video with sound (${fmtClock(len)}) …`)}</button>
          ) : (
            <div className="lt-toolbar">
              <span className="small">{t(`Video wird geschrieben … ${Math.round(vBusy * 100)} %`, `Writing the video … ${Math.round(vBusy * 100)} %`)}</span>
              <button className="btn small" onClick={() => vAbort.current?.abort()}>{t('Abbrechen', 'Cancel')}</button>
            </div>
          )}
          {srtReady && (
            <div className="lt-toolbar">
              <button className="btn small" onClick={() => {
                saveText(srtReady.name, srtReady.text, 'SRT', 'application/x-subrip', '.srt')
                  .then((n) => { onNotice(t(`Untertitel gespeichert: ${n} (${srtReady.cues} Blöcke).`, `Subtitles saved: ${n} (${srtReady.cues} blocks).`)); setSrtReady(null) })
                  .catch((e) => { if ((e as DOMException)?.name !== 'AbortError') onError(String((e as Error).message ?? e)) })
              }}>{t(`Untertitel dazu speichern (SRT, ${srtReady.cues} Blöcke) …`, `Save the matching subtitles (SRT, ${srtReady.cues} blocks) …`)}</button>
            </div>
          )}
        </div>
      )}
      {sec === 'package' && (
        <div className="au-tool">
          <p className="hint small">{t('Der ganze Fall in einem Ordner, mit der Prüf-App (NVAI-Pruefer.html): alle Spuren zum Anhören, Wellenformen und Spektrogramme, die Übersetzer-Spur mit allen Übersetzungen, Notizen, Ereignisse, Schiffsdaten, Protokoll und Prüfsummen. Die Prüf-App läuft in Edge oder Chrome ohne Installation, ohne Internet und ohne KI; dort lässt sich der Fall weiterbearbeiten und exportieren.',
            'The whole case in one folder, with the review app (NVAI-Pruefer.html): all tracks to listen to, waveforms and spectrograms, the translation track with all translations, notes, events, ship data, log and checksums. The review app runs in Edge or Chrome without installation, internet or AI; the case can be edited and exported there.')}</p>
          {!est ? <button className="btn small" onClick={() => api.audioPackageEstimate(proj.id).then(setEst).catch((e) => onError(String(e.message ?? e)))}>{t('Größen ermitteln', 'Measure sizes')}</button> : (
            <>
              {!est.app && <p className="hint small warn">{t('Die Prüf-App fehlt in dieser Installation (NVAI-Pruefer.html).', 'The review app is missing in this installation (NVAI-Pruefer.html).')}</p>}
              <div className="fx-exp-range">
                <span className="small">{t(`Grundpaket (Ton zum Abspielen, Anzeigen, Daten): ${gb(est.base)}`, `Base package (audio for playback, displays, data): ${gb(est.base)}`)}</span>
                {est.images > 0 && <label className="check small"><input type="checkbox" checked={pkgImages} onChange={(e) => setPkgImages(e.target.checked)} />{t(`Radar-/ECDIS-Bilder (${gb(est.images)})`, `Radar/ECDIS pictures (${gb(est.images)})`)}</label>}
                {est.video > 0 && <label className="check small"><input type="checkbox" checked={pkgVideo} onChange={(e) => setPkgVideo(e.target.checked)} />{t(`Video „${est.video_name}“ (${gb(est.video)})`, `Video “${est.video_name}” (${gb(est.video)})`)}</label>}
              </div>
              <h4>{t('Originalton als WAV (für bitgenaue Ton-Exporte in der Prüf-App)', 'Original audio as WAV (for bit-exact audio exports in the review app)')}</h4>
              <div className="fx-exp-tracks">
                {tracks.filter((x) => est.originals[x.id]).map((x) => (
                  <label key={x.id} className="check small"><input type="checkbox" checked={pkgOrig.includes(x.id)}
                    onChange={(e) => setPkgOrig(e.target.checked ? [...pkgOrig, x.id] : pkgOrig.filter((y) => y !== x.id))} />
                    <span className="au-swatch" style={{ background: x.color }} />{x.name} <span className="muted small">{gb(est.originals[x.id])}</span></label>
                ))}
              </div>
              {destPick}
              <p className="muted small">{t(`Zusammen rund ${gb(pkgSize)}.`, `About ${gb(pkgSize)} in total.`)}</p>
              <button className="btn primary" disabled={!dest || !est.app || busy('audio_package')}
                onClick={() => dest && api.audioPackage(proj.id, { dest_dir: dest, images: pkgImages, video: pkgVideo, originals: pkgOrig })
                  .then(() => { onNotice(t(`Prüfpaket wird erstellt, ${where}.`, `Creating the review package ${where}.`)); onReload() })
                  .catch((e) => onError(String(e.message ?? e)))}>{t('Prüfpaket exportieren', 'Export review package')}</button>
              {!dest && <p className="hint small">{t('Für das Prüfpaket unter „Speichern in“ einen Ordner wählen.', 'Choose a folder under “Save to” for the review package.')}</p>}
            </>
          )}
        </div>
      )}
      {sec === 'speech' && (
        <div className="au-tool">
          <p className="hint small">{t('Erkannte Sprache (Original) und Übersetzung. Der Text im Gerichtsformat nennt je Block Zeit, Kanal, Sprecher, Prüfstand und Sicherheit; Entwürfe der KI sind als solche markiert.',
            'Recognised speech (original) and translation. The text in court format gives per block the time, channel, speaker, review state and confidence; AI drafts are marked as such.')}</p>
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
          <label className="check small"><input type="checkbox" checked={checkedOnly} onChange={(e) => setCheckedOnly(e.target.checked)} />{t('nur geprüfte Blöcke', 'only checked blocks')}</label>
          <div className="lt-toolbar">
            {([['txt', false, t('Text, zweisprachig', 'Text, bilingual')], ['csv', false, t('Tabelle (CSV)', 'Table (CSV)')],
              ['srt', false, t('SRT Original', 'SRT original')], ['srt', true, t('SRT Übersetzung', 'SRT translation')], ['vtt', true, t('VTT Übersetzung', 'VTT translation')]] as ['txt' | 'csv' | 'srt' | 'vtt', boolean, string][])
              .map(([f, useTr, label]) => (
                <button key={label} className="btn small" disabled={!doc.segments.length}
                  onClick={() => { const n = exportTranscript(proj, tracks, doc, f, useTr, { checkedOnly, region }); onNotice(t(`${n} Blöcke exportiert.`, `${n} blocks exported.`)) }}>{label}</button>
              ))}
          </div>
          {!doc.segments.length && <p className="muted small">{t('Die Übersetzer-Spur ist noch leer.', 'The translation track is still empty.')}</p>}
        </div>
      )}
      {sec === 'notes' && (
        <div className="au-tool">
          <p className="hint small">{t(`${markers.filter((m) => m.kind === 'note').length} Notizen mit Zeitstempel, Dauer, Verfasser und Text.`, `${markers.filter((m) => m.kind === 'note').length} notes with timestamp, duration, author and text.`)}</p>
          <div className="lt-toolbar">
            <button className="btn small" onClick={() => exportNotes(proj, markers.filter((m) => m.kind === 'note' && (!region || (m.end >= region[0] && m.start <= region[1]))), 'txt')}>{t('Als Text', 'As text')}</button>
            <button className="btn small" onClick={() => exportNotes(proj, markers.filter((m) => m.kind === 'note' && (!region || (m.end >= region[0] && m.start <= region[1]))), 'csv')}>CSV</button>
          </div>
          <h4>{t('Bereich', 'Range')}</h4>
          {rangePick}
        </div>
      )}
    </div>
  )
}

export function ExportDialog(props: Parameters<typeof ExportPanel>[0] & { onClose: () => void }) {
  // Solange ein Export im Browser läuft (Prüf-App), schließt ein Klick daneben den Dialog nicht
  const [running, setRunning] = useState(false)
  return (
    <div className="lt-modal" onClick={() => { if (!running) props.onClose() }}>
      <div className="lt-modal-box panel fx-exp-dialog" onClick={(e) => e.stopPropagation()}>
        <div className="lt-modal-head">
          <strong>{t('Export', 'Export')}</strong>
          <span className="au-spacer" />
          <button className="btn small ghost" disabled={running} title={running ? t('Erst den Export abwarten oder abbrechen', 'Wait for the export or cancel it first') : undefined}
            onClick={props.onClose}>{t('Schließen', 'Close')}</button>
        </div>
        <ExportPanel {...props} onBusy={setRunning} />
      </div>
    </div>
  )
}
