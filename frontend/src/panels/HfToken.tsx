import { useEffect, useState } from 'react'
import { api } from '../api'
import { t } from '../i18n'

/**
 * Hugging-Face-Token hinterlegen -- nötig für Modelle hinter einer Lizenzbestätigung
 * (FLUX 3). Der Server prüft den Token bei Hugging Face und speichert ihn wie
 * `hf auth login`; die Seite zeigt ihn danach nie wieder an.
 */
export function HfToken() {
  const [status, setStatus] = useState<{ logged_in: boolean; name: string | null } | null>(null)
  const [token, setToken] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api.hfTokenStatus().then(setStatus).catch(() => setStatus(null))
  }, [])

  const save = async () => {
    setBusy(true)
    setError(null)
    try {
      setStatus(await api.setHfToken(token.trim()))
      setToken('')
    } catch (e) {
      setError(String(e))
    } finally {
      setBusy(false)
    }
  }

  const logout = async () => {
    setStatus(await api.deleteHfToken())
  }

  if (!status) return null
  if (status.logged_in) {
    return (
      <p className="muted small hf-token">
        {status.name
          ? t(`Hugging Face: angemeldet als ${status.name}`, `Hugging Face: signed in as ${status.name}`)
          : t('Hugging Face: angemeldet', 'Hugging Face: signed in')}{' '}
        ·{' '}
        <button className="link-button" onClick={logout}>
          {t('abmelden', 'sign out')}
        </button>
      </p>
    )
  }
  return (
    <div className="panel hf-token">
      <p className="small">
        {t(
          'Für FLUX 3 braucht NV-AI einen Hugging-Face-Token: auf der ',
          'For FLUX 3, NV-AI needs a Hugging Face token: accept the license on the ',
        )}
        <a
          href="https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy"
          target="_blank"
          rel="noreferrer"
        >
          {t('Modellseite', 'model page')}
        </a>
        {t(' die Lizenz bestätigen, dann unter ', ', then create a token with read access under ')}
        <a href="https://huggingface.co/settings/tokens" target="_blank" rel="noreferrer">
          {t('Einstellungen → Tokens', 'Settings → Tokens')}
        </a>
        {t(' einen Token mit Leserecht anlegen und hier eintragen.', ' and enter it here.')}
      </p>
      <form
        className="hf-form"
        onSubmit={(e) => {
          e.preventDefault()
          save()
        }}
      >
        <input
          type="password"
          autoComplete="off"
          placeholder="hf_…"
          value={token}
          onChange={(e) => setToken(e.target.value)}
        />
        <button className="btn primary" disabled={busy || !token.trim()}>
          {busy ? t('Prüft …', 'Checking …') : t('Speichern', 'Save')}
        </button>
      </form>
      {error && <div className="error">{error}</div>}
    </div>
  )
}
