import { useCallback, useEffect, useMemo, useState } from 'react'
import { api, type AudioMarker, type AudioModel, type AudioProject, type AudioStatus, type AudioTrack } from '../api'
import { fmtClock } from '../audio/Timeline'
import { t } from '../i18n'

// Werkzeuge der Ton-Forensik (bis 17.11.2026 abends in panels/Audio.tsx): KI-Trennen und Entrauschen, Filter,
// Export, Geräusch lernen mit Ton-Suche. Die Arbeitsfläche (Workspace.tsx) zeigt sie rechts als Reiter.

export function fmtMb(mb: number): string {
  return mb >= 1024 ? `${(mb / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 })} GB` : `${Math.round(mb)} MB`
}

export function fmtDur(s: number): string {
  if (s < 90) return `${Math.max(1, Math.round(s))} s`
  const m = Math.round(s / 60)
  return m < 90 ? `${m} min` : `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} min`
}

export function LicenseBadge({ m }: { m: AudioModel }) {
  const nc = !m.commercial_ok
  const sa = /BY-SA/i.test(m.license_weights)
  return (
    <span className={`au-lic ${nc ? 'nc' : sa ? 'sa' : 'ok'}`} title={`${t('Code', 'Code')}: ${m.license_code} · ${t('Gewichte', 'Weights')}: ${m.license_weights}`}>
      {nc ? t('nicht kommerziell', 'non-commercial') : sa ? 'CC BY-SA' : t('frei nutzbar', 'free to use')}
    </span>
  )
}

export function ModelPick({ st, task, value, onChange, onInstall, busy }: {
  st: AudioStatus
  task: string
  value: string
  onChange: (id: string) => void
  onInstall: (id: string) => void
  busy: boolean
}) {
  const list = st.models.filter((m) => m.task === task || (task === 'denoise' && m.task === 'denoise'))
  const m = list.find((x) => x.id === value)
  if (!list.length) return <p className="hint small warn">{t('Für diese Aufgabe ist noch kein Modell eingetragen.', 'No model is registered for this task yet.')}</p>
  return (
    <div className="au-model">
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {list.map((x) => (
          <option key={x.id} value={x.id}>{x.label}{x.recommended_for.length ? ` ★` : ''}{x.installed ? '' : ` (${t('nicht geladen', 'not downloaded')})`}</option>
        ))}
      </select>
      {m && (
        <div className="au-model-info">
          <LicenseBadge m={m} />
          {m.recommended_for.length > 0 && <span className="au-rec">★ {t('empfohlen', 'recommended')}</span>}
          <span className="muted small">{m.device === 'cpu' ? t('Prozessor', 'CPU') : t('Grafikkarte', 'GPU')}{m.vram_gb ? ` · ${m.vram_gb} GB` : ''} · {fmtMb(m.size_mb)}</span>
          {m.notes && <p className="hint small">{m.notes}</p>}
          {!m.installed && (
            <button className="btn small" disabled={busy} onClick={() => onInstall(m.id)}>{t(`Laden (${fmtMb(m.size_mb)})`, `Download (${fmtMb(m.size_mb)})`)}</button>
          )}
        </div>
      )}
    </div>
  )
}

