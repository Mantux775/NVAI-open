// „Übernehmen“ mit Rückfrage (Nutzer 27.10.2026: „was passiert wenn ich nochmal auf Conform klicke? überschreibt es
// Clips? es soll erkennen wenn die clips schon generiert worden sind …, ich kann dann mit der Checkbox wählen, welche
// überschrieben werden sollen; wenn es sich mit einem Clip nur überschneidet, soll es mich warnen“). Zeigt den Plan des
// Servers (GET …/conform): neue Clips, neuer Take für vorhandene Clips, Überdeckungen. Vorgewählt ist, was nichts
// Vorhandenes verändert, das der Nutzer geschnitten hat.

import { useState } from 'react'
import type { StudioConformItem } from '../api'
import { t } from '../i18n'
import { decimal } from './time'

export interface ConformPlan {
  items: StudioConformItem[]
  without_take: number
  transition_markers: number
}

const num = (x: number | undefined) => decimal((x ?? 0).toFixed(2))

export function ConformDialog({ plan, onRun, onClose }: {
  plan: ConformPlan
  onRun: (params: { scenes: string[]; overwrite: string[] }) => void
  onClose: () => void
}) {
  const [checked, setChecked] = useState(() => new Set(plan.items.filter((i) => i.default).map((i) => i.scene_id)))
  const toggle = (id: string, on: boolean) =>
    setChecked((old) => {
      const next = new Set(old)
      if (on) next.add(id)
      else next.delete(id)
      return next
    })
  const create = plan.items.filter((i) => i.action === 'create')
  const replace = plan.items.filter((i) => i.action === 'replace')
  const same = plan.items.filter((i) => i.action === 'same').length
  const errors = plan.items.filter((i) => i.action === 'error')

  const line = (i: StudioConformItem) => {
    const warn = i.action === 'create' && (i.overlaps?.length || i.in_edit)
    return (
      <label key={i.scene_id} className={`st-check st-conform-item${warn ? ' warn' : ''}`}>
        <input type="checkbox" checked={checked.has(i.scene_id)} onChange={(e) => toggle(i.scene_id, e.target.checked)} />
        <span>
          <b>{i.title}</b>{' '}
          <span className="muted">
            {i.track} · {num(i.start_s)} s · {num(i.length_s)} s
          </span>
          {i.action === 'replace' && (
            <span className="small muted">
              {' '}
              {i.edited
                ? t('· von dir geschnitten: Schnitt bleibt, das Material wird getauscht', '· cut by you: the cut stays, the material is swapped')
                : t('· unverändert: bekommt den neuen Take', '· unchanged: gets the new take')}
            </span>
          )}
          {i.action === 'create' && !!i.overlaps?.length && (
            <span className="small warn-text">
              {' '}
              {t('· würde überdecken: ', '· would cover: ')}
              {i.overlaps.map((o) => t(`„${o.title}“`, `"${o.title}"`) + ` (${num(o.seconds)} s)`).join(', ')}
              {t(' – Häkchen erlaubt das Überschreiben', ' – the tick allows overwriting')}
            </span>
          )}
          {i.action === 'create' && i.in_edit && (
            <span className="small warn-text">{t(' · dieser Take liegt schon im Schnitt', ' · this take is already in the edit')}</span>
          )}
        </span>
      </label>
    )
  }

  return (
    <div className="st-dialog-layer" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="st-dialog" role="dialog" aria-label={t('Übernehmen', 'Conform')}>
        <h3>{t('Komposition in den Schnitt übernehmen', 'Conform the composition into the edit')}</h3>
        {create.length > 0 && (
          <>
            <h4>{t('Neue Clips', 'New clips')}</h4>
            {create.map(line)}
          </>
        )}
        {replace.length > 0 && (
          <>
            <h4>{t('Neuer Take für Clips im Schnitt (überschreiben?)', 'New take for clips in the edit (overwrite?)')}</h4>
            {replace.map(line)}
          </>
        )}
        {errors.map((i) => (
          <p key={i.scene_id} className="small warn-text">
            {i.title}: {i.error}
          </p>
        ))}
        <p className="muted small">
          {same > 0 && t(`${same} Clip(s) sind schon auf dem Stand ihrer Szene. `, `${same} clip(s) already match their scene. `)}
          {plan.without_take > 0 && t(`${plan.without_take} Szene(n) ohne Take bleiben außen vor. `, `${plan.without_take} scene(s) without a take are left out. `)}
          {plan.transition_markers > 0 && t(`${plan.transition_markers} Übergang-Marker werden angewendet.`, `${plan.transition_markers} transition marker(s) are applied.`)}
        </p>
        <div className="st-actions st-dialog-actions">
          <button className="btn small ghost" onClick={onClose}>{t('Abbrechen', 'Cancel')}</button>
          <button
            className="btn small primary"
            onClick={() => {
              const scenes = plan.items.filter((i) => checked.has(i.scene_id)).map((i) => i.scene_id)
              const overwrite = create.filter((i) => checked.has(i.scene_id) && i.overlaps?.length).map((i) => i.scene_id)
              onRun({ scenes, overwrite })
            }}
          >
            {t(`Übernehmen (${checked.size})`, `Conform (${checked.size})`)}
          </button>
        </div>
      </div>
    </div>
  )
}
