// Konzept „NVAI im Fluss“, Bildschirm E (seit 0.5.42): Szene im Fokus. Oben der Zustand mit dem passenden Knopf (fehlt,
// wartet, rechnet, wählen, veraltet), darunter Modell und Weg, dann nur die Zusätze, die das Modell kann; die Aktionen
// stehen fest unten, statt mit langen Eigenschaften nach unten zu wandern. Die Felder selbst (Startbild, Endbild,
// Layout, Prompt …) bleiben in studio/Inspector.tsx, Seltenes dort unter „Feineinstellung“.

import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { LoraRef, ModelInfo, StudioProject, StudioScene } from '../../api'
import { t } from '../../i18n'
import { currentPhase, isActive, remainingSeconds, useJob, useNow } from '../jobs'
import { ModelNeed } from '../ModelNeed'
import { fmtLeft } from '../time'
import { takeSeed } from './estimates'
import {
  chainApart, loadedAlternative, missingModel, noDfrWay, sceneBefore, sceneFacts, sceneModel, sceneNum, sceneRef, startImageNeed, usesDfr,
  WAY_ORDER, waysFor, wayOf, type SceneFlow, type SceneState, type Way,
} from './logic'

const WAY_LABEL: Record<Way, string> = {
  text: t('Nur Text', 'Text only'),
  start: t('Startbild', 'Start image'),
  chain: t('Anschluss', 'Chain'),
  loop: t('Schleife', 'Loop'),
  ends: t('Start und Ende', 'Start and end'),
  layout: t('Layout', 'Layout'),
}

const WAY_HINT: Record<Way, string> = {
  text: t('Das Modell erfindet das erste Bild aus dem Prompt.', 'The model invents the first frame from the prompt.'),
  start: t('Der Clip beginnt mit einem Bild; so sieht eine Figur in jeder Einstellung gleich aus.', 'The clip begins with an image, so a character looks the same in every shot.'),
  chain: t('Beginnt mit dem Ende der Szene davor; mit LTX-2.5 mit deren letzter Sekunde, beim Übernehmen überblendet.', 'Begins with the end of the scene before; with LTX-2.5 with its last second, crossfaded on conform.'),
  loop: t('Endet wieder im Startbild. Nur mit ruhiger Kamera; Wasser und Rauch stehen dann still. Ohne DFR.', 'Ends with the start image again. Only with a calm camera; water and smoke then stand still. No DFR.'),
  ends: t('Start- und Endbild halten Kamera und Gesicht. Ohne DFR.', 'Start and end image hold camera and face. No DFR.'),
  layout: t('Ein grobes Layout-Video gibt Kamera und Bewegung vor, das Startbild Look und Licht. Ohne DFR.', 'A rough layout video sets camera and motion, the start image look and light. No DFR.'),
}

// ------------------------------------------------------------------------------------------------- Kopf

/** Titel im Kopf, direkt bearbeitbar; gilt beim Verlassen oder mit Enter wie die übrigen Felder */
function InlineTitle({ value, placeholder, onCommit }: { value: string; placeholder: string; onCommit: (v: string) => void }) {
  const [v, setV] = useState(value)
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
  // Verschwindet der Kopf vor dem Verlassen des Feldes (andere Szene gewählt), den Titel noch an seine Szene geben
  const latest = useRef({ v, value, onCommit })
  latest.current = { v, value, onCommit }
  useEffect(() => () => {
    const { v: cur, value: orig, onCommit: to } = latest.current
    if (cur !== orig && cur !== committed.current) to(cur)
  }, [])
  return (
    <input className="sf-title" value={v} placeholder={placeholder} aria-label={t('Titel', 'Title')}
      onChange={(e) => setV(e.target.value)} onBlur={commit}
      onKeyDown={(e) => e.key === 'Enter' && (e.target as HTMLInputElement).blur()} />
  )
}

