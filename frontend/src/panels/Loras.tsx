import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  api, loraFileUrl, LORA_BASE_LABEL, type Job, type LoraDataset, type LoraRun, type LoraTrainImage,
  type LoraTrainStatus, type ModelInfo, type ServerEvent,
} from '../api'
import { LoraAssign, LoraUpload } from '../components/LoraFile'
import { Recommendations } from '../components/Recommendations'
import { t } from '../i18n'
import { RunMonitor } from './LoraRunMonitor'
import { LoraWizard } from './LoraWizard'
import {
  AssetPicker, CaptionField, fmtDuration, fmtGb, fmtTime, ImageViewer, STATUS_LABEL, type Progress, type Viewer,
} from './loraShared'

// Bereich „LoRA erstellen/Bearbeiten“ (seit 0.5.29; Nutzer 16.11.2026: „integriere neuen Bereich ‚LoRA
// erstellen/Bearbeiten'. dort soll ich mit eigenen loras arbeiten können“). Server: server/nvai/lora_train.py.
// Weg wie bei den Somi-LoRAs: Datensatz (Verlauf, Ordner oder aus einer Vorlage mit Qwen-Image-Edit-2511) →
// Training mit musubi-tuner → Probebilder je Zwischenstand → den besten Stand übernehmen.

interface Props {
  event: ServerEvent | null
  modelsVersion: number
  onShowModels: () => void
}

/** Einrichten: Trainer, bf16-Gewichte, Qwen-Image-2512 zum Testen, Vorlagen-Modell */
function SetupBox({ st, progress, onSetup, onCancel, onShowModels }: {
  st: LoraTrainStatus
  progress: (Progress & { id: string }) | null
  onSetup: (parts: ('tool' | 'weights' | 'edit')[]) => void
  onCancel: (id: string) => void
  onShowModels: () => void
}) {
  const missingWeights = st.weights.filter((w) => !w.installed)
  const missingEdit = st.edit.filter((w) => !w.installed)
  const allReady = st.ready && st.template_ready
  const busy = !!progress
  return (
    <details className="panel lt-setup" open={!allReady}>
      <summary>
        <strong>{t('Einrichten', 'Set up')}</strong>{' '}
        <span className="muted small">
          {allReady ? t('alles da', 'all set') : st.ready ? t('Training bereit, Vorlagen-Modell fehlt', 'training ready, template model missing')
            : t('es fehlt noch etwas', 'something is missing')} · {t(`${fmtGb(st.free_gb)} frei`, `${fmtGb(st.free_gb)} free`)}
        </span>
      </summary>
      {!st.nvidia && (
        <p className="hint warn">{t('Das Training läuft nur auf NVIDIA-Karten (musubi-tuner mit CUDA).', 'Training runs on NVIDIA cards only (musubi-tuner with CUDA).')}</p>
      )}
      <ul className="lt-checklist">
        <li className={st.tool.installed ? 'ok' : ''}>
          <span>{st.tool.installed ? '✓' : '○'} {t('Trainer musubi-tuner', 'Trainer musubi-tuner')} {st.tool.version ?? st.tool.tag.replace(/^v/, '')}
            <span className="muted small"> · {t('eigene Umgebung mit PyTorch, rund', 'own environment with PyTorch, about')} {fmtGb(st.tool.size_gb)}</span></span>
          {!st.tool.installed && <button className="btn small" disabled={busy || !st.nvidia} onClick={() => onSetup(['tool'])}>{t('Einrichten', 'Set up')}</button>}
        </li>
        <li className={missingWeights.length ? '' : 'ok'}>
          <span>{missingWeights.length ? '○' : '✓'} {t('Trainingsgewichte (bf16, nur fürs Training)', 'Training weights (bf16, for training only)')}
            <span className="muted small"> · {st.weights.map((w) => `${w.label} ${fmtGb(w.size_gb)}`).join(', ')}</span></span>
          {missingWeights.length > 0 && (
            <button className="btn small" disabled={busy} onClick={() => onSetup(['weights'])}>
              {t('Laden', 'Download')} ({fmtGb(missingWeights.reduce((a, w) => a + w.size_gb, 0))})
            </button>
          )}
        </li>
        <li className={st.base.installed ? 'ok' : ''}>
          <span>{st.base.installed ? '✓' : '○'} {t('Qwen-Image-2512 zum Testen und Benutzen', 'Qwen-Image-2512 for testing and using')}
            {st.base.model_id && <span className="muted small"> · {st.base.model_id}</span>}</span>
          {!st.base.installed && <button className="btn small" onClick={onShowModels}>{t('Unter „Modelle“', 'Under “Models”')}</button>}
        </li>
        <li className={missingEdit.length ? '' : 'ok'}>
          <span>{missingEdit.length ? '○' : '✓'} {t('Für Bilder aus einer Vorlage: Qwen-Image-Edit-2511 (Apache-2.0)', 'For images from a template: Qwen-Image-Edit-2511 (Apache-2.0)')}
            <span className="muted small"> · {st.edit.map((w) => `${w.label} ${fmtGb(w.size_gb)}`).join(', ')}</span></span>
          {missingEdit.length > 0 && (
            <button className="btn small" disabled={busy} onClick={() => onSetup(['edit'])}>
              {t('Laden', 'Download')} ({fmtGb(missingEdit.reduce((a, w) => a + w.size_gb, 0))})
            </button>
          )}
        </li>
      </ul>
      {progress && (
        <div className="lt-progress">
          <div className="progress"><div className="bar" style={{ width: `${Math.round(progress.progress * 100)}%` }} /></div>
          <span className="muted small">{progress.stage}</span>
          <button className="btn small ghost danger-text" onClick={() => onCancel(progress.id)}>{t('Abbrechen', 'Cancel')}</button>
        </div>
      )}
      <p className="hint small">
        {t(`Gemessen auf einer RTX 5060 Ti mit 16 GB und 64 GB Arbeitsspeicher: höchstens 14,3 GB Grafikspeicher, ${st.timing.seconds_per_step} s je Schritt. Mit weniger Speicher ist das Training nicht getestet. Ablage: ${st.root}`,
          `Measured on an RTX 5060 Ti with 16 GB and 64 GB RAM: at most 14.3 GB graphics memory, ${st.timing.seconds_per_step} s per step. Training with less memory is untested. Location: ${st.root}`)}
      </p>
    </details>
  )
}

