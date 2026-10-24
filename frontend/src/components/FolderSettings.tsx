import { useEffect, useState } from 'react'
import { api, type FolderSettings as Folders } from '../api'
import { t } from '../i18n'

/**
 * „Speicherorte“ auf der Modellseite: Daten- und Modellordner wählen. Gilt nach einem Neustart;
 * vorhandene Dateien verschiebt NVAI-open nicht selbst (siehe server/nvai/folders.py).
 */
export function FolderSettings() {
  const [cur, setCur] = useState<Folders | null>(null)
  const [open, setOpen] = useState(false)
  const [dataDir, setDataDir] = useState('')
  const [modelsDir, setModelsDir] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  const load = () => api.folders().then((f) => {
    setCur(f)
    setDataDir(f.data_dir)
    setModelsDir(f.models_dir)
  }).catch(() => setCur(null))

  useEffect(() => { load() }, [])
  if (!cur) return null

  const changed = dataDir.trim() !== cur.data_dir || modelsDir.trim() !== cur.models_dir

  const browse = async (which: 'data' | 'models') => {
    setError(null)
    const r = await api.browseFolder(which === 'data' ? dataDir : modelsDir).catch(() => ({ path: null }))
    if (r.path) (which === 'data' ? setDataDir : setModelsDir)(r.path)
  }

  const save = async () => {
    setBusy(true)
    setError(null)
    setMsg(null)
    try {
      await api.saveFolders({
        data_dir: dataDir.trim() !== cur.data_dir ? dataDir.trim() : undefined,
        models_dir: modelsDir.trim() !== cur.models_dir ? modelsDir.trim() : undefined,
      })
      setSaved(true)
      setMsg(t(
        'Gespeichert. Die neuen Ordner gelten nach einem Neustart von NVAI-open. Vorhandene Dateien bleiben im alten Ordner: '
          + 'Wer sie mitnehmen will, beendet NVAI-open, verschiebt den Inhalt des alten Ordners in den neuen und startet neu.',
        'Saved. The new folders apply after NVAI-open restarts. Existing files stay in the old folder: to take them along, '
          + 'quit NVAI-open, move the contents of the old folder into the new one and start it again.',
      ))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const restart = async () => {
    setBusy(true)
    setError(null)
    try {
      await api.restart()
      setMsg(t('NVAI-open startet neu … die Seite lädt in einigen Sekunden neu.',
        'NVAI-open is restarting … the page reloads in a few seconds.'))
      // Warten, bis der neue Server antwortet, dann neu laden.
      const until = Date.now() + 120_000
      await new Promise((r) => setTimeout(r, 4000))
      while (Date.now() < until) {
        try {
          await api.folders()
          window.location.reload()
          return
        } catch {
          await new Promise((r) => setTimeout(r, 1500))
        }
      }
      setError(t('NVAI-open meldet sich nicht zurück. Bitte über das Startmenü starten.',
        'NVAI-open does not come back. Please start it from the Start menu.'))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const gb = (v: number | null) => (v == null ? '' : t(` · ${v} GB frei`, ` · ${v} GB free`))

  return (
    <section className="panel folder-settings">
      <button className="folder-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="folder-title">{t('Speicherorte', 'Storage locations')}</span>
        <span className="muted small folder-summary">
          {t('Daten', 'Data')}: {cur.data_dir}{gb(cur.data_free_gb)} · {t('Modelle', 'Models')}: {cur.models_dir}{gb(cur.models_free_gb)}
        </span>
        <span className="muted">{open ? '▴' : '▾'}</span>
      </button>

      {open && (
        <div className="folder-body">
          {!cur.managed && (
            <p className="hint small">
              {t('Dieses NVAI-open läuft aus dem Quelltext. Die Ordner dort über NVAI_DATA_DIR und NVAI_MODEL_DIR setzen '
                + '(siehe docs/INSTALL.md).',
              'This NVAI-open runs from source. Set the folders there with NVAI_DATA_DIR and NVAI_MODEL_DIR '
                + '(see docs/INSTALL.md).')}
            </p>
          )}
          {cur.env_override.length > 0 && (
            <p className="hint small warn">
              {t(`Gesetzte Umgebungsvariablen (${cur.env_override.join(', ')}) gehen den Einstellungen hier vor.`,
                `Environment variables (${cur.env_override.join(', ')}) take precedence over the settings here.`)}
            </p>
          )}
          <label className="field">
            <span className="label">
              {t('Datenordner', 'Data folder')}{' '}
              <span className="muted small">({t('Verlauf, Bilder, Protokolle', 'history, images, logs')})</span>
            </span>
            <div className="folder-row">
              <input value={dataDir} onChange={(e) => { setDataDir(e.target.value); setSaved(false) }} disabled={!cur.managed} />
              <button className="btn small" onClick={() => browse('data')} disabled={!cur.managed}>
                {t('Durchsuchen …', 'Browse …')}
              </button>
            </div>
          </label>
          <label className="field">
            <span className="label">
              {t('Modellordner', 'Models folder')}{' '}
              <span className="muted small">({t('die großen Modelldateien, 5 bis 30 GB je Modell', 'the large model files, 5 to 30 GB each')})</span>
            </span>
            <div className="folder-row">
              <input value={modelsDir} onChange={(e) => { setModelsDir(e.target.value); setSaved(false) }} disabled={!cur.managed} />
              <button className="btn small" onClick={() => browse('models')} disabled={!cur.managed}>
                {t('Durchsuchen …', 'Browse …')}
              </button>
            </div>
          </label>
          <div className="row-gap">
            <button className="btn small primary" onClick={save} disabled={!cur.managed || !changed || busy}>
              {t('Speichern', 'Save')}
            </button>
            {saved && cur.can_restart && (
              <button className="btn small" onClick={restart} disabled={busy}>
                {t('NVAI-open jetzt neu starten', 'Restart NVAI-open now')}
              </button>
            )}
          </div>
          {msg && <p className="hint small">{msg}</p>}
          {error && <p className="error small">{error}</p>}
        </div>
      )}
    </section>
  )
}
