import { useEffect, useMemo, useRef, useState } from 'react'
import {
  api, LORA_BASE_LABEL, type LoraAssignment, type LoraCheck, type LoraExpert, type LoraUploadResult, type ModelInfo,
} from '../api'
import { locale, t } from '../i18n'

/**
 * Eigene LoRA-Dateien (seit 0.5.24, Reddit-Frage „Is there any way to use the Loras you trained locally“):
 * hinzufügen vom Rechner und die Zuordnung zu den Modellen ändern. Die Zuordnung ist die LoRA-Basis (family): sie
 * entscheidet, bei welchen Modellen die LoRA beim Generieren erscheint (lora_bases der Modelle).
 */

/** Eine LoRA-Basis mit den Katalogmodellen, die sie nehmen (geladene zuerst). */
export interface LoraBaseOption {
  base: string
  label: string
  models: ModelInfo[]
}

export function loraBaseOptions(catalog: ModelInfo[]): LoraBaseOption[] {
  const byBase = new Map<string, ModelInfo[]>()
  for (const m of catalog) {
    if (m.kind === 'lora') continue
    for (const b of m.lora_bases ?? []) byBase.set(b, [...(byBase.get(b) ?? []), m])
  }
  const anyInstalled = (o: LoraBaseOption) => Number(o.models.some((m) => m.installed))
  return [...byBase.entries()]
    .map(([base, models]) => ({
      base,
      label: baseLabel(base),
      models: [...models].sort((a, b) => Number(b.installed) - Number(a.installed)),
    }))
    .sort((a, b) => anyInstalled(b) - anyInstalled(a) || a.label.localeCompare(b.label))
}

function baseLabel(base: string): string {
  return LORA_BASE_LABEL[base] ?? base
}

function sizeText(bytes: number): string {
  if (bytes >= 1e9) return `${(bytes / 1e9).toLocaleString(locale(), { maximumFractionDigits: 2 })} GB`
  if (bytes >= 1e6) return `${Math.round(bytes / 1e6).toLocaleString(locale())} MB`
  return `${Math.max(1, Math.round(bytes / 1e3)).toLocaleString(locale())} KB`
}

/** Felder der Zuordnung: Basis samt den Modellen, die sie nehmen, bei Wan 14B der Experte, Name, Trigger-Wörter. */
function AssignFields({ value, onChange, options, detected }: {
  value: LoraAssignment
  onChange: (v: LoraAssignment) => void
  options: LoraBaseOption[]
  /** am Dateikopf erkannte Basis: weicht die Wahl ab, ein Hinweis */
  detected: string | null
}) {
  const opt = options.find((o) => o.base === value.family)
  return (
    <div className="lora-fields">
      <label className="lora-field">
        <span>{t('Gehört zu', 'Belongs to')}</span>
        <select value={value.family} onChange={(e) => onChange({ ...value, family: e.target.value })}>
          {!opt && (
            <option value={value.family}>
              {value.family ? baseLabel(value.family) : t('(bitte wählen)', '(please choose)')}
            </option>
          )}
          {options.map((o) => {
            const n = o.models.length
            const k = o.models.filter((m) => m.installed).length
            return (
              <option key={o.base} value={o.base}>
                {o.label} ({t(`${n} Modell${n === 1 ? '' : 'e'}, ${k} geladen`,
                  `${n} model${n === 1 ? '' : 's'}, ${k} downloaded`)})
              </option>
            )
          })}
        </select>
      </label>
      {opt && (
        <p className="muted small lora-models">
          {t('Erscheint beim Generieren mit: ', 'Shows up when generating with: ')}
          {opt.models.map((m, i) => (
            <span key={m.id} className={m.installed ? '' : 'not-installed'}
              title={m.installed ? '' : t('noch nicht geladen', 'not downloaded yet')}>
              {i > 0 && ', '}{m.name}
            </span>
          ))}
        </p>
      )}
      {detected && value.family && detected !== value.family && (
        <p className="warn-text small lora-models">
          {t(`Der Dateikopf passt zu ${baseLabel(detected)}. Eine LoRA, die nicht zum Modell passt, wirkt meist gar nicht.`,
            `The file header fits ${baseLabel(detected)}. A LoRA that does not fit the model usually has no effect at all.`)}
        </p>
      )}
      {value.family === 'wan-14b' && (
        <label className="lora-field"
          title={t('Wan 2.2 A14B rechnet mit zwei Experten nacheinander; LoRAs dafür kommen meist als Paar (high/low).',
            'Wan 2.2 A14B runs two experts one after the other; LoRAs for it usually come as a pair (high/low).')}>
          <span>{t('Wan-2.2-Experte', 'Wan 2.2 expert')}</span>
          <select value={value.expert || 'both'} onChange={(e) => onChange({ ...value, expert: e.target.value as LoraExpert })}>
            <option value="both">{t('beide', 'both')}</option>
            <option value="high">{t('nur High-Noise', 'high noise only')}</option>
            <option value="low">{t('nur Low-Noise', 'low noise only')}</option>
          </select>
        </label>
      )}
      <label className="lora-field">
        <span>{t('Name', 'Name')}</span>
        <input value={value.name} maxLength={120} onChange={(e) => onChange({ ...value, name: e.target.value })} />
      </label>
      <label className="lora-field">
        <span>{t('Trigger-Wörter', 'Trigger words')}</span>
        <input value={value.trigger} maxLength={300}
          placeholder={t('z. B. ohwx person; leer, wenn es keine gibt', 'e.g. ohwx person; empty if there are none')}
          onChange={(e) => onChange({ ...value, trigger: e.target.value })} />
      </label>
    </div>
  )
}