/** Die eigenen LoRAs (hochgeladen, gesucht, trainiert): Zuordnung ändern, löschen, Datei hinzufügen */
function OwnLoras({ models, onChanged }: { models: ModelInfo[]; onChanged: () => void }) {
  const own = useMemo(() => models.filter((m) => m.kind === 'lora' && (m.custom || m.uploaded)), [models])
  const [editing, setEditing] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<string | null>(null)
  const [error, setError] = useState('')
  const remove = async (m: ModelInfo) => {
    setError('')
    try {
      await api.deleteModel(m.id)
      setDeleting(null)
      onChanged()
    } catch (e) {
      setError(String((e as Error).message ?? e))
    }
  }
  return (
    <section className="panel lt-section">
      <h3>{t('Meine LoRAs', 'My LoRAs')}</h3>
      {own.length === 0 && <p className="muted small">{t('Noch keine eigenen LoRAs. Unten eine Datei hinzufügen oder eine trainieren.', 'No LoRAs of your own yet. Add a file below or train one.')}</p>}
      <div className="lt-own">
        {own.map((m) => (
          <div key={m.id} className="lt-own-row">
            {editing === m.id ? (
              <LoraAssign model={m} catalog={models} onSaved={() => { setEditing(null); onChanged() }} onCancel={() => setEditing(null)} />
            ) : (
              <>
                <div className="lt-own-main">
                  <strong>{m.name}</strong>
                  <span className="muted small">
                    {LORA_BASE_LABEL[m.family] ?? m.family}
                    {m.trigger ? <> · {t('Auslöser', 'trigger')}: <code>{m.trigger}</code></> : null}
                    {' '}· {fmtGb(m.size_gb)}
                    {m.trained ? <> · {t(`selbst trainiert: Epoche ${m.trained.epoch}, ${m.trained.images ?? '?'} Bilder`, `trained here: epoch ${m.trained.epoch}, ${m.trained.images ?? '?'} images`)}</> : null}
                  </span>
                </div>
                <button className="btn small" onClick={() => setEditing(m.id)}>{t('Bearbeiten', 'Edit')}</button>
                {deleting === m.id ? (
                  <>
                    <button className="btn small danger-text" onClick={() => remove(m)}>{t('Wirklich löschen', 'Really delete')}</button>
                    <button className="btn small ghost" onClick={() => setDeleting(null)}>{t('Nein', 'No')}</button>
                  </>
                ) : (
                  <button className="btn small ghost danger-text" onClick={() => setDeleting(m.id)}>{t('Löschen', 'Delete')}</button>
                )}
              </>
            )}
          </div>
        ))}
      </div>
      {error && <p className="error">{error}</p>}
      <LoraUpload catalog={models} onDone={onChanged} />
    </section>
  )
}

