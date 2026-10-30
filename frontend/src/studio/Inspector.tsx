// Eigenschaften der Auswahl: Szene (Prompt, Modell, Länge, Anschluss, Takes), Clip (In/Out, Geschwindigkeit,
// Lautstärke, Übergang), Übergang (Art, Dauer), Marker (Art, Auftrag, Angaben je Art) oder Material (Angaben, Einfügen,
// Löschen); mehrere Objekte zeigen, was für alle gilt; ohne Auswahl das Projekt (Format, Bildrate). Eingaben gelten
// beim Verlassen des Feldes oder mit Enter; jede Änderung am Projekt ist ein Befehl und lässt sich rückgängig machen.

import { useEffect, useState } from 'react'
import {
  fileUrl,
  TPS,
  type Asset,
  type ModelInfo,
  type StudioClip,
  type StudioLane,
  type StudioMarker,
  type StudioMarkerKind,
  type StudioProject,
  type StudioScene,
  type StudioTransitionKind,
} from '../api'
import { t } from '../i18n'
import { assetFacts, assetLabel, mediaKind } from './Bin'
import { SCALE_MAX, SCALE_MIN, clipEnd, clipLength, clipScaleAt, clipSpeed, decimal, frameTicks, keyTime, mediaAt, sec, tracksOf, trackOrHighest } from './time'
import { selIds, TRANSITION_LABEL, type Selection } from './Timelines'

interface Props {
  project: StudioProject
  selection: Selection
  models: ModelInfo[]
  onCommand: (command: string, params: Record<string, unknown>) => Promise<any>
  onGenerate: (sceneIds: string[]) => void
  onSelect: (s: Selection) => void
  /** angeklicktes Material (Auswahl „asset“) */
  asset: Asset | null
  playhead: number
  onDeleteAsset: (a: Asset) => Promise<void>
  /** Geschwindigkeit setzen; fragt nach, wenn der längere Clip an den nächsten stößt */
  onSpeed: (c: StudioClip, speed: number) => void
  /** Abspielkopf setzen (Springen zwischen Keyframes) */
  onPlayhead: (t: number) => void
}

/** Formate für bestehende Projekte (neue beginnen mit 1920 × 1080) */
export const FORMATS: { label: string; w: number; h: number }[] = [
  { label: t('Querformat 1920 × 1080 (YouTube)', 'Landscape 1920 × 1080 (YouTube)'), w: 1920, h: 1080 },
  { label: t('Hochformat 1080 × 1920 (Shorts)', 'Portrait 1080 × 1920 (Shorts)'), w: 1080, h: 1920 },
  { label: t('Querformat 1280 × 720', 'Landscape 1280 × 720'), w: 1280, h: 720 },
  { label: t('4K 3840 × 2160', '4K 3840 × 2160'), w: 3840, h: 2160 },
]
const FRAME_RATES = [24, 25, 30, 50, 60]

export const LANE_LABEL: Record<StudioLane, string> = {
  video: t('Bild/Video', 'Picture'),
  voice: t('Sprecher', 'Voice'),
  music: t('Musik', 'Music'),
  sfx: t('Klang', 'Sound'),
}

export const MARKER_LABEL: Record<StudioMarkerKind, string> = {
  place: t('Platzieren', 'Place'),
  transition: t('Übergang', 'Transition'),
  chain: t('Anschluss', 'Chain'),
  audio: t('Ton ab hier', 'Audio from here'),
  ai: t('KI-Auftrag', 'AI task'),
  note: t('Notiz', 'Note'),
}

const MARKER_HINT: Record<StudioMarkerKind, string> = {
  place: t('Beim Übernehmen kommt die gewählte Szene an diese Stelle, auf die gewählte Spur (V2 liegt über V1).',
    'On conform, the chosen scene goes here, on the chosen track (V2 is above V1).'),
  transition: t('Der Videoclip, der hier beginnt, bekommt diesen Übergang: sofort, wenn er schon im Schnitt liegt, sonst beim Übernehmen. Wandert der Marker, wandert der Übergang mit.',
    'The video clip that starts here gets this transition: right away if it is already in the edit, otherwise on conform. Move the marker and the transition moves along.'),
  chain: t('Beim Erzeugen setzt die Videoszene an dieser Stelle die Szene davor fort: mit LTX-2.5 beginnt sie mit deren '
    + 'letzter Sekunde, und „Übernehmen“ blendet über diese Sekunde über (Latent-Kette, ohne Sprung an der Naht); sonst mit '
    + 'deren letztem Bild.',
    'On generate, the video scene starting here continues the scene before it: with LTX-2.5 it begins with that scene’s '
    + 'last second, and “Conform” crossfades over that second (latent chain, no jump at the seam); otherwise with its last '
    + 'frame.'),
  audio: t('Beim Übernehmen beginnt die gewählte Ton-Szene (Musik, Sprecher, Klang) an dieser Stelle.',
    'On conform, the chosen audio scene (music, voice, sound) starts here.'),
  ai: t('Ein Auftrag für Claude: Es liest ihn per MCP, arbeitet ihn ab und hakt ihn ab.',
    'A task for Claude: it reads it through MCP, carries it out and ticks it off.'),
  note: t('Nur eine Notiz, ohne Wirkung.', 'Just a note, no effect.'),
}

/** Textfeld, das beim Verlassen oder mit Enter übernimmt. */
function sceneName(p: StudioProject, id?: string | null): string {
  const s = p.scenes.find((x) => x.id === id)
  return s ? s.title || s.prompt.slice(0, 40) || s.id : '?'
}

