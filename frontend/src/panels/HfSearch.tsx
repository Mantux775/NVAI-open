import { useMemo, useState } from 'react'
import { api, type HfCheck, type HfPartKind, type HfResult, type ModelInfo } from '../api'
import { locale, t } from '../i18n'

interface Props {
  /** Der Katalog -- passende Modelle stehen über den Treffern von Hugging Face. */
  catalog: ModelInfo[]
  /** Ein Katalogmodell in der Liste aufklappen und hinscrollen. */
  onShowModel: (id: string) => void
  /** Nach dem Start eines Downloads: Modellliste neu laden. */
  onQueued: (message: string) => void
}

const PART_LABEL: Record<HfPartKind, () => string> = {
  diffusion: () => t('Diffusionsmodell', 'diffusion model'),
  text_encoder: () => t('Text-Encoder', 'text encoder'),
  vae: () => 'VAE',
  lora: () => 'LoRA',
  controlnet: () => 'ControlNet',
  upscaler: () => t('Hochskalierer', 'upscaler'),
}
// Reihenfolge der Teile in der Anzeige: das Wichtigste zuerst.
const PART_ORDER: HfPartKind[] = ['diffusion', 'text_encoder', 'vae', 'controlnet', 'upscaler', 'lora']

/** Katalogmodelle, deren Name, ID oder Familie alle Wörter der Suche enthält. Versionsnummern
 *  ("2.1") zählen nur zur Reihenfolge, damit "qwen 2.1" die vorhandenen Qwen-Modelle zeigt. */
function catalogHits(catalog: ModelInfo[], query: string): ModelInfo[] {
  const words = query.toLowerCase().split(/[\s_-]+/).filter(Boolean)
  const names = words.filter((w) => /[a-z]/.test(w))
  if (!names.length) return []
  const text = (m: ModelInfo) => `${m.name} ${m.id} ${m.family}`.toLowerCase().replace(/[\s_-]+/g, ' ')
  const score = (m: ModelInfo) => words.filter((w) => text(m).includes(w)).length
  return catalog
    .filter((m) => m.kind !== 'controlnet' && names.every((w) => text(m).includes(w)))
    .sort((a, b) => score(b) - score(a))
    .slice(0, 6)
}

/**
 * Weitere Modelle auf Hugging Face suchen -- wie in NVAILocal mit Prüfung vor dem Laden:
 * Der Server liest nur den safetensors-Kopf und erkennt daran die Architektur. Laden
 * lässt sich, was ein vorhandener Workflow sicher rechnet (SDXL- und SD-1.5-Checkpoints).
 * Teile neuerer Modelle (Qwen, FLUX, Wan …) erkennt er und nennt das passende Katalogmodell.
 */