/** Ein Datensatz: Angaben, Bilder mit Bildbeschreibung, Vorlage, Training */
function DatasetEditor({ st, ds, genProgress, onReload, onDeleted, onJob, onCancel, setViewer }: {
  st: LoraTrainStatus
  ds: LoraDataset
  genProgress: (Progress & { id: string }) | null
  onReload: () => void
  onDeleted: () => void
  onJob: (job: Job) => void
  onCancel: (id: string) => void
  setViewer: (v: Viewer) => void
}) {
  const [form, setForm] = useState({ name: ds.name, trigger: ds.trigger, class_word: ds.class_word, notes: ds.notes ?? '' })
  const [hideRejected, setHideRejected] = useState(false)
  const [picker, setPicker] = useState<'images' | 'template' | null>(null)
  const [folder, setFolder] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [count, setCount] = useState(0)
  const [settings, setSettings] = useState({ ...st.defaults })
  const [test, setTest] = useState(true)
  const [prompts, setPrompts] = useState<string[]>(st.test_prompts)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const templateInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    setForm({ name: ds.name, trigger: ds.trigger, class_word: ds.class_word, notes: ds.notes ?? '' })
    setConfirmDelete(false)
  }, [ds.id, ds.name, ds.trigger, ds.class_word, ds.notes])

  const keep = ds.images.filter((im) => im.status !== 'reject')
  const rejectedTemplate = ds.images.filter((im) => im.status === 'reject' && im.pose != null)
  const posesDone = new Set(ds.images.filter((im) => im.pose != null).map((im) => im.pose))
  const posesOpen = st.poses.length - posesDone.size
  useEffect(() => { setCount(posesOpen > 0 ? posesOpen : st.poses.length) }, [posesOpen, st.poses.length])

  const run = async (fn: () => Promise<unknown>) => {
    setError('')
    setMessage('')
    setBusy(true)
    try {
      const r = await fn()
      if (r && typeof r === 'object' && 'message' in r && (r as LoraDataset).message) setMessage((r as LoraDataset).message!)
      onReload()
    } catch (e) {
      setError(String((e as Error).message ?? e))
    } finally {
      setBusy(false)
    }
  }
  const saveField = (key: keyof typeof form) => {
    if ((form[key] ?? '') === ((ds as unknown as Record<string, string>)[key] ?? '')) return
    run(() => api.loraDatasetUpdate(ds.id, { [key]: form[key] }))
  }
  const uploadFiles = async (files: FileList | null, asTemplate: boolean) => {
    if (!files?.length) return
    await run(async () => {
      const ids: string[] = []
      for (const f of Array.from(files)) ids.push((await api.upload(f)).id)
      if (asTemplate) return api.loraDatasetTemplate(ds.id, ids[0])
      return api.loraDatasetAddAssets(ds.id, ids)
    })
  }
  const setStatus = (im: LoraTrainImage, status: 'keep' | 'reject') => run(() => api.loraImageUpdate(ds.id, im.file, { status }))
  const shown = hideRejected ? keep : ds.images
  const steps = keep.length * settings.epochs
  const ckpts = Math.max(1, Math.floor(settings.epochs / Math.max(1, settings.save_every)))
  const estimate = steps * st.timing.seconds_per_step + keep.length * st.timing.te_seconds_per_caption + 60
    + (test ? (ckpts + 1) * prompts.filter((p) => p.trim()).length * st.timing.test_seconds_per_image : 0)
  const urls = shown.map((im) => loraFileUrl('datasets', ds.id, im.file))

  return (
    <div className="lt-editor">
      <div className="lt-fields">
        <label>{t('Name', 'Name')}<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} onBlur={() => saveField('name')} /></label>
        <label>{t('Auslösewort', 'Trigger word')}<input value={form.trigger} onChange={(e) => setForm({ ...form, trigger: e.target.value })} onBlur={() => saveField('trigger')} placeholder="somi_dark1" /></label>
        <label>{t('Gattung', 'Class')}<input value={form.class_word} onChange={(e) => setForm({ ...form, class_word: e.target.value })} onBlur={() => saveField('class_word')} placeholder="a cartoon rabbit" /></label>
      </div>
      <p className="hint small">
        {t('Vor jede Bildbeschreibung setzt das Training „Auslösewort, Gattung“. Die Beschreibung nennt, was sich von Bild zu Bild ändert (Haltung, Ausschnitt, Hintergrund), nicht die Figur selbst: Die lernt die LoRA.',
          'The training puts “trigger word, class” in front of every caption. The caption names what changes from image to image (pose, framing, background), not the character itself: that is what the LoRA learns.')}
      </p>

      <h4>{t('Bilder hinzufügen', 'Add images')}</h4>
      <div className="lt-toolbar">
        <button className="btn small" disabled={busy} onClick={() => setPicker('images')}>{t('Aus dem Verlauf …', 'From the history …')}</button>
        <button className="btn small" disabled={busy} onClick={() => fileInput.current?.click()}>{t('Vom Rechner …', 'From this computer …')}</button>
        <input ref={fileInput} type="file" accept="image/png,image/jpeg,image/webp" multiple hidden onChange={(e) => { uploadFiles(e.target.files, false); e.target.value = '' }} />
        <input className="lt-folder" value={folder} onChange={(e) => setFolder(e.target.value)} placeholder={t('Ordner mit Bildern und .txt (kohya) …', 'Folder with images and .txt (kohya) …')} />
        <button className="btn small" disabled={busy || !folder.trim()} onClick={() => run(() => api.loraDatasetAddFolder(ds.id, folder))}>{t('Ordner übernehmen', 'Add folder')}</button>
      </div>

      <div className="lt-template">
        <div className="lt-template-img">
          {ds.template
            ? <img src={`${loraFileUrl('datasets', ds.id, ds.template)}?v=${ds.updated ?? 0}`} alt={t('Vorlage', 'Template')}
                onClick={() => setViewer({ urls: [loraFileUrl('datasets', ds.id, ds.template!)], labels: [t('Vorlage', 'Template')], index: 0 })} />
            : <span className="muted small">{t('keine Vorlage', 'no template')}</span>}
        </div>
        <div className="lt-template-body">
          <strong>{t('Aus einer Vorlage erzeugen', 'Generate from a template')}</strong>
          <p className="hint small">
            {t(`Eine Skizze oder ein Bild der Figur: Qwen-Image-Edit-2511 zeichnet sie in ${st.poses.length} Haltungen, Ausschnitten und Umgebungen, rund ${st.timing.edit_seconds_per_image} s je Bild. Was gleich bleiben muss (Farben, Gesicht, Zähne), steht im Feld darunter auf Englisch.`,
              `A sketch or an image of the character: Qwen-Image-Edit-2511 draws it in ${st.poses.length} poses, framings and settings, about ${st.timing.edit_seconds_per_image} s per image. What has to stay the same (colors, face, teeth) goes in the field below, in English.`)}
          </p>
          <div className="lt-toolbar">
            <button className="btn small" disabled={busy} onClick={() => setPicker('template')}>{t('Vorlage aus dem Verlauf …', 'Template from the history …')}</button>
            <button className="btn small" disabled={busy} onClick={() => templateInput.current?.click()}>{t('Vorlage vom Rechner …', 'Template from this computer …')}</button>
            <input ref={templateInput} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => { uploadFiles(e.target.files, true); e.target.value = '' }} />
          </div>
          <textarea rows={2} value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} onBlur={() => saveField('notes')}
            placeholder={t('z. B.: The insides of his ears are bright blue, everything else is black, white and grey.', 'e.g.: The insides of his ears are bright blue, everything else is black, white and grey.')} />
          {genProgress ? (
            <div className="lt-progress">
              <div className="progress"><div className="bar" style={{ width: `${Math.round(genProgress.progress * 100)}%` }} /></div>
              <span className="muted small">{genProgress.stage}</span>
              <button className="btn small ghost danger-text" onClick={() => onCancel(genProgress.id)}>{t('Abbrechen', 'Cancel')}</button>
            </div>
          ) : (
            <div className="lt-toolbar">
              <input type="number" className="lt-num" min={1} max={st.poses.length} value={count} onChange={(e) => setCount(Math.max(1, Math.min(st.poses.length, Number(e.target.value) || 1)))} />
              <button className="btn small primary" disabled={busy || !ds.template || !st.template_ready}
                onClick={() => run(async () => onJob(await api.loraDatasetGenerate(ds.id, { count, notes: form.notes })))}>
                {t(`${count} Bilder erzeugen (rund ${fmtDuration(count * st.timing.edit_seconds_per_image)})`, `Generate ${count} images (about ${fmtDuration(count * st.timing.edit_seconds_per_image)})`)}
              </button>
              {rejectedTemplate.length > 0 && (
                <button className="btn small" disabled={busy || !ds.template || !st.template_ready}
                  onClick={() => run(async () => onJob(await api.loraDatasetGenerate(ds.id, { replace: rejectedTemplate.map((im) => im.file), notes: form.notes })))}>
                  {t(`Ersatz für ${rejectedTemplate.length} aussortierte`, `Replace ${rejectedTemplate.length} rejected`)}
                </button>
              )}
              {!st.template_ready && <span className="hint small warn">{t('Vorlagen-Modell fehlt (oben unter „Einrichten“).', 'Template model missing (see “Set up” above).')}</span>}
            </div>
          )}
        </div>
      </div>

      <div className="lt-grid-head">
        <h4>{t(`Bilder: ${keep.length} im Training, ${ds.images.length - keep.length} aussortiert`, `Images: ${keep.length} in training, ${ds.images.length - keep.length} rejected`)}</h4>
        <label className="check small"><input type="checkbox" checked={hideRejected} onChange={(e) => setHideRejected(e.target.checked)} />{t('Aussortierte ausblenden', 'Hide rejected')}</label>
      </div>
      {message && <p className="hint">{message}</p>}
      {error && <p className="error">{error}</p>}
      <div className="lt-images">
        {shown.map((im, i) => (
          <figure key={im.file} className={`lt-image${im.status === 'reject' ? ' rejected' : ''}`}>
            <img src={urls[i]} alt={im.caption} loading="lazy" onClick={() => setViewer({ urls, labels: shown.map((x) => x.caption || x.file), index: i })} />
            <figcaption>
              <CaptionField key={`${im.file}-${im.caption}`} value={im.caption}
                onSave={(caption) => run(() => api.loraImageUpdate(ds.id, im.file, { caption }))} />
              <div className="lt-image-actions">
                <button className={`btn small${im.status !== 'reject' ? ' on' : ''}`} title={t('im Training', 'in training')} onClick={() => setStatus(im, 'keep')}>✓</button>
                <button className={`btn small${im.status === 'reject' ? ' off' : ''}`} title={t('aussortieren', 'reject')} onClick={() => setStatus(im, 'reject')}>✕</button>
                <span className="muted small" title={im.file}>{im.width}×{im.height}</span>
                {im.license_note && <span className="hint small warn" title={im.license_note}>⚠</span>}
                <button className="btn small ghost danger-text" title={t('aus dem Datensatz löschen (die Datei im Datensatz-Ordner)', 'delete from the dataset (the file in the dataset folder)')}
                  onClick={() => run(() => api.loraImageDelete(ds.id, im.file))}>{t('Löschen', 'Delete')}</button>
              </div>
            </figcaption>
          </figure>
        ))}
      </div>

      <h4>{t('Trainieren', 'Train')}</h4>
      <div className="lt-fields">
        <label>{t('Epochen', 'Epochs')}<input type="number" min={1} max={100} value={settings.epochs} onChange={(e) => setSettings({ ...settings, epochs: Number(e.target.value) || 1 })} /></label>
        <label>{t('Lernrate', 'Learning rate')}<input value={settings.lr} onChange={(e) => setSettings({ ...settings, lr: e.target.value })} /></label>
        <label>{t('Rang', 'Rank')}<input type="number" min={4} max={128} value={settings.rank} onChange={(e) => {
          // Alpha folgt dem Rang, solange beide gleich waren (volle Wirkung)
          const rank = Number(e.target.value) || 16
          setSettings({ ...settings, rank, alpha: settings.alpha === settings.rank ? rank : settings.alpha })
        }} /></label>
        <label>{t('Alpha', 'Alpha')}<input type="number" min={0.5} max={256} step={0.5} value={settings.alpha} onChange={(e) => setSettings({ ...settings, alpha: Number(e.target.value) || settings.rank })} /></label>
        <label>{t('Zwischenstand alle … Epochen', 'Checkpoint every … epochs')}<input type="number" min={1} max={100} value={settings.save_every} onChange={(e) => setSettings({ ...settings, save_every: Number(e.target.value) || 1 })} /></label>
      </div>
      <p className="hint small">
        {t('Alpha gleich Rang lässt die LoRA voll wirken; mit Alpha 1 (der Vorgabe von musubi-tuner) kam die erste Somi-LoRA bei Stärke 1 kaum durch. Mit Lernrate 2e-4 trafen unsere Somi-LoRAs die Figur bei Stärke 1, mit 1e-4 erst bei 2 bis 2,5.',
          'Alpha equal to the rank lets the LoRA work at full strength; with alpha 1 (musubi-tuner\'s default) the first Somi LoRA barely showed at strength 1. With learning rate 2e-4 our Somi LoRAs matched the character at strength 1, with 1e-4 only at 2 to 2.5.')}
      </p>
      <label className="check small"><input type="checkbox" checked={test} onChange={(e) => setTest(e.target.checked)} />
        {t('Danach Probebilder je Zwischenstand (gleicher Seed, dazu ohne LoRA)', 'Then test images per checkpoint (same seed, plus without LoRA)')}</label>
      {test && prompts.map((p, i) => (
        <input key={i} className="lt-prompt" value={p} onChange={(e) => setPrompts(prompts.map((x, j) => (j === i ? e.target.value : x)))}
          placeholder={t('Probe-Prompt (Auslösewort und Gattung kommen davor)', 'Test prompt (trigger word and class go in front)')} />
      ))}
      <div className="lt-toolbar">
        <button className="btn primary" disabled={busy || !st.ready || keep.length < st.min_images}
          onClick={() => run(async () => onJob(await api.loraTrain(ds.id, { ...settings, test, prompts: prompts.filter((p) => p.trim()) }) as Job))}>
          {t(`Training starten: ${steps} Schritte, rund ${fmtDuration(estimate)}`, `Start training: ${steps} steps, about ${fmtDuration(estimate)}`)}
        </button>
        {!st.ready && <span className="hint small warn">{t('Erst oben einrichten.', 'Set up above first.')}</span>}
        {st.ready && keep.length < st.min_images && <span className="hint small warn">{t(`Mindestens ${st.min_images} Bilder (gut sind 20 bis 30).`, `At least ${st.min_images} images (20 to 30 work well).`)}</span>}
      </div>
      <p className="hint small">
        {t('Während des Trainings ist die Grafikkarte voll belegt; andere Aufträge warten so lange.', 'While training, the graphics card is fully in use; other jobs wait until it is done.')}
      </p>
      <div className="lt-toolbar lt-danger">
        {confirmDelete ? (
          <>
            <button className="btn small danger-text" onClick={() => run(async () => { await api.loraDatasetDelete(ds.id); onDeleted() })}>
              {t(`Datensatz „${ds.name}“ mit ${ds.images.length} Bildern löschen`, `Delete dataset “${ds.name}” with ${ds.images.length} images`)}
            </button>
            <button className="btn small ghost" onClick={() => setConfirmDelete(false)}>{t('Nein', 'No')}</button>
          </>
        ) : (
          <button className="btn small ghost danger-text" onClick={() => setConfirmDelete(true)}>{t('Datensatz löschen', 'Delete dataset')}</button>
        )}
      </div>

      {picker && (
        <AssetPicker multiple={picker === 'images'} onClose={() => setPicker(null)}
          onPick={(ids) => { setPicker(null); run(() => (picker === 'images' ? api.loraDatasetAddAssets(ds.id, ids) : api.loraDatasetTemplate(ds.id, ids[0]))) }} />
      )}
    </div>
  )
}