export function SceneHead({ p, s, state, onTitle }: {
  p: StudioProject; s: StudioScene; state: SceneState; onTitle: (v: string) => void
}) {
  return (
    <h3 className="sf-head">
      <span className="sf-num">{s.lane === 'video' ? sceneRef(p, s.id) : sceneNum(p, s.id)} ·</span>
      <InlineTitle value={s.title} placeholder={t('Titel', 'Title')} onCommit={onTitle} />
      <span className={`flow-chip ${state.tone}`}>{state.label}</span>
    </h3>
  )
}

// ------------------------------------------------------------------------------------------- Zustand oben

/** Fortschritt des laufenden Auftrags: Phase, Balken, Restzeit (aus der Auftragsliste, sonst aus dem Live-Feed) */
function RunNote({ jobId, fallback, expected, what }: { jobId?: string; fallback: number | null; expected: number | null; what?: string }) {
  const job = useJob(jobId)
  const now = useNow(!!job && isActive(job))
  const phase = job ? currentPhase(job) : null
  const pct = Math.max(0, Math.min(100, Math.round((job ? job.progress : fallback ?? 0) * 100)))
  const left = job ? remainingSeconds(job, expected, now) : null
  const label = phase === 'queue' ? t('Wartet auf die GPU', 'Waiting for the GPU')
    : phase === 'prepare' ? t('Bereitet vor', 'Preparing')
      : phase === 'start' ? t('Rechner startet (ComfyUI)', 'Engine starts (ComfyUI)')
        : phase === 'load' ? t('Modell lädt', 'Model loads')
          : phase === 'save' ? t('Speichert', 'Saving')
            : job?.step && job.step.pass ? t(`Rechnet · Durchgang ${job.step.pass.n} von ${job.step.pass.of} · Schritt ${job.step.n} von ${job.step.of}`, `Computing · pass ${job.step.pass.n} of ${job.step.pass.of} · step ${job.step.n} of ${job.step.of}`)
            : job?.step ? t(`Rechnet · Schritt ${job.step.n} von ${job.step.of}`, `Computing · step ${job.step.n} of ${job.step.of}`)
              : t(`Rechnet · ${pct} %`, `Computing · ${pct} %`)
  return (
    <div className="flow-note small sf-run" aria-live="polite">
      <div className="sf-run-line">
        <span>{what ? `${what}: ` : ''}{label}</span>
        <span className="sf-run-left">{fmtLeft(left)}</span>
      </div>
      <div className="flow-bar"><i style={{ width: `${!job || phase === 'run' ? pct : phase === 'save' ? 100 : 0}%` }} /></div>
    </div>
  )
}

