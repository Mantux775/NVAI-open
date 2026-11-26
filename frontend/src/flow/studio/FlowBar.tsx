// Konzept „NVAI im Fluss“, Bildschirm D (seit 0.5.42): oben im Studio eine Leiste mit den Schritten Idee · Szenen ·
// Startbilder · Videos · Schnitt · Export, daneben ein Knopf für den nächsten Schritt samt Zeit, darunter die Szenen als
// Karten mit ihrem Zustand (zusammenklappbar). Vorher standen „Szenen erzeugen“, „Übernehmen“, „Assistent“, Marker und
// Export gleichrangig nebeneinander; was als Nächstes dran ist, musste man selbst wissen. Die Knöpfe oben bleiben.
//
// Karten (Nutzer 26.11.2026: „wenn ich eine scene einfüge soll ich es auch mit rechtsklick entfernen oder mit x icon
// rechts oben (bei mouse over) löschen, genau so für andere elemente, dann via drag and drop schieben“): × beim
// Überfahren löscht, Rechtsklick zeigt das Menü der Szene wie in der Zeitleiste, Ziehen ordnet innerhalb der Bahn um.

import { useState, type DragEvent as RDragEvent, type MouseEvent as RMouseEvent } from 'react'
import type { ModelInfo, StudioProject, StudioScene } from '../../api'
import { t } from '../../i18n'
import { isActive, remainingSeconds, useJobs, useNow, type TrackedJob } from '../jobs'
import { fmtEta, fmtLeft } from '../time'
import { useStartImageEstimate, useStudioEstimates } from './estimates'
import {
  nextStep, railSteps, sceneEstimates, sceneNum, sceneOrder, sceneState, sceneTitle, sumEstimates, type ExportInfo,
  type FlowCtx, type Next, type StartRun,
} from './logic'

interface Props {
  p: StudioProject
  models: ModelInfo[]
  active?: Partial<Record<string, string | null>>
  selectedId: string | null
  startRuns: Record<string, StartRun>
  /** Fortschritt aus dem Live-Feed des Studios, falls die Auftragsliste den Auftrag noch nicht kennt */
  jobProgress: Record<string, { progress: number; stage: string }>
  exportInfo: ExportInfo
  /** Kartenreihe aufgeklappt */
  open: boolean
  onToggle: () => void
  onSelect: (sceneId: string) => void
  onNext: (next: Next) => void
  onAddScene: () => void
  /** Rechtsklick auf eine Karte: das Studio zeigt das Menü der Szene */
  onMenu: (e: RMouseEvent, sceneId: string) => void
  /** × auf einer Karte */
  onDelete: (sceneId: string) => void
  /** Neue Reihenfolge der Szenen einer Bahn (alle IDs der Bahn) */
  onReorder: (lane: string, ids: string[]) => void
}

