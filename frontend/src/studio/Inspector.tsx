// Eigenschaften der Auswahl: Szene (Prompt, Modell, Startbild, Länge, Anschluss, Takes), Clip (In/Out, Geschwindigkeit,
// Lautstärke, Übergang), Übergang (Art, Dauer), Marker (Art, Auftrag, Angaben je Art) oder Material (Angaben, Einfügen,
// Löschen); mehrere Objekte zeigen, was für alle gilt; ohne Auswahl das Projekt (Format, Bildrate). Eingaben gelten
// beim Verlassen des Feldes oder mit Enter; jede Änderung am Projekt ist ein Befehl und lässt sich rückgängig machen.

import { Fragment, useEffect, useRef, useState, type DragEvent as RDragEvent } from 'react'
import {
  api,
  fileUrl,
  LORA_BASE_LABEL,
  SPEECH_LANGUAGES,
  TPS,
  type Asset,
  type ModelInfo,
  type StudioCharacter,
  type StudioClip,
  type StudioLane,
  type StudioMarker,
  type StudioMarkerKind,
  type StudioProject,
  type StudioScene,
  type StudioTransitionKind,
  type ExpandTarget,
} from '../api'
import { ModelTip, type RecommendationMode } from '../components/Recommendations'
import { OutputBadge, licenseBlocked } from '../components/LicenseBadge'
import { totalSeconds } from '../flow/estimate'
import { useSceneEstimate, useStartImageEstimate } from '../flow/studio/estimates'
import {
  missingModel, modelKindOf, sceneModel, sceneNum, sceneRef, sceneState, spokenInVideo, wayChange, wayOf, withSources,
  type FlowCtx, type SceneFlow, type Way,
} from '../flow/studio/logic'
import { ModelLine, SceneFoot, SceneHead, SceneTakes, SceneToggles, StateNote, WaySeg } from '../flow/studio/SceneFocus'
import { fmtEta } from '../flow/time'
import { t } from '../i18n'
import { assetFacts, assetLabel, mediaKind } from './Bin'
import { SCALE_MAX, SCALE_MIN, clipEnd, clipLength, clipScaleAt, clipSpeed, decimal, frameTicks, keyTime, mediaAt, sec, snapFrame, tracksOf, trackOrHighest } from './time'
import { ASSET_MIME, selIds, TRANSITION_LABEL, type Selection } from './Timelines'
import { startImageUse } from '../videoStart'