export function StateNote({ p, s, state, model, models, eta, startEta, expected, flow, onGenerate, onWay, update }: {
  p: StudioProject
  s: StudioScene
  state: SceneState
  model?: ModelInfo
  models: ModelInfo[]
  /** „≈ 1:50“ für Erzeugen bzw. Neu rechnen */
  eta: string
  /** „≈ 40 s“ für Startbild erzeugen */
  startEta: string
  /** geschätzte Rechenzeit ohne Start und Laden (Sekunden) für die Restzeit */
  expected: number | null
  flow?: SceneFlow
  onGenerate: () => void
  /** Weg wechseln; beim Anschluss mit der Szene, an die er gehen soll */
  onWay: (w: Way, chainTo?: string | null) => void
  update: (fields: Record<string, unknown>) => void
}) {
  const withEta = (label: string, e: string) => (e ? `${label} · ${e}` : label)
  switch (state.key) {
    case 'running':
      return <RunNote jobId={s.jobs[s.jobs.length - 1]} fallback={flow?.progressOf(s) ?? null} expected={expected} />
    case 'start_running': {
      const run = flow?.startRuns[s.id]
      return <RunNote jobId={run?.job} fallback={null} expected={null} what={t('Startbild', 'Start image')} />
    }
    case 'waiting': {
      const src = p.scenes.find((x) => x.id === s.waiting_for)
      const ref = sceneRef(p, s.waiting_for)
      return (
        <p className="flow-note small">
          {s.lane === 'voice'
            ? t(`Wartet auf den Take von ${ref}: Er gibt die Stimme vor.`, `Waiting for the take of ${ref}: it sets the voice.`)
            : src?.lane === 'voice'
              ? t(`Wartet auf den Satz von ${ref}: Diese Szene spricht ihn.`, `Waiting for the line of ${ref}: this scene speaks it.`)
              : t(`Wartet auf ${ref}: Diese Szene beginnt mit deren Ende.`, `Waiting for ${ref}: this scene begins with its ending.`)}
        </p>
      )
    }
    case 'chain_wait':
      return (
        <p className="flow-note small">
          {t(`Schließt an ${sceneRef(p, s.chain_from)} an, die noch kein Video hat. „Erzeugen“ rechnet erst sie, dann diese.`,
            `Continues ${sceneRef(p, s.chain_from)}, which has no video yet. "Generate" renders it first, then this one.`)}
        </p>
      )
    case 'error':
      return (
        <div className="flow-note warn small">
          <b>{t('Fehler', 'Error')}:</b> {s.error}
          <div className="flow-row sf-note-actions">
            <button type="button" className="btn small" onClick={onGenerate}>{withEta(t('Erneut versuchen', 'Try again'), eta)}</button>
          </div>
        </div>
      )
    case 'cancelled':
      return (
        <div className="flow-note warn small">
          {t('Der letzte Auftrag wurde abgebrochen.', 'The last job was cancelled.')}
          <div className="flow-row sf-note-actions">
            <button type="button" className="btn small" onClick={onGenerate}>{withEta(t('Neu erzeugen', 'Generate again'), eta)}</button>
          </div>
        </div>
      )
    case 'stale': {
      const st = s.stale!
      const text = st.why === 'take'
        ? t(`${sceneRef(p, st.source)} hat einen neuen Take. Diese Szene schließt daran an und beginnt noch mit dem alten Ende.`,
          `${sceneRef(p, st.source)} has a new take. This scene continues from it and still begins with the old ending.`)
        : st.reason
      return (
        <div className="flow-note warn small" role="status">
          {text}
          <div className="flow-row sf-note-actions">
            <button type="button" className="btn small primary" onClick={onGenerate}>{withEta(t('Neu rechnen', 'Render again'), eta)}</button>
            <button type="button" className="btn small" onClick={() => update({ params: { chain_keep: { take: s.take, source: st.take } } })}
              title={t('Den Hinweis für genau diesen Take nicht mehr zeigen (Strg+Z holt ihn zurück)', 'Stop showing this notice for exactly this take (Ctrl+Z brings it back)')}>
              {t('So lassen', 'Keep as is')}
            </button>
          </div>
        </div>
      )
    }
    case 'choose': {
      const i = s.takes.indexOf(s.take ?? '')
      return (
        <div className="flow-note small">
          {t(`${s.takes.length} Takes: unten den besten wählen; der gewählte kommt in den Schnitt.`,
            `${s.takes.length} takes: choose the best one below; the chosen one goes into the edit.`)}
          <div className="flow-row sf-note-actions">
            <button type="button" className="btn small" onClick={() => update({ params: { take_ok: s.take } })}>
              {t(`Take ${takeLetter(i)} behalten`, `Keep take ${takeLetter(i)}`)}
            </button>
          </div>
        </div>
      )
    }
    case 'start_missing': {
      const canText = !!model && waysFor(model, false).includes('text')
      const busy = flow?.startRuns[s.id]?.status === 'running'
      const need = startImageNeed(models)
      if (need && flow?.downloads) {
        return (
          <div className="sf-stack">
            <p className="flow-note warn small">{t('Startbild fehlt, und für Startbilder ist noch kein Bildmodell geladen.', 'The start image is missing, and no image model for start images is downloaded yet.')}</p>
            <ModelNeed model={need} why={t('für die Startbilder', 'for the start images')} downloads={flow.downloads} compact />
            {canText && <button type="button" className="btn small" onClick={() => onWay('text')}>{t('Ohne Startbild: Nur Text', 'Without a start image: text only')}</button>}
          </div>
        )
      }
      return (
        <div className="flow-note warn small">
          {t('Startbild fehlt. Erzeugen oder ein Bild aus dem Material auf „Startbild“ ziehen.', 'The start image is missing. Generate one or drag an image from the media onto "Start image".')}
          <div className="flow-row sf-note-actions">
            {flow && (
              <button type="button" className="btn small primary" disabled={busy || !s.prompt.trim()} onClick={() => flow.onStartImages([s.id])}>
                {withEta(t('Startbild erzeugen', 'Generate start image'), startEta)}
              </button>
            )}
            {canText && <button type="button" className="btn small" onClick={() => onWay('text')}>{t('Nur Text', 'Text only')}</button>}
          </div>
        </div>
      )
    }
    case 'chain_apart': {
      // Seit sich Szenen in der Kartenreihe umordnen lassen: Der Anschluss bleibt, die Naht passt aber nicht mehr
      const src = chainApart(p, s)
      const before = sceneBefore(p, s)
      const ref = sceneRef(p, src?.id)
      const canStart = !!model && waysFor(model, false).includes('start')
      return (
        <div className="flow-note warn small">
          {s.take
            ? t(`${ref} liegt nicht mehr direkt vor dieser Szene. Der Take beginnt mit deren Ende; im Schnitt passt die Naht so nicht.`,
              `${ref} is no longer directly before this scene. The take begins with its ending; in the edit the seam does not fit like this.`)
            : t(`${ref} liegt nicht mehr direkt vor dieser Szene; ein neuer Take begänne trotzdem mit deren Ende.`,
              `${ref} is no longer directly before this scene; a new take would still begin with its ending.`)}
          <div className="flow-row sf-note-actions">
            {before && before.id !== src?.id && before.kind === 'video' && (
              <button type="button" className="btn small" onClick={() => onWay('chain', before.id)}>
                {t(`Anschluss an ${sceneNum(p, before.id)}`, `Chain to ${sceneNum(p, before.id)}`)}
              </button>
            )}
            {canStart && !!s.chain_from && !s.chain_marker && (
              <button type="button" className="btn small" onClick={() => onWay('start')}>{t('Startbild statt Anschluss', 'Start image instead')}</button>
            )}
          </div>
        </div>
      )
    }
    case 'end_missing':
      return <p className="flow-note warn small">{t('Endbild fehlt: unten ein Bild wählen.', 'The end image is missing: choose an image below.')}</p>
    case 'layout_missing':
      return <p className="flow-note warn small">{t('Layout-Video fehlt: unten ein Video wählen.', 'The layout video is missing: choose a video below.')}</p>
    default:
      return null
  }
}

