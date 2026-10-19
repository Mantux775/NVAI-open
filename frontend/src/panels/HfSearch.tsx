import { useState } from 'react'
import { api, type HfCheck, type HfResult } from '../api'
import { locale, t } from '../i18n'

interface Props {
  /** Nach dem Start eines Downloads: Modellliste neu laden. */
  onQueued: (message: string) => void
}

/**
 * Weitere Modelle auf Hugging Face suchen -- wie in NVAILocal mit Prüfung vor dem Laden:
 * Der Server liest nur den safetensors-Kopf und erkennt daran die Architektur. Laden
 * lässt sich, was ein vorhandener Workflow sicher rechnet (SDXL- und SD-1.5-Checkpoints).
 */
export function HfSearch({ onQueued }: Props) {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<HfResult[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [checks, setChecks] = useState<Record<string, HfCheck | 'checking'>>({})

  const search = async () => {
    if (!query.trim()) return
    setBusy(true)
    setError(null)
    try {
      setResults(await api.searchHf(query.trim()))
      setChecks({})
    } catch (e) {
      setError(String(e))
    } finally {
      setBusy(false)
    }
  }

  const check = async (repo: string, file: string) => {
    const key = `${repo}/${file}`
    setChecks((c) => ({ ...c, [key]: 'checking' }))
    try {
      const result = await api.inspectHf(repo, file)
      setChecks((c) => ({ ...c, [key]: result }))
    } catch (e) {
      setError(String(e))
      setChecks((c) => {
        const next = { ...c }
        delete next[key]
        return next
      })
    }
  }

  const download = async (c: HfCheck, license: string) => {
    try {
      await api.downloadChecked(c, license)
      const gb = c.size_gb ?? '?'
      onQueued(
        t(
          `${c.file} wird geladen (${gb} GB) — erscheint in der Liste.`,
          `${c.file} is downloading (${gb} GB) — it will appear in the list.`,
        ),
      )
    } catch (e) {
      setError(String(e))
    }
  }

  return (
    <section className="panel hf-search">
      <h3>{t('Weitere Modelle auf Hugging Face', 'More models on Hugging Face')}</h3>
      <p className="muted small">
        {t(
          'Vor dem Laden prüft NV-AI die Datei. Laden lassen sich vollständige SDXL-Checkpoints '
            + '(zum Beispiel Juggernaut, Pony, Illustrious) und SD-1.5-Checkpoints. Die Lizenz steht '
            + 'im Repo — bitte dort prüfen, bevor Bilder veröffentlicht werden.',
          'NV-AI checks each file before downloading it. Complete SDXL checkpoints (for example '
            + 'Juggernaut, Pony, Illustrious) and SD 1.5 checkpoints can be downloaded. The license '
            + 'is stated in the repo — please check it there before publishing images.',
        )}
      </p>
      <form
        className="hf-form"
        onSubmit={(e) => {
          e.preventDefault()
          search()
        }}
      >
        <input
          type="search"
          placeholder={t('z. B. juggernaut xl, pony, illustrious', 'e.g. juggernaut xl, pony, illustrious')}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <button className="btn primary" disabled={busy || !query.trim()}>
          {busy ? t('Sucht …', 'Searching …') : t('Suchen', 'Search')}
        </button>
      </form>
      {error && <div className="error">{error}</div>}
      {results && results.length === 0 && <p className="muted">{t('Keine Treffer.', 'No results.')}</p>}
      {results?.map((r) => (
        <div key={r.repo} className="hf-result">
          <div className="hf-head">
            <a href={`https://huggingface.co/${r.repo}`} target="_blank" rel="noreferrer">
              {r.repo}
            </a>
            <span className="muted small">
              {' '}
              · {r.downloads.toLocaleString(locale())} {t('Downloads', 'downloads')} · {r.likes} ♥
              {r.license && ` · ${r.license}`}
            </span>
            {r.gated && <span className="badge warn">{t('Lizenz bestätigen', 'Accept license')}</span>}
          </div>
          {r.note && <p className="muted small">{r.note}</p>}
          {r.files.map((f) => {
            const c = checks[`${r.repo}/${f}`]
            return (
              <div key={f} className="hf-file">
                <code>{f}</code>
                {c === undefined && (
                  <button className="btn small" onClick={() => check(r.repo, f)}>
                    {t('Prüfen', 'Check')}
                  </button>
                )}
                {c === 'checking' && <span className="muted small">{t('prüft …', 'checking …')}</span>}
                {c && c !== 'checking' && (
                  <>
                    <span className={c.ok ? 'ok-text small' : 'warn-text small'}>
                      {c.verdict}
                      {c.size_gb !== null && ` · ${c.size_gb} GB`}
                    </span>
                    {c.ok && (
                      <button className="btn small primary" onClick={() => download(c, r.license)}>
                        {t('Herunterladen', 'Download')}
                      </button>
                    )}
                  </>
                )}
              </div>
            )
          })}
        </div>
      ))}
    </section>
  )
}