/** Wan-Experte nur bei Wan 14B mitschicken; sonst leer (= nach Dateiname, wirkt dort ohnehin nicht). */
function expertFor(v: LoraAssignment): LoraExpert | '' {
  return v.family === 'wan-14b' ? (v.expert || 'both') : ''
}

/**
 * „Eigene LoRA hinzufügen“: Datei wählen oder hineinziehen, NVAI-open prüft nur den Dateikopf (Basis, passende
 * Modelle, Trigger aus den Metadaten), der Nutzer bestätigt oder ändert die Zuordnung, dann wird hochgeladen.
 * compact: ohne Rahmen und Einleitung, für die LoRA-Auswahl beim Generieren; preferBase schlägt dort die Basis des
 * gewählten Modells vor, wenn der Dateikopf nichts verrät.
 */
export function LoraUpload({ catalog, onDone, preferBase, compact = false }: {
  catalog: ModelInfo[]
  onDone: (r: LoraUploadResult) => void
  preferBase?: string[]
  compact?: boolean
}) {
  const options = useMemo(() => loraBaseOptions(catalog), [catalog])
  const [file, setFile] = useState<File | null>(null)
  const [check, setCheck] = useState<LoraCheck | null>(null)
  const [checking, setChecking] = useState(false)
  const [form, setForm] = useState<LoraAssignment>({ family: '', name: '', trigger: '', expert: 'both' })
  const [progress, setProgress] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [drag, setDrag] = useState(false)
  const abort = useRef<AbortController | null>(null)
  const busy = progress !== null

  // Vorbelegung der Basis: erkannt, aus den Metadaten vorgeschlagen oder, wenn der Kopf nichts verrät, die des gewählten
  // Modells. Als Effekt, damit sie auch greift, wenn die Modellliste erst nach der Prüfung ankommt (12.11.2026: Datei
  // gleich nach dem Öffnen gewählt, die Prüfung erkannte Qwen-Image, die Auswahl stand trotzdem auf „bitte wählen“).
  useEffect(() => {
    if (!check?.lora || form.family) return
    const known = (b?: string | null) => (b && options.some((o) => o.base === b) ? b : '')
    const family = known(check.suggested) || (check.family ? '' : known(preferBase?.find((b) => known(b))))
    if (family) setForm((f) => (f.family ? f : { ...f, family }))
  }, [check, options, preferBase, form.family])

  const pick = async (f: File | undefined) => {
    if (!f || busy) return
    setFile(f)
    setCheck(null)
    setError(null)
    if (!f.name.toLowerCase().endsWith('.safetensors')) {
      setError(t('Nur .safetensors-Dateien lassen sich als LoRA hinzufügen.', 'Only .safetensors files can be added as a LoRA.'))
      return
    }
    setChecking(true)
    try {
      const c = await api.inspectLora(f)
      // Die Basis setzt der Effekt unten, sobald die Modellliste da ist
      setForm({ family: '', name: c.name, trigger: c.trigger, expert: c.expert ?? 'both' })
      setCheck(c)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setChecking(false)
    }
  }

  const add = async () => {
    if (!file || !form.family) return
    setError(null)
    setProgress(0)
    const ctrl = new AbortController()
    abort.current = ctrl
    try {
      const r = await api.uploadLora(file, { ...form, expert: expertFor(form) }, setProgress, ctrl.signal)
      setFile(null)
      setCheck(null)
      onDone(r)
    } catch (e) {
      if (!(e instanceof DOMException && e.name === 'AbortError')) setError(e instanceof Error ? e.message : String(e))
    } finally {
      setProgress(null)
      abort.current = null
    }
  }

  const pct = Math.round((progress ?? 0) * 100)
  return (
    <section className={compact ? 'lora-upload compact' : 'panel lora-upload'}>
      {!compact && (
        <>
          <h3>{t('Eigene LoRA hinzufügen', 'Add your own LoRA')}</h3>
          <p className="muted small">
            {t('Eine LoRA-Datei (.safetensors) von diesem Rechner, etwa selbst trainiert mit ai-toolkit, kohya_ss, '
                + 'OneTrainer oder musubi-tuner. NVAI-open liest zuerst nur den Dateikopf und erkennt daran, zu welchem '
                + 'Modell sie gehört; die Zuordnung lässt sich vor und nach dem Hinzufügen ändern.',
              'A LoRA file (.safetensors) from this computer, for example one you trained with ai-toolkit, kohya_ss, '
                + 'OneTrainer or musubi-tuner. NVAI-open first reads only the file header and detects which model it '
                + 'belongs to; you can change the assignment before and after adding it.')}
          </p>
        </>
      )}
      <label
        className={`drop-zone${drag ? ' drag' : ''}${busy ? ' disabled' : ''}`}
        onDragOver={(e) => {
          e.preventDefault()
          if (!busy) setDrag(true)
        }}
        onDragLeave={() => setDrag(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDrag(false)
          pick(e.dataTransfer.files[0])
        }}
      >
        <input type="file" accept=".safetensors" hidden disabled={busy}
          onChange={(e) => {
            pick(e.target.files?.[0])
            e.target.value = ''   // dieselbe Datei noch einmal wählbar
          }} />
        {file ? (
          <>
            <strong>{file.name}</strong>
            <span className="muted small">{sizeText(file.size)}</span>
          </>
        ) : (
          <span>{t('LoRA-Datei (.safetensors) hierher ziehen oder klicken', 'Drop a LoRA file (.safetensors) here or click')}</span>
        )}
      </label>
      {checking && <p className="muted small">{t('prüft den Dateikopf …', 'checking the file header …')}</p>}
      {check && <p className={check.ok ? 'ok-text small' : 'warn-text small'}>{check.verdict}</p>}
      {check?.lora && (
        <>
          <AssignFields value={form} onChange={setForm} options={options} detected={check.family} />
          <div className="row-gap">
            {busy ? (
              <>
                <div className="progress lora-progress">
                  <div className="bar" style={{ width: `${pct}%` }} />
                </div>
                <span className="muted small">
                  {pct < 100 ? t(`lädt hoch … ${pct} %`, `uploading … ${pct} %`) : t('prüft …', 'checking …')}
                </span>
                <button className="btn small ghost danger-text" onClick={() => abort.current?.abort()}>
                  {t('Abbrechen', 'Cancel')}
                </button>
              </>
            ) : (
              <button className="btn small primary" disabled={!form.family} onClick={add}
                title={form.family ? '' : t('Erst wählen, zu welchem Modell die LoRA gehört', 'First choose which model the LoRA belongs to')}>
                {t('Hinzufügen', 'Add')}
              </button>
            )}
          </div>
        </>
      )}
      {error && <div className="error">{error}</div>}
    </section>
  )
}

