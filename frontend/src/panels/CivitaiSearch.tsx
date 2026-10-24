import { useEffect, useMemo, useState } from 'react'
import {
  api, LORA_BASE_LABEL, type CivitaiCheck, type CivitaiResult, type ModelInfo,
} from '../api'
import { locale, t } from '../i18n'

interface Props {
  catalog: ModelInfo[]
  onQueued: (message: string) => void
}

/**
 * LoRAs von Civitai. Civitai nennt zu jeder Version das Basismodell; daraus wird die
 * LoRA-Basis (server: civitai.BASE_MODELS). Mit eigenem API-Schlüssel prüft NVAI-open vor dem
 * Laden zusätzlich den Dateikopf wie bei Hugging Face — ohne Schlüssel lässt Civitai die
 * meisten Dateien gar nicht laden.
 */
export function CivitaiSearch({ catalog, onQueued }: Props) {
  const [status, setStatus] = useState<{ logged_in: boolean; name: string | null } | null>(null)
  const [token, setToken] = useState('')
  const [query, setQuery] = useState('')
  const [base, setBase] = useState('')
  const [results, setResults] = useState<CivitaiResult[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [checks, setChecks] = useState<Record<number, CivitaiCheck | 'checking'>>({})

  useEffect(() => {
    api.civitaiStatus().then(setStatus).catch(() => setStatus(null))
  }, [])

  // Nur Basen anbieten, für die es ein Modell im Katalog gibt; installierte zuerst.
  const bases = useMemo(() => {
    const seen = new Map<string, boolean>()
    for (const m of catalog) {
      for (const b of m.lora_bases ?? []) seen.set(b, (seen.get(b) ?? false) || m.installed)
    }
    return [...seen.entries()].sort((a, b) => Number(b[1]) - Number(a[1])).map(([b]) => b)
  }, [catalog])

  const search = async () => {
    setBusy(true)
    setError(null)
    try {
      setResults(await api.searchCivitai(query.trim(), base || undefined))
      setChecks({})
    } catch (e) {
      setError(String(e))
    } finally {
      setBusy(false)
    }
  }

  const saveToken = async () => {
    setError(null)
    try {
      setStatus(await api.setCivitaiToken(token.trim()))
      setToken('')
    } catch (e) {
      setError(String(e))
    }
  }

  const check = async (r: CivitaiResult) => {
    setChecks((c) => ({ ...c, [r.version_id]: 'checking' }))
    try {
      const res = await api.checkCivitai(r)
      setChecks((c) => ({ ...c, [r.version_id]: res }))
    } catch (e) {
      setError(String(e))
    }
  }

  const download = async (r: CivitaiResult, c: CivitaiCheck) => {
    try {
      await api.downloadCivitai(r, c.family ?? r.lora_base ?? '', r.trigger || c.trigger || '')
      onQueued(t(`${r.name} wird geladen (${r.size_gb} GB) — erscheint unter „LoRA“.`,
        `${r.name} is downloading (${r.size_gb} GB) — it will appear under “LoRA”.`))
    } catch (e) {
      setError(String(e))
    }
  }

  return (
    <section className="panel hf-search">
      <h3>{t('LoRAs auf Civitai', 'LoRAs on Civitai')}</h3>
      <p className="muted small">
        {t('Die meisten LoRAs, auch unzensierte, liegen auf Civitai. Laden geht dort fast nur mit einem '
          + 'eigenen API-Schlüssel (civitai.com → Einstellungen → API Keys). Lizenz und Inhalte bitte auf '
          + 'der Civitai-Seite prüfen.',
        'Most LoRAs, uncensored ones too, are on Civitai. Downloading there almost always needs your own '
          + 'API key (civitai.com → Settings → API Keys). Please check license and content on the Civitai page.')}
      </p>
      {status?.logged_in ? (
        <div className="row-gap small">
          <span className="ok-text">
            {t('Schlüssel hinterlegt', 'Key stored')}{status.name ? ` (${status.name})` : ''}
          </span>
          <button className="btn small ghost" onClick={async () => setStatus(await api.deleteCivitaiToken())}>
            {t('Entfernen', 'Remove')}
          </button>
        </div>
      ) : (
        <form className="hf-form" onSubmit={(e) => { e.preventDefault(); saveToken() }}>
          <input type="password" autoComplete="off" value={token} onChange={(e) => setToken(e.target.value)}
            placeholder={t('Civitai-API-Schlüssel', 'Civitai API key')} />
          <button className="btn" disabled={!token.trim()}>{t('Speichern', 'Save')}</button>
        </form>
      )}

      <form className="hf-form" onSubmit={(e) => { e.preventDefault(); search() }}>
        <select value={base} onChange={(e) => setBase(e.target.value)}>
          <option value="">{t('alle Modelle', 'all models')}</option>
          {bases.map((b) => <option key={b} value={b}>{LORA_BASE_LABEL[b] ?? b}</option>)}
        </select>
        <input type="search" value={query} onChange={(e) => setQuery(e.target.value)}
          placeholder={t('z. B. pixel art, camera orbit, anime', 'e.g. pixel art, camera orbit, anime')} />
        <button className="btn primary" disabled={busy}>{busy ? t('Sucht …', 'Searching …') : t('Suchen', 'Search')}</button>
      </form>
      {error && <div className="error">{error}</div>}
      {results && results.length === 0 && <p className="muted">{t('Keine Treffer.', 'No results.')}</p>}
      {results?.map((r) => {
        const c = checks[r.version_id]
        return (
          <div key={r.version_id} className="hf-result">
            <div className="hf-head">
              <a href={r.page} target="_blank" rel="noreferrer">{r.name}</a>
              <span className="muted small">
                {' '}· {r.version} · {r.base_model} · {r.downloads.toLocaleString(locale())} {t('Downloads', 'downloads')}
                {r.creator && ` · ${r.creator}`}
              </span>
              {r.nsfw && <span className="badge warn">NSFW</span>}
            </div>
            {r.trigger && <p className="muted small">{t('Trigger', 'Trigger')}: <code>{r.trigger}</code></p>}
            <div className="hf-file">
              <code>{r.file}</code>
              <span className="muted small">{r.size_gb} GB</span>
              {!r.lora_base && (
                <span className="warn-text small">
                  {t('Für dieses Basismodell gibt es in NVAI-open kein Modell.', 'NVAI-open has no model for this base model.')}
                </span>
              )}
              {r.lora_base && c === undefined && (
                <button className="btn small" onClick={() => check(r)}>{t('Prüfen', 'Check')}</button>
              )}
              {c === 'checking' && <span className="muted small">{t('prüft …', 'checking …')}</span>}
              {c && c !== 'checking' && (
                <>
                  <span className={c.ok ? 'ok-text small' : 'warn-text small'}>{c.verdict}</span>
                  {c.ok && (
                    <button className="btn small primary" onClick={() => download(r, c)}
                      disabled={!status?.logged_in}
                      title={status?.logged_in ? '' : t('Erst den Civitai-Schlüssel eintragen', 'Enter the Civitai key first')}>
                      {t('Herunterladen', 'Download')}
                    </button>
                  )}
                </>
              )}
            </div>
          </div>
        )
      })}
    </section>
  )
}