function Field({ label, value, onCommit, area = false, rows = 4, placeholder }: {
  label: string
  value: string
  onCommit: (v: string) => void
  area?: boolean
  rows?: number
  placeholder?: string
}) {
  const [v, setV] = useState(value)
  useEffect(() => setV(value), [value])
  const commit = () => {
    if (v !== value) onCommit(v)
  }
  return (
    <label className="st-field">
      <span>{label}</span>
      {area ? (
        <textarea value={v} rows={rows} placeholder={placeholder} onChange={(e) => setV(e.target.value)} onBlur={commit} />
      ) : (
        <input
          value={v}
          placeholder={placeholder}
          onChange={(e) => setV(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => e.key === 'Enter' && (e.target as HTMLInputElement).blur()}
        />
      )}
    </label>
  )
}

/** Zahl in Sekunden (Komma oder Punkt nach Sprache, beides wird gelesen), intern Ticks. */
function Seconds({ label, value, onCommit, min = 0 }: { label: string; value: number; onCommit: (ticks: number) => void; min?: number }) {
  const text = decimal(sec(value).toFixed(2))
  return (
    <Field
      label={label}
      value={text}
      onCommit={(v) => {
        const n = parseFloat(v.replace(',', '.'))
        if (Number.isFinite(n) && n >= min) onCommit(Math.round(n * TPS))
      }}
    />
  )
}

export function Inspector({ project, selection, models, onCommand, onGenerate, onSelect, asset, playhead, onDeleteAsset, onSpeed, onPlayhead }: Props) {
  const p = project
  if (!selection) return <ProjectProps p={p} onCommand={onCommand} />
  if (selection.type === 'asset') {
    return asset ? <AssetProps p={p} a={asset} playhead={playhead} onCommand={onCommand} onDelete={onDeleteAsset} /> : null
  }
  if ((selection.ids?.length ?? 1) > 1) return <ManyProps p={p} selection={selection} onCommand={onCommand} onGenerate={onGenerate} onSelect={onSelect} />
  if (selection.type === 'scene') {
    const s = p.scenes.find((x) => x.id === selection.id)
    return s ? <SceneProps p={p} s={s} models={models} onCommand={onCommand} onGenerate={onGenerate} /> : null
  }
  if (selection.type === 'clip') {
    const c = p.clips.find((x) => x.id === selection.id)
    return c ? <ClipProps p={p} c={c} onCommand={onCommand} onSelect={onSelect} onSpeed={onSpeed} playhead={playhead} onPlayhead={onPlayhead} /> : null
  }
  if (selection.type === 'transition') {
    const c = p.clips.find((x) => x.id === selection.id)
    return c?.transition ? <TransitionProps p={p} c={c} onCommand={onCommand} onSelect={onSelect} /> : null
  }
  const m = p.markers.find((x) => x.id === selection.id)
  return m ? <MarkerProps p={p} m={m} onCommand={onCommand} /> : null
}

/** Mehrere Objekte derselben Art (Rahmen oder Umschalt-Klick): was für alle gilt. */
function ManyProps({ p, selection, onCommand, onGenerate, onSelect }: {
  p: StudioProject
  selection: NonNullable<Selection>
  onCommand: Props['onCommand']
  onGenerate: Props['onGenerate']
  onSelect: Props['onSelect']
}) {
  const ids = selIds(selection, selection.type)
  const batch = (command: string, items: Record<string, unknown>[]) =>
    onCommand('batch', { commands: items.map((params) => ({ command, params })) })
  if (selection.type === 'clip') {
    const clips = p.clips.filter((c) => ids.includes(c.id))
    const allMuted = clips.every((c) => c.muted)
    const from = Math.min(...clips.map((c) => c.start))
    const to = Math.max(...clips.map((c) => c.start + clipLength(c)))
    return (
      <div className="st-inspector">
        <h3>{t(`${clips.length} Clips`, `${clips.length} clips`)}</h3>
        <p className="muted small">
          {t(`Von ${decimal(sec(from).toFixed(2))} bis ${decimal(sec(to).toFixed(2))} s. Ziehen verschiebt alle zusammen, auch auf eine andere Spur.`,
            `From ${decimal(sec(from).toFixed(2))} to ${decimal(sec(to).toFixed(2))} s. Dragging moves them all together, also to another track.`)}
        </p>
        <div className="st-actions">
          <button className="btn small ghost" onClick={() => batch('clip.update', clips.map((c) => ({ id: c.id, muted: !allMuted })))}>
            {allMuted ? t('Ton an', 'Unmute') : t('Stumm schalten', 'Mute')}
          </button>
          <button className="btn small ghost" onClick={() => batch('clip.update', clips.map((c) => ({ id: c.id, transition: { kind: 'dissolve', duration_s: 0.5 } })))}>
            {t('Überblendung 0,5 s an jeden', 'Dissolve 0.5 s on each')}
          </button>
        </div>
        <div className="st-actions">
          <button className="btn small ghost" onClick={() => { onCommand('clip.delete', { ids }); onSelect(null) }}>{t('Löschen', 'Delete')}</button>
          <button className="btn small ghost" onClick={() => { onCommand('clip.delete', { ids, ripple: true }); onSelect(null) }}>
            {t('Löschen, Lücken schließen', 'Delete, close gaps')}
          </button>
        </div>
      </div>
    )
  }
  if (selection.type === 'scene') {
    const scenes = p.scenes.filter((s) => ids.includes(s.id))
    const busy = scenes.filter((s) => s.status === 'running' || s.status === 'waiting').length
    return (
      <div className="st-inspector">
        <h3>{t(`${scenes.length} Szenen`, `${scenes.length} scenes`)}</h3>
        <p className="muted small">{t('Ziehen verschiebt alle zusammen.', 'Dragging moves them all together.')}</p>
        <div className="st-actions">
          <button className="btn primary small" disabled={busy === scenes.length} onClick={() => onGenerate(scenes.filter((s) => s.status !== 'running' && s.status !== 'waiting').map((s) => s.id))}>
            {t('Alle erzeugen', 'Generate all')}
          </button>
          <button className="btn small ghost" onClick={() => { batch('scene.delete', scenes.map((s) => ({ id: s.id }))); onSelect(null) }}>{t('Löschen', 'Delete')}</button>
        </div>
      </div>
    )
  }
  const markers = p.markers.filter((m) => ids.includes(m.id))
  const allDone = markers.every((m) => m.done)
  return (
    <div className="st-inspector">
      <h3>{t(`${markers.length} Marker`, `${markers.length} markers`)}</h3>
      <div className="st-actions">
        <button className="btn small ghost" onClick={() => batch('marker.update', markers.map((m) => ({ id: m.id, done: !allDone })))}>
          {allDone ? t('Wieder offen', 'Reopen') : t('Erledigt', 'Done')}
        </button>
        <button className="btn small ghost" onClick={() => { batch('marker.delete', markers.map((m) => ({ id: m.id }))); onSelect(null) }}>{t('Löschen', 'Delete')}</button>
      </div>
    </div>
  )
}

function SceneProps({ p, s, models, onCommand, onGenerate }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  onCommand: Props['onCommand']
  onGenerate: Props['onGenerate']
}) {
  const update = (fields: Record<string, unknown>) => onCommand('scene.update', { id: s.id, ...fields })
  const modelKind = s.lane === 'video' ? (s.kind === 'image' ? 'image' : 'video') : 'audio'
  const usable = models.filter((m) => m.kind === modelKind && m.installed)
  const earlier = p.scenes.filter((x) => x.lane === 'video' && x.id !== s.id && x.start < s.start)
  return (
    <div className="st-inspector">
      <h3>
        {t('Szene', 'Scene')} · {LANE_LABEL[s.lane]}
        <span className={`badge ${s.status === 'done' ? 'done' : s.status === 'error' ? 'error' : ''}`}>
          {s.status === 'running' ? t('wird erzeugt', 'generating') : s.status === 'waiting' ? t('wartet', 'waiting') : s.status === 'done' ? t('fertig', 'done') : s.status === 'error' ? t('Fehler', 'error') : t('leer', 'empty')}
        </span>
      </h3>
      {s.error && <p className="warn-text small">{s.error}</p>}
      {s.status === 'waiting' && (
        <p className="muted small">
          {t(`Wartet auf „${sceneName(p, s.waiting_for)}“: Deren letztes Bild wird das Startbild.`, `Waiting for "${sceneName(p, s.waiting_for)}": its last frame becomes the start image.`)}
        </p>
      )}
      <Field label={t('Titel', 'Title')} value={s.title} onCommit={(v) => update({ title: v })} />
      <Field
        label={s.lane === 'video' ? t('Prompt (was zu sehen ist und wie es sich bewegt)', 'Prompt (what is seen and how it moves)') : t('Prompt (Klang, Stil, Tempo)', 'Prompt (sound, style, tempo)')}
        value={s.prompt}
        area
        rows={6}
        placeholder={s.lane === 'video' ? t(
          'Ein Absatz: Einstellung, Handlung, Kamera, Ton. Personen: Gesicht im Bild lassen, sonst erfindet LTX ein neues; sprechen nur mit Gesicht im Bild, die Stimme immer gleich beschreiben („in a warm, cheerful, clear female voice“).',
          'One paragraph: shot, action, camera, sound. People: keep the face in the picture, or LTX invents a new one; let them speak only with their face in the shot and describe the voice the same way every time ("in a warm, cheerful, clear female voice").',
        ) : undefined}
        onCommit={(v) => update({ prompt: v })}
      />
      <div className="st-grid2">
        <label className="st-field">
          <span>{t('Bahn', 'Lane')}</span>
          <select value={s.lane} onChange={(e) => update({ lane: e.target.value, kind: e.target.value === 'video' ? 'video' : 'audio' })}>
            {Object.entries(LANE_LABEL).map(([id, label]) => (
              <option key={id} value={id}>{label}</option>
            ))}
          </select>
        </label>
        {s.lane === 'video' && (
          <label className="st-field">
            <span>{t('Art', 'Kind')}</span>
            <select value={s.kind} onChange={(e) => update({ kind: e.target.value })}>
              <option value="video">{t('Videoclip', 'Video clip')}</option>
              <option value="image">{t('Standbild', 'Still image')}</option>
            </select>
          </label>
        )}
        <Seconds label={t('Start (s)', 'Start (s)')} value={s.start} onCommit={(v) => update({ start: v })} />
        <Seconds label={t('Dauer (s)', 'Duration (s)')} value={s.duration} min={0.1} onCommit={(v) => update({ duration: v })} />
      </div>
      <label className="st-field">
        <span>{t('Modell', 'Model')}</span>
        <select value={s.model_id ?? ''} onChange={(e) => update({ model_id: e.target.value || null })}>
          <option value="">{t('aktives Modell', 'active model')}</option>
          {usable.map((m) => (
            <option key={m.id} value={m.id}>{m.name}</option>
          ))}
        </select>
      </label>
      {s.lane === 'video' && s.kind === 'video' && (
        <label className="st-field">
          <span>{t('Anschluss an', 'Chain to')}</span>
          <select value={s.chain_from ?? ''} disabled={!!s.chain_marker} onChange={(e) => update({ chain_from: e.target.value || null })}>
            <option value="">{t('— keins —', '— none —')}</option>
            {earlier.map((x) => (
              <option key={x.id} value={x.id}>{x.title || x.prompt.slice(0, 40) || x.id}</option>
            ))}
          </select>
          {s.chain_marker && (
            <span className="small">{t('Kommt vom Anschluss-Marker. Zum Ändern den Marker verschieben oder löschen.', 'Set by a chain marker. Move or delete the marker to change it.')}</span>
          )}
        </label>
      )}
      <div className="st-actions">
        <button className="btn primary small" disabled={s.status === 'running' || s.status === 'waiting'} onClick={() => onGenerate([s.id])}>
          {s.take ? t('Neu erzeugen', 'Generate again') : t('Erzeugen', 'Generate')}
        </button>
        <button className="btn small ghost" onClick={() => onCommand('scene.delete', { id: s.id })}>{t('Löschen', 'Delete')}</button>
      </div>
      <h4>{t('Takes', 'Takes')} ({s.takes.length})</h4>
      {s.takes.length === 0 && (
        <p className="muted small">{t('Noch keine. Erzeugen oder ein Asset aus der Medienleiste auf die Szene ziehen.', 'None yet. Generate, or drag an asset from the media bin onto the scene.')}</p>
      )}
      <div className="st-takes">
        {s.takes.map((id, i) => {
          const a = p.assets[id]
          return (
            <button key={id} className={`st-take${s.take === id ? ' st-sel' : ''}`} onClick={() => onCommand('scene.take', { id: s.id, asset_id: id })} title={a?.prompt}>
              {a?.kind === 'image' ? <img src={a.url} alt="" /> : a?.kind === 'video' ? <video src={`${a.url}#t=0.1`} preload="metadata" muted /> : <span>♪</span>}
              <span className="small">{i + 1}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

function ProjectProps({ p, onCommand }: { p: StudioProject; onCommand: Props['onCommand'] }) {
  const s = p.settings
  const fps = s.fps[0] / s.fps[1]
  const format = FORMATS.findIndex((f) => f.w === s.width && f.h === s.height)
  return (
    <div className="st-inspector">
      <h3>{t('Projekt', 'Project')}</h3>
      <Field label={t('Name', 'Name')} value={p.name} onCommit={(v) => v.trim() && onCommand('project.update', { name: v.trim() })} />
      <div className="st-grid2">
        <label className="st-field">
          <span>{t('Format', 'Format')}</span>
          <select
            value={format}
            onChange={(e) => {
              const f = FORMATS[Number(e.target.value)]
              if (f) onCommand('project.update', { width: f.w, height: f.h })
            }}
          >
            {format < 0 && <option value={-1}>{s.width} × {s.height}</option>}
            {FORMATS.map((f, i) => (
              <option key={f.label} value={i}>{f.label}</option>
            ))}
          </select>
        </label>
        <label className="st-field">
          <span>{t('Bildrate', 'Frame rate')}</span>
          <select value={FRAME_RATES.includes(fps) ? fps : ''} onChange={(e) => onCommand('project.update', { fps: [Number(e.target.value), 1] })}>
            {!FRAME_RATES.includes(fps) && <option value="">{decimal(fps.toFixed(3))}</option>}
            {FRAME_RATES.map((r) => (
              <option key={r} value={r}>{r} fps</option>
            ))}
          </select>
        </label>
      </div>
      <label className="st-field">
        <span>{t('Videoszenen (LTX-2.5)', 'Video scenes (LTX-2.5)')}</span>
        <select value={s.video_quality ?? 'dfr'} onChange={(e) => onCommand('project.update', { video_quality: e.target.value })}>
          <option value="dfr">{t('Höchste Qualität (DFR), rund 3× so lang', 'Best quality (DFR), about 3× as long')}</option>
          <option value="standard">{t('Standard, schneller', 'Standard, faster')}</option>
        </select>
      </label>
      <p className="muted small">
        {t(`${p.scenes.length} Szenen, ${p.clips.length} Clips, Schnitt ${decimal(sec(p.edit_duration).toFixed(1))} s.`,
          `${p.scenes.length} scenes, ${p.clips.length} clips, edit ${decimal(sec(p.edit_duration).toFixed(1))} s.`)}{' '}
        {t('LTX-2.5 rechnet mit 24 fps, 1080p als 1920 × 1088; den Rand schneidet der Export ab. Gemessen 5 s 1080p: DFR 786 s, Standard 241 s. DFR braucht das Detail-IC-LoRA (unter „Modelle“), sonst gilt Standard.',
          'LTX-2.5 renders at 24 fps, 1080p as 1920 × 1088; the export crops the edge. Measured 5 s at 1080p: DFR 786 s, standard 241 s. DFR needs the detail IC-LoRA (under "Models"), otherwise standard applies.')}
      </p>
      <h4>{t('So geht es', 'How it works')}</h4>
      <p className="muted small">
        {t('Eine Szene, einen Clip, einen Marker oder links Material anklicken; Rechtsklick zeigt überall, was geht. Werkzeuge links oben: Auswahl (V), Schneiden (C), Magnet (S, ohne Magnet andocken mit Umschalt). Mehrere Objekte: Rahmen im Leeren aufziehen oder Umschalt-Klick. Leertaste spielt ab, Strg+K schneidet am Abspielkopf, Strg+C/X/V kopiert, schneidet aus, fügt am Abspielkopf ein, Strg+D setzt eine Überblendung, Entf löscht, Esc zeigt wieder den Schnitt. Spuren: Rechtsklick auf V1, A1 … fügt hinzu oder entfernt, Auge und Lautsprecher schalten Bild und Ton (auch im Export).',
          'Click a scene, a clip, a marker or media on the left; right-click anywhere shows what you can do. Tools at the top left: Selection (V), Razor (C), Magnet (S; without it, hold Shift to dock). Several objects: drag a box in empty space or Shift-click. Space plays, Ctrl+K cuts at the playhead, Ctrl+C/X/V copies, cuts, pastes at the playhead, Ctrl+D adds a dissolve, Del deletes, Esc shows the edit again. Tracks: right-click V1, A1 … to add or remove, the eye and speaker switch picture and sound (also in the export).')}
      </p>
    </div>
  )
}

function AssetProps({ p, a, playhead, onCommand, onDelete }: {
  p: StudioProject
  a: Asset
  playhead: number
  onCommand: Props['onCommand']
  onDelete: Props['onDeleteAsset']
}) {
  const [asking, setAsking] = useState(false)
  useEffect(() => setAsking(false), [a.id])
  const kind = mediaKind(a)
  const m = a.meta ?? {}
  const used = p.clips.some((c) => c.asset_id === a.id)
  const track = kind === 'audio' ? trackOrHighest(p, 'A2', 'audio') : 'V1'
  const created = new Date(a.created_at * 1000).toLocaleString(t('de-DE', 'en-GB'), { dateStyle: 'short', timeStyle: 'short' })
  const rows: [string, string][] = []
  if (m.model_name) rows.push([t('Modell', 'Model'), String(m.model_name)])
  const facts = assetFacts(a)
  if (facts.length) rows.push([t('Länge, Größe', 'Length, size'), facts.join(' · ')])
  // Exporte melden die Bildrate als [Zähler, Nenner], erzeugte Videos als Zahl
  const fps = Array.isArray(m.fps) ? m.fps[0] / m.fps[1] : Number(m.fps)
  if (fps) rows.push([t('Bildrate', 'Frame rate'), `${decimal(String(Math.round(fps * 1000) / 1000))} fps`])
  if (m.seed !== undefined && m.seed !== null) rows.push(['Seed', String(m.seed)])
  rows.push([t('Erstellt', 'Created'), created])
  // Projektordner (seit 0.5.15); oberste Ebene = der allgemeine Verlauf
  rows.push([t('Ordner', 'Folder'), a.folder ? a.folder.split('/').pop()! : t('Verlauf', 'History')])
  return (
    <div className="st-inspector">
      <h3>
        {t('Material', 'Media')} · {kind === 'video' ? t('Video', 'Video') : kind === 'audio' ? t('Ton', 'Audio') : t('Bild', 'Image')}
        {used && <span className="badge">{t('im Schnitt', 'in edit')}</span>}
      </h3>
      <p className="st-asset-prompt small">{assetLabel(a)}</p>
      <table className="st-facts small">
        <tbody>
          {rows.map(([k, v]) => (
            <tr key={k}>
              <td className="muted">{k}</td>
              <td>{v}</td>
            </tr>
          ))}
          {kind === 'video' && a.kind !== 'upload' && (
            <tr>
              <td className="muted">{t('Verlustfrei', 'Lossless')}</td>
              <td>
                {m.preset === 'master' ? (
                  t('ja, diese Datei (FFV1)', 'yes, this file (FFV1)')
                ) : m.preset === 'prores' ? (
                  t('ProRes 4444, fast verlustfrei', 'ProRes 4444, near lossless')
                ) : m.master ? (
                  <a href={fileUrl(m.master)} download title={t('FFV1 in MKV, Ton als Float-PCM', 'FFV1 in MKV, sound as float PCM')}>
                    {t('MKV herunterladen', 'Download MKV')}
                  </a>
                ) : m.studio_project ? (
                  t('nein, ein Export', 'no, an export')
                ) : m.imported ? (
                  t('nein, ohne verlustfreie Kopie importiert', 'no, imported without the lossless copy')
                ) : (
                  t('nein (vor 0.5.13 oder abgeschaltet)', 'no (before 0.5.13 or switched off)')
                )}
              </td>
            </tr>
          )}
        </tbody>
      </table>
      <div className="st-actions">
        <button className="btn small primary" onClick={() => onCommand('clip.add', { track, asset_id: a.id, start: playhead })}>
          {t(`Am Abspielkopf einfügen (${track})`, `Insert at the playhead (${track})`)}
        </button>
        <a className="btn small ghost" href={a.url} target="_blank" rel="noreferrer">{t('Datei öffnen', 'Open file')}</a>
      </div>
      <div className="st-actions">
        <button
          className="btn small ghost"
          disabled={used}
          title={used ? t('Liegt im Schnitt: erst den Clip löschen.', 'It is in the edit: delete the clip first.') : undefined}
          onClick={() => {
            if (!asking) {
              setAsking(true)
              return
            }
            setAsking(false)
            onDelete(a)
          }}
        >
          {asking ? t('Wirklich löschen? Die Datei ist dann weg.', 'Really delete? The file will be gone.') : t('Löschen', 'Delete')}
        </button>
      </div>
    </div>
  )
}

/** Auswahl der Übergangsart (klassisch gerechnet, in Vorschau und Export gleich). */
function TransitionKind({ value, onChange }: { value: StudioTransitionKind; onChange: (k: StudioTransitionKind) => void }) {
  return (
    <label className="st-field">
      <span>{t('Art', 'Kind')}</span>
      <select value={value} onChange={(e) => onChange(e.target.value as StudioTransitionKind)}>
        {Object.entries(TRANSITION_LABEL).map(([id, label]) => (
          <option key={id} value={id}>{label}</option>
        ))}
      </select>
    </label>
  )
}

/** Geschwindigkeit in Prozent (wie FilmCraft: In und Out bleiben, die Länge ändert sich). */
function Speed({ c, onSpeed }: { c: StudioClip; onSpeed: Props['onSpeed'] }) {
  const pct = Math.round(clipSpeed(c) * 1000) / 10
  return (
    <Field
      label={t('Geschwindigkeit (%)', 'Speed (%)')}
      value={decimal(String(pct))}
      onCommit={(v) => {
        const n = parseFloat(v.replace(',', '.').replace('%', ''))
        if (Number.isFinite(n) && n >= 10 && n <= 1000 && n !== pct) onSpeed(c, n / 100)
      }}
    />
  )
}

function ClipProps({ p, c, onCommand, onSelect, onSpeed, playhead, onPlayhead }: {
  p: StudioProject
  c: StudioClip
  onCommand: Props['onCommand']
  onSelect: Props['onSelect']
  onSpeed: Props['onSpeed']
  playhead: number
  onPlayhead: (t: number) => void
}) {
  const media = p.media[c.asset_id]
  const scene = c.scene_id ? p.scenes.find((s) => s.id === c.scene_id) : undefined
  const update = (fields: Record<string, unknown>) => onCommand('clip.update', { id: c.id, ...fields })
  const speed = clipSpeed(c)
  return (
    <div className="st-inspector">
      <h3>{t('Clip', 'Clip')} · {c.track}</h3>
      <p className="muted small">{p.assets[c.asset_id]?.prompt || c.asset_id}</p>
      {scene && (
        <button className="link-btn small" onClick={() => onSelect({ type: 'scene', id: scene.id })}>
          {t('aus Szene', 'from scene')}: {scene.title || scene.prompt.slice(0, 40)}
        </button>
      )}
      <div className="st-grid2">
        <Seconds label={t('Start (s)', 'Start (s)')} value={c.start} onCommit={(v) => onCommand('clip.move', { id: c.id, start: v })} />
        <Seconds label={t('Länge (s)', 'Length (s)')} value={clipLength(c)} min={0.04} onCommit={(v) => onCommand('clip.trim', { id: c.id, out: c.in + Math.round(v * speed) })} />
        <Seconds label={t('In (s)', 'In (s)')} value={c.in} onCommit={(v) => onCommand('clip.trim', { id: c.id, in: v })} />
        <Seconds label={t('Out (s)', 'Out (s)')} value={c.out} onCommit={(v) => onCommand('clip.trim', { id: c.id, out: v })} />
        {media?.kind !== 'image' && <Speed c={c} onSpeed={onSpeed} />}
      </div>
      {media?.kind !== 'image' && speed !== 1 && (
        <p className="muted small">
          {t('In und Out sind Zeiten im Material. Der Ton behält seine Tonhöhe.', 'In and Out are times in the material. The sound keeps its pitch.')}
        </p>
      )}
      {media?.kind !== 'image' && (
        <>
          <label className="st-field">
            <span>{t('Lautstärke', 'Volume')}: {c.gain_db > 0 ? '+' : ''}{c.gain_db} dB</span>
            <input type="range" min={-30} max={12} step={1} value={c.gain_db} onChange={(e) => update({ gain_db: Number(e.target.value) })} />
          </label>
          <label className="st-check">
            <input type="checkbox" checked={c.muted} onChange={(e) => update({ muted: e.target.checked })} />
            <span>{t('Stumm', 'Muted')}</span>
          </label>
        </>
      )}
      <label className="st-check">
        <input
          type="checkbox"
          checked={!!c.transition}
          onChange={(e) => update({ transition: e.target.checked ? { kind: 'dissolve', duration_s: 0.5 } : null })}
        />
        <span>{t('Übergang vom vorigen Clip', 'Transition from the previous clip')}</span>
      </label>
      {c.transition && (
        <div className="st-grid2">
          <TransitionKind value={c.transition.kind} onChange={(kind) => update({ transition: { kind, duration: c.transition!.duration } })} />
          <Seconds
            label={t('Dauer (s)', 'Duration (s)')}
            value={c.transition.duration}
            min={0.04}
            onCommit={(v) => update({ transition: { kind: c.transition!.kind, duration: v } })}
          />
        </div>
      )}
      {p.tracks.find((tr) => tr.id === c.track)?.kind === 'video' && (
        <ScaleSection p={p} c={c} playhead={playhead} onCommand={onCommand} onPlayhead={onPlayhead} />
      )}
      <div className="st-actions">
        <button className="btn small ghost" onClick={() => onCommand('clip.delete', { ids: [c.id] })}>{t('Löschen', 'Delete')}</button>
        <button className="btn small ghost" onClick={() => onCommand('clip.delete', { ids: [c.id], ripple: true })}>
          {t('Löschen, Lücke schließen', 'Delete, close gap')}
        </button>
      </div>
    </div>
  )
}

/** Regler, der erst beim Loslassen meldet: ein Schritt im Rückgängig statt eines je Pixel. */
function CommitRange({ value, min, max, onCommit }: { value: number; min: number; max: number; onCommit: (v: number) => void }) {
  const [draft, setDraft] = useState<number | null>(null)
  const commit = () => {
    if (draft !== null && draft !== value) onCommit(draft)
    setDraft(null)
  }
  return (
    <input type="range" min={min} max={max} step={1} value={draft ?? value}
      onChange={(e) => setDraft(Number(e.target.value))} onPointerUp={commit} onKeyUp={commit} onBlur={commit} />
  )
}

/** Skalieren (seit 0.5.16): Wert am Abspielkopf, Fokuspunkt, Keyframes. */
function ScaleSection({ p, c, playhead, onCommand, onPlayhead }: {
  p: StudioProject
  c: StudioClip
  playhead: number
  onCommand: Props['onCommand']
  onPlayhead: (t: number) => void
}) {
  const keys = c.scale_keys ?? []
  const inside = playhead >= c.start && playhead <= clipEnd(c)
  const at = inside ? playhead : c.start
  const media = mediaAt(c, at - c.start)
  const value = clipScaleAt(c, media)
  const near = (frameTicks(p) * clipSpeed(c)) / 2
  const keyHere = keys.some((k) => Math.abs(k.at - media) <= near)
  const anchor = c.anchor ?? [0.5, 0.5]
  const times = keys.map((k) => keyTime(c, k.at)).filter((x) => x >= c.start && x <= clipEnd(c))
  const prev = [...times].reverse().find((x) => x < playhead - near)
  const next = times.find((x) => x > playhead + near)
  const setValue = (percent: number) => {
    const v = Math.min(SCALE_MAX, Math.max(SCALE_MIN, percent / 100))
    if (keys.length && inside) onCommand('clip.key', { id: c.id, at, value: v })
    else if (!keys.length) onCommand('clip.update', { id: c.id, scale: v })
  }
  const setAnchor = (i: 0 | 1, percent: number) => {
    const a: [number, number] = [anchor[0], anchor[1]]
    a[i] = percent / 100
    onCommand('clip.update', { id: c.id, anchor: a })
  }
  return (
    <>
      <h4>{t('Skalieren', 'Scale')}</h4>
      <label className="st-field">
        <span>
          {t('Skalierung', 'Scale')}: {Math.round(value * 100)} %
          {keys.length > 0 && (keyHere ? ' ◆' : inside ? t(' (zwischen Keyframes)', ' (between keyframes)') : t(' (Abspielkopf außerhalb)', ' (playhead outside)'))}
        </span>
        <CommitRange value={Math.round(value * 100)} min={10} max={400} onCommit={setValue} />
      </label>
      <div className="st-grid2">
        <label className="st-field">
          <span>{t('Fokuspunkt X', 'Focus point X')}: {Math.round(anchor[0] * 100)} %</span>
          <CommitRange value={Math.round(anchor[0] * 100)} min={0} max={100} onCommit={(v) => setAnchor(0, v)} />
        </label>
        <label className="st-field">
          <span>{t('Fokuspunkt Y', 'Focus point Y')}: {Math.round(anchor[1] * 100)} %</span>
          <CommitRange value={Math.round(anchor[1] * 100)} min={0} max={100} onCommit={(v) => setAnchor(1, v)} />
        </label>
      </div>
      <div className="st-actions">
        <button className="btn small" disabled={!inside} onClick={() => onCommand('clip.key', { id: c.id, at, value })}
          title={t('Keyframe mit dem jetzigen Wert am Abspielkopf', 'Keyframe with the current value at the playhead')}>
          ◆ {t('Keyframe setzen', 'Set keyframe')}
        </button>
        <button className="btn small ghost" disabled={!keyHere || !inside} onClick={() => onCommand('clip.key', { id: c.id, at, delete: true })}>
          {t('Keyframe löschen', 'Delete keyframe')}
        </button>
        <button className="btn small ghost" disabled={prev === undefined} onClick={() => prev !== undefined && onPlayhead(prev)}
          title={t('Voriger Keyframe', 'Previous keyframe')}>◀ ◆</button>
        <button className="btn small ghost" disabled={next === undefined} onClick={() => next !== undefined && onPlayhead(next)}
          title={t('Nächster Keyframe', 'Next keyframe')}>◆ ▶</button>
        {keys.length > 0 && (
          <button className="btn small ghost" onClick={() => onCommand('clip.key', { id: c.id, clear: true })}>
            {t(`Alle ${keys.length} Keyframes löschen`, `Delete all ${keys.length} keyframes`)}
          </button>
        )}
      </div>
      <p className="muted small">
        {t('Werkzeug Skalieren (Z): im Monitor ziehen setzt einen Keyframe am Abspielkopf, ein Klick den Fokuspunkt. Zwischen zwei Keyframes läuft die Skalierung gleichmäßig; unter 100 % scheint die Spur darunter durch. Keyframes hängen am Material und wandern beim Schneiden mit.',
          'Scale tool (Z): dragging in the monitor sets a keyframe at the playhead, a click the focus point. Between two keyframes the scale changes evenly; below 100 % the track underneath shows through. Keyframes stick to the material and move with it when you cut.')}
      </p>
    </>
  )
}

function TransitionProps({ p, c, onCommand, onSelect }: { p: StudioProject; c: StudioClip; onCommand: Props['onCommand']; onSelect: Props['onSelect'] }) {
  const tr = c.transition!
  const update = (fields: Record<string, unknown>) => onCommand('clip.update', { id: c.id, transition: { kind: tr.kind, duration: tr.duration, ...fields } })
  const marker = tr.marker ? p.markers.find((m) => m.id === tr.marker) : undefined
  return (
    <div className="st-inspector">
      <h3>{t('Übergang', 'Transition')} · {c.track}</h3>
      <p className="muted small">
        {t('Klassisch gerechnet, ohne KI: Vorschau und Export zeigen dasselbe. Der vorige Clip läuft dafür über sein Ende hinaus weiter; reicht sein Material nicht, steht sein letztes Bild.',
          'Computed classically, no AI: preview and export show the same. The previous clip runs on past its end; if its material runs out, its last frame holds.')}
      </p>
      <div className="st-grid2">
        <TransitionKind value={tr.kind} onChange={(kind) => update({ kind })} />
        <Seconds label={t('Dauer (s)', 'Duration (s)')} value={tr.duration} min={0.04} onCommit={(v) => update({ duration: v })} />
      </div>
      {marker && (
        <button className="link-btn small" onClick={() => onSelect({ type: 'marker', id: marker.id })}>
          {t('Kommt vom Übergang-Marker', 'Comes from the transition marker')} {marker.name ? t(`„${marker.name}“`, `"${marker.name}"`) : ''}
        </button>
      )}
      <div className="st-actions">
        <button className="btn small ghost" onClick={() => onSelect({ type: 'clip', id: c.id })}>{t('Zum Clip', 'To the clip')}</button>
        <button className="btn small ghost" onClick={() => { onCommand('clip.update', { id: c.id, transition: null }); onSelect({ type: 'clip', id: c.id }) }}>
          {t('Entfernen', 'Remove')}
        </button>
      </div>
    </div>
  )
}

function MarkerProps({ p, m, onCommand }: { p: StudioProject; m: StudioMarker; onCommand: Props['onCommand'] }) {
  const update = (fields: Record<string, unknown>) => onCommand('marker.update', { id: m.id, ...fields })
  const sceneSelect = (lanes: StudioLane[]) => (
    <label className="st-field">
      <span>{t('Szene', 'Scene')}</span>
      <select value={m.params.scene_id ?? ''} onChange={(e) => update({ params: { scene_id: e.target.value || null } })}>
        <option value="">{t('— wählen —', '— choose —')}</option>
        {p.scenes.filter((s) => lanes.includes(s.lane)).map((s) => (
          <option key={s.id} value={s.id}>{s.title || s.prompt.slice(0, 40) || s.id}</option>
        ))}
      </select>
    </label>
  )
  return (
    <div className="st-inspector">
      <h3>{t('Marker', 'Marker')}</h3>
      <label className="st-field">
        <span>{t('Art', 'Kind')}</span>
        <select value={m.kind} onChange={(e) => update({ kind: e.target.value, color: null })}>
          {Object.entries(MARKER_LABEL).map(([id, label]) => (
            <option key={id} value={id}>{label}</option>
          ))}
        </select>
      </label>
      <p className="muted small">{MARKER_HINT[m.kind]}</p>
      <Field label={t('Name', 'Name')} value={m.name} onCommit={(v) => update({ name: v })} />
      <Field
        label={m.kind === 'ai' ? t('Auftrag an die KI', 'Task for the AI') : t('Kommentar', 'Comment')}
        value={m.comment}
        area
        rows={m.kind === 'ai' ? 5 : 3}
        placeholder={m.kind === 'ai' ? t('z. B. „Diese Szene ruhiger, die Kamera steht.“', 'e.g. "Calmer here, the camera stays still."') : ''}
        onCommit={(v) => update({ comment: v })}
      />
      <div className="st-grid2">
        <Seconds label={t('Position (s)', 'Position (s)')} value={m.at} onCommit={(v) => update({ at: v })} />
        <Seconds label={t('Dauer (s)', 'Duration (s)')} value={m.duration} onCommit={(v) => update({ duration: v })} />
      </div>
      {m.kind === 'place' && (
        <>
          {sceneSelect(['video'])}
          <label className="st-field">
            <span>{t('Spur', 'Track')}</span>
            <select value={trackOrHighest(p, m.params.track ?? 'V2', 'video')} onChange={(e) => update({ params: { track: e.target.value } })}>
              {tracksOf(p, 'video').map((tr, i) => (
                <option key={tr.id} value={tr.id}>{tr.id}{i === 0 ? ` (${t('oben', 'top')})` : ''}</option>
              ))}
            </select>
          </label>
        </>
      )}
      {m.kind === 'audio' && sceneSelect(['voice', 'music', 'sfx'])}
      {m.kind === 'transition' && (
        <div className="st-grid2">
          <TransitionKind value={m.params.transition ?? 'dissolve'} onChange={(kind) => update({ params: { transition: kind } })} />
          {!m.duration && (
            <Seconds
              label={t('Dauer (s)', 'Duration (s)')}
              value={Math.round((m.params.seconds ?? 0.5) * TPS)}
              min={0.04}
              onCommit={(v) => update({ params: { seconds: v / TPS } })}
            />
          )}
        </div>
      )}
      <label className="st-check">
        <input type="checkbox" checked={m.done} onChange={(e) => update({ done: e.target.checked })} />
        <span>{t('Erledigt', 'Done')}</span>
      </label>
      <div className="st-actions">
        <button className="btn small ghost" onClick={() => onCommand('marker.delete', { id: m.id })}>{t('Löschen', 'Delete')}</button>
      </div>
    </div>
  )
}