/** Zuordnung einer LoRA aus dem Nutzer-Katalog ändern (hochgeladen, Hugging Face, Civitai). */
export function LoraAssign({ model, catalog, onSaved, onCancel }: {
  model: ModelInfo
  catalog: ModelInfo[]
  onSaved: (m: ModelInfo) => void
  onCancel: () => void
}) {
  const options = useMemo(() => loraBaseOptions(catalog), [catalog])
  const [form, setForm] = useState<LoraAssignment>({
    family: model.family, name: model.name, trigger: model.trigger ?? '',
    expert: (model.expert || 'both') as LoraExpert,
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const save = async () => {
    setBusy(true)
    setError(null)
    try {
      // Den Namen nur ändern, wenn er geändert wurde: Namen aus der Suche („repo / datei“) blieben sonst nicht gleich
      onSaved(await api.updateLora(model.id, {
        family: form.family, trigger: form.trigger, expert: expertFor(form),
        ...(form.name.trim() !== model.name ? { name: form.name } : {}),
      }))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="lora-assign">
      <AssignFields value={form} onChange={setForm} options={options} detected={null} />
      <div className="row-gap">
        <button className="btn small primary" disabled={busy || !form.family} onClick={save}>
          {t('Speichern', 'Save')}
        </button>
        <button className="btn small ghost" onClick={onCancel}>{t('Abbrechen', 'Cancel')}</button>
      </div>
      {error && <div className="error">{error}</div>}
    </div>
  )
}