interface Props {
  project: StudioProject
  selection: Selection
  models: ModelInfo[]
  /** aktive Modelle je Art (GET /api/health), für „aktives Modell (Name)“ */
  active?: Partial<Record<string, string | null>>
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
  /** Reiter „Modelle“ öffnen, wenn ein Modell fehlt */
  onShowModels?: () => void
  /** Konzept „NVAI im Fluss“, Bildschirm E (seit 0.5.42): Startbild-Aufträge, Fortschritt, Downloads und „In den Schnitt“
   *  vom Studio, damit der Zustand oben in der Szene stimmt */
  flow?: SceneFlow
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

function Field({ label, value, onCommit, area = false, rows = 4, placeholder, prompt = false }: {
  label: string
  value: string
  onCommit: (v: string) => void
  area?: boolean
  rows?: number
  placeholder?: string
  /** Prompt-Feld: etwas höher (st-prompt) */
  prompt?: boolean
}) {
  const [v, setV] = useState(value)
  // Zuletzt abgeschickter Text: verhindert, dass Verlassen und Verschwinden ihn doppelt schicken, solange die Antwort
  // aussteht. Kommt ein neuer Stand (Antwort, Rückgängig, Änderung per MCP), gilt er nicht mehr: Vorher ließ sich nach
  // Strg+Z derselbe Text nicht noch einmal speichern
  const committed = useRef<string | null>(null)
  useEffect(() => {
    setV(value)
    committed.current = null
  }, [value])
  const commit = () => {
    if (v !== value && v !== committed.current) {
      committed.current = v
      onCommit(v)
    }
  }
  // Verschwindet das Feld, bevor es den Fokus verliert (anderes Objekt angeklickt), den getippten Wert noch an sein
  // eigenes Objekt geben; sonst landete er im neu gewählten oder ging verloren
  const latest = useRef({ v, value, onCommit })
  latest.current = { v, value, onCommit }
  useEffect(() => () => {
    const { v: cur, value: orig, onCommit: commitTo } = latest.current
    if (cur !== orig && cur !== committed.current) commitTo(cur)
  }, [])
  return (
    <label className="st-field">
      <span>{label}</span>
      {area ? (
        <textarea className={prompt ? 'st-prompt' : undefined} value={v} rows={rows} placeholder={placeholder}
          onChange={(e) => setV(e.target.value)} onBlur={commit} />
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

/** Zahl in Sekunden (Komma oder Punkt nach Sprache, beides wird gelesen), intern Ticks. Mit `p` rastet der Wert aufs
 * Bildraster des Projekts ein wie beim Ziehen: Die Anzeige rundet auf 0,01 s, und „2,96“ hinter einen Clip bis Bild 71
 * (2,958 s) gesetzt ließ sonst ein Bild Lücke, im Export schwarz. */
function Seconds({ label, value, onCommit, min = 0, p }: {
  label: string; value: number; onCommit: (ticks: number) => void; min?: number; p?: StudioProject
}) {
  const text = decimal(sec(value).toFixed(2))
  return (
    <Field
      label={label}
      value={text}
      onCommit={(v) => {
        const n = parseFloat(v.replace(',', '.'))
        if (!Number.isFinite(n) || n < min) return
        const ticks = Math.round(n * TPS)
        onCommit(p ? Math.max(min > 0 ? frameTicks(p) : 0, snapFrame(p, ticks)) : ticks)
      }}
    />
  )
}

export function Inspector({ project, selection, models, active, onCommand, onGenerate, onSelect, asset, playhead, onDeleteAsset, onSpeed, onPlayhead, onShowModels, flow }: Props) {
  const p = project
  if (!selection) return <ProjectProps p={p} models={models} onCommand={onCommand} onShowModels={onShowModels} />
  if (selection.type === 'asset') {
    return asset ? <AssetProps key={asset.id} p={p} a={asset} model={models.find((m) => m.id === asset.model_id)} playhead={playhead} onCommand={onCommand} onDelete={onDeleteAsset} /> : null
  }
  if ((selection.ids?.length ?? 1) > 1) return <ManyProps p={p} selection={selection} onCommand={onCommand} onGenerate={onGenerate} onSelect={onSelect} />
  if (selection.type === 'scene') {
    const s = p.scenes.find((x) => x.id === selection.id)
    return s ? <SceneProps key={s.id} p={p} s={s} models={models} active={active} onCommand={onCommand} onGenerate={onGenerate} onShowModels={onShowModels} flow={flow} /> : null
  }
  if (selection.type === 'clip') {
    const c = p.clips.find((x) => x.id === selection.id)
    return c ? <ClipProps key={c.id} p={p} c={c} onCommand={onCommand} onSelect={onSelect} onSpeed={onSpeed} playhead={playhead} onPlayhead={onPlayhead} /> : null
  }
  if (selection.type === 'transition') {
    const c = p.clips.find((x) => x.id === selection.id)
    return c?.transition ? <TransitionProps key={c.id} p={p} c={c} onCommand={onCommand} onSelect={onSelect} /> : null
  }
  const m = p.markers.find((x) => x.id === selection.id)
  return m ? <MarkerProps key={m.id} p={p} m={m} onCommand={onCommand} /> : null
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

/** Zuletzt in den Blick geholter Wunsch des großen Knopfs (SceneFlow.focus.n zählt nur hoch) */
const focusUsed = { n: 0 }

/** Eigenschaften einer Szene. Konzept „NVAI im Fluss“, Bildschirm E (seit 0.5.42): oben Zustand und passender Knopf,
 * Modell, Weg (Videoszenen), Prompt, was das Modell dazu kann, Takes; Seltenes unter „Feineinstellung“; „Neu erzeugen“
 * und „In den Schnitt“ stehen fest unten. Vorher wanderten die Knöpfe mit langen Eigenschaften nach unten. */
function SceneProps({ p, s, models, active, onCommand, onGenerate, onShowModels, flow }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  active: Props['active']
  onCommand: Props['onCommand']
  onGenerate: Props['onGenerate']
  onShowModels?: () => void
  flow?: SceneFlow
}) {
  const update = (fields: Record<string, unknown>) => onCommand('scene.update', { id: s.id, ...fields })
  const modelKind = modelKindOf(s)
  const usable = models.filter((m) => m.kind === modelKind && m.installed)
  // Das Modell der Szene ist nicht installiert (gelöscht, vom Assistenten gewählt, aber nie geladen): ehrlich anzeigen.
  // Die Auswahl zeigte sonst „aktives Modell“, der Server rechnete aber mit diesem und scheiterte.
  const sceneModelInfo = s.model_id ? models.find((m) => m.id === s.model_id) : undefined
  const missingSelected = sceneModelInfo && sceneModelInfo.kind === modelKind && !sceneModelInfo.installed ? sceneModelInfo : undefined
  // Welches Modell „aktiv“ ist, steht dabei (Nutzer 3.11.2026: in der Sprecher-Bahn stand nur „aktives Modell“)
  const activeName = usable.find((m) => m.id === active?.[modelKind])?.name
  const earlier = p.scenes.filter((x) => x.lane === 'video' && x.id !== s.id && x.start < s.start)
  const model = sceneModel(s, models, active)
  const c: FlowCtx = { p, models, active, startRuns: flow?.startRuns ?? {}, progress: flow?.progressOf ?? (() => null) }
  const state = sceneState(c, s)
  const video = s.lane === 'video' && s.kind === 'video'
  const way: Way | null = video ? wayOf(s, model) : null
  const est = useSceneEstimate(c, s)
  const eta = fmtEta(totalSeconds(est))
  // Zeit für „Startbild erzeugen“ nur, wenn der Weg ein Startbild nimmt
  const startEta = fmtEta(useStartImageEstimate(p, models, video && way !== 'text' && way !== 'chain' ? [s] : []))
  const missing = !!missingModel(s, models, active)
  const q = s.params ?? {}
  // Ohne das nötige Bild scheiterte der Auftrag beim Server (Schleife ohne Startbild) oder täte nicht, was gewählt ist
  const lacks = way === 'loop' && !q.image_asset_id ? t('Erst ein Startbild wählen', 'Choose a start image first')
    : way === 'ends' && !q.end_image_asset_id ? t('Erst ein Endbild wählen', 'Choose an end image first')
      : way === 'layout' && !q.guide_asset_id ? t('Erst ein Layout-Video wählen', 'Choose a layout video first') : undefined
  const fine = useRef<HTMLDetailsElement>(null)
  const modelSelect = useRef<HTMLSelectElement>(null)
  const topBox = useRef<HTMLDivElement>(null)
  const wayBox = useRef<HTMLDivElement>(null)
  const promptBox = useRef<HTMLDivElement>(null)
  const takesBox = useRef<HTMLDivElement>(null)
  // Nach einem Klick auf den großen Knopf (Studio-Leiste) das passende Feld in den Blick holen; jeder Klick nur einmal,
  // sonst sprang es beim nächsten Wählen derselben Szene wieder dorthin
  const focusN = flow?.focus?.scene === s.id ? flow.focus.n : 0
  useEffect(() => {
    const field = flow?.focus?.field
    if (!focusN || !field || focusN <= focusUsed.n) return
    focusUsed.n = focusN
    const el = field === 'prompt' ? promptBox.current : field === 'takes' ? takesBox.current
      : field === 'way' ? wayBox.current ?? topBox.current : topBox.current
    el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    if (field === 'prompt') el?.querySelector('textarea')?.focus()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusN])
  const openModel = () => {
    if (fine.current) fine.current.open = true
    window.requestAnimationFrame(() => {
      modelSelect.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
      modelSelect.current?.focus()
    })
  }
  // Vorlagen ohne Take (Anschluss, Satz für die Lippen, gleiche Stimme) gehen mit, der Server wartet dann auf sie;
  // allein scheiterte die Szene an „braucht die vorherige Szene erst ein Video“
  const batch = withSources(p, [s.id])
  const generate = () => onGenerate(batch)
  const alsoNames = batch.filter((id) => id !== s.id).map((id) => sceneRef(p, id)).join(', ')
  // Klick auf einen Take wählt ihn und bestätigt die Wahl (params.take_ok): „Take wählen“ ist damit erledigt
  const pickTake = (id: string) => onCommand('batch', { commands: [
    { command: 'scene.take', params: { id: s.id, asset_id: id } },
    { command: 'scene.update', params: { id: s.id, params: { take_ok: id } } },
  ] })
  const setWay = (w: Way, chainTo: string | null) => update(wayChange(s, w, chainTo))
  // Harte Lizenzgrenze des gewählten Modells: Warnung sichtbar, bis eine Genehmigung bestätigt ist
  const blocked = licenseBlocked(model) && model?.warning ? model.warning : null
  return (
    <div className="st-inspector sf-scene">
      <div ref={topBox} className="sf-stack">
        <SceneHead p={p} s={s} state={state} onTitle={(v) => update({ title: v })} />
        <StateNote p={p} s={s} state={state} model={model} models={models} eta={eta} startEta={startEta} expected={est?.seconds ?? null}
          flow={flow} onGenerate={generate} onWay={(w, to) => setWay(w, to ?? null)} update={update} />
        {s.error && state.key !== 'error' && <p className="warn-text small">{s.error}</p>}
        {(s.hints ?? []).map((h) => <p key={h} className="st-hint small">{h}</p>)}
        <ModelLine p={p} s={s} models={models} active={active} flow={flow} onPick={(id) => update({ model_id: id })}
          onModelClick={openModel} onShowModels={onShowModels} />
        {blocked && <p className="warn-banner small">{blocked}</p>}
      </div>
      {video && (
        <div ref={wayBox} className="sf-stack">
          <WaySeg p={p} s={s} model={model} onWay={setWay} />
          <WaySlots p={p} s={s} way={way!} model={model} models={models} active={active} update={update} flow={flow}
            startEta={startEta} earlier={earlier} />
        </div>
      )}
      <div ref={promptBox} className="sf-stack">
        <Field
          label={s.lane === 'video' ? t('Prompt (was zu sehen ist und wie es sich bewegt)', 'Prompt (what is seen and how it moves)') : s.lane === 'voice' ? t('Text (was gesprochen wird)', 'Text (what is said)') : t('Prompt (Klang, Stil, Tempo)', 'Prompt (sound, style, tempo)')}
          value={s.prompt}
          area
          prompt
          rows={8}
          placeholder={s.lane === 'video' ? t(
            'Ein Absatz: Einstellung, Handlung, Kamera, Ton. Personen: Gesicht im Bild lassen, sonst erfindet LTX ein neues; sprechen nur mit Gesicht im Bild, die Stimme immer gleich beschreiben („in a warm, cheerful, clear female voice“).',
            'One paragraph: shot, action, camera, sound. People: keep the face in the picture, or LTX invents a new one; let them speak only with their face in the shot and describe the voice the same way every time ("in a warm, cheerful, clear female voice").',
          ) : s.lane === 'voice' ? t(
            'So, wie es gesprochen werden soll; Satzzeichen setzen Pausen. Die Szene wird so lang wie ihr Take.',
            'As it should be spoken; punctuation sets the pauses. The scene takes the length of its take.',
          ) : undefined}
          onCommit={(v) => update({ prompt: v })}
        />
        <ExpandPrompt p={p} s={s} models={models} active={active} update={update} />
      </div>
      {s.lane === 'voice' && <VoiceProps p={p} s={s} update={update} />}
      {s.lane === 'video' && <SceneRefs p={p} s={s} model={model} update={update} />}
      {video && <SceneSound s={s} model={model} update={update} />}
      {s.lane === 'video' && <SceneCharacters p={p} s={s} models={models} active={active} update={update} hint={false} />}
      <SceneToggles p={p} s={s} model={model} models={models} update={update} />
      <div ref={takesBox}>
        <SceneTakes p={p} s={s} attention={state.key === 'choose'} onPick={pickTake} />
      </div>
      <details ref={fine} className="sf-fine">
        <summary>{t('Feineinstellung', 'Advanced settings')}</summary>
        <div className="sf-stack">
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
            <Seconds p={p} label={t('Start (s)', 'Start (s)')} value={s.start} onCommit={(v) => update({ start: v })} />
            <Seconds p={p} label={t('Dauer (s)', 'Duration (s)')} value={s.duration} min={0.1} onCommit={(v) => update({ duration: v })} />
          </div>
          <label className="st-field">
            <span>{t('Modell', 'Model')}</span>
            <select ref={modelSelect} value={s.model_id ?? ''} onChange={(e) => update({ model_id: e.target.value || null })}>
              <option value="">{activeName ? t(`aktives Modell (${activeName})`, `active model (${activeName})`) : t('aktives Modell', 'active model')}</option>
              {missingSelected && (
                <option value={missingSelected.id} disabled>
                  {t(`${missingSelected.name} (nicht installiert)`, `${missingSelected.name} (not installed)`)}
                </option>
              )}
              {usable.map((m) => (
                <option key={m.id} value={m.id}>{licenseBlocked(m) ? '⚠ ' : ''}{m.name}</option>
              ))}
            </select>
          </label>
          {(() => {
            // Kurzer Tipp zum gewählten Modell wie unter der Modellwahl im Reiter Generieren (seit 0.5.30)
            const chosen = usable.find((m) => m.id === (s.model_id || active?.[modelKind]))
            const mode: RecommendationMode = modelKind === 'speech' ? 'speech' : modelKind === 'audio' ? 'audio' : modelKind === 'image' ? 'image' : 'video'
            return <ModelTip mode={mode} model={chosen ?? null} />
          })()}
          <SceneFine p={p} s={s} model={model} models={models} update={update} />
          {s.lane === 'video' && !(p.characters ?? []).length && (
            <p className="muted small">
              {t('Figuren (Aussehen per LoRA, eigene Stimme) legst du in den Projekteinstellungen an: dafür im Leeren klicken.',
                'Characters (look via LoRA, their own voice) are set up in the project settings: click an empty spot.')}
            </p>
          )}
          <div className="st-actions">
            <button className="btn small ghost" onClick={() => onCommand('scene.delete', { id: s.id })}>{t('Szene löschen', 'Delete scene')}</button>
          </div>
        </div>
      </details>
      <SceneFoot p={p} s={s} state={state} eta={eta} missing={missing} lacks={lacks} also={alsoNames} spoken={spokenInVideo(c, s)} onGenerate={generate}
        onConform={() => flow?.onConform([s.id])} />
    </div>
  )
}

/** Unter der Wegwahl: was der Weg braucht (Startbild, Endbild, Layout-Video, Vorlage des Anschlusses). Endbild und Layout
 * setzen wie bisher Schleife, DFR und 48 fps zurück, die damit nicht gehen. Passt etwas nicht zum Modell, steht es dabei. */
function WaySlots({ p, s, way, model, models, active, update, flow, startEta, earlier }: {
  p: StudioProject
  s: StudioScene
  way: Way
  model?: ModelInfo
  models: ModelInfo[]
  active: Props['active']
  update: (fields: Record<string, unknown>) => void
  flow?: SceneFlow
  startEta: string
  earlier: StudioScene[]
}) {
  const q = s.params ?? {}
  const f = model?.features
  const ltx = model?.family === 'ltx25'
  const name = model?.name ?? t('Dieses Modell', 'This model')
  const plain = { quality: null, temporal_upscale: null }
  const set = (fields: Record<string, unknown>) => update({ params: fields })
  const end: string | null = q.end_image_asset_id || null
  const guide: string | null = q.guide_asset_id || null
  const start = <StartImage p={p} s={s} models={models} active={active} update={update} flow={flow} eta={startEta} />
  if (way === 'text') {
    return <p className="muted small">{t('Kein Bild nötig: Das Modell erfindet den Anfang aus dem Prompt.', 'No image needed: the model invents the beginning from the prompt.')}</p>
  }
  if (way === 'chain') {
    if (s.chain_marker) {
      return <p className="muted small">{t('Kommt vom Anschluss-Marker. Zum Ändern den Marker verschieben oder löschen.', 'Set by a chain marker. Move or delete the marker to change it.')}</p>
    }
    const source = p.scenes.find((x) => x.id === s.chain_from)
    const options = source && !earlier.includes(source) ? [source, ...earlier] : earlier
    return (
      <>
        {options.length > 1 && (
          <label className="st-field">
            <span>{t('Anschluss an', 'Chain to')}</span>
            <select value={s.chain_from ?? ''} onChange={(e) => e.target.value && update({ chain_from: e.target.value })}>
              {options.map((x) => (
                <option key={x.id} value={x.id}>{sceneNum(p, x.id)} · {x.title || x.prompt.slice(0, 40) || x.id}</option>
              ))}
            </select>
          </label>
        )}
        <p className="muted small">{ltx
          ? t('Der Clip beginnt mit der letzten Sekunde dieser Szene und setzt ihre Bewegung fort; „Übernehmen“ blendet darüber.', 'The clip begins with the last second of that scene and continues its motion; "Conform" crossfades over it.')
          : t('Der Clip beginnt mit dem letzten Bild dieser Szene.', 'The clip begins with the last frame of that scene.')}</p>
      </>
    )
  }
  if (way === 'ends') {
    return (
      <>
        {start}
        <AssetPicker p={p} media="image" ids={end ? [end] : []} max={f?.end_image ? 1 : 0} label={t('Endbild', 'End image')}
          empty={t('Bild aus dem Material hierher ziehen', 'Drag an image from the media here')}
          onChange={(ids) => set({ end_image_asset_id: ids[0] ?? null, ...(ids[0] ? { loop: false, guide_asset_id: null, ...plain } : {}) })} />
        {!f?.end_image && <p className="warn-text small">{t(`${name} nimmt kein Endbild: entfernen oder LTX-2.5 wählen.`, `${name} takes no end image: remove it or choose LTX-2.5.`)}</p>}
      </>
    )
  }
  if (way === 'loop') {
    return (
      <>
        {start}
        {f?.loop
          ? <p className="muted small">{t('Endet wieder im Startbild. Nur mit ruhiger Kamera; Wasser und Rauch stehen dann still.', 'Ends with the start image again. Only with a calm camera; water and smoke then stand still.')}</p>
          : <p className="warn-text small">{t(`${name} kann keine Schleife: einen anderen Weg oder LTX-2.5 wählen.`, `${name} cannot loop: choose another path or LTX-2.5.`)}</p>}
      </>
    )
  }
  if (way === 'layout') {
    return (
      <>
        <AssetPicker p={p} media="video" ids={guide ? [guide] : []} max={ltx && f?.layout ? 1 : 0}
          label={t('Layout-Video (Layout to Render)', 'Layout video (layout to render)')}
          empty={ltx && !f?.layout
            ? t('Braucht die Layout-To-Render-LoRA: unter „Modelle“ bei LTX-2.5 „Zusätze laden“.', 'Needs the Layout-To-Render LoRA: "Download extras" for LTX-2.5 under "Models".')
            : t('Video aus dem Material hierher ziehen', 'Drag a video from the media here')}
          onChange={(ids) => set({ guide_asset_id: ids[0] ?? null, ...(ids[0] ? { end_image_asset_id: null, loop: false, ...plain } : {}) })} />
        {guide && !ltx && <p className="warn-text small">{t(`${name} nimmt kein Layout-Video; es bleibt hier unbenutzt.`, `${name} takes no layout video; it stays unused here.`)}</p>}
        {guide && ltx && (q.audio_from || q.audio_asset_id) && (
          <p className="warn-text small">{t('Ein Layout geht nicht zusammen mit Ton aus einer Sprecher-Szene.', 'A layout does not combine with sound from a voice scene.')}</p>
        )}
        {ltx && f?.layout && (
          <p className="muted small">{t('Eine grobe graue Animation (24 fps) gibt Kamera und Bewegung vor, das Startbild Look und Licht. Ohne Ton und DFR, höchstens so lang wie das Layout. Der erste Auftrag lädt zwei Knoten von Lightricks.',
            'A rough grey animation (24 fps) sets camera and motion, the start image look and light. No sound, no DFR, at most as long as the layout. The first job downloads two nodes by Lightricks.')}</p>
        )}
        {start}
      </>
    )
  }
  return start
}

/** Referenzbilder, wenn das Modell welche nimmt (FLUX 3, MiniMax H3 Referenz …) oder schon welche gewählt sind */
function SceneRefs({ p, s, model, update }: {
  p: StudioProject; s: StudioScene; model?: ModelInfo; update: (fields: Record<string, unknown>) => void
}) {
  const still = s.kind === 'image'
  const f = model?.features
  const refs: string[] = s.params?.reference_asset_ids ?? []
  const maxRefs = Number(f?.references ?? 0)
  if (maxRefs <= 0 && refs.length === 0) return null
  const name = model?.name ?? t('Dieses Modell', 'This model')
  const needsRefs = maxRefs > 0 && refs.length === 0
    && (still ? model?.workflow === 'qwen_image_edit' : !!model && startImageUse(model) === null)
  return (
    <div className="sf-stack">
      <AssetPicker p={p} media="image" ids={refs} max={maxRefs}
        label={f?.reference_kind === 'style' ? t('Stilvorlage', 'Style template') : t('Referenzbilder', 'Reference images')}
        empty={t('Bild aus dem Material hierher ziehen', 'Drag an image from the media here')}
        onChange={(ids) => update({ params: { reference_asset_ids: ids } })} />
      {maxRefs === 0 || refs.length > maxRefs
        ? <p className="warn-text small">{maxRefs === 0
          ? t(`${name} nimmt keine Referenzbilder: entfernen oder ein anderes Modell wählen.`, `${name} takes no reference images: remove them or choose another model.`)
          : t(`${name} nimmt höchstens ${maxRefs}.`, `${name} takes at most ${maxRefs}.`)}</p>
        : needsRefs
          ? <p className="warn-text small">{t(`${name} braucht ein Referenzbild.`, `${name} needs a reference image.`)}</p>
          : f?.reference_kind === 'style'
            ? <p className="muted small">{t('Gibt nur den Stil vor, nicht den Inhalt.', 'Sets the style only, not the content.')}</p>
            : <p className="muted small">{t('Im Prompt nennen: „The person from the first image …“ zeigt die Person aus einem Foto, „the first image“ eine Figur oder ein Ding.',
              'Name them in the prompt: "The person from the first image …" shows the person from a photo, "the first image" a character or an object.')}</p>}
    </div>
  )
}

/** Eigene Tonbeschreibung (Kandinsky 6, features.audio_prompt) */
function SceneSound({ s, model, update }: { s: StudioScene; model?: ModelInfo; update: (fields: Record<string, unknown>) => void }) {
  const f = model?.features
  const sound = String(s.params?.audio_prompt ?? '')
  if (!f?.audio_prompt && !sound) return null
  return (
    <>
      <Field label={t('Ton (was zu hören ist)', 'Sound (what is heard)')} value={sound} area rows={2}
        placeholder={f?.audio_placeholder} onCommit={(v) => update({ params: { audio_prompt: v } })} />
      {!f?.audio_prompt && sound && (
        <p className="muted small">{t(`${model?.name ?? 'Dieses Modell'} nimmt keine eigene Tonbeschreibung; sie bleibt hier unbenutzt.`, `${model?.name ?? 'This model'} takes no separate sound description; it stays unused here.`)}</p>
      )}
    </>
  )
}

/** Stimme einer Sprecher-Szene (seit 0.5.21): beschreiben, gleich wie eine andere Sprecher-Szene (deren Take mit
 * seinem Text als Vorlage) oder aus einer Aufnahme im Projekt. params.voice / voice_from / voice_asset_id. */
function VoiceProps({ p, s, update }: { p: StudioProject; s: StudioScene; update: (fields: Record<string, unknown>) => void }) {
  const params = s.params || {}
  const chars = p.characters ?? []
  const character = chars.find((c) => c.id === params.character)
  const source = character ? 'character' : params.voice_from ? 'scene' : params.voice_asset_id ? 'asset' : 'describe'
  const others = p.scenes.filter((x) => x.lane === 'voice' && x.id !== s.id)
  const recordings = recordingsOf(p)
  const setSource = (v: string) => update({ params: {
    character: v === 'character' ? (chars[0]?.id ?? null) : null,
    voice_from: v === 'scene' ? (others[0]?.id ?? null) : null,
    voice_asset_id: v === 'asset' ? (recordings[0]?.[0] ?? null) : null,
  } })
  return (
    <>
      <label className="st-field">
        <span>{t('Stimme', 'Voice')}</span>
        <select value={source} onChange={(e) => setSource(e.target.value)}>
          <option value="describe">{t('beschreiben', 'describe')}</option>
          <option value="character" disabled={chars.length === 0}>{t('einer Figur …', 'of a character …')}</option>
          <option value="scene" disabled={others.length === 0}>{t('gleich wie Szene …', 'same as scene …')}</option>
          <option value="asset" disabled={recordings.length === 0}>{t('aus einer Aufnahme', 'from a recording')}</option>
        </select>
      </label>
      {character && (
        <label className="st-field">
          <span>{t('Figur', 'Character')}</span>
          <select value={character.id} onChange={(e) => update({ params: { character: e.target.value } })}>
            {chars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <span className="small">{voiceSummary(p, character, s.id)}</span>
        </label>
      )}
      {source === 'describe' && (
        <Field
          label={t('Beschreibung der Stimme', 'Description of the voice')}
          value={String(params.voice ?? '')}
          area
          rows={3}
          placeholder={t('z. B. eine ruhige, tiefe Männerstimme, etwa fünfzig, warm und leicht rau. Leer: das Modell wählt.',
            'e.g. a calm, deep male voice, about fifty, warm and slightly rough. Empty: the model chooses.')}
          onCommit={(v) => update({ params: { voice: v } })}
        />
      )}
      {source === 'scene' && (
        <label className="st-field">
          <span>{t('Gleiche Stimme wie', 'Same voice as')}</span>
          <select value={params.voice_from ?? ''} onChange={(e) => update({ params: { voice_from: e.target.value || null } })}>
            {others.map((x) => (
              <option key={x.id} value={x.id}>{x.title || x.prompt.slice(0, 40) || x.id}</option>
            ))}
          </select>
          <span className="small">{t('Deren gewählter Take ist die Vorlage; ohne Take wird sie zuerst erzeugt.',
            'Its chosen take is the reference; without a take it is generated first.')}</span>
        </label>
      )}
      {source === 'asset' && (
        <>
          <label className="st-field">
            <span>{t('Aufnahme', 'Recording')}</span>
            <select value={params.voice_asset_id ?? ''} onChange={(e) => update({ params: { voice_asset_id: e.target.value || null } })}>
              {recordings.map(([id, a]) => (
                <option key={id} value={id}>{a.kind === 'video' ? '▶ ' : '♪ '}{(a.prompt || id).slice(0, 50)}</option>
              ))}
            </select>
          </label>
          <Field
            label={t('Was darin gesagt wird (optional)', 'What is said in it (optional)')}
            value={String(params.voice_text ?? '')}
            area
            rows={2}
            placeholder={t('wortgenau; dann auch Sprechweise und Betonung, sonst nur der Stimmklang',
              'word for word; then also the way of speaking, otherwise only the sound of the voice')}
            onCommit={(v) => update({ params: { voice_text: v } })}
          />
          <p className="muted small">{t('Die ersten 20 s zählen. Nur Aufnahmen, deren Sprecher zugestimmt haben.',
            'The first 20 s count. Only recordings whose speakers agreed.')}</p>
        </>
      )}
      {!character && (
        <label className="st-field">
          <span>{t('Sprache', 'Language')}</span>
          <select value={params.language ?? 'auto'} onChange={(e) => update({ params: { language: e.target.value } })}>
            {SPEECH_LANGUAGES.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
          </select>
        </label>
      )}
    </>
  )
}

/** Startbild einer Videoszene (seit 0.5.27; Nutzer 14.11.2026: „Startbild in die Szenen-Eigenschaften einbauen“):
 * params.image_asset_id, das erste Bild des Clips; so bleibt eine Figur in jeder Einstellung gleich. Ein Bild aus dem
 * Material hierher ziehen oder aus dem Projektordner wählen. Vorher ging das nur per MCP/REST, und ein Bild auf der Szene
 * wurde ein Take (das bleibt so). Ein Anschluss hat Vorrang: Dann beginnt der Clip mit dem Ende der Szene davor. */
/** Videomodelle mit eigenem Ton (wie wizard.SOUND_FAMILIES) */
const SOUND_FAMILIES = ['ltx25', 'ltx23', 'kandinsky6']

/** Format für „Prompt ausbauen“: Der Server nimmt 256 bis 2560 in Vielfachen von 8 (schemas.ExpandPromptRequest); ein
 *  4K-Projekt (3840 × 2160) oder eines mit 1366 × 768 scheiterte sonst. Das Seitenverhältnis bleibt. */
function expandSize(w: number, h: number): { width: number; height: number } {
  const k = Math.min(1, 2560 / Math.max(w, h, 1))
  const fit = (x: number) => Math.max(256, Math.min(2560, Math.round((x * k) / 8) * 8))
  return { width: fit(w), height: fit(h) }
}

/** „Prompt ausbauen“ (seit 0.5.30): wie im Reiter Generieren, das Ziel nach Art der Szene (mit Startbild nur die
 * Bewegung); überträgt nebenbei ins Englische. Ersetzt den Prompt, Strg+Z holt den alten zurück. */
function ExpandPrompt({ p, s, models, active, update }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  active: Props['active']
  update: (fields: Record<string, unknown>) => void
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const latest = useRef(p)  // der neueste Stand des Projekts, wenn das Ergebnis nach rund 15 s kommt
  latest.current = p
  if (s.lane === 'voice') return null
  const video = models.find((m) => m.id === (s.model_id || active?.video))
  const image: string | null = s.params?.image_asset_id || null
  const target: ExpandTarget = s.lane === 'music' ? 'music_sa3' : s.lane === 'sfx' ? 'sfx' : s.kind === 'image' ? 'image'
    : image || s.chain_from || s.chain_marker ? 'video_start'
      : video && SOUND_FAMILIES.includes(video.family) ? 'video_sound' : 'video'
  const run = async () => {
    setBusy(true)
    setError(null)
    const sent = s.prompt
    try {
      const r = await api.expandPrompt({
        prompt: sent, target, ...expandSize(p.settings.width, p.settings.height),
        ...(image && target === 'video_start' ? { reference_asset_ids: [image] }
          : target === 'image' && s.params?.reference_asset_ids?.length ? { reference_asset_ids: s.params.reference_asset_ids } : {}),
      })
      // Nur übernehmen, wenn der Prompt inzwischen nicht geändert wurde (vorher ersetzte das Ergebnis neue Eingaben)
      const now = latest.current.scenes.find((x) => x.id === s.id)
      if (now && now.prompt !== sent) {
        setError(t('Der Prompt wurde inzwischen geändert; der ausgebaute Text ist nicht übernommen.',
          'The prompt was changed in the meantime; the expanded text was not applied.'))
      } else if (r.expanded.trim()) update({ prompt: r.expanded.trim() })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="st-start-actions">
      <button className="btn small ghost" disabled={busy || !s.prompt.trim()} onClick={run}
        title={t('Baut den Prompt zur vollen Beschreibung aus und überträgt ihn ins Englische (rund 15 s auf der Grafikkarte). Danach lesen und Erfundenes streichen; Strg+Z holt den alten zurück.',
          'Expands the prompt into a full description and translates it into English (about 15 s on the graphics card). Read it afterwards and remove anything invented; Ctrl+Z brings back the old one.')}>
        {busy ? t('Baut aus …', 'Expanding …') : t('Prompt ausbauen', 'Expand prompt')}
      </button>
      {error && <span className="warn-text small">{error}</span>}
    </div>
  )
}

function StartImage({ p, s, models, active, update, flow, eta }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  active: Props['active']
  update: (fields: Record<string, unknown>) => void
  /** Startbild-Aufträge des Studios (seit 0.5.42): laufen weiter, wenn man eine andere Szene wählt */
  flow?: SceneFlow
  /** geschätzte Zeit für zwei Varianten: „≈ 40 s“ */
  eta?: string
}) {
  const id: string | null = s.params?.image_asset_id || null
  const model = models.find((m) => m.id === (s.model_id || active?.video))
  const use = model ? startImageUse(model) : 'optional'
  const [open, setOpen] = useState(false)
  const [images, setImages] = useState<Asset[] | null>(null)
  const [over, setOver] = useState(false)
  useEffect(() => {
    if (!open) return
    let alive = true
    api.assetPage({ media: 'image', folder: p.folder ?? '', limit: 60, offset: 0 })
      .then((list) => alive && setImages(list))
      .catch(() => alive && setImages([]))
    return () => { alive = false }
  }, [open, p.folder])
  const set = (v: string | null) => update({ params: { image_asset_id: v } })
  // „Startbild erzeugen“ (seit 0.5.30): zwei Varianten wie im Assistenten, die erste wird gleich das Startbild
  const [gen, setGen] = useState<{ busy: boolean; error: string | null; variants: Asset[] }>({ busy: false, error: null, variants: [] })
  const latest = useRef(p)  // der neueste Stand des Projekts, wenn die Bilder nach rund einer Minute kommen
  latest.current = p
  const generate = async () => {
    const before = s.params?.image_asset_id ?? null
    setGen({ busy: true, error: null, variants: [] })
    try {
      const job = await api.studioStartImage(p.id, s.id)
      for (;;) {
        const j = await api.job(job.id)
        if (j.status === 'done') break
        if (j.status === 'error' || j.status === 'cancelled') throw new Error(j.error || j.status)
        await new Promise((r) => setTimeout(r, 1500))
      }
      const variants = await api.jobAssets(job.id)
      // Startbild nur setzen, wenn inzwischen kein anderes gewählt wurde (vorher überschrieb das Ergebnis die Wahl)
      const now = latest.current.scenes.find((x) => x.id === s.id)
      if (variants[0] && (!now || (now.params?.image_asset_id ?? null) === before)) set(variants[0].id)
      setGen({ busy: false, error: null, variants })
    } catch (e) {
      setGen({ busy: false, error: e instanceof Error ? e.message : String(e), variants: [] })
    }
  }
  // Mit dem Studio (Konzept „NVAI im Fluss“) gehört der Auftrag ihm: Zustand, Varianten und Fehler kommen von dort
  const shared = flow ? flow.startRuns[s.id] : undefined
  const busy = flow ? shared?.status === 'running' : gen.busy
  const error = flow ? (shared?.status === 'error' ? shared.error ?? t('Fehler', 'Error') : null) : gen.error
  const variants = flow ? (shared?.status === 'done' ? shared.variants : []) : gen.variants
  const start = flow ? () => flow.onStartImages([s.id]) : generate
  const accept = (e: RDragEvent) => {
    if (!e.dataTransfer.types.includes(ASSET_MIME)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    setOver(true)
  }
  const drop = (e: RDragEvent) => {
    setOver(false)
    const raw = e.dataTransfer.getData(ASSET_MIME)
    if (!raw) return
    e.preventDefault()
    const dropped = JSON.parse(raw) as { id: string; kind: string | null }
    if (dropped.kind === 'image') set(dropped.id)
  }
  if (use === null && !id) {
    return <p className="muted small">{t(`${model?.name ?? 'Dieses Modell'} nimmt kein Startbild.`, `${model?.name ?? 'This model'} takes no start image.`)}</p>
  }
  const a = id ? p.assets[id] : undefined
  const chained = !!(s.chain_from || s.chain_marker)
  return (
    <div className="st-field">
      <span>{t('Startbild', 'Start image')}{use === 'required' ? ` ${t('(nötig)', '(required)')}` : ''}</span>
      <div className={`st-start${over ? ' st-over' : ''}`} onDragOver={accept} onDragEnter={accept}
        onDragLeave={() => setOver(false)} onDrop={drop}>
        {id
          ? (a ? <img src={a.url} alt="" title={a.prompt} />
            : <span className="warn-text small">{t('Das Bild fehlt (gelöscht?).', 'The image is missing (deleted?).')}</span>)
          : <span className="small">{t('Bild aus dem Material hierher ziehen', 'Drag an image from the media here')}</span>}
      </div>
      <div className="st-start-actions">
        <button className="btn small ghost" onClick={() => setOpen((x) => !x)}>
          {open ? t('Auswahl schließen', 'Close the selection') : t('Aus dem Projektordner wählen …', 'Choose from the project folder …')}
        </button>
        {id && <button className="btn small ghost" onClick={() => set(null)}>{t('Entfernen', 'Remove')}</button>}
        {use !== null && !chained && (
          <button className="btn small ghost" disabled={busy || !s.prompt.trim()} onClick={start}
            title={t('Zwei Varianten aus dem Prompt der Szene, wie die Startbilder des Assistenten: mit den Figuren der Szene (ihre LoRAs), ohne die Sätze über Ton, ohne schwarze Balken. Beide landen im Projektordner; die erste wird das Startbild.',
              'Two variants from the scene prompt, like the start images of the assistant: with the characters of the scene (their LoRAs), without the sentences about sound, without black bars. Both go into the project folder; the first becomes the start image.')}>
            {busy ? t('Erzeugt zwei Varianten …', 'Generating two variants …') : t('Startbild erzeugen', 'Generate start image')}
            {!busy && eta && <span className="flow-eta">&nbsp;· {eta}</span>}
          </button>
        )}
      </div>
      {error && <span className="warn-text small">{error}</span>}
      {variants.length > 1 && (
        <div className="st-takes st-start-grid">
          {variants.map((x) => (
            <button key={x.id} className={`st-take${x.id === id ? ' st-sel' : ''}`} title={assetLabel(x)} onClick={() => set(x.id)}>
              <img src={x.thumb_url || x.url} alt="" />
            </button>
          ))}
        </div>
      )}
      {open && (images === null
        ? <span className="small">{t('Lädt …', 'Loading …')}</span>
        : images.length === 0
          ? <span className="small">{t('Im Projektordner liegen noch keine Bilder.', 'There are no images in the project folder yet.')}</span>
          : (
            <div className="st-takes st-start-grid">
              {images.map((x) => (
                <button key={x.id} className={`st-take${x.id === id ? ' st-sel' : ''}`} title={assetLabel(x)}
                  onClick={() => { set(x.id); setOpen(false) }}>
                  <img src={x.thumb_url || x.url} alt="" loading="lazy" />
                </button>
              ))}
            </div>
          ))}
      {/* Die Erklärung des Wegs steht seit 0.5.42 am Knopf „Startbild“ der Wegwahl; hier nur, was nicht passt */}
      {(chained || use === null) && (
        <span className="small">
          {chained
            ? t('Der Anschluss hat Vorrang: Der Clip beginnt mit dem Ende der Szene davor.', 'The chain comes first: the clip begins with the end of the scene before.')
            : t('Dieses Modell nimmt kein Startbild; es bleibt hier unbenutzt.', 'This model takes no start image; it stays unused here.')}
        </span>
      )}
    </div>
  )
}

/** Bilder oder Videos des Projekts wählen: aus dem Material hierher ziehen oder aus dem Projektordner. Mit `max` 1 ersetzt
 * die neue Wahl die alte; 0 heißt, das Modell nimmt keine (dann nur noch entfernen). */
function AssetPicker({ p, media, ids, max, label, empty, onChange }: {
  p: StudioProject
  media: 'image' | 'video'
  ids: string[]
  max: number
  label: string
  empty: string
  onChange: (ids: string[]) => void
}) {
  const [open, setOpen] = useState(false)
  const [list, setList] = useState<Asset[] | null>(null)
  const [over, setOver] = useState(false)
  useEffect(() => {
    if (!open) return
    let alive = true
    api.assetPage({ media, folder: p.folder ?? '', limit: 60, offset: 0 })
      .then((found) => alive && setList(found))
      .catch(() => alive && setList([]))
    return () => { alive = false }
  }, [open, media, p.folder])
  const add = (id: string) => {
    if (max === 1) onChange([id])
    else if (!ids.includes(id) && ids.length < max) onChange([...ids, id])
  }
  const accept = (e: RDragEvent) => {
    if (max < 1 || !e.dataTransfer.types.includes(ASSET_MIME)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    setOver(true)
  }
  const drop = (e: RDragEvent) => {
    setOver(false)
    const raw = e.dataTransfer.getData(ASSET_MIME)
    if (!raw || max < 1) return
    e.preventDefault()
    const dropped = JSON.parse(raw) as { id: string; kind: string | null }
    if (dropped.kind === media) add(dropped.id)
  }
  const picture = (x: { url: string; thumb_url?: string | null }) => media === 'video'
    ? <video src={`${x.url}#t=0.1`} preload="metadata" muted />
    : <img src={x.thumb_url || x.url} alt="" loading="lazy" />
  return (
    <div className="st-field">
      <span>{label}{max > 1 ? ` (${ids.length}/${max})` : ''}</span>
      <div className={`st-drop${over ? ' st-over' : ''}`} onDragOver={accept} onDragEnter={accept}
        onDragLeave={() => setOver(false)} onDrop={drop}>
        {ids.length === 0 ? <span className="small">{empty}</span> : (
          <div className="st-takes">
            {ids.map((id) => {
              const a = p.assets[id]
              return (
                <button key={id} type="button" className="st-take" onClick={() => onChange(ids.filter((x) => x !== id))}
                  title={t('Klick entfernt es', 'Click to remove it')}>
                  {a ? picture(a) : <span className="warn-text small">{t('fehlt', 'missing')}</span>}
                  <span className="st-take-x">✕</span>
                </button>
              )
            })}
          </div>
        )}
      </div>
      {max > 0 && (
        <div className="st-start-actions">
          <button type="button" className="btn small ghost" onClick={() => setOpen((x) => !x)}>
            {open ? t('Auswahl schließen', 'Close the selection') : t('Aus dem Projektordner wählen …', 'Choose from the project folder …')}
          </button>
        </div>
      )}
      {open && max > 0 && (list === null
        ? <span className="small">{t('Lädt …', 'Loading …')}</span>
        : list.length === 0
          ? <span className="small">{t('Im Projektordner liegt noch nichts Passendes.', 'There is nothing suitable in the project folder yet.')}</span>
          : (
            <div className="st-takes st-start-grid">
              {list.map((x) => (
                <button key={x.id} type="button" className={`st-take${ids.includes(x.id) ? ' st-sel' : ''}`} title={assetLabel(x)}
                  onClick={() => { add(x.id); if (max === 1) setOpen(false) }}>
                  {picture(x)}
                </button>
              ))}
            </div>
          ))}
    </div>
  )
}

/** Feineinstellung einer Szene (seit 0.5.42; vorher „Vorlagen und Zusätze“, 0.5.40/0.5.41): Qualität, Faktor der
 * Zeitlupe, 48 fps, LoRAs mit Stärke und der Seed als Zahl. Die Schalter oben („Was … dazu kann“) setzen dieselben
 * Felder; Weg, Endbild, Layout, Referenzen und Ton stehen sichtbar oben. Ohne eigene Wahl gilt das Projekt bzw. das
 * Modell. */
function SceneFine({ p, s, model, models, update }: {
  p: StudioProject
  s: StudioScene
  model?: ModelInfo
  models: ModelInfo[]
  update: (fields: Record<string, unknown>) => void
}) {
  const picture = s.lane === 'video'
  const still = s.kind === 'image'
  const f = model?.features
  const params = s.params ?? {}
  const end: string | null = params.end_image_asset_id || null
  const guide: string | null = params.guide_asset_id || null
  const loop = !!params.loop
  const ltx = picture && !still && model?.family === 'ltx25'
  const noDfr = !!end || loop || !!guide
  const quality: string = params.quality ?? ''
  const projectDfr = (p.settings.video_quality ?? 'dfr') === 'dfr' && !!f?.dfr
  const dfr = !noDfr && (quality ? quality === 'dfr' : projectDfr)
  const speed = Number(params.motion_speed ?? 1)
  const loras: { model_id: string; strength: number }[] = params.loras ?? []
  const fitting = picture ? models.filter((m) => m.kind === 'lora' && m.installed && (model?.lora_bases ?? []).includes(m.family)) : []
  const loraName = (id: string) => models.find((m) => m.id === id)?.name ?? id
  const seed = params.seed ?? null
  const set = (fields: Record<string, unknown>) => update({ params: fields })
  return (
    <>
      {ltx && (
        <>
          <div className="st-grid2">
            <label className="st-field">
              <span>{t('Qualität', 'Quality')}</span>
              <select value={noDfr ? 'standard' : quality} disabled={noDfr}
                onChange={(e) => set({ quality: e.target.value || null, ...(e.target.value === 'dfr' ? {} : { temporal_upscale: null }) })}>
                <option value="">{projectDfr ? t('wie im Projekt (DFR)', 'as in the project (DFR)') : t('wie im Projekt (Standard)', 'as in the project (standard)')}</option>
                <option value="standard">{t('Standard', 'Standard')}</option>
                <option value="dfr" disabled={!f?.dfr}>{t('Höchste Qualität (DFR)', 'Best quality (DFR)')}</option>
              </select>
            </label>
            {f?.motion_speed && (
              <label className="st-field">
                <span>{t('Zeitlupe', 'Slow motion')}</span>
                <select value={speed} onChange={(e) => set({ motion_speed: Number(e.target.value) < 1 ? Number(e.target.value) : null })}>
                  {([[1, t('aus (Echtzeit)', 'off (real time)')], [0.5, '2×'], [0.2, '5×'], [0.1, '10×'], [0.05, '20×'],
                    [0.025, '40×']] as [number, string][]).map(([v, label]) => <option key={v} value={v}>{label}</option>)}
                </select>
              </label>
            )}
          </div>
          {dfr && f?.temporal_upscale && (
            <label className="st-check">
              <input type="checkbox" checked={!!params.temporal_upscale}
                onChange={(e) => set(e.target.checked ? { temporal_upscale: true, quality: 'dfr' } : { temporal_upscale: null })} />
              <span>{t('48 fps (zeitlich verdoppelt, langsamer)', '48 fps (temporal upscale, slower)')}</span>
            </label>
          )}
          <p className="muted small">{noDfr
            ? t('Mit Endbild, Schleife oder Layout rechnet LTX-2.5 im Standardweg.', 'With an end image, a loop or a layout, LTX-2.5 renders the standard way.')
            : t('DFR: über die ganze Länge scharf, rund dreimal so lang.', 'DFR: sharp over the whole clip, about three times the time.')}</p>
          {speed < 1 && (
            <p className="muted small">{t('Zeitlupe: mit der LoRA „Slow Motion Control“ und einem Startbild.', 'Slow motion: with the "Slow Motion Control" LoRA and a start image.')}</p>
          )}
        </>
      )}
      {(fitting.length > 0 || loras.length > 0) && (
        <div className="st-field">
          <span>{t('LoRAs dieser Szene', 'LoRAs of this scene')}</span>
          {loras.map((l) => {
            const m = models.find((x) => x.id === l.model_id)
            const fits = fitting.some((x) => x.id === l.model_id)
            return (
              <div key={l.model_id} className="st-lora-row">
                <span className="st-lora-name" title={m?.trigger ? t(`Trigger: ${m.trigger}`, `Trigger: ${m.trigger}`) : ''}>
                  <span>{loraName(l.model_id)}</span>
                  {!fits && <span className="warn-text small">{m?.installed ? t('passt nicht zum Modell', 'does not fit the model') : t('fehlt', 'missing')}</span>}
                </span>
                <StrengthInput value={l.strength}
                  onCommit={(v) => set({ loras: loras.map((x) => (x.model_id === l.model_id ? { ...x, strength: v } : x)) })} />
                <button type="button" className="btn small ghost" title={t('LoRA entfernen', 'Remove LoRA')}
                  onClick={() => set({ loras: loras.filter((x) => x.model_id !== l.model_id) })}>✕</button>
              </div>
            )
          })}
          <select value="" onChange={(e) => e.target.value && set({ loras: [...loras, { model_id: e.target.value, strength: models.find((m) => m.id === e.target.value)?.features?.strength ?? 0.8 }] })}>
            <option value="">{t('+ LoRA hinzufügen …', '+ Add LoRA …')}</option>
            {fitting.filter((m) => !loras.some((l) => l.model_id === m.id)).map((m) => (
              <option key={m.id} value={m.id}>{loraName(m.id)}</option>
            ))}
          </select>
        </div>
      )}
      {model && (
        <Field label={t('Seed (leer = zufällig)', 'Seed (empty = random)')} value={seed === null ? '' : String(seed)}
          onCommit={(v) => { const n = Number.parseInt(v, 10); set({ seed: Number.isFinite(n) && n >= 0 ? n : null }) }} />
      )}
    </>
  )
}

/** Aufnahmen im Projekt, die als Stimmvorlage taugen (Ton, Video, hochgeladene Ton- und Videodateien) */
function recordingsOf(p: StudioProject) {
  return Object.entries(p.assets).filter(([, a]) => a.kind === 'audio' || a.kind === 'video'
    || (a.kind === 'upload' && /\.(wav|mp3|flac|ogg|m4a|aac|opus|mp4|mov|mkv|webm)$/i.test(a.url)))
}

/** Woher die Stimme einer Figur kommt, in einem Satz */
function voiceSummary(p: StudioProject, c: StudioCharacter, sceneId?: string): string {
  if (c.voice_from && c.voice_from !== sceneId) {
    return t(`Stimme wie der Take von „${sceneName(p, c.voice_from)}“.`, `Voice like the take of "${sceneName(p, c.voice_from)}".`)
  }
  if (c.voice_asset_id) {
    const a = p.assets[c.voice_asset_id]
    return t(`Stimme aus der Aufnahme „${(a?.prompt || c.voice_asset_id).slice(0, 40)}“.`,
      `Voice from the recording "${(a?.prompt || c.voice_asset_id).slice(0, 40)}".`)
  }
  return c.voice
    ? t(`Stimme: ${c.voice}`, `Voice: ${c.voice}`)
    : t('Ohne Beschreibung: das Modell wählt eine Stimme.', 'No description: the model picks a voice.')
}

/** Figuren im Bild (seit 0.5.24): ihre LoRAs, die zum Modell der Szene passen, und deren Trigger-Wörter kommen in den
 * Auftrag. Videoszenen mit LTX-2.5 können dazu den Satz einer Sprecher-Szene als Ton nehmen: Er wird zuerst in der
 * Stimme seiner Figur gesprochen, das Video folgt ihm mit den Lippen. */
function SceneCharacters({ p, s, models, active, update, hint = true }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  active: Props['active']
  update: (fields: Record<string, unknown>) => void
  /** false: ohne Figuren nichts zeigen (der Hinweis steht dann unter „Feineinstellung“) */
  hint?: boolean
}) {
  const chars = p.characters ?? []
  const params = s.params || {}
  const chosen: string[] = params.characters ?? []
  const model = models.find((m) => m.id === (s.model_id || active?.[s.kind === 'image' ? 'image' : 'video']))
  const bases = model?.lora_bases ?? []
  const fits = (c: StudioCharacter) => c.loras.some((l) => {
    const m = models.find((x) => x.id === l.model_id)
    return !!m && m.installed && bases.includes(m.family)
  })
  const voices = p.scenes.filter((x) => x.lane === 'voice')
  const speaks = s.kind === 'video' && !!model?.features?.audio_input
  const nameOf = (id?: string) => chars.find((c) => c.id === id)?.name
  if (chars.length === 0 && !(speaks && params.audio_from)) {
    if (!hint) return null
    return (
      <p className="muted small">
        {t('Figuren (Aussehen per LoRA, eigene Stimme) legst du in den Projekteinstellungen an: dafür im Leeren klicken.',
          'Characters (look via LoRA, their own voice) are set up in the project settings: click an empty spot.')}
      </p>
    )
  }
  return (
    <>
      {chars.length > 0 && (
        <div className="st-field">
          <span>{t('Figuren im Bild', 'Characters in the picture')}</span>
          {chars.map((c) => (
            <label key={c.id} className="st-check">
              <input type="checkbox" checked={chosen.includes(c.id)}
                onChange={(e) => update({ params: { characters: e.target.checked ? [...chosen, c.id] : chosen.filter((x) => x !== c.id) } })} />
              <span>{c.name}</span>
              {chosen.includes(c.id) && !fits(c) && (
                <span className="warn-text small">{model
                  ? t(`keine LoRA für ${model.name}`, `no LoRA for ${model.name}`)
                  : t('keine passende LoRA', 'no matching LoRA')}</span>
              )}
            </label>
          ))}
        </div>
      )}
      {speaks && (
        <label className="st-field">
          <span>{t('Ton aus Sprecher-Szene', 'Sound from voice scene')}</span>
          <select value={params.audio_from ?? ''} onChange={(e) => update({ params: { audio_from: e.target.value || null } })}>
            <option value="">{t('keiner, LTX macht den Ton', 'none, LTX makes the sound')}</option>
            {voices.map((x) => (
              <option key={x.id} value={x.id}>
                {(x.title || x.prompt.slice(0, 40) || x.id) + (nameOf(x.params?.character) ? ` (${nameOf(x.params?.character)})` : '')}
              </option>
            ))}
          </select>
          <span className="small">
            {t('Der Satz wird zuerst gesprochen, in der Stimme seiner Figur; das Video folgt ihm mit den Lippen und wird so lang wie er. Beim Übernehmen kommt er nicht noch einmal in den Schnitt.',
              'The line is spoken first, in its character\'s voice; the video follows it with the lips and takes its length. Conform does not add it to the edit a second time.')}
          </span>
        </label>
      )}
    </>
  )
}

/** Stärke einer LoRA: gilt beim Verlassen des Feldes oder mit Enter (jede Änderung ist ein Befehl mit Rückgängig) */
function StrengthInput({ value, onCommit }: { value: number; onCommit: (v: number) => void }) {
  const [text, setText] = useState(decimal(String(value)))
  useEffect(() => setText(decimal(String(value))), [value])
  const commit = () => {
    const v = Number(text.replace(',', '.'))
    if (Number.isFinite(v) && v >= 0 && v <= 3 && v !== value) onCommit(Math.round(v * 100) / 100)
    else setText(decimal(String(value)))
  }
  return (
    <input className="st-strength" value={text} inputMode="decimal" title={t('Stärke 0 bis 3, meist 0,6 bis 1', 'Strength 0 to 3, usually 0.6 to 1')}
      onChange={(e) => setText(e.target.value)} onBlur={commit} onKeyDown={(e) => e.key === 'Enter' && commit()} />
  )
}

/** Eine Figur in den Projekteinstellungen: Name, Aussehen (LoRAs), Stimme */
function CharacterEditor({ p, c, models, onCommand, onShowModels }: {
  p: StudioProject
  c: StudioCharacter
  models: ModelInfo[]
  onCommand: Props['onCommand']
  onShowModels?: () => void
}) {
  const update = (fields: Record<string, unknown>) => onCommand('character.update', { id: c.id, ...fields })
  const loraModels = models.filter((m) => m.kind === 'lora' && m.installed)
  const voiceScenes = p.scenes.filter((x) => x.lane === 'voice')
  const recordings = recordingsOf(p)
  const source = c.voice_from ? 'scene' : c.voice_asset_id ? 'asset' : 'describe'
  const setSource = (v: string) => update({
    voice_from: v === 'scene' ? (voiceScenes.find((x) => x.params?.character === c.id)?.id ?? voiceScenes[0]?.id ?? null) : null,
    voice_asset_id: v === 'asset' ? (recordings[0]?.[0] ?? null) : null,
  })
  const label = (id: string) => {
    const m = models.find((x) => x.id === id)
    return m ? m.name.replace(/^.*\//, '').replace(/\.safetensors$/, '') : id
  }
  return (
    <details className="st-character">
      <summary>
        <strong>{c.name}</strong>
        <span className="muted small">
          {c.loras.length ? c.loras.map((l) => label(l.model_id)).join(', ') : t('ohne LoRA', 'no LoRA')}
        </span>
      </summary>
      <Field label={t('Name', 'Name')} value={c.name} onCommit={(v) => v.trim() && update({ name: v.trim() })} />
      <div className="st-field">
        <span>{t('Aussehen (LoRAs; je Szene gilt, was zum Modell passt)', 'Look (LoRAs; each scene uses those that fit its model)')}</span>
        {c.loras.map((l) => {
          const m = models.find((x) => x.id === l.model_id)
          return (
            <div key={l.model_id} className="st-lora-row">
              <span className="st-lora-name" title={m?.trigger ? t(`Trigger: ${m.trigger}`, `Trigger: ${m.trigger}`) : ''}>
                <span>{label(l.model_id)}</span>
                <span className={m?.installed ? 'muted small' : 'warn-text small'}>
                  {m ? (m.installed ? (LORA_BASE_LABEL[m.family] ?? m.family) : t('nicht geladen', 'not downloaded')) : t('fehlt', 'missing')}
                </span>
              </span>
              <StrengthInput value={l.strength}
                onCommit={(v) => update({ loras: c.loras.map((x) => (x.model_id === l.model_id ? { ...x, strength: v } : x)) })} />
              <button className="btn small ghost" title={t('LoRA entfernen', 'Remove LoRA')}
                onClick={() => update({ loras: c.loras.filter((x) => x.model_id !== l.model_id) })}>✕</button>
            </div>
          )
        })}
        <select value="" onChange={(e) => e.target.value && update({ loras: [...c.loras, { model_id: e.target.value, strength: 0.8 }] })}>
          <option value="">{t('+ LoRA hinzufügen …', '+ Add LoRA …')}</option>
          {loraModels.filter((m) => !c.loras.some((l) => l.model_id === m.id)).map((m) => (
            <option key={m.id} value={m.id}>{label(m.id)} ({LORA_BASE_LABEL[m.family] ?? m.family})</option>
          ))}
        </select>
        {loraModels.length === 0 && (
          <span className="small">{t('Noch keine LoRA geladen: unter „Modelle“ suchen oder eine eigene LoRA-Datei hinzufügen.',
            'No LoRA downloaded yet: search under "Models" or add your own LoRA file.')}
          {onShowModels && (
            <>{' '}<button className="link-btn small" onClick={onShowModels}>{t('Unter „Modelle“ suchen', 'Search under “Models”')}</button></>
          )}</span>
        )}
      </div>
      <label className="st-field">
        <span>{t('Stimme', 'Voice')}</span>
        <select value={source} onChange={(e) => setSource(e.target.value)}>
          <option value="describe">{t('beschreiben', 'describe')}</option>
          <option value="scene" disabled={voiceScenes.length === 0}>{t('wie der Take einer Sprecher-Szene …', 'like the take of a voice scene …')}</option>
          <option value="asset" disabled={recordings.length === 0}>{t('aus einer Aufnahme', 'from a recording')}</option>
        </select>
      </label>
      {source === 'describe' && (
        <Field
          label={t('Beschreibung der Stimme', 'Description of the voice')}
          value={c.voice}
          area
          rows={3}
          placeholder={t('z. B. eine tiefe, raue Männerstimme, etwa sechzig. Dieselbe Beschreibung klingt je Satz etwas anders: ist ein Satz gut, ihn als Vorlage wählen.',
            'e.g. a deep, rough male voice, about sixty. The same description sounds a little different per line: once a line is good, choose it as the reference.')}
          onCommit={(v) => update({ voice: v })}
        />
      )}
      {source === 'scene' && (
        <label className="st-field">
          <span>{t('Vorlage', 'Reference')}</span>
          <select value={c.voice_from ?? ''} onChange={(e) => update({ voice_from: e.target.value || null })}>
            {voiceScenes.map((x) => <option key={x.id} value={x.id}>{x.title || x.prompt.slice(0, 40) || x.id}</option>)}
          </select>
          <span className="small">{t('Deren gewählter Take gibt die Stimme für alle Sätze der Figur vor; ohne Take wird sie zuerst erzeugt (nach der Beschreibung).',
            'Its chosen take sets the voice for all of the character\'s lines; without a take it is generated first (from the description).')}</span>
        </label>
      )}
      {source === 'asset' && (
        <>
          <label className="st-field">
            <span>{t('Aufnahme', 'Recording')}</span>
            <select value={c.voice_asset_id ?? ''} onChange={(e) => update({ voice_asset_id: e.target.value || null })}>
              {recordings.map(([id, a]) => (
                <option key={id} value={id}>{a.kind === 'video' ? '▶ ' : '♪ '}{(a.prompt || id).slice(0, 50)}</option>
              ))}
            </select>
          </label>
          <Field
            label={t('Was darin gesagt wird (optional)', 'What is said in it (optional)')}
            value={c.voice_text}
            area
            rows={2}
            placeholder={t('wortgenau; dann auch Sprechweise und Betonung, sonst nur der Stimmklang',
              'word for word; then also the way of speaking, otherwise only the sound of the voice')}
            onCommit={(v) => update({ voice_text: v })}
          />
        </>
      )}
      <label className="st-field">
        <span>{t('Sprache', 'Language')}</span>
        <select value={c.language || 'auto'} onChange={(e) => update({ language: e.target.value })}>
          {SPEECH_LANGUAGES.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
        </select>
      </label>
      <div className="st-actions">
        <button className="btn small ghost danger-text" onClick={() => onCommand('character.delete', { id: c.id })}>
          {t('Figur löschen', 'Delete character')}
        </button>
      </div>
    </details>
  )
}

function ProjectProps({ p, models, onCommand, onShowModels }: {
  p: StudioProject; models: ModelInfo[]; onCommand: Props['onCommand']; onShowModels?: () => void
}) {
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
      <h4>{t('Figuren', 'Characters')}</h4>
      <p className="muted small">
        {t('Eine Figur bündelt Aussehen (LoRA, etwa selbst trainiert) und Stimme. Bild- und Videoszenen wählen unter „Figuren im Bild“, wer zu sehen ist, Sprecher-Szenen unter „Stimme“, wer spricht. Eine Videoszene mit „Ton aus Sprecher-Szene“ spricht deren Satz mit den Lippen.',
          'A character bundles a look (LoRA, e.g. one you trained) and a voice. Picture scenes choose under "Characters in the picture" who is seen, voice scenes under "Voice" who speaks. A video scene with "Sound from voice scene" speaks that line with its lips.')}
      </p>
      <div className="st-chars">
        {(p.characters ?? []).map((c) => <CharacterEditor key={c.id} p={p} c={c} models={models} onCommand={onCommand} onShowModels={onShowModels} />)}
      </div>
      <div className="st-actions">
        <button className="btn small" onClick={() => onCommand('character.add', {})}>{t('+ Figur', '+ Character')}</button>
      </div>
      <h4>{t('So geht es', 'How it works')}</h4>
      <p className="muted small">
        {t('Eine Szene, einen Clip, einen Marker oder links Material anklicken; Rechtsklick zeigt überall, was geht. Werkzeuge links oben: Auswahl (V), Schneiden (C), Magnet (S, ohne Magnet andocken mit Umschalt). Mehrere Objekte: Rahmen im Leeren aufziehen oder Umschalt-Klick. Leertaste spielt ab, Strg+K schneidet am Abspielkopf, Strg+C/X/V kopiert, schneidet aus, fügt am Abspielkopf ein, Strg+D setzt eine Überblendung, Entf löscht, Esc zeigt wieder den Schnitt. Spuren: Rechtsklick auf V1, A1 … fügt hinzu oder entfernt, Auge und Lautsprecher schalten Bild und Ton (auch im Export).',
          'Click a scene, a clip, a marker or media on the left; right-click anywhere shows what you can do. Tools at the top left: Selection (V), Razor (C), Magnet (S; without it, hold Shift to dock). Several objects: drag a box in empty space or Shift-click. Space plays, Ctrl+K cuts at the playhead, Ctrl+C/X/V copies, cuts, pastes at the playhead, Ctrl+D adds a dissolve, Del deletes, Esc shows the edit again. Tracks: right-click V1, A1 … to add or remove, the eye and speaker switch picture and sound (also in the export).')}
      </p>
    </div>
  )
}

function AssetProps({ p, a, model, playhead, onCommand, onDelete }: {
  p: StudioProject
  a: Asset
  /** Das Modell, das die Datei erzeugt hat (für die Marke „nicht veröffentlichen“), sonst undefined */
  model?: ModelInfo
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
        <OutputBadge model={model} />
      </h3>
      <FileName name={a.filename.split('/').pop() || a.filename} />
      {model?.output_badge && !model.license_confirmed && model.warning && (
        <p className="warn-banner small">{model.warning}</p>
      )}
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

/** Dateiname der angeklickten Datei (Nutzer 15.11.2026: „sonst finde ich die nicht“): ein Klick markiert ihn ganz,
 *  der Knopf kopiert ihn. Ohne sicheren Kontext (Aufruf im LAN über http) fehlt navigator.clipboard, dann kopiert
 *  der Knopf über die Markierung. */
function FileName({ name }: { name: string }) {
  const [copied, setCopied] = useState(false)
  const ref = useRef<HTMLSpanElement>(null)
  useEffect(() => setCopied(false), [name])
  const copy = async () => {
    let ok = false
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(name)
        ok = true
      }
    } catch {
      ok = false
    }
    if (!ok && ref.current) {
      const range = document.createRange()
      range.selectNodeContents(ref.current)
      const sel = window.getSelection()
      sel?.removeAllRanges()
      sel?.addRange(range)
      ok = document.execCommand('copy')
    }
    setCopied(ok)
    if (ok) window.setTimeout(() => setCopied(false), 1500)
  }
  return (
    <div className="st-filename">
      <span ref={ref} className="st-filename-name" title={t('Ein Klick markiert den ganzen Namen', 'One click selects the whole name')}>
        {/* Umbruch bevorzugt nach _ . - (wbr trägt keine Zeichen bei, kopiert wird genau der Name) */}
        {name.split(/(?<=[_.-])/).map((part, i) => (
          <Fragment key={i}>{part}<wbr /></Fragment>
        ))}
      </span>
      <button className="btn small ghost" onClick={copy} title={t('Dateinamen in die Zwischenablage kopieren', 'Copy the file name to the clipboard')}>
        {copied ? t('Kopiert', 'Copied') : t('Kopieren', 'Copy')}
      </button>
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
        <Seconds p={p} label={t('Start (s)', 'Start (s)')} value={c.start} onCommit={(v) => onCommand('clip.move', { id: c.id, start: v })} />
        <Seconds p={p} label={t('Länge (s)', 'Length (s)')} value={clipLength(c)} min={0.04} onCommit={(v) => onCommand('clip.trim', { id: c.id, out: c.in + Math.round(v * speed) })} />
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
          <VolumeRange value={c.gain_db} onCommit={(v) => update({ gain_db: v })} />
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
            p={p}
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
/** Lautstärke: der Wert zieht beim Schieben mit, gespeichert wird beim Loslassen (vorher je Schritt ein clip.update:
 * bis zu 42 Einträge auf dem Rückgängig-Stapel, und ein Zwischenwert konnte als letzter gespeichert bleiben) */
function VolumeRange({ value, onCommit }: { value: number; onCommit: (v: number) => void }) {
  const [draft, setDraft] = useState<number | null>(null)
  const v = draft ?? value
  const commit = () => {
    if (draft !== null && draft !== value) onCommit(draft)
    setDraft(null)
  }
  return (
    <label className="st-field">
      <span>{t('Lautstärke', 'Volume')}: {v > 0 ? '+' : ''}{v} dB</span>
      <input type="range" min={-30} max={12} step={1} value={v}
        onChange={(e) => setDraft(Number(e.target.value))} onPointerUp={commit} onKeyUp={commit} onBlur={commit} />
    </label>
  )
}

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
        <Seconds p={p} label={t('Dauer (s)', 'Duration (s)')} value={tr.duration} min={0.04} onCommit={(v) => update({ duration: v })} />
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
        prompt={m.kind === 'ai'}
        rows={m.kind === 'ai' ? 5 : 3}
        placeholder={m.kind === 'ai' ? t('z. B. „Diese Szene ruhiger, die Kamera steht.“', 'e.g. "Calmer here, the camera stays still."') : ''}
        onCommit={(v) => update({ comment: v })}
      />
      <div className="st-grid2">
        <Seconds p={p} label={t('Position (s)', 'Position (s)')} value={m.at} onCommit={(v) => update({ at: v })} />
        <Seconds p={p} label={t('Dauer (s)', 'Duration (s)')} value={m.duration} onCommit={(v) => update({ duration: v })} />
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