export function FlowBar({ p, models, active, selectedId, startRuns, jobProgress, exportInfo, open, onToggle, onSelect, onNext, onAddScene, onMenu, onDelete, onReorder }: Props) {
  const jobs = useJobs()
  const progress = (s: StudioScene): number | null => {
    for (const id of s.jobs) {
      const j = jobs.find((x) => x.id === id)
      if (j && isActive(j)) return j.progress
      if (jobProgress[id]) return jobProgress[id].progress
    }
    return null
  }
  const c: FlowCtx = { p, models, active, startRuns, progress }
  const next = nextStep(c, exportInfo)
  const rail = railSteps(c, exportInfo, next.kind)
  const eta = useNextEta(c, next, jobs)
  const scenes = sceneOrder(p)
  const second = eta || next.note
  // Ziehen und Ablegen: nur innerhalb derselben Bahn; die Marke zeigt, wohin die Karte käme
  const [drag, setDrag] = useState<{ id: string; lane: string } | null>(null)
  const [mark, setMark] = useState<{ id: string; side: 'before' | 'after' } | null>(null)
  const sideOf = (e: RDragEvent<HTMLElement>): 'before' | 'after' => {
    const box = e.currentTarget.getBoundingClientRect()
    return e.clientX < box.left + box.width / 2 ? 'before' : 'after'
  }
  const dropOn = (target: StudioScene, side: 'before' | 'after') => {
    const from = drag
    setDrag(null)
    setMark(null)
    if (!from || from.lane !== target.lane || from.id === target.id) return
    const lane = scenes.filter((x) => x.lane === target.lane).map((x) => x.id)
    const ids = lane.filter((id) => id !== from.id)
    const at = ids.indexOf(target.id) + (side === 'after' ? 1 : 0)
    ids.splice(at, 0, from.id)
    if (ids.join() !== lane.join()) onReorder(target.lane, ids)
  }
  return (
    <div className="sf-flow">
      <div className="sf-top">
        <button type="button" className="sf-fold" onClick={onToggle} aria-expanded={open}
          title={open ? t('Szenenreihe einklappen', 'Collapse the scene row') : t('Szenenreihe zeigen', 'Show the scene row')}>
          {open ? '▾' : '▸'}
        </button>
        <ol className="flow-rail" aria-label={t('Stand des Projekts', 'Project progress')}>
          {rail.map((r, i) => (
            <li key={r.key} className={`step${i === next.step ? ' now' : r.done ? ' done' : ''}`} title={`${r.label}: ${r.small}. ${r.title}`}
              aria-current={i === next.step ? 'step' : undefined}>
              <b>{r.label}</b>
              <small>{r.small}</small>
            </li>
          ))}
        </ol>
        <button type="button" className="btn primary flow-big sf-next" disabled={next.disabled} onClick={() => onNext(next)}
          title={second ? `${next.label} · ${second}` : next.label}>
          <span className="sf-next-label">{next.label}</span>
          {second && <span className="flow-eta">{second}</span>}
        </button>
      </div>
      {(open || !scenes.length) && (
        <div className="sf-cards" role="group" aria-label={t('Szenen', 'Scenes')}>
          {scenes.map((s) => {
            const st = sceneState(c, s)
            const sel = s.id === selectedId
            return (
              // Karte als div statt button: Ziehen beginnt so in jedem Browser, und das × darf darin ein Knopf sein
              <div key={s.id} role="button" tabIndex={0} aria-pressed={sel} draggable data-scene-card={s.id}
                className={`flow-card${sel ? ' sel' : ''}${drag?.id === s.id ? ' sf-dragging' : ''}${mark?.id === s.id ? ` sf-drop-${mark.side}` : ''}`}
                title={`${sceneTitle(s)}: ${st.label}. ${t('Ziehen ordnet innerhalb der Bahn um, Rechtsklick zeigt mehr.', 'Drag to reorder within the lane, right-click for more.')}`}
                onClick={() => onSelect(s.id)}
                onKeyDown={(e) => {
                  if (e.key !== 'Enter' && e.key !== ' ') return
                  // nicht auch noch die Leertaste des Studios (Abspielen)
                  e.preventDefault()
                  e.stopPropagation()
                  onSelect(s.id)
                }}
                onContextMenu={(e) => {
                  e.preventDefault()
                  onMenu(e, s.id)
                }}
                onDragStart={(e) => {
                  e.dataTransfer.setData('application/x-nvai-scene-card', s.id)
                  e.dataTransfer.effectAllowed = 'move'
                  setDrag({ id: s.id, lane: s.lane })
                }}
                onDragOver={(e) => {
                  if (!drag || drag.lane !== s.lane) return // andere Bahn: hier nicht ablegen
                  e.preventDefault()
                  e.dataTransfer.dropEffect = 'move'
                  const side = sideOf(e)
                  if (drag.id === s.id) {
                    if (mark) setMark(null)
                  } else if (mark?.id !== s.id || mark.side !== side) setMark({ id: s.id, side })
                }}
                onDragLeave={(e) => {
                  if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setMark((m) => (m?.id === s.id ? null : m))
                }}
                onDrop={(e) => {
                  e.preventDefault()
                  dropOn(s, sideOf(e))
                }}
                onDragEnd={() => {
                  setDrag(null)
                  setMark(null)
                }}>
                <span className="pic"><CardPicture p={p} s={s} /></span>
                <span className="meta">
                  <b>{sceneNum(p, s.id)} · {sceneTitle(s)}</b>
                  <span className={`flow-chip ${st.tone}`}>{st.label}</span>
                </span>
                <button type="button" className="sf-card-x" draggable={false}
                  title={t('Szene löschen (Strg+Z holt sie zurück)', 'Delete the scene (Ctrl+Z brings it back)')}
                  aria-label={t(`${sceneTitle(s)} löschen`, `Delete ${sceneTitle(s)}`)}
                  onClick={(e) => {
                    e.stopPropagation()
                    onDelete(s.id)
                  }}>
                  ×
                </button>
              </div>
            )
          })}
          <button type="button" className="flow-card sf-add" onClick={onAddScene}
            title={t('Neue Videoszene hinten an der Bildbahn (5 s)', 'New video scene at the end of the picture lane (5 s)')}>
            + {t('Szene', 'Scene')}
          </button>
          {!scenes.length && (
            <span className="muted small sf-empty">
              {t('oder mit dem Assistenten ein ganzes Video anlegen (Knopf rechts oben)', 'or set up a whole video with the assistant (button at the top right)')}
            </span>
          )}
        </div>
      )}
    </div>
  )
}

