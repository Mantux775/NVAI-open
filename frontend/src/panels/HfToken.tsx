import { useEffect, useState } from 'react'
import { api } from '../api'
import { hfGuideUrl } from '../components/GatedNotice'
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
        <strong>Hugging Face: </strong>
        {t(
          'FLUX 3 und LTX-2.5 brauchen ein kostenloses Konto. Auf der Modellseite die Lizenz annehmen (',
          'FLUX 3 and LTX-2.5 need a free account. Accept the license on the model page (',
        )}
        <a href="https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy" target="_blank" rel="noreferrer">
          FLUX 3
        </a>
        {', '}
        <a href="https://huggingface.co/Lightricks/LTX-2.5" target="_blank" rel="noreferrer">
          LTX-2.5
        </a>
        {t('), dann unter ', '), then create a token with read access under ')}
        <a href="https://huggingface.co/settings/tokens" target="_blank" rel="noreferrer">
          {t('Einstellungen → Access Tokens', 'Settings → Access Tokens')}
        </a>
        {t(' einen Token mit Leserecht anlegen und hier eintragen. ', ' and enter it here. ')}
        <a href={hfGuideUrl()} target="_blank" rel="noreferrer">
          {t('Anleitung mit Bildern', 'Illustrated guide')}
        </a>
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