export function HfSearch({ catalog, onShowModel, onQueued }: Props) {
  const [query, setQuery] = useState('')
  const [searched, setSearched] = useState('')
  const [results, setResults] = useState<HfResult[] | null>(null)
  const [showAll, setShowAll] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [checks, setChecks] = useState<Record<string, HfCheck | 'checking'>>({})

  const search = async () => {
    if (!query.trim()) return
    setBusy(true)
    setError(null)
    try {
      setResults(await api.searchHf(query.trim()))
      setSearched(query.trim())
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

  const inCatalog = useMemo(() => (searched ? catalogHits(catalog, searched) : []), [catalog, searched])
  // Standard: nur Repos mit ladbaren Checkpoints oder erkennbaren Modellteilen. LoRAs,
  // GGUF-, Diffusers- und Sammel-Repos ohne Modell blendet der Schalter wieder ein.
  const visible = results?.filter((r) => showAll || r.kind === 'checkpoint' || r.kind === 'parts') ?? []
  const hidden = (results?.length ?? 0) - visible.length

  const fileRow = (repo: string, file: string, license: string, label?: string) => {
    const c = checks[`${repo}/${file}`]
    return (
      <div key={file} className="hf-file">
        {label && <span className="badge">{label}</span>}
        <code>{file}</code>
        {c === undefined && (
          <button className="btn small" onClick={() => check(repo, file)}>
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
              <button className="btn small primary" onClick={() => download(c, license)}>
                {t('Herunterladen', 'Download')}
              </button>
            )}
          </>
        )}
      </div>
    )
  }

  return (
    <section className="panel hf-search">
      <h3>{t('Weitere Modelle auf Hugging Face', 'More models on Hugging Face')}</h3>
      <p className="muted small">
        {t(
          'Vor dem Laden prüft NV-AI die Datei. Laden lassen sich vollständige SDXL-Checkpoints '
            + '(zum Beispiel Juggernaut, Pony, Illustrious) und SD-1.5-Checkpoints. Teile neuerer Modelle '
            + '(Qwen, FLUX, Wan …) erkennt die Prüfung und nennt das passende Modell aus dem Katalog. Die '
            + 'Lizenz steht im Repo — bitte dort prüfen, bevor Bilder veröffentlicht werden.',
          'NV-AI checks each file before downloading it. Complete SDXL checkpoints (for example '
            + 'Juggernaut, Pony, Illustrious) and SD 1.5 checkpoints can be downloaded. Parts of newer '
            + 'models (Qwen, FLUX, Wan …) are recognized, and the check names the matching catalog '
            + 'model. The license is stated in the repo — please check it there before publishing images.',
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
          placeholder={t('z. B. juggernaut xl, pony, qwen image', 'e.g. juggernaut xl, pony, qwen image')}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <button className="btn primary" disabled={busy || !query.trim()}>
          {busy ? t('Sucht …', 'Searching …') : t('Suchen', 'Search')}
        </button>
      </form>
      {error && <div className="error">{error}</div>}

      {inCatalog.length > 0 && (
        <div className="hf-catalog">
          <div className="muted small">{t('Schon im Katalog:', 'Already in the catalog:')}</div>
          {inCatalog.map((m) => (
            <div key={m.id} className="hf-file">
              <strong>{m.name}</strong>
              <span className="muted small">
                {m.size_gb} GB · {m.license}
                {m.installed && ` · ${t('installiert', 'installed')}`}
              </span>
              <button className="btn small" onClick={() => onShowModel(m.id)}>
                {t('Zeigen', 'Show')}
              </button>
            </div>
          ))}
        </div>
      )}

      {results && (
        <label className="hf-toggle muted small">
          <input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} />
          {t(
            `Auch LoRAs, GGUF und Repos ohne Modell zeigen${hidden > 0 && !showAll ? ` (${hidden} ausgeblendet)` : ''}`,
            `Also show LoRAs, GGUF and repos without a model${hidden > 0 && !showAll ? ` (${hidden} hidden)` : ''}`,
          )}
        </label>
      )}
      {results && visible.length === 0 && (
        <p className="muted">
          {results.length === 0
            ? t('Keine Treffer.', 'No results.')
            : t('Keine ladbaren Modelle unter den Treffern.', 'No loadable models among the results.')}
        </p>
      )}
      {visible.map((r) => {
        const parts = [...r.parts]
          .filter((p) => showAll || p.kind !== 'lora')
          .sort((a, b) => PART_ORDER.indexOf(a.kind) - PART_ORDER.indexOf(b.kind))
        return (
          <div key={r.repo} className="hf-result">
            <div className="hf-head">
              <a href={`https://huggingface.co/${r.repo}`} target="_blank" rel="noreferrer">
                {r.repo}
              </a>
              <span className="muted small">
                {' '}
                · {r.downloads.toLocaleString(locale())} {t('Downloads', 'downloads')} · {r.likes} ♥
                {r.license && ` · ${r.license}`}
                {r.base_model && r.base_model !== r.repo && ` · ${t('basiert auf', 'based on')} ${r.base_model}`}
              </span>
              {r.gated && <span className="badge warn">{t('Lizenz bestätigen', 'Accept license')}</span>}
            </div>
            {r.note && <p className="muted small">{r.note}</p>}
            {r.files.map((f) => fileRow(r.repo, f, r.license))}
            {parts.map((p) => fileRow(r.repo, p.file, r.license, PART_LABEL[p.kind]()))}
          </div>
        )
      })}
    </section>
  )
}