// ----------------------------------------------------------------------------------------------- Modell

export function ModelLine({ p, s, models, active, flow, onPick, onModelClick, onShowModels }: {
  p: StudioProject
  s: StudioScene
  models: ModelInfo[]
  active?: Partial<Record<string, string | null>>
  flow?: SceneFlow
  onPick: (modelId: string) => void
  /** Modell wechseln (öffnet „Feineinstellung“ mit der Auswahl) */
  onModelClick: () => void
  onShowModels?: () => void
}) {
  const missing = missingModel(s, models, active)
  const model = sceneModel(s, models, active)
  if (missing) {
    const alt = loadedAlternative(s, models, missing)
    if (flow?.downloads) {
      return (
        <ModelNeed model={missing} why={t('für diese Szene', 'for this scene')} downloads={flow.downloads} compact
          alternative={alt} onUseAlternative={alt ? () => onPick(alt.id) : undefined} onShowModels={onShowModels} />
      )
    }
    return (
      <p className="warn-text small">
        {t(`${missing.name} ist nicht installiert:`, `${missing.name} is not installed:`)}{' '}
        {onShowModels && <button type="button" className="link-btn small" onClick={onShowModels}>{t('unter „Modelle“ laden', 'download it under “Models”')}</button>}
      </p>
    )
  }
  if (!model) return null
  const dl = flow?.downloads?.active[model.id]
  return (
    <div className="sf-model">
      <button type="button" className="flow-chip ok" onClick={onModelClick}
        title={t('Modell wechseln (unter „Feineinstellung“)', 'Change the model (under "Advanced settings")')}>
        {model.name} · {dl ? t(`lädt ${Math.round(dl.progress * 100)} %`, `downloading ${Math.round(dl.progress * 100)} %`) : t('bereit', 'ready')}
      </button>
      <span className="muted">{sceneFacts(p, s, model)}</span>
    </div>
  )
}

