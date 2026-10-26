// Eigenschaften der Auswahl: Szene (Prompt, Modell, Länge, Anschluss, Takes), Clip (In/Out, Lautstärke,
// Überblendung), Marker (Art, Auftrag, Angaben je Art) oder Material (Angaben, Einfügen, Löschen); ohne Auswahl das
// Projekt (Format, Bildrate). Eingaben gelten beim Verlassen des Feldes oder mit Enter; jede Änderung am Projekt ist
// ein Befehl und lässt sich rückgängig machen.

import { useEffect, useState } from 'react'
import {
  TPS,
  type Asset,
  type ModelInfo,
  type StudioClip,
  type StudioLane,
  type StudioMarker,
  type StudioMarkerKind,
  type StudioProject,
  type StudioScene,
} from '../api'
import { t } from '../i18n'
import { assetFacts, assetLabel, mediaKind } from './Bin'
import { decimal, sec } from './time'
import type { Selection } from './Timelines'

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
  transition: t('Beim Übernehmen bekommt der Clip, der hier beginnt, eine Überblendung dieser Länge.',
    'On conform, the clip that starts here gets a dissolve of this length.'),
  chain: t('Beim Erzeugen beginnt die Videoszene an dieser Stelle mit dem letzten Bild der Szene davor (nahtloser Anschluss).',
    'On generate, the video scene starting here begins with the last frame of the scene before it (seamless chain).'),
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

export function Inspector({ project, selection, models, onCommand, onGenerate, onSelect, asset, playhead, onDeleteAsset }: Props) {
  const p = project
  if (!selection) return <ProjectProps p={p} onCommand={onCommand} />
  if (selection.type === 'asset') {
    return asset ? <AssetProps p={p} a={asset} playhead={playhead} onCommand={onCommand} onDelete={onDeleteAsset} /> : null
  }
  if (selection.type === 'scene') {
    const s = p.scenes.find((x) => x.id === selection.id)
    return s ? <SceneProps p={p} s={s} models={models} onCommand={onCommand} onGenerate={onGenerate} /> : null
  }
  if (selection.type === 'clip') {
    const c = p.clips.find((x) => x.id === selection.id)
    return c ? <ClipProps p={p} c={c} onCommand={onCommand} onSelect={onSelect} /> : null
  }
  const m = p.markers.find((x) => x.id === selection.id)
  return m ? <MarkerProps p={p} m={m} onCommand={onCommand} /> : null
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
          <span>{t('Anschluss: Startbild aus', 'Chain: start image from')}</span>
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
        {t('Eine Szene, einen Clip, einen Marker oder links Material anklicken. Doppelklick auf eine leere Bahn legt eine Szene an, auf die Markerzeile einen Marker. Leertaste spielt ab, C schneidet am Abspielkopf, Entf löscht, Esc zeigt wieder den Schnitt.',
          'Click a scene, a clip, a marker or media on the left. Double-click an empty lane to add a scene, the marker row to add a marker. Space plays, C cuts at the playhead, Del deletes, Esc shows the edit again.')}
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
  const track = kind === 'audio' ? 'A2' : 'V1'
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
                  <a href={`/files/${m.master}`} download title={t('FFV1 in MKV, Ton als Float-PCM', 'FFV1 in MKV, sound as float PCM')}>
                    {t('MKV herunterladen', 'Download MKV')}
                  </a>
                ) : m.studio_project ? (
                  t('nein, ein Export', 'no, an export')
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

function ClipProps({ p, c, onCommand, onSelect }: { p: StudioProject; c: StudioClip; onCommand: Props['onCommand']; onSelect: Props['onSelect'] }) {
  const media = p.media[c.asset_id]
  const scene = c.scene_id ? p.scenes.find((s) => s.id === c.scene_id) : undefined
  const update = (fields: Record<string, unknown>) => onCommand('clip.update', { id: c.id, ...fields })
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
        <Seconds label={t('Länge (s)', 'Length (s)')} value={c.out - c.in} min={0.04} onCommit={(v) => onCommand('clip.trim', { id: c.id, out: c.in + v })} />
        <Seconds label={t('In (s)', 'In (s)')} value={c.in} onCommit={(v) => onCommand('clip.trim', { id: c.id, in: v })} />
        <Seconds label={t('Out (s)', 'Out (s)')} value={c.out} onCommit={(v) => onCommand('clip.trim', { id: c.id, out: v })} />
      </div>
      {media?.kind !== 'image' && (
        <>
          <label className="st-field">
            <span>{t('Lautstärke', 'Volume')}: {c.gain_db > 0 ? '+' : ''}{c.gain_db} dB</span>
            <input type="range" min={-30} max={12} step={1} value={c.gain_db} onChange={(e) => update({ gain_db: Number(e.target.value) })} />
          </label>
          <label className="st-check">
            <input type="checkbox" checked={c.muted} onChange={(e) => update({ muted: e.target.checked })} /> {t('Stumm', 'Muted')}
          </label>
        </>
      )}
      <label className="st-check">
        <input
          type="checkbox"
          checked={!!c.transition}
          onChange={(e) => update({ transition: e.target.checked ? { kind: 'dissolve', duration_s: 0.5 } : null })}
        />{' '}
        {t('Überblenden vom vorigen Clip', 'Dissolve from the previous clip')}
      </label>
      {c.transition && (
        <Seconds
          label={t('Überblendung (s)', 'Dissolve (s)')}
          value={c.transition.duration}
          min={0.04}
          onCommit={(v) => update({ transition: { kind: 'dissolve', duration: v } })}
        />
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
            <select value={m.params.track ?? 'V2'} onChange={(e) => update({ params: { track: e.target.value } })}>
              <option value="V2">V2 ({t('oben', 'top')})</option>
              <option value="V1">V1</option>
            </select>
          </label>
        </>
      )}
      {m.kind === 'audio' && sceneSelect(['voice', 'music', 'sfx'])}
      {m.kind === 'transition' && !m.duration && (
        <Seconds
          label={t('Überblendung (s)', 'Dissolve (s)')}
          value={Math.round((m.params.seconds ?? 0.5) * TPS)}
          min={0.04}
          onCommit={(v) => update({ params: { seconds: v / TPS } })}
        />
      )}
      <label className="st-check">
        <input type="checkbox" checked={m.done} onChange={(e) => update({ done: e.target.checked })} /> {t('Erledigt', 'Done')}
      </label>
      <div className="st-actions">
        <button className="btn small ghost" onClick={() => onCommand('marker.delete', { id: m.id })}>{t('Löschen', 'Delete')}</button>
      </div>
    </div>
  )
}
