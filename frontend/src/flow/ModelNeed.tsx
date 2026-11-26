// Fehlendes Modell an Ort und Stelle laden (seit 0.5.42, Konzept „NVAI im Fluss“: „Fehlendes an Ort und Stelle:
// Modell laden, Lizenz annehmen, Vorlage wählen, ohne in einen anderen Reiter zu springen. Geladen wird erst nach dem
// Klick.“). Der Klick ist die Rückfrage vor dem Download: Größe, Lizenz und Ladezeit stehen davor.
import { useState } from 'react'
import type { ModelInfo } from '../api'
import { hfGuideUrl } from '../components/GatedNotice'
import type { Downloads } from '../downloads'
import { t } from '../i18n'
import { downloadSeconds, fmtGb, fmtSpan } from './time'

/** Fehlt dem gesperrten Modell noch die Freigabe auf Hugging Face (Lizenz oder Token)? */
export function gatedMissing(m: ModelInfo): boolean {
  const repos = m.gated_repos ?? []
  return !m.installed && repos.length > 0 && repos.some((r) => m.gated_access?.[r] !== 'granted')
}

/** Lizenz in einer kurzen Zeile */
export function licenseLine(m: ModelInfo): string {
  return m.commercial_ok ? m.license : `${m.license} · ${t('nicht kommerziell', 'not commercial')}`
}

/** Größe, Lizenz, Ladezeit: „13 GB, Apache-2.0, bei 100 MBit/s rund 18 min“ */
export function needLine(m: ModelInfo): string {
  const gb = Math.max(0, (m.size_gb || 0) - (m.partially_installed ? m.disk_gb || 0 : 0))
  return t(`${fmtGb(gb)}, ${licenseLine(m)}, bei 100 MBit/s rund ${fmtSpan(downloadSeconds(gb))}`,
    `${fmtGb(gb)}, ${licenseLine(m)}, about ${fmtSpan(downloadSeconds(gb))} at 100 Mbit/s`)
}

interface Props {
  model: ModelInfo
  /** wofür, schon übersetzt: „für Schrift und Plakate“ */
  why?: string
  downloads: Downloads
  /** ein geladenes Modell, das es auch tut */
  alternative?: ModelInfo | null
  onUseAlternative?: () => void
  /** zum Token-Feld unter „Modelle“ */
  onShowModels?: () => void
  /** schmal (Studio-Eigenschaften): Text kürzer */
  compact?: boolean
}

export function ModelNeed({ model, why, downloads, alternative, onUseAlternative, onShowModels, compact }: Props) {
  const dl = downloads.active[model.id]
  const [err, setErr] = useState<string | null>(null)
  const gated = gatedMissing(model)
  const pct = dl ? Math.round(dl.progress * 100) : 0
  return (
    <div className="flow-need" role="group" aria-label={t(`${model.name} fehlt`, `${model.name} is missing`)}>
      <div>
        <b>{model.partially_installed ? t(`${model.name} ist nur zum Teil geladen`, `${model.name} is only partly downloaded`) : t(`${model.name} fehlt`, `${model.name} is missing`)}</b>
        {why && <> {why}.</>} {!compact && <span className="muted">{needLine(model)}.</span>}
        {compact && <div className="muted small">{needLine(model)}</div>}
      </div>
      {gated && !dl && (
        <div className="small">
          {t('Gesperrtes Modell: vorher Hugging-Face-Konto, Lizenz annehmen und Token unter „Modelle“ hinterlegen. ',
            'Gated model: first a Hugging Face account, accept the license and store a token under "Models". ')}
          <a href={hfGuideUrl()} target="_blank" rel="noreferrer">{t('Anleitung', 'Guide')}</a>
          {onShowModels && <> · <button type="button" className="link-button" onClick={onShowModels}>{t('Zum Token', 'To the token')}</button></>}
        </div>
      )}
      {dl ? (
        <div className="flow-need-dl small">
          <div className="flow-bar"><i style={{ width: `${dl.status === 'queued' ? 0 : pct}%` }} /></div>
          <span className="muted">{dl.status === 'queued' ? t('wartet auf den Download', 'waiting to download') : `${pct} %${dl.stage ? ` · ${dl.stage}` : ''}`}</span>
          <button type="button" className="btn small ghost" onClick={() => downloads.cancel(model.id)}>{t('Abbrechen', 'Cancel')}</button>
        </div>
      ) : (
        <div className="flow-row">
          <button type="button" className="btn small primary" disabled={gated}
            title={gated ? t('Erst die Lizenz auf Hugging Face annehmen und einen Token hinterlegen', 'First accept the license on Hugging Face and store a token') : undefined}
            onClick={() => { setErr(null); downloads.start(model.id).catch((e) => setErr(e instanceof Error ? e.message : String(e))) }}>
            {model.partially_installed ? t('Fortsetzen', 'Resume') : t('Laden', 'Download')}
          </button>
          {alternative && onUseAlternative && (
            <button type="button" className="btn small" onClick={onUseAlternative}>
              {t(`Lieber ${alternative.name} (geladen)`, `Rather ${alternative.name} (downloaded)`)}
            </button>
          )}
        </div>
      )}
      {err && !dl && <div className="warn-text small">{err}</div>}
    </div>
  )
}
