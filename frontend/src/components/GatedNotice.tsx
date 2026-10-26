import type { ModelInfo } from '../api'
import { getLang, t } from '../i18n'

/** Bebilderte Anleitung (Konto, Lizenz annehmen, Token) im öffentlichen Repo, wie catalog.HF_GUIDE_URL. */
export function hfGuideUrl(): string {
  return getLang() === 'de'
    ? 'https://github.com/Mantux775/NVAI-open/blob/main/docs/de/HUGGINGFACE.md'
    : 'https://github.com/Mantux775/NVAI-open/blob/main/docs/HUGGINGFACE.md'
}

/** Beschriftung des Zustimmen-Knopfs auf Hugging Face; Lightricks setzt eine eigene (extra_gated_button_content). */
function agreeButton(repo: string): string {
  return repo.startsWith('Lightricks/') ? 'Agree and Access' : 'Agree and access repository'
}

/** Zum Token-Feld über der Modellliste springen (HfToken). */
function focusTokenField() {
  const box = document.querySelector('.hf-token')
  box?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  box?.querySelector('input')?.focus({ preventScroll: true })
}

/**
 * Für Modelle aus gesperrten Hugging-Face-Repos (FLUX 3, LTX-2.5): vor dem Download zeigen, ob die Lizenz mit dem
 * hinterlegten Token schon angenommen ist, und wohin man dafür muss. Der Server prüft je Repo (registry.gated_access).
 */
export function GatedNotice({ model, onRecheck }: { model: ModelInfo; onRecheck: () => void }) {
  const repos = model.gated_repos ?? []
  if (model.installed || repos.length === 0) return null
  const access = model.gated_access ?? {}
  const allGranted = repos.every((r) => access[r] === 'granted')
  return (
    <div className={allGranted ? 'gated-notice ok' : 'gated-notice'}>
      <p className="small">
        <strong>
          {allGranted
            ? t('Hugging-Face-Lizenz angenommen', 'Hugging Face license accepted')
            : t('Vor dem Download: Lizenz auf Hugging Face annehmen', 'Before downloading: accept the license on Hugging Face')}
        </strong>
      </p>
      <ul className="small">
        {repos.map((repo) => (
          <li key={repo}>
            <a href={`https://huggingface.co/${repo}`} target="_blank" rel="noreferrer">
              {repo}
            </a>
            {' — '}
            {access[repo] === 'granted' && <span className="ok-text">{t('Zugriff vorhanden', 'access granted')}</span>}
            {access[repo] === 'missing' && (
              <span className="warn-text">
                {t(
                  `noch nicht angenommen: Seite öffnen, „${agreeButton(repo)}“ klicken`,
                  `not accepted yet: open the page and click “${agreeButton(repo)}”`,
                )}
              </span>
            )}
            {access[repo] === 'no_token' && (
              <span className="warn-text">
                {t('noch kein Token hinterlegt: ', 'no token stored yet: ')}
                <button className="link-button" onClick={focusTokenField}>
                  {t('Token eintragen', 'enter token')}
                </button>
              </span>
            )}
            {(access[repo] === 'unknown' || !access[repo]) && (
              <span className="muted">{t('Stand unbekannt (keine Verbindung)', 'state unknown (no connection)')}</span>
            )}
          </li>
        ))}
      </ul>
      {!allGranted && (
        <p className="small">
          <a href={hfGuideUrl()} target="_blank" rel="noreferrer">
            {t('Anleitung mit Bildern', 'Illustrated guide')}
          </a>
          {' · '}
          <button className="link-button" onClick={onRecheck}>
            {t('erneut prüfen', 'check again')}
          </button>
        </p>
      )}
    </div>
  )
}