export function LorasPanel({ event, modelsVersion, onShowModels }: Props) {
  const [st, setSt] = useState<LoraTrainStatus | null>(null)
  const [models, setModels] = useState<ModelInfo[]>([])
  const [dsId, setDsId] = useState<string | null>(null)
  const [ds, setDs] = useState<LoraDataset | null>(null)
  const [runId, setRunId] = useState<string | null>(null)
  const [run, setRun] = useState<LoraRun | null>(null)
  const [progress, setProgress] = useState<Record<string, Progress>>({})
  // laufende Aufträge je Art: Einrichten, Bilder je Datensatz, Probebilder je Training
  const [jobs, setJobs] = useState<{ setup?: string; gen: Record<string, string>; test: Record<string, string> }>({ gen: {}, test: {} })
  // rechte Seite: Übersicht, Einrichten, Meine LoRAs, neuer Assistent, Datensatz oder Training
  const [main, setMain] = useState<'home' | 'setup' | 'mine' | 'new' | 'dataset' | 'run'>('home')
  const [wizardStep, setWizardStep] = useState<number | undefined>(undefined)
  // Assistent (Vorgabe) oder alles auf einer Seite; gemerkt je Browser
  const [view, setView] = useState<'wizard' | 'all'>(() => {
    try { return localStorage.getItem('nvai.lora.view') === 'all' ? 'all' : 'wizard' } catch { return 'wizard' }
  })
  const chooseView = (v: 'wizard' | 'all') => {
    setView(v)
    try { localStorage.setItem('nvai.lora.view', v) } catch { /* nur Bequemlichkeit */ }
  }
  const [error, setError] = useState('')
  const [viewer, setViewer] = useState<Viewer | null>(null)

  const loadStatus = useCallback(() => {
    api.loraTrainStatus().then(setSt).catch((e) => setError(String(e.message ?? e)))
  }, [])
  const loadModels = useCallback(() => { api.models().then(setModels).catch(() => {}) }, [])
  const loadDs = useCallback(() => {
    if (dsId) api.loraDataset(dsId).then(setDs).catch(() => { setDs(null); setDsId(null) })
    else setDs(null)
  }, [dsId])
  const loadRun = useCallback(() => {
    if (runId) api.loraRun(runId).then(setRun).catch(() => { setRun(null); setRunId(null) })
    else setRun(null)
  }, [runId])

  useEffect(loadStatus, [loadStatus])
  useEffect(loadModels, [loadModels, modelsVersion])
  useEffect(loadDs, [loadDs])
  useEffect(loadRun, [loadRun])

  // Laufende Aufträge nach dem Neuladen der Seite wiederfinden
  useEffect(() => {
    Promise.all(['lora_setup', 'lora_dataset', 'lora_test'].map((k) => api.activeJobs(k).catch(() => [] as Job[])))
      .then(([setup, gen, test]) => {
        setJobs({
          setup: setup[0]?.id,
          gen: Object.fromEntries(gen.map((j) => [String(j.params?.dataset_id), j.id])),
          test: Object.fromEntries(test.map((j) => [String(j.params?.run_id), j.id])),
        })
        const p: Record<string, Progress> = {}
        for (const j of [...setup, ...gen, ...test]) p[j.id] = { progress: j.progress ?? 0, stage: j.stage ?? '' }
        setProgress((old) => ({ ...p, ...old }))
      })
  }, [])

  const refreshAll = useCallback(() => { loadStatus(); loadDs(); loadRun() }, [loadStatus, loadDs, loadRun])
  const refreshTimer = useRef<number | null>(null)
  const refreshSoon = useCallback(() => {
    if (refreshTimer.current) window.clearTimeout(refreshTimer.current)
    refreshTimer.current = window.setTimeout(refreshAll, 400)
  }, [refreshAll])

  useEffect(() => {
    if (!event) return
    if (event.type === 'job.progress') {
      setProgress((p) => ({ ...p, [event.job_id]: { progress: event.progress, stage: event.stage } }))
    } else if (event.type === 'job.done' || event.type === 'job.error' || event.type === 'job.cancelled') {
      const id = event.job_id
      setProgress((p) => { const n = { ...p }; delete n[id]; return n })
      setJobs((j) => ({
        setup: j.setup === id ? undefined : j.setup,
        gen: Object.fromEntries(Object.entries(j.gen).filter(([, v]) => v !== id)),
        test: Object.fromEntries(Object.entries(j.test).filter(([, v]) => v !== id)),
      }))
      if (event.type === 'job.error' && (Object.values(jobs.gen).includes(id) || Object.values(jobs.test).includes(id) || jobs.setup === id
        || st?.runs.some((r) => r.job_id === id))) setError(event.error)
      refreshSoon()
    } else if (event.type === 'lora.changed') {
      refreshSoon()
    } else if (event.type === 'models.changed') {
      loadModels()
    }
  }, [event]) // eslint-disable-line react-hooks/exhaustive-deps

  const onJob = (kind: 'setup' | 'gen' | 'test' | 'train', key: string) => (job: Job) => {
    setProgress((p) => ({ ...p, [job.id]: { progress: 0, stage: t('wartet', 'queued') } }))
    if (kind === 'setup') setJobs((j) => ({ ...j, setup: job.id }))
    if (kind === 'gen') setJobs((j) => ({ ...j, gen: { ...j.gen, [key]: job.id } }))
    if (kind === 'test') setJobs((j) => ({ ...j, test: { ...j.test, [key]: job.id } }))
    // Nach „Training starten“ gleich das neue Training öffnen, mit Fortschritt und „Abbrechen“
    if (kind === 'train') { loadStatus(); setRunId(typeof job.params?.run_id === 'string' ? job.params.run_id : null) }
    refreshSoon()
  }
  const cancel = async (id: string) => {
    try { await api.cancelJob(id) } catch (e) { setError(String((e as Error).message ?? e)) }
    refreshSoon()
  }
  const setup = async (parts: ('tool' | 'weights' | 'edit')[]) => {
    setError('')
    try { onJob('setup', '')(await api.loraTrainSetup(parts)) } catch (e) { setError(String((e as Error).message ?? e)) }
  }
  const openRun = (id: string) => {
    loadStatus()
    setRunId(id)
    setMain('run')
  }
  const dsJob = (id: string) => (job: Job) => (job.kind === 'lora_train' ? onJob('train', id)(job) : onJob('gen', id)(job))
  const withProgress = (id?: string) => (id ? { id, ...(progress[id] ?? { progress: 0, stage: t('wartet', 'queued') }) } : null)

  if (!st) {
    return <div className="lt-panel"><p className="muted">{error || t('Lädt …', 'Loading …')}</p></div>
  }
  const allReady = st.ready && st.template_ready
  const own = models.filter((m) => m.kind === 'lora' && (m.custom || m.uploaded))
  const show = main === 'dataset' && !ds ? 'home' : main === 'run' && !run ? 'home' : main
  const goDataset = (id: string, step?: number) => { setDsId(id); setWizardStep(step); setMain('dataset') }

  return (
    <div className="lt-panel lt-studio">
      <aside className="lt-side">
        <div className="lt-side-head">
          <h2>{t('LoRA erstellen/Bearbeiten', 'Create/Edit LoRA')}</h2>
          <button className="btn small primary" onClick={() => { setDsId(null); setMain('new') }}>+ {t('Neue LoRA', 'New LoRA')}</button>
        </div>
        <button className={`lt-side-item${show === 'home' ? ' on' : ''}`} onClick={() => setMain('home')}>
          <span>{t('Übersicht und Tipps', 'Overview and tips')}</span>
        </button>
        <button className={`lt-side-item${show === 'setup' ? ' on' : ''}`} onClick={() => setMain('setup')}>
          <span>{t('Einrichten', 'Set up')}</span>
          <span className={`lt-dot ${allReady ? 'ok' : st.ready ? 'part' : 'no'}`} title={allReady ? t('alles da', 'all set') : t('es fehlt noch etwas', 'something is missing')} />
        </button>
        <button className={`lt-side-item${show === 'mine' ? ' on' : ''}`} onClick={() => setMain('mine')}>
          <span>{t('Meine LoRAs', 'My LoRAs')}</span><span className="muted small">{own.length}</span>
        </button>

        <h4>{t('Datensätze', 'Datasets')}</h4>
        {st.datasets.length === 0 && <p className="muted small">{t('Noch keiner: „+ Neue LoRA“.', 'None yet: “+ New LoRA”.')}</p>}
        {st.datasets.map((d) => (
          <button key={d.id} className={`lt-side-ds${show === 'dataset' && d.id === dsId ? ' on' : ''}`} onClick={() => goDataset(d.id)}>
            {d.cover ? <img src={loraFileUrl('datasets', d.id, d.cover)} alt="" loading="lazy" /> : <span className="lt-ds-empty">+</span>}
            <span><strong>{d.name}</strong><span className="muted small">{t(`${d.keep} von ${d.images} Bildern`, `${d.keep} of ${d.images} images`)}</span></span>
            {jobs.gen[d.id] && <span className="lt-dot busy" title={progress[jobs.gen[d.id]]?.stage ?? ''} />}
          </button>
        ))}

        <h4>{t('Trainings', 'Trainings')}</h4>
        {st.runs.length === 0 && <p className="muted small">{t('Noch kein Training.', 'No training yet.')}</p>}
        {st.runs.map((r) => {
          const p = r.job_id ? progress[r.job_id] : undefined
          const active = r.status === 'running' && p
          return (
            <button key={r.id} className={`lt-side-run${show === 'run' && r.id === runId ? ' on' : ''}`} onClick={() => { setRunId(r.id); setMain('run') }}>
              <span className="lt-side-run-top">
                <strong>{r.id}</strong>
                <span className={`lt-status ${r.pause && r.status === 'running' ? 'pausing' : r.status}`}>{r.pause && r.status === 'running' ? t('hält an', 'pausing') : STATUS_LABEL[r.status] ?? r.status}</span>
              </span>
              <span className="muted small">
                {r.status === 'scheduled' ? t(`Start ${fmtTime(r.start_at)}`, `starts ${fmtTime(r.start_at)}`)
                  : r.state && r.status !== 'done' ? t(`bis Epoche ${r.state.epoch} von ${r.settings.epochs}`, `up to epoch ${r.state.epoch} of ${r.settings.epochs}`)
                    : <>{r.checkpoints.length} {t('Zwischenstände', 'checkpoints')}{r.started ? ` · ${fmtTime(r.started)}` : ''}</>}
              </span>
              {active && <span className="lt-mini"><span style={{ width: `${Math.round(p.progress * 100)}%` }} /></span>}
            </button>
          )
        })}
      </aside>

      <section className="lt-main panel">
        {error && <p className="error" onClick={() => setError('')}>{error}</p>}
        {show === 'home' && (
          <div className="lt-home">
            <h3>{t('So entsteht eine eigene LoRA', 'How a LoRA of your own comes about')}</h3>
            <p className="hint">
              {t('Eine eigene LoRA bringt Qwen-Image-2512 eine Figur oder einen Stil bei: 20 bis 30 Bilder mit Bildbeschreibung, ein Training von rund zwei Stunden, dann den besten Zwischenstand übernehmen. Danach steht sie beim Generieren und im Studio bei den Figuren bereit.',
                'A LoRA of your own teaches Qwen-Image-2512 a character or a style: 20 to 30 images with captions, about two hours of training, then add the best checkpoint. It is then ready when generating and for characters in the Studio.')}
            </p>
            <ol className="lt-home-steps">
              <li>{t('„+ Neue LoRA“: Der Assistent führt durch Figur, Vorlage, Bilder, Aussortieren und Training.', '“+ New LoRA”: the assistant leads through character, template, images, sorting out and training.')}</li>
              <li>{t('Ein Training lässt sich pausieren und fortsetzen, auch nachts vormerken. Beim Fortsetzen gilt der korrigierte Datensatz.', 'A training can be paused and resumed, also scheduled for the night. On resume the corrected dataset counts.')}</li>
              <li>{t('Zwischenstände vergleichen, mit dem Schnelltest Stärken ausprobieren, den besten übernehmen.', 'Compare checkpoints, try strengths with the quick test, add the best one.')}</li>
            </ol>
            {!allReady && <button className="btn" onClick={() => setMain('setup')}>{t('Zuerst einrichten', 'Set up first')}</button>}
            <Recommendations mode="lora" />
          </div>
        )}
        {show === 'setup' && <SetupBox st={st} progress={withProgress(jobs.setup)} onSetup={setup} onCancel={cancel} onShowModels={onShowModels} />}
        {show === 'mine' && <OwnLoras models={models} onChanged={() => { loadModels() }} />}
        {show === 'new' && (
          <LoraWizard key="new" st={st} ds={null} genProgress={null} onReload={refreshAll} onJob={() => {}}
            onCreated={(id) => { goDataset(id, 1); loadStatus() }} onTrainStarted={openRun} onCancel={cancel} setViewer={setViewer} />
        )}
        {show === 'dataset' && ds && (
          <>
            <div className="lt-main-head">
              <h3>{ds.name} <code>{ds.trigger}</code></h3>
              <div className="lw-view">
                <button className={`btn small${view === 'wizard' ? ' on' : ''}`} onClick={() => chooseView('wizard')}>{t('Assistent', 'Assistant')}</button>
                <button className={`btn small${view === 'all' ? ' on' : ''}`} onClick={() => chooseView('all')}>{t('Alles auf einer Seite', 'Everything on one page')}</button>
              </div>
            </div>
            {view === 'wizard' ? (
              <LoraWizard key={`${ds.id}-${wizardStep ?? ''}`} st={st} ds={ds} genProgress={withProgress(jobs.gen[ds.id])} onReload={refreshAll}
                onJob={dsJob(ds.id)} onCreated={setDsId} onTrainStarted={openRun} onCancel={cancel} setViewer={setViewer} initialStep={wizardStep} />
            ) : (
              <DatasetEditor key={ds.id} st={st} ds={ds} genProgress={withProgress(jobs.gen[ds.id])} onReload={refreshAll}
                onDeleted={() => { setDsId(null); setMain('home'); loadStatus() }} onJob={dsJob(ds.id)}
                onCancel={cancel} setViewer={setViewer} />
            )}
          </>
        )}
        {show === 'run' && run && (
          <RunMonitor key={run.id} st={st} run={run} progress={run.job_id ? progress[run.job_id] ?? null : null}
            testProgress={withProgress(jobs.test[run.id])} onJob={onJob('test', run.id)} onCancel={cancel} onReload={refreshAll}
            onDeleted={() => { setRunId(null); setMain('home'); loadStatus() }} onAdopted={loadModels}
            onOpenRun={openRun} onOpenDataset={(id) => goDataset(id, 3)} setViewer={setViewer} />
        )}
      </section>
      {viewer && <ImageViewer viewer={viewer} onIndex={(index) => setViewer({ ...viewer, index })} onClose={() => setViewer(null)} />}
    </div>
  )
}