/** Bild der Karte: Take, sonst Startbild. Ein Video zeigt sein Startbild, wenn es eins hat (weniger Verbindungen zum
 *  Server als ein weiteres Video-Element), sonst sein erstes Bild. */
function CardPicture({ p, s }: { p: StudioProject; s: StudioScene }) {
  if (s.lane !== 'video') return <span aria-hidden="true">♪</span>
  const start = s.params?.image_asset_id ? p.assets[s.params.image_asset_id] : undefined
  const take = s.take ? p.assets[s.take] : undefined
  if (take?.kind === 'image') return <img src={take.url} alt="" loading="lazy" draggable={false} />
  if (start && (!take || take.kind === 'video')) return <img src={start.url} alt="" loading="lazy" draggable={false} />
  if (take?.kind === 'video') return <video src={`${take.preview ?? take.url}#t=0.1`} preload="metadata" muted />
  return null
}

/** Zeit des nächsten Schritts: Szenen erzeugen, Startbilder, oder die Restzeit dessen, was gerade rechnet */
function useNextEta(c: FlowCtx, next: Next, jobs: TrackedJob[]): string {
  const generating = next.kind === 'generate' ? next.scenes : []
  const ids = generating.map((s) => s.id)
  const got = useStudioEstimates(c.p.id, ids.length ? ids : null, `${ids.join(',')}|${c.p.updated_at}`, 500)
  const startSeconds = useStartImageEstimate(c.p, c.models, next.kind === 'start' ? next.scenes : [])
  const busyJobs = next.kind === 'busy'
    ? jobs.filter((j) => isActive(j) && next.scenes.some((s) => s.jobs.includes(j.id) || c.startRuns[s.id]?.job === j.id))
    : []
  const now = useNow(busyJobs.length > 0)
  if (next.kind === 'generate') {
    const sum = sumEstimates(sceneEstimates(c, generating, got))
    if (sum.seconds == null) return ''
    return sum.unknown ? `${fmtEta(sum.seconds)} +` : fmtEta(sum.seconds)
  }
  if (next.kind === 'start') return fmtEta(startSeconds)
  if (busyJobs.length) {
    const left = busyJobs.map((j) => remainingSeconds(j, null, now)).filter((x): x is number => x != null)
    return left.length ? fmtLeft(Math.max(...left)) : ''
  }
  return ''
}