export function SourcePick({ tracks, value, onChange }: { tracks: AudioTrack[]; value: string; onChange: (v: string) => void }) {
  return (
    <label className="lr-inline">{t('Spur', 'Track')}
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {tracks.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
      </select>
    </label>
  )
}

export function RegionToggle({ selection, value, onChange }: { selection: [number, number] | null; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="check small">
      <input type="checkbox" checked={value && !!selection} disabled={!selection} onChange={(e) => onChange(e.target.checked)} />
      {selection ? t(`nur die Auswahl (${fmtClock(selection[1] - selection[0], true)}) als Vorschau`, `only the selection (${fmtClock(selection[1] - selection[0], true)}) as a preview`)
        : t('nur eine Auswahl (erst im Zeitstrahl ziehen)', 'only a selection (drag in the timeline first)')}
    </label>
  )
}

export function AiTool({ st, proj, tool, tracks, selection, span, busy, setupBusy, onInstall, onError, onNotice, onReload }: {
  st: AudioStatus
  proj: AudioProject
  tool: 'separate' | 'denoise'
  tracks: AudioTrack[]
  selection: [number, number] | null
  span: number
  busy: boolean
  setupBusy: boolean
  onInstall: (id: string) => void
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
}) {
  const [task, setTask] = useState(tool === 'denoise' ? 'denoise' : 'voice')
  useEffect(() => { setTask(tool === 'denoise' ? 'denoise' : 'voice') }, [tool])
  const pickDefault = useCallback((tk: string) => st.recommended[tk] ?? st.models.find((m) => m.task === tk)?.id ?? '', [st])
  const [model, setModel] = useState(pickDefault(task))
  useEffect(() => { setModel(pickDefault(task)) }, [task, pickDefault])
  const [track, setTrack] = useState(tracks[0]?.id ?? 't_orig')
  const [onlySel, setOnlySel] = useState(true)
  const [quality, setQuality] = useState<'normal' | 'high'>('normal')
  const [atten, setAtten] = useState(100)
  const m = st.models.find((x) => x.id === model)
  const region = onlySel && selection ? selection : null
  const secs = (region ? region[1] - region[0] : proj.duration ?? span) / 60 * (m?.seconds_per_minute ?? 0)
  const params: Record<string, any> = {}
  if (m?.id === 'melroformer_kim' && quality === 'high') params.overlap = 4
  if (m?.id === 'bandit_v2' && quality === 'high') params.hop_seconds = 2
  if (m?.id === 'deepfilternet3' && atten < 100) params.atten_lim_db = atten
  const run = async () => {
    try {
      await api.audioOp(proj.id, { kind: 'ai', track, model, task, params, region: region as [number, number] | null })
      onNotice(t('Läuft: Die neuen Spuren erscheinen, sobald es fertig ist.', 'Running: the new tracks appear when it is done.'))
      onReload()
    } catch (e) { onError(String((e as Error).message ?? e)) }
  }
  return (
    <div className="au-tool">
      {tool === 'separate' && (
        <div className="au-task">
          <label className="check"><input type="radio" checked={task === 'voice'} onChange={() => setTask('voice')} />
            {t('Stimme / Begleitung', 'Voice / accompaniment')} <span className="muted small">{t('Gesang oder Sprache über Musik', 'singing or speech over music')}</span></label>
          <label className="check"><input type="radio" checked={task === 'dialogue'} onChange={() => setTask('dialogue')} />
            {t('Sprache / Musik / Geräusche', 'Speech / music / effects')} <span className="muted small">{t('Filme, Mitschnitte, Vorträge mit Publikum', 'films, recordings, talks with an audience')}</span></label>
        </div>
      )}
      {tool === 'denoise' && <p className="hint small">{t('Für Sprache: Rauschen, Brummen-Reste, Hall. Das Entfernte landet als eigene Spur daneben, so lässt sich prüfen, dass nichts von der Stimme fehlt; mit einer leisen Beimischung klingt es natürlicher.', 'For speech: noise, hum leftovers, reverb. What is removed becomes a track of its own, so you can check nothing of the voice is missing; mixing a little back in sounds more natural.')}</p>}
      {!st.env_ready && <p className="hint small warn">{t('Erst unter „Modelle und Einrichten“ die Audio-Umgebung einrichten.', 'Set up the audio environment under “Models and setup” first.')}</p>}
      <ModelPick st={st} task={task} value={model} onChange={setModel} onInstall={onInstall} busy={setupBusy} />
      <div className="lt-toolbar">
        <SourcePick tracks={tracks} value={track} onChange={setTrack} />
        {(m?.id === 'melroformer_kim' || m?.id === 'bandit_v2') && (
          <label className="lr-inline">{t('Qualität', 'Quality')}
            <select value={quality} onChange={(e) => setQuality(e.target.value as 'normal' | 'high')}>
              <option value="normal">{t('normal', 'normal')}</option><option value="high">{t('hoch (doppelte Zeit)', 'high (double time)')}</option>
            </select></label>
        )}
        {m?.id === 'deepfilternet3' && (
          <label className="lr-inline">{t('höchstens absenken um', 'attenuate at most')}
            <input type="range" min={6} max={100} step={1} value={atten} onChange={(e) => setAtten(Number(e.target.value))} />
            <span className="small">{atten >= 100 ? t('voll', 'full') : `${atten} dB`}</span></label>
        )}
      </div>
      <RegionToggle selection={selection} value={onlySel} onChange={setOnlySel} />
      <div className="lt-toolbar">
        <button className="btn primary" disabled={busy || !m?.installed || !st.env_ready} onClick={run}>
          {region ? t('Vorschau rechnen', 'Render preview') : t('Ganze Spur rechnen', 'Process the whole track')}
          {m?.seconds_per_minute ? ` (${t('rund', 'about')} ${fmtDur(secs)})` : ''}
        </button>
        {busy && <span className="hint small">{t('Es läuft schon eine Bearbeitung in diesem Projekt.', 'An operation is already running in this project.')}</span>}
      </div>
    </div>
  )
}

const FILTERS: { type: string; label: string; hint: string }[] = [
  { type: 'hum', label: t('Netzbrummen entfernen', 'Remove mains hum'), hint: t('Kerbfilter auf 50 bzw. 60 Hz und Oberwellen (aus der Messung)', 'notch filters at 50 or 60 Hz and harmonics (from the measurement)') },
  { type: 'linewhistle', label: t('Zeilenpfeifen 15,6 kHz', 'Line whistle 15.6 kHz'), hint: t('typisch für Ton von Videobändern und Röhrenfernsehern', 'typical for sound from video tapes and CRT TVs') },
  { type: 'highpass', label: t('Trittschall und Wind (unter 80 Hz)', 'Rumble and wind (below 80 Hz)'), hint: t('Hochpass', 'high-pass') },
  { type: 'declick', label: t('Knackser', 'Clicks'), hint: t('kurze Störimpulse', 'short impulses') },
  { type: 'denoise', label: t('Rauschen klassisch', 'Classic denoise'), hint: t('Spektral (ffmpeg afftdn), ohne KI', 'spectral (ffmpeg afftdn), no AI') },
  { type: 'level', label: t('Pegel angleichen (Sprache)', 'Level speech'), hint: t('leise und laute Stellen annähern', 'bring quiet and loud passages closer') },
  { type: 'deess', label: t('Zischlaute', 'De-ess'), hint: t('scharfe S-Laute dämpfen', 'tame sharp S sounds') },
  { type: 'loudness', label: t('Lautheit', 'Loudness'), hint: t('auf ein Ziel nach EBU R 128, Spitzen bei −1 dB begrenzt', 'to a target per EBU R 128, peaks limited at −1 dB') },
]

export function FilterTool({ proj, tracks, selection, onError, onNotice, onReload }: {
  proj: AudioProject
  tracks: AudioTrack[]
  selection: [number, number] | null
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
}) {
  const hum = proj.analysis?.hum
  const [on, setOn] = useState<Record<string, boolean>>(() => ({ hum: Boolean(hum?.present), highpass: true, loudness: true }))
  const [denoise, setDenoise] = useState('light')
  const [target, setTarget] = useState(-16)
  const [humFreq, setHumFreq] = useState<number>(hum?.freq ?? 50)
  const [track, setTrack] = useState(tracks[tracks.length - 1]?.id ?? 't_orig')
  const [onlySel, setOnlySel] = useState(false)
  const chain = useMemo(() => FILTERS.filter((f) => on[f.type]).map((f) => {
    if (f.type === 'hum') return { type: 'hum', freq: humFreq, harmonics: 5 }
    if (f.type === 'highpass') return { type: 'highpass', freq: 80 }
    if (f.type === 'denoise') return { type: 'denoise', strength: denoise }
    if (f.type === 'loudness') return { type: 'loudness', target }
    return { type: f.type }
  }), [on, humFreq, denoise, target])
  const run = async () => {
    try {
      await api.audioOp(proj.id, { kind: 'classic', track, chain, region: onlySel && selection ? selection : null })
      onNotice(t('Läuft: Die neue Spur erscheint, sobald es fertig ist.', 'Running: the new track appears when it is done.'))
      onReload()
    } catch (e) { onError(String((e as Error).message ?? e)) }
  }
  return (
    <div className="au-tool">
      <p className="hint small">{t('Klassische Filter ohne KI, schnell auch bei Stunden. Reihenfolge wie unten.', 'Classic filters without AI, fast even for hours. Order as below.')}</p>
      {FILTERS.map((f) => (
        <div key={f.type} className="au-filter">
          <label className="check"><input type="checkbox" checked={!!on[f.type]} onChange={(e) => setOn({ ...on, [f.type]: e.target.checked })} />
            {f.label} <span className="muted small">{f.hint}</span></label>
          {f.type === 'hum' && on.hum && (
            <select value={humFreq} onChange={(e) => setHumFreq(Number(e.target.value))}>
              <option value={50}>50 Hz</option><option value={60}>60 Hz</option>
            </select>
          )}
          {f.type === 'denoise' && on.denoise && (
            <select value={denoise} onChange={(e) => setDenoise(e.target.value)}>
              <option value="light">{t('leicht', 'light')}</option><option value="medium">{t('mittel', 'medium')}</option><option value="strong">{t('stark', 'strong')}</option>
            </select>
          )}
          {f.type === 'loudness' && on.loudness && (
            <select value={target} onChange={(e) => setTarget(Number(e.target.value))}>
              <option value={-16}>−16 LUFS ({t('Sprache, Podcast', 'speech, podcast')})</option>
              <option value={-14}>−14 LUFS ({t('Musik, YouTube', 'music, YouTube')})</option>
              <option value={-23}>−23 LUFS ({t('Rundfunk', 'broadcast')})</option>
            </select>
          )}
        </div>
      ))}
      <div className="lt-toolbar">
        <SourcePick tracks={tracks} value={track} onChange={setTrack} />
        <RegionToggle selection={selection} value={onlySel} onChange={setOnlySel} />
      </div>
      <button className="btn primary" disabled={!chain.length} onClick={run}>{t(`${chain.length} Filter anwenden`, `Apply ${chain.length} filters`)}</button>
    </div>
  )
}

export function ExportTool({ proj, tracks, onError, onNotice, onReload }: {
  proj: AudioProject
  tracks: AudioTrack[]
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
}) {
  const [fmt, setFmt] = useState('mp3')
  const [video, setVideo] = useState(false)
  const [mono, setMono] = useState(false)
  const [name, setName] = useState('')
  const anySolo = tracks.some((x) => x.solo)
  const mix = tracks.map((x) => ({ id: x.id, gain_db: x.gain_db, mute: anySolo ? !x.solo : x.mute }))
  const audible = tracks.filter((x) => (anySolo ? x.solo : !x.mute))
  const run = async () => {
    try {
      await api.audioExport(proj.id, { tracks: mix, format: fmt, into_video: video, name, mono })
      onNotice(t('Export läuft; das Ergebnis kommt in den Verlauf.', 'Export running; the result goes into the History.'))
      onReload()
    } catch (e) { onError(String((e as Error).message ?? e)) }
  }
  return (
    <div className="au-tool">
      <p className="hint small">{t('Gemischt wird, was zu hören ist: Spuren ohne „stumm“ (oder nur die mit „solo“), jede mit ihrem Pegel. Vorschau-Spuren bleiben draußen.', 'What you hear is mixed: tracks not muted (or only the soloed ones), each at its level. Preview tracks are left out.')}</p>
      <ul className="au-mixlist">
        {audible.map((x) => <li key={x.id}><span className="au-swatch" style={{ background: x.color }} />{x.name} <span className="muted small">{x.gain_db > 0 ? '+' : ''}{x.gain_db.toFixed(1)} dB</span></li>)}
        {audible.length === 0 && <li className="muted small">{t('Keine Spur zu hören.', 'No track audible.')}</li>}
      </ul>
      <div className="lt-toolbar">
        {proj.source.has_video && <label className="check"><input type="checkbox" checked={video} onChange={(e) => setVideo(e.target.checked)} />{t('Ton im Video ersetzen (Bild unverändert, MP4)', 'Replace the sound in the video (picture unchanged, MP4)')}</label>}
        {!video && (
          <select value={fmt} onChange={(e) => setFmt(e.target.value)}>
            <option value="wav">WAV (16 bit)</option><option value="flac">FLAC (24 bit)</option><option value="mp3">MP3 192 kbit/s</option>
            <option value="m4a">M4A (AAC 256 kbit/s)</option><option value="opus">Opus</option>
          </select>
        )}
        {!video && <label className="check small"><input type="checkbox" checked={mono} onChange={(e) => setMono(e.target.checked)} />{t('mono (halbe Größe, gut für Sprache)', 'mono (half the size, good for speech)')}</label>}
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Dateiname (optional)', 'file name (optional)')} />
      </div>
      {!video && (proj.duration ?? 0) > 3 * 3600 && fmt === 'wav' && (
        <p className="hint small warn">{t('Über rund 3 Stunden wird WAV größer als 4 GB und als RF64 geschrieben; nicht jedes Programm liest das. MP3, M4A oder FLAC passen besser.', 'Beyond about 3 hours WAV exceeds 4 GB and is written as RF64, which not every program reads. MP3, M4A or FLAC fit better.')}</p>
      )}
      <button className="btn primary" disabled={!audible.length} onClick={run}>{t('Exportieren', 'Export')}</button>
    </div>
  )
}

export function LearnTool({ st, proj, tracks, selection, busy, markers, onAddMarkers, onSeek, onSelect, onDeleteMarker, onError, onNotice, onReload }: {
  st: AudioStatus
  proj: AudioProject
  tracks: AudioTrack[]
  selection: [number, number] | null
  busy: boolean
  markers: AudioMarker[]
  onAddMarkers: (list: AudioMarker[]) => void
  onSeek: (s: number) => void
  onSelect: (a: number, b: number) => void
  onDeleteMarker: (m: AudioMarker) => void
  onError: (e: string) => void
  onNotice: (e: string) => void
  onReload: () => void
}) {
  const [name, setName] = useState('')
  const [steps, setSteps] = useState(3000)
  const [track, setTrack] = useState(tracks[0]?.id ?? 't_orig')
  const [applyTrack, setApplyTrack] = useState(tracks[0]?.id ?? 't_orig')
  const [onlySel, setOnlySel] = useState(true)
  const [strength, setStrength] = useState(1)
  const noise = markers.filter((m) => m.kind === 'noise')
  const keep = markers.filter((m) => m.kind === 'keep')
  // Beispiele aus der Auswahl (vorher ließen sich Marken „Störgeräusch“ und „behalten“ nur über die Ton-Suche setzen)
  const hasSel = !!selection && selection[1] > selection[0]
  const mark = (kind: 'noise' | 'keep') => {
    if (!selection || selection[1] <= selection[0]) return
    onAddMarkers([{ id: Math.random().toString(36).slice(2, 10), start: selection[0], end: selection[1], kind,
      label: kind === 'noise' ? t('Störgeräusch', 'unwanted sound') : t('behalten', 'keep') }])
  }
  const profiles = proj.profiles ?? []
  const learn = async () => {
    try {
      await api.audioLearn(proj.id, { name, track, steps })
      onNotice(t('Lernt im Hintergrund; das Ergebnis erscheint unten.', 'Learning in the background; the result appears below.'))
      onReload()
    } catch (e) { onError(String((e as Error).message ?? e)) }
  }
  const apply = async (prof: string) => {
    try {
      await api.audioOp(proj.id, { kind: 'learned', profile: prof, track: applyTrack, params: { strength },
        region: onlySel && selection ? selection : null })
      onNotice(t('Läuft: Es entstehen zwei Spuren, ohne das Geräusch und nur das Geräusch.', 'Running: two tracks appear, without the sound and only the sound.'))
      onReload()
    } catch (e) { onError(String((e as Error).message ?? e)) }
  }
  return (
    <div className="au-tool">
      <p className="hint small">{t('Für ein bestimmtes, wiederkehrendes Geräusch (Alarm, Piepen, Maschine, Klingel): im Zeitstrahl 4 bis 10 Beispiele auswählen und je als „Störgeräusch“ markieren, gern auch Stellen mit Gespräch darüber. Optional „behalten“-Marken auf Stellen ohne das Geräusch. Ein kleines Netz lernt daraus auf der Grafikkarte; danach entstehen zwei Spuren: ohne das Geräusch und nur das Geräusch.',
        'For one specific, recurring sound (alarm, beep, machine, bell): select 4 to 10 examples in the timeline and mark each as “unwanted sound”, also places with talking over it. Optionally “keep” markers on places without the sound. A small network learns from them on the graphics card; then two tracks appear: without the sound and only the sound.')}</p>
      <div className="au-scan">
        <button className="btn small" disabled={busy} onClick={() => api.audioScan(proj.id, tracks[0]?.id).then(() => { onNotice(t('Sucht gleichbleibende Töne (Alarme, Piepser) in der ganzen Aufnahme; rund 1 min je Stunde.', 'Looking for steady tones (alarms, beeps) in the whole recording; about 1 min per hour.')); onReload() }).catch((e) => onError(String(e.message ?? e)))}>
          {t('Alarme und Piepser in der Aufnahme suchen', 'Find alarms and beeps in the recording')}</button>
        {proj.scan && (
          <span className="muted small">{t(`${proj.scan.events} Tonereignisse in ${fmtClock(proj.scan.seconds_scanned)}`, `${proj.scan.events} tone events in ${fmtClock(proj.scan.seconds_scanned)}`)}</span>
        )}
      </div>
      {proj.scan && proj.scan.clusters.length > 0 && (
        <div className="au-scan-list">
          {proj.scan.clusters.slice(0, 8).map((c, i) => {
            const ev = c.events
            const pick = (n: number) => Array.from({ length: Math.min(n, ev.length) }, (_, k) => ev[Math.floor((k * ev.length) / Math.min(n, ev.length))])
            const label = `${c.freqs.join(' + ')} Hz`
            const add = (n: number, kind: AudioMarker['kind']) => onAddMarkers(pick(n).filter(([a]) => !markers.some((m) => Math.abs(m.start - a) < 0.2))
              .map(([a, b]) => ({ id: Math.random().toString(36).slice(2, 10), start: Math.max(0, a - 0.05), end: b + 0.05, kind, label })))
            return (
              <div key={i} className="au-scan-row">
                <span className="au-scan-freq">{label}</span>
                <span className="muted small">{t(`${c.count}× · zusammen ${fmtClock(c.total_s)} · je ${c.mean_s} s · Reinheit ${c.tonality_db} dB`, `${c.count}× · ${fmtClock(c.total_s)} in total · ${c.mean_s} s each · purity ${c.tonality_db} dB`)}</span>
                <button className="linklike small" onClick={() => { onSelect(ev[0][0], ev[0][1]); onSeek(Math.max(0, ev[0][0] - 1)) }}>{t('anhören', 'listen')}</button>
                <button className="btn small" onClick={() => add(6, 'noise')}>{t('6 als Beispiele markieren', 'mark 6 as examples')}</button>
                <button className="btn small ghost" onClick={() => add(400, 'note')}>{t('alle Stellen markieren', 'mark all places')}</button>
              </div>
            )
          })}
          <p className="hint small">{t('Oben stehen die reinsten und häufigsten Töne. Erst anhören, ob es wirklich der Alarm ist; Treffer mit niedriger Reinheit (unter rund 40 dB) sind oft Musik oder Stimme.', 'The purest and most frequent tones are at the top. Listen first whether it really is the alarm; hits with low purity (below about 40 dB) are often music or voice.')}</p>
        </div>
      )}
      <div className="au-learn-marks">
        <strong>{t(`Beispiele: ${noise.length} Störgeräusch, ${keep.length} behalten`, `Examples: ${noise.length} unwanted, ${keep.length} keep`)}</strong>
        {[...noise, ...keep].sort((a, b) => a.start - b.start).map((m) => (
          <span key={m.id} className={`au-learn-mark ${m.kind}`}>
            <button className="linklike" onClick={() => { onSelect(m.start, m.end); onSeek(m.start) }}>{fmtClock(m.start, true)} ({(m.end - m.start).toFixed(1)} s)</button>
            <button className="au-x" onClick={() => onDeleteMarker(m)}>✕</button>
          </span>
        ))}
        {noise.length < 2 && <span className="hint small warn">{t('Mindestens zwei Beispiele markieren (Auswahl ziehen, dann „Auswahl als Störgeräusch“).', 'Mark at least two examples (drag a selection, then “Selection as unwanted sound”).')}</span>}
      </div>
      <div className="lt-toolbar">
        <button className="btn small" disabled={!hasSel} onClick={() => mark('noise')}
          title={hasSel ? '' : t('Erst im Zeitstrahl eine Stelle auswählen', 'Select a place in the timeline first')}>{t('Auswahl als Störgeräusch', 'Selection as unwanted sound')}</button>
        <button className="btn small ghost" disabled={!hasSel} onClick={() => mark('keep')}
          title={hasSel ? '' : t('Erst im Zeitstrahl eine Stelle auswählen', 'Select a place in the timeline first')}>{t('Auswahl als „behalten“', 'Selection as “keep”')}</button>
      </div>
      <div className="lt-toolbar">
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('Name, z. B. Alarm', 'Name, e.g. alarm')} />
        <SourcePick tracks={tracks} value={track} onChange={setTrack} />
        <select value={steps} onChange={(e) => setSteps(Number(e.target.value))}>
          <option value={1500}>{t('schnell', 'quick')}</option>
          <option value={3000}>{t('normal', 'normal')}</option>
          <option value={6000}>{t('gründlich', 'thorough')}</option>
        </select>
        <button className="btn primary" disabled={busy || noise.length < 2 || !st.env_ready} onClick={learn}>{t('Geräusch lernen', 'Learn the sound')}</button>
      </div>
      {profiles.length > 0 && (
        <>
          <h4>{t('Gelernte Geräusche', 'Learned sounds')}</h4>
          <div className="lt-toolbar">
            <SourcePick tracks={tracks} value={applyTrack} onChange={setApplyTrack} />
            <label className="lr-inline">{t('Stärke', 'Strength')}<input type="range" min={0.3} max={1} step={0.05} value={strength} onChange={(e) => setStrength(Number(e.target.value))} />{Math.round(strength * 100)} %</label>
          </div>
          <RegionToggle selection={selection} value={onlySel} onChange={setOnlySel} />
          {[...profiles].reverse().map((pr) => (
            <div key={pr.id} className="lt-own-row">
              <div className="lt-own-main">
                <strong>{pr.name}</strong>
                <span className="muted small">
                  {pr.metrics.noise_reduction_db != null ? t(`Geräusch rund ${pr.metrics.noise_reduction_db} dB leiser`, `sound about ${pr.metrics.noise_reduction_db} dB quieter`) : ''}
                  {pr.metrics.clean_change_db != null ? t(` · saubere Stellen ${pr.metrics.clean_change_db > 0 ? '+' : ''}${pr.metrics.clean_change_db} dB`, ` · clean places ${pr.metrics.clean_change_db > 0 ? '+' : ''}${pr.metrics.clean_change_db} dB`) : ''}
                  {t(` · ${pr.metrics.examples} Beispiele (${pr.metrics.example_seconds} s), gelernt in ${fmtDur(pr.metrics.train_seconds)}`, ` · ${pr.metrics.examples} examples (${pr.metrics.example_seconds} s), learned in ${fmtDur(pr.metrics.train_seconds)}`)}
                </span>
                <span className="hint small">{t('Gemessen an zurückgehaltenen Beispielen; ob es passt, zeigt erst das Anhören.', 'Measured on held-back examples; listening shows whether it fits.')}</span>
                {((pr.metrics.noise_reduction_db ?? 99) < 6 || (pr.metrics.clean_change_db ?? 0) < -1) && (
                  <span className="hint small warn">{t('Schwaches Ergebnis: Die Beispiele sind sich wohl nicht ähnlich genug, oder die zufällig gewählten sauberen Stellen enthalten das Geräusch selbst. Besser nur eindeutige Beispiele markieren und einige „behalten“-Marken auf Stellen ohne das Geräusch setzen.',
                    'Weak result: the examples are probably not similar enough, or the randomly chosen clean places contain the sound itself. Better mark only clear examples and set a few “keep” markers on places without the sound.')}</span>
                )}
              </div>
              <button className="btn small primary" disabled={busy} onClick={() => apply(pr.id)}>{onlySel && selection ? t('Vorschau', 'Preview') : t('Anwenden', 'Apply')}</button>
              <button className="btn small ghost danger-text" onClick={() => api.audioProfileDelete(proj.id, pr.id).then(onReload).catch((e) => onError(String(e.message ?? e)))}>✕</button>
            </div>
          ))}
        </>
      )}
    </div>
  )
}