// ------------------------------------------------------------------------------------------------- Weg

export function WaySeg({ p, s, model, onWay }: {
  p: StudioProject
  s: StudioScene
  model?: ModelInfo
  onWay: (w: Way, chainTo: string | null) => void
}) {
  const current = wayOf(s, model)
  const before = sceneBefore(p, s)
  const ways = waysFor(model, !!before)
  if (!ways.includes(current)) ways.push(current) // die aktuelle Wahl bleibt sichtbar, auch wenn das Modell sie nicht kann
  const marker = !!s.chain_marker
  const target = s.chain_from ?? before?.id ?? null
  return (
    <div className="flow-seg sf-ways" role="group" aria-label={t('Weg', 'Path')}>
      {WAY_ORDER.filter((w) => ways.includes(w)).map((w) => (
        <button key={w} type="button" aria-pressed={current === w} disabled={marker && w !== current}
          title={marker && w !== current
            ? t('Der Anschluss kommt von einem Anschluss-Marker: zum Ändern den Marker verschieben oder löschen.', 'The chain comes from a chain marker: move or delete the marker to change it.')
            : WAY_HINT[w]}
          onClick={() => current !== w && onWay(w, w === 'chain' ? before?.id ?? null : null)}>
          {w === 'chain' ? t(`Anschluss an ${sceneNum(p, target)}`, `Chain to ${sceneNum(p, target)}`) : WAY_LABEL[w]}
        </button>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------------- Was das Modell dazu kann

function Toggle({ on, label, title, onClick }: { on: boolean; label: string; title?: string; onClick: () => void }) {
  return (
    <button type="button" className={`sf-toggle${on ? ' on' : ''}`} aria-pressed={on} title={title} onClick={onClick}>
      {label}
    </button>
  )
}

/** „Slow Motion Control (LTX-2.5, Lightricks)“ → „Slow Motion Control“ */
const loraShort = (name: string) => name.replace(/\s*\([^)]*\)\s*$/, '')

/** Schalter für das, was das Modell der Szene laut Katalog kann: DFR, Zeitlupe, 48 fps, passende LoRAs, Seed festhalten.
 *  Genaue Werte (Faktor der Zeitlupe, Stärke der LoRAs, Seed als Zahl) stehen unter „Feineinstellung“. */
export function SceneToggles({ p, s, model, models, update }: {
  p: StudioProject
  s: StudioScene
  model?: ModelInfo
  models: ModelInfo[]
  update: (fields: Record<string, unknown>) => void
}) {
  const [seedBusy, setSeedBusy] = useState(false)
  if (!model) return null
  const f = model.features ?? {}
  const q = s.params ?? {}
  const video = s.lane === 'video' && s.kind === 'video'
  const picture = s.lane === 'video'
  const ltx = video && model.family === 'ltx25'
  const way = wayOf(s, model)
  const dfr = usesDfr(p, s, model)
  const speed = Number(q.motion_speed ?? 1)
  const loras: LoraRef[] = q.loras ?? []
  const set = (fields: Record<string, unknown>) => update({ params: fields })
  // LoRAs: die der Szene und die für dieses Modell empfohlenen, die gerade passen (Zeitlupe, Schleife, Start und Ende …)
  const fitting = picture ? models.filter((m) => m.kind === 'lora' && m.installed && (model.lora_bases ?? []).includes(m.family)) : []
  const uses = new Set<string>()
  if (q.image_asset_id) uses.add('start_image')
  if (way === 'loop') uses.add('loop')
  if (way === 'ends') uses.add('end_image')
  if (speed < 1) uses.add('motion_speed')
  if (q.audio_from || q.audio_asset_id) uses.add('audio_input')
  const offered = fitting.filter((m) => (m.features?.recommended_for ?? []).includes(model.family)
    && (!m.features?.use || uses.has(m.features.use)))
  const shown = [...loras.map((l) => l.model_id), ...offered.map((m) => m.id).filter((id) => !loras.some((l) => l.model_id === id))].slice(0, 5)
  const keepSeed = async () => {
    if (q.seed != null) {
      set({ seed: null })
      return
    }
    setSeedBusy(true)
    const seed = s.take ? await takeSeed(s.take) : null
    setSeedBusy(false)
    set({ seed: seed ?? Math.floor(Math.random() * 2 ** 31) })
  }
  const items: ReactNode[] = []
  if (ltx && f.dfr && !noDfrWay(way)) {
    items.push(<Toggle key="dfr" on={dfr} label="DFR"
      title={t('Höchste Qualität: über die ganze Länge scharf, rund dreimal so lang', 'Best quality: sharp over the whole clip, about three times the time')}
      onClick={() => set(dfr ? { quality: 'standard', temporal_upscale: null } : { quality: 'dfr' })} />)
  }
  if (ltx && f.motion_speed) {
    items.push(<Toggle key="slow" on={speed < 1}
      label={speed < 1 ? t(`Zeitlupe ${Math.round(1 / speed)}×`, `Slow motion ${Math.round(1 / speed)}×`) : t('Zeitlupe 2×', 'Slow motion 2×')}
      title={t('Echte Zeitlupe mit der LoRA „Slow Motion Control“ und einem Startbild; den Faktor stellst du unter „Feineinstellung“ ein.', 'Real slow motion with the "Slow Motion Control" LoRA and a start image; set the factor under "Advanced settings".')}
      onClick={() => set({ motion_speed: speed < 1 ? null : 0.5 })} />)
  }
  if (ltx && f.temporal_upscale && dfr) {
    items.push(<Toggle key="fps" on={!!q.temporal_upscale} label="48 fps"
      title={t('Zeitlich verdoppelt, langsamer (nur mit DFR)', 'Temporal upscale, slower (DFR only)')}
      onClick={() => set(q.temporal_upscale ? { temporal_upscale: null } : { temporal_upscale: true, quality: 'dfr' })} />)
  }
  for (const id of shown) {
    const m = models.find((x) => x.id === id)
    const on = loras.some((l) => l.model_id === id)
    items.push(<Toggle key={id} on={on} label={`LoRA: ${loraShort(m?.name ?? id)}`}
      title={[m?.best_for, m?.trigger ? t(`Trigger: ${m.trigger}`, `Trigger: ${m.trigger}`) : ''].filter(Boolean).join(' · ')}
      onClick={() => set({ loras: on ? loras.filter((l) => l.model_id !== id) : [...loras, { model_id: id, strength: m?.features?.strength ?? 0.8 }] })} />)
  }
  items.push(<Toggle key="seed" on={q.seed != null} label={seedBusy ? t('Seed …', 'Seed …') : t('Seed festhalten', 'Keep the seed')}
    title={q.seed != null ? t(`Seed ${q.seed}: „Neu erzeugen“ rechnet mit demselben Zufall`, `Seed ${q.seed}: "Generate again" uses the same randomness`)
      : t('Den Seed des gewählten Takes behalten, um nur den Prompt zu ändern', 'Keep the seed of the chosen take to change only the prompt')}
    onClick={keepSeed} />)
  return (
    <div className="sf-can">
      <span className="flow-label">{t(`Was ${model.name} dazu kann`, `What ${model.name} adds`)}</span>
      <div className="flow-row sf-toggles">{items}</div>
    </div>
  )
}

// ------------------------------------------------------------------------------------------------- Takes

/** A, B, C … (ab dem 27. die Nummer) */
export const takeLetter = (i: number) => (i >= 0 && i < 26 ? String.fromCharCode(65 + i) : String(i + 1))

export function SceneTakes({ p, s, attention, onPick }: {
  p: StudioProject; s: StudioScene; attention: boolean; onPick: (assetId: string) => void
}) {
  return (
    <div className={`sf-takes${attention ? ' sf-attn' : ''}`}>
      <span className="flow-label">{t('Takes', 'Takes')} ({s.takes.length})</span>
      {s.takes.length === 0 && (
        <p className="muted small">{t('Noch keine. Erzeugen oder ein Asset aus der Medienleiste auf die Szene ziehen.', 'None yet. Generate, or drag an asset from the media bin onto the scene.')}</p>
      )}
      {s.takes.length > 0 && (
        <div className="st-takes">
          {s.takes.map((id, i) => {
            const a = p.assets[id]
            const sel = s.take === id
            return (
              <button key={id} type="button" className={`st-take${sel ? ' st-sel' : ''}`} onClick={() => onPick(id)}
                title={sel ? t('Gewählt. Klick bestätigt die Wahl.', 'Chosen. Click to confirm the choice.') : a?.prompt}>
                {a?.kind === 'image' ? <img src={a.url} alt="" /> : a?.kind === 'video' ? <video src={`${a.preview ?? a.url}#t=0.1`} preload="metadata" muted /> : <span>♪</span>}
                <span className="small">{takeLetter(i)}{sel ? ` · ${t('gewählt', 'chosen')}` : ''}</span>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------------------- Fester Fuß

export function SceneFoot({ p, s, state, eta, missing, lacks, also, spoken, onGenerate, onConform }: {
  p: StudioProject
  s: StudioScene
  state: SceneState
  eta: string
  /** fehlendes Modell: Erzeugen geht erst nach dem Laden */
  missing: boolean
  /** dem gewählten Weg fehlt noch etwas (Schleife ohne Startbild …): der Grund */
  lacks?: string
  /** Vorlagen ohne Take, die mit erzeugt werden („Szene 2“) */
  also?: string
  /** Sprechersatz, den eine Videoszene schon als Ton spricht: kommt nicht eigens in den Schnitt */
  spoken?: boolean
  onGenerate: () => void
  onConform: () => void
}) {
  const busy = state.key === 'running' || state.key === 'waiting'
  const linked = p.clips.filter((c) => c.scene_id === s.id)
  const inEditNow = !!s.take && linked.some((c) => c.asset_id === s.take)
  const label = state.key === 'running' ? t('Rechnet …', 'Computing …')
    : state.key === 'waiting' ? t('Wartet …', 'Waiting …')
      : also ? t(`Erzeugen, ${also} zuerst`, `Generate, ${also} first`)
        : s.take ? t('Neu erzeugen', 'Generate again') : t('Erzeugen', 'Generate')
  const why = !s.prompt.trim() ? t('Erst einen Prompt schreiben', 'Write a prompt first')
    : missing ? t('Erst das Modell laden (oben)', 'Download the model first (above)') : lacks
  return (
    <div className="sf-foot">
      <button type="button" className="btn small primary" disabled={busy || !!why} onClick={onGenerate} title={why}>
        <span>{label}</span>{eta && !busy && <span className="flow-eta">· {eta}</span>}
      </button>
      <button type="button" className="btn small" disabled={!s.take || inEditNow || spoken} onClick={onConform}
        title={spoken ? t('Den Satz spricht schon eine Videoszene; er kommt nicht noch einmal in den Schnitt', 'A video scene already speaks this line; it does not go into the edit a second time')
          : inEditNow ? t('Dieser Take liegt schon im Schnitt', 'This take is already in the edit')
          : linked.length ? t('Den Clip im Schnitt gegen diesen Take tauschen (fragt nach, wenn er geschnitten ist)', 'Swap the clip in the edit for this take (asks if it was trimmed)')
            : t('Diese Szene in den Schnitt legen', 'Put this scene into the edit')}>
        {inEditNow ? t('Im Schnitt', 'In the edit') : t('In den Schnitt', 'Into the edit')}
      </button>
    </div>
  )
}
