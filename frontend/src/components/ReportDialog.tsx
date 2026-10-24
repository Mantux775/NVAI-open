import { useEffect, useState } from 'react'
import { api, type ProblemReport } from '../api'
import { t } from '../i18n'

/** Bericht als Textdatei speichern (im Browser: Download). */
function download(report: ProblemReport) {
  const url = URL.createObjectURL(new Blob([report.text], { type: 'text/plain;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = report.filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

/** Neues GitHub-Issue, vorausgefüllt; die Datei hängt der Nutzer per Ziehen an. */
function issueUrl(report: ProblemReport, description: string): string {
  const s = report.summary
  const firstLine = description.trim().split('\n')[0].slice(0, 80)
  const body = [
    '### What happened / Was ist passiert',
    description.trim(),
    '',
    `When / Wann: ${s.time}`,
    `NVAI-open: ${s.version} (Windows) · ${s.os}`,
    `Graphics / Grafik: ${s.graphics} · driver ${s.driver}`,
    s.last_error ? `Last error / Letzter Fehler:\n\`\`\`\n${s.last_error}\n\`\`\`` : '',
    '',
    `Report / Bericht: please drag \`${report.filename}\` into this box / bitte \`${report.filename}\` hier hineinziehen.`,
  ].filter((l, i, a) => l !== '' || a[i - 1] !== '').join('\n')
  const q = new URLSearchParams({ title: `[Bug] ${firstLine}`, labels: 'bug', body })
  return `${report.issues_url}?${q.toString()}`
}

/**
 * „Problem melden“: kurze Beschreibung, dann ein anonymisierter Bericht (Systemangaben, letzte
 * Aufträge ohne Prompts, Logenden). Herunterladen und als GitHub-Issue melden; hochgeladen wird
 * nichts von selbst -- der Nutzer sieht vorher, was drinsteht.
 */
export function ReportDialog({ onClose }: { onClose: () => void }) {
  const [description, setDescription] = useState('')
  const [report, setReport] = useState<ProblemReport | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', esc)
    return () => document.removeEventListener('keydown', esc)
  }, [onClose])

  const enough = description.trim().length >= 10

  const create = async () => {
    setBusy(true)
    setError(null)
    try {
      setReport(await api.report(description))
      setSaved(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const save = () => {
    if (!report) return
    download(report)
    setSaved(true)
  }

  const github = () => {
    if (!report) return
    if (!saved) save()
    window.open(issueUrl(report, description), '_blank', 'noopener')
  }

  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal report-dialog" role="dialog" aria-modal="true" aria-labelledby="report-title">
        <h3 id="report-title">{t('Problem melden', 'Report a problem')}</h3>
        <p className="hint small">
          {t(
            'Beschreib kurz, was passiert ist und was du erwartet hast. NVAI-open erstellt daraus einen Bericht mit '
              + 'Zeitstempel, Systemangaben, den letzten Aufträgen und den Enden der Logs. Er ist anonymisiert: '
              + 'Benutzer- und Rechnername, Ordnerpfade, E-Mail- und IP-Adressen und Token werden ersetzt, '
              + 'Prompts und Bilder sind nicht enthalten. Du siehst ihn, bevor du ihn weitergibst.',
            'Briefly describe what happened and what you expected. NVAI-open turns it into a report with a timestamp, '
              + 'system details, the recent jobs and the ends of the logs. It is anonymized: user and computer name, '
              + 'folder paths, e-mail and IP addresses and tokens are replaced, prompts and images are not included. '
              + 'You see it before you pass it on.',
          )}
        </p>
        <textarea
          className="report-text"
          rows={4}
          maxLength={4000}
          autoFocus
          value={description}
          placeholder={t('z. B. „Nach dem Klick auf Generieren bleibt FLUX 3 bei 0 % stehen.“',
            'e.g. "After clicking Generate, FLUX 3 stays at 0 %."')}
          onChange={(e) => { setDescription(e.target.value); setReport(null) }}
        />
        <div className="row-gap">
          <button className="btn small primary" onClick={create} disabled={!enough || busy}>
            {busy ? '…' : report ? t('Neu erstellen', 'Create again') : t('Bericht erstellen', 'Create report')}
          </button>
          {!enough && <span className="muted small">{t('mindestens ein Satz', 'at least one sentence')}</span>}
          {error && <span className="error small">{error}</span>}
        </div>

        {report && (
          <>
            <div className="muted small">
              {report.filename} · {(report.text.length / 1024).toFixed(0)} KB · {report.text.split('\n').length}{' '}
              {t('Zeilen', 'lines')}
            </div>
            <pre className="report-preview">{report.text}</pre>
            <div className="row-gap">
              <button className="btn small" onClick={save}>
                {saved ? t('✓ Heruntergeladen', '✓ Downloaded') : t('Bericht herunterladen', 'Download report')}
              </button>
              <button className="btn small primary" onClick={github}>
                {t('Auf GitHub melden', 'Report on GitHub')}
              </button>
            </div>
            <p className="hint small">
              {t(
                'GitHub öffnet ein neues Issue mit Beschreibung, Zeitpunkt und Systemangaben. Die heruntergeladene '
                  + 'Datei dort ins Textfeld ziehen, dann absenden. Dafür braucht es ein GitHub-Konto.',
                'GitHub opens a new issue with the description, time and system details. Drag the downloaded file '
                  + 'into the text box there, then submit. This needs a GitHub account.',
              )}
            </p>
          </>
        )}
        <div className="modal-close">
          <button className="btn small ghost" onClick={onClose}>{t('Schließen', 'Close')}</button>
        </div>
      </div>
    </div>
  )
}
