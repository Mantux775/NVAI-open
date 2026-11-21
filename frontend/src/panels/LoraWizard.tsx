import { useEffect, useRef, useState } from 'react'
import { api, loraFileUrl, type Job, type LoraDataset, type LoraTrainImage, type LoraTrainStatus } from '../api'
import { t } from '../i18n'
import { AssetPicker, CaptionField, fmtDuration, fmtTime, STATUS_LABEL, type Progress, type Viewer } from './loraShared'

// Assistent für eine eigene LoRA (Nutzer 17.11.2026: „im LoRA bereich müssen noch mehr funktionen rein … bilder
// auswählen hochladen oder erzeugen …, dann aussortieren und weitere aus ausgewählten generieren … trotzdem noch
// überschaubar … empfehlungen für einzelne schritte. einen wizzard einbauen“). Fünf Schritte, je eine Empfehlung
// aus gemessenen Läufen (die Somi-LoRAs, notizen/loras.md). „Alles auf einer Seite“ bleibt in Loras.tsx.

type Step = 0 | 1 | 2 | 3 | 4

const STEPS: { title: string; short: string }[] = [
  { title: t('Figur beschreiben', 'Describe the character'), short: t('Figur', 'Character') },
  { title: t('Vorlage wählen', 'Choose a template'), short: t('Vorlage', 'Template') },
  { title: t('Bilder sammeln', 'Collect images'), short: t('Bilder', 'Images') },
  { title: t('Aussortieren', 'Sort out'), short: t('Aussortieren', 'Sort out') },
  { title: t('Trainieren', 'Train'), short: t('Training', 'Training') },
]

/** Kurze Empfehlung je Schritt, nur Gemessenes */
const TIPS: string[][] = [
  [
    t('Auslösewort ohne Bedeutung (etwa smdk1): Mit „dark“ im Auslösewort zeichnete Qwen-Image einen gewöhnlichen schwarzen Hasen.',
      'A trigger word without meaning (such as smdk1): with “dark” in the trigger word Qwen-Image drew an ordinary black rabbit.'),
    t('Die Beschreibung auf Englisch nennt, worin die Figur vom Gewöhnlichen abweicht: Körperform, Kopf, Ohren, Gesicht, Farben, und was fehlen muss (no tail, no whiskers). Mit „long upright ears“ wurde aus unserer Figur ein Durchschnittshase.',
      'The description in English names how the character differs from the ordinary: body shape, head, ears, face, colors, and what must be missing (no tail, no whiskers). With “long upright ears” our character turned into an average rabbit.'),
  ],
  [
    t('Eine eigene Skizze, ein Foto oder ein Bild aus Qwen-Image geht; Bilder aus FLUX 3 nicht (Lizenz 4(b)). Ohne Ausgangsbild entstehen die Entwürfe nur aus der Beschreibung.',
      'A sketch of your own, a photo or an image from Qwen-Image works; images from FLUX 3 do not (license 4(b)). Without a starting image the drafts come from the description alone.'),
    t('Mindestens 4 Entwürfe in voller Größe vergleichen: Die Vorlage legt fest, was die LoRA lernt. Passt keiner, die Beschreibung schärfen und neu erzeugen; zwei Sätze zu Körper und Ohren machten aus dem Normalhasen die Figur der Skizze.',
      'Compare at least 4 drafts at full size: the template decides what the LoRA learns. If none fits, sharpen the description and generate again; two sentences about body and ears turned the ordinary rabbit into the character of the sketch.'),
  ],
  [
    t('20 bis 30 Bilder derselben Figur in verschiedenen Haltungen, Ausschnitten und Umgebungen. Aus der Vorlage entstehen 24 Haltungen, rund 44 s je Bild.',
      '20 to 30 images of the same character in different poses, framings and settings. The template gives 24 poses, about 44 s per image.'),
    t('Trifft die Figur nur in manchen Bildern: die gelungenen anhaken und daraus weitere erzeugen. Eigene Bilder (Verlauf, Rechner, Ordner) passen dazu.',
      'If the character only matches in some images: tick the good ones and generate more from them. Images of your own (history, computer, folder) fit in too.'),
  ],
  [
    t('Jedes Bild in voller Größe ansehen, Taste 1 behält, Taste 2 sortiert aus. Aussortieren: falsche Farben, ein Schwanz oder Schnurrhaare, wo keine hingehören, ein anderes Gesicht, Profil, Rahmen. Den Schwanz sahen wir erst in voller Größe.',
      'Look at every image at full size, key 1 keeps, key 2 rejects. Reject: wrong colors, a tail or whiskers where none belong, a different face, profile, a frame. We only spotted the tail at full size.'),
    t('Lieber wenige gute als viele gemischte: Unsere Happy-LoRA traf die Figur mit 17 Bildern. Fehler lernt die LoRA mit.',
      'Better a few good ones than many mixed ones: our Happy LoRA matched the character with 17 images. The LoRA learns mistakes too.'),
  ],
  [
    t('Vorgabe 20 Epochen, Lernrate 2e-4, Rang 16, Alpha 16: Unsere Somi-LoRAs trafen die Figur ab Epoche 15 bei Stärke 1 (mit 1e-4 erst bei 2,5).',
      'Preset 20 epochs, learning rate 2e-4, rank 16, alpha 16: our Somi LoRAs matched the character from epoch 15 on at strength 1 (with 1e-4 only at 2.5).'),
    t('Die Grafikkarte ist 1,5 bis 2,5 h belegt. Nachts planen: Bis zum Start lässt sich weiter aussortieren, es zählen die Bilder beim Start. Beim Einsatz die Farben im Prompt nennen, sonst kamen die Ohren oft rosa.',
      'The graphics card is busy for 1.5 to 2.5 h. Schedule it for the night: you can keep sorting until the start, the images at the start count. When using it, name the colors in the prompt, otherwise the ears often came out pink.'),
  ],
]

/** Auslösewort aus dem Namen: je Wort der erste Buchstabe und der nächste Mitlaut, dazu 1 („Somi Happy“ → smhp1) */
export function suggestTrigger(name: string): string {
  const words = name.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').split(/[^a-z0-9]+/).filter(Boolean)
  let s = words.map((w) => w[0] + (w.slice(1).match(/[bcdfghjklmnpqrstvwxz]/)?.[0] ?? '')).join('')
  if (s.length < 3) s = (s + 'lra').slice(0, 3)
  return `${s.slice(0, 12)}1`
}

function nextNight(hhmm: string): number {
  const [h, m] = hhmm.split(':').map((x) => Number(x) || 0)
  const d = new Date()
  d.setHours(h, m, 0, 0)
  if (d.getTime() < Date.now() + 60_000) d.setDate(d.getDate() + 1)
  return Math.round(d.getTime() / 1000)
}

function firstOpenStep(ds: LoraDataset | null, minImages: number): Step {
  if (!ds) return 0
  if (!ds.template) return 1
  const keep = ds.images.filter((im) => im.status !== 'reject').length
  if (ds.images.length < Math.max(minImages, 20)) return 2
  return keep >= minImages ? 3 : 2
}

export function LoraWizard({ st, ds, genProgress, onCreated, onReload, onJob, onTrainStarted, onCancel, setViewer, initialStep }: {
  st: LoraTrainStatus
  ds: LoraDataset | null
  genProgress: (Progress & { id: string }) | null
  onCreated: (id: string) => void
  onReload: () => void
  onJob: (job: Job) => void
  onTrainStarted: (runId: string) => void
  onCancel: (id: string) => void
  setViewer: (v: Viewer) => void
  /** Schritt beim Öffnen (0 bis 4); sonst der erste offene */
  initialStep?: number
}) {
  const [step, setStep] = useState<Step>(() => (initialStep != null && ds ? Math.max(0, Math.min(4, initialStep)) as Step : firstOpenStep(ds, st.min_images)))
  const [form, setForm] = useState({ name: ds?.name ?? '', trigger: ds?.trigger ?? '', class_word: ds?.class_word ?? '', notes: ds?.notes ?? '' })
  const [triggerTouched, setTriggerTouched] = useState(Boolean(ds))
  const [picker, setPicker] = useState<'sketch' | 'images' | null>(null)
  const [folder, setFolder] = useState('')
  const [draftCount, setDraftCount] = useState(4)
  const [imageCount, setImageCount] = useState(24)
  const [moreCount, setMoreCount] = useState(6)
  const [selected, setSelected] = useState<string[]>([])
  const [hideRejected, setHideRejected] = useState(false)
  const [settings, setSettings] = useState({ ...st.defaults })
  const [test, setTest] = useState(true)
  const [prompts, setPrompts] = useState<string[]>(st.test_prompts)
  const [when, setWhen] = useState<'now' | 'night'>('night')
  const [nightTime, setNightTime] = useState('02:00')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const sketchInput = useRef<HTMLInputElement>(null)
  const imagesInput = useRef<HTMLInputElement>(null)

  useEffect(() => {
    setForm({ name: ds?.name ?? '', trigger: ds?.trigger ?? '', class_word: ds?.class_word ?? '', notes: ds?.notes ?? '' })
  }, [ds?.id, ds?.name, ds?.trigger, ds?.class_word, ds?.notes]) // eslint-disable-line react-hooks/exhaustive-deps

  const images = ds?.images ?? []
  const keep = images.filter((im) => im.status !== 'reject')
  const rejected = images.filter((im) => im.status === 'reject')
  const rejectedTemplate = rejected.filter((im) => im.pose != null)
  const drafts = ds?.drafts ?? []
  const posesDone = new Set(images.filter((im) => im.pose != null).map((im) => im.pose))
  const posesOpen = st.poses.length - posesDone.size
  useEffect(() => { setImageCount(posesOpen > 0 ? posesOpen : st.poses.length) }, [posesOpen, st.poses.length])
  useEffect(() => { setSelected((sel) => sel.filter((f) => images.some((im) => im.file === f))) }, [images.length]) // eslint-disable-line react-hooks/exhaustive-deps

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
    if (!ds) return
    if ((form[key] ?? '') === ((ds as unknown as Record<string, string>)[key] ?? '')) return
    run(() => api.loraDatasetUpdate(ds.id, { [key]: form[key] }))
  }
  const create = () => run(async () => {
    const d = await api.loraDatasetCreate({ ...form, name: form.name || form.trigger })
    onCreated(d.id)
    setStep(1)
  })
  // Ein Array, keine FileList: Die Liste des Eingabefelds ist lebendig und leer, sobald value = '' gesetzt ist
  const upload = async (files: File[]): Promise<string[]> => {
    const ids: string[] = []
    for (const f of files) ids.push((await api.upload(f)).id)
    return ids
  }
  const fileUrl = (name: string) => (ds ? `${loraFileUrl('datasets', ds.id, name)}?v=${ds.updated ?? 0}` : '')
  const showImages = (list: LoraTrainImage[], index: number, sorting: boolean) => {
    if (!ds) return
    setViewer({
      urls: list.map((im) => loraFileUrl('datasets', ds.id, im.file)),
      labels: list.map((im) => im.caption || im.file),
      index,
      ...(sorting ? {
        marks: list.map((im) => (im.status === 'reject' ? 'reject' : 'keep')),
        onMark: (i: number, status: 'keep' | 'reject') => { api.loraImageUpdate(ds.id, list[i].file, { status }).then(onReload).catch(() => {}) },
      } : {}),
    })
  }
  const genBusy = Boolean(genProgress)
  const progressBar = genProgress && (
    <div className="lt-progress">
      <div className="progress"><div className="bar" style={{ width: `${Math.round(genProgress.progress * 100)}%` }} /></div>
      <span className="muted small">{genProgress.stage}</span>
      <button className="btn small ghost danger-text" onClick={() => onCancel(genProgress.id)}>{t('Abbrechen', 'Cancel')}</button>
    </div>
  )
  const missingEdit = !st.template_ready && (
    <p className="hint small warn">{t('Für Entwürfe und Bilder fehlt das Vorlagen-Modell (oben unter „Einrichten“).', 'The template model for drafts and images is missing (see “Set up” above).')}</p>
  )

  // Fortschritt je Schritt für die Leiste oben
  const stepNote = [
    ds ? <code key="t">{ds.trigger}</code> : t('neu', 'new'),
    ds?.template ? t('gewählt', 'chosen') : drafts.length ? t(`${drafts.length} Entwürfe`, `${drafts.length} drafts`) : '–',
    images.length ? t(`${images.length} Bilder`, `${images.length} images`) : '–',
    images.length ? t(`${keep.length} behalten`, `${keep.length} kept`) : '–',
    (() => {
      const r = ds ? st.runs.find((x) => x.dataset_id === ds.id) : undefined
      return r ? STATUS_LABEL[r.status] ?? r.status : '–'
    })(),
  ]
  const done = [Boolean(ds), Boolean(ds?.template), images.length >= 20, keep.length >= st.min_images && images.length > 0,
    Boolean(ds && st.runs.some((x) => x.dataset_id === ds.id))]

  const steps = keep.length * settings.epochs
  const ckpts = Math.max(1, Math.floor(settings.epochs / Math.max(1, settings.save_every)))
  const estimate = steps * st.timing.seconds_per_step + keep.length * st.timing.te_seconds_per_caption + 60
    + (test ? (ckpts + 1) * prompts.filter((p) => p.trim()).length * st.timing.test_seconds_per_image : 0)
  const dsRuns = ds ? st.runs.filter((r) => r.dataset_id === ds.id) : []

  return (
    <div className="lw">
      <ol className="lw-steps">
        {STEPS.map((s, i) => (
          <li key={i}>
            <button className={`lw-step${i === step ? ' on' : ''}${done[i] ? ' done' : ''}`} disabled={!ds && i > 0}
              onClick={() => setStep(i as Step)}>
              <span className="lw-num">{done[i] && i !== step ? '✓' : i + 1}</span>
              <span className="lw-step-text"><strong>{s.short}</strong><span className="muted small">{stepNote[i]}</span></span>
            </button>
          </li>
        ))}
      </ol>

      <div className="lw-body">
        <div className="lw-main">
          <h3>{t(`Schritt ${step + 1}: `, `Step ${step + 1}: `)}{STEPS[step].title}</h3>

          {step === 0 && (
            <>
              <div className="lt-fields">
                <label>{t('Name', 'Name')}<input value={form.name} placeholder={t('z. B. Somi Happy', 'e.g. Somi Happy')}
                  onChange={(e) => setForm({ ...form, name: e.target.value, trigger: triggerTouched ? form.trigger : suggestTrigger(e.target.value) })}
                  onBlur={() => saveField('name')} /></label>
                <label>{t('Auslösewort', 'Trigger word')}<input value={form.trigger} placeholder="smhp1"
                  onChange={(e) => { setTriggerTouched(true); setForm({ ...form, trigger: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_') }) }}
                  onBlur={() => saveField('trigger')} /></label>
                <label>{t('Gattung (englisch)', 'Class (English)')}<input value={form.class_word} placeholder="a cartoon rabbit"
                  onChange={(e) => setForm({ ...form, class_word: e.target.value })} onBlur={() => saveField('class_word')} /></label>
              </div>
              <label className="lw-label">{t('Beschreibung der Figur (englisch): was gleich bleiben muss', 'Description of the character (English): what has to stay the same')}
                <textarea rows={5} value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} onBlur={() => saveField('notes')}
                  placeholder="A white cartoon creature with no neck: the wide head flows straight into a plump, pear-shaped body. Two thick ears with rounded tips. The insides of the ears and the nose are bright blue, everything else is black, white and grey. No whiskers, no tail." />
              </label>
              <p className="hint small">
                {t('Die Beschreibung geht in jeden Entwurf und jedes Bild aus der Vorlage. In der Bildbeschreibung je Bild steht später nur, was sich ändert (Haltung, Ausschnitt, Hintergrund).',
                  'The description goes into every draft and every image from the template. Each image caption later names only what changes (pose, framing, background).')}
              </p>
              {!ds && (
                <div className="lt-toolbar">
                  <button className="btn primary" disabled={busy || form.trigger.length < 3} onClick={create}>{t('Anlegen und weiter', 'Create and continue')}</button>
                </div>
              )}
            </>
          )}

          {step === 1 && ds && (
            <>
              <div className="lw-row">
                <div className="lw-sketch">
                  {ds.sketch
                    ? <img src={fileUrl(ds.sketch)} alt={t('Ausgangsbild', 'Starting image')}
                        onClick={() => setViewer({ urls: [fileUrl(ds.sketch!)], labels: [t('Ausgangsbild', 'Starting image')], index: 0 })} />
                    : <span className="muted small">{t('kein Ausgangsbild', 'no starting image')}</span>}
                </div>
                <div className="lw-col">
                  <strong>{t('Ausgangsbild: Skizze, Foto oder Bild der Figur', 'Starting image: sketch, photo or image of the character')}</strong>
                  <div className="lt-toolbar">
                    <button className="btn small" disabled={busy} onClick={() => sketchInput.current?.click()}>{t('Vom Rechner …', 'From this computer …')}</button>
                    <input ref={sketchInput} type="file" accept="image/png,image/jpeg,image/webp" hidden
                      onChange={(e) => { const f = Array.from(e.target.files ?? []); e.target.value = ''; if (f.length) run(async () => api.loraDatasetSketch(ds.id, (await upload(f))[0])) }} />
                    <button className="btn small" disabled={busy} onClick={() => setPicker('sketch')}>{t('Aus dem Verlauf …', 'From the history …')}</button>
                    {ds.sketch && (
                      <button className={`btn small${ds.template_from === ds.sketch ? ' on' : ''}`} disabled={busy}
                        title={t('Wenn das Ausgangsbild schon eine fertige Zeichnung der Figur ist', 'If the starting image already is a finished drawing of the character')}
                        onClick={() => run(() => api.loraTemplatePick(ds.id, ds.sketch!))}>{t('Direkt als Vorlage', 'Use as template directly')}</button>
                    )}
                  </div>
                  <p className="hint small">
                    {ds.notes
                      ? t(`Beschreibung: ${ds.notes.slice(0, 160)}${ds.notes.length > 160 ? ' …' : ''}`, `Description: ${ds.notes.slice(0, 160)}${ds.notes.length > 160 ? ' …' : ''}`)
                      : t('Noch keine Beschreibung: Sie hilft jedem Entwurf (Schritt 1).', 'No description yet: it helps every draft (step 1).')}
                    {' '}<button className="linklike" onClick={() => setStep(0)}>{t('ändern', 'change')}</button>
                  </p>
                  {genProgress ? progressBar : (
                    <div className="lt-toolbar">
                      <input type="number" className="lt-num" min={1} max={12} value={draftCount} onChange={(e) => setDraftCount(Math.max(1, Math.min(12, Number(e.target.value) || 1)))} />
                      <button className="btn small primary" disabled={busy || genBusy || !st.template_ready || (!ds.sketch && !ds.notes)}
                        onClick={() => run(async () => onJob(await api.loraDatasetDrafts(ds.id, { count: draftCount })))}>
                        {t(`${draftCount} Entwürfe erzeugen (rund ${fmtDuration(draftCount * st.timing.edit_seconds_per_image)})`,
                          `Generate ${draftCount} drafts (about ${fmtDuration(draftCount * st.timing.edit_seconds_per_image)})`)}
                      </button>
                    </div>
                  )}
                  {missingEdit}
                </div>
              </div>
              {drafts.length > 0 && (
                <>
                  <div className="lt-grid-head">
                    <h4>{t(`Entwürfe (${drafts.length}): einen als Vorlage wählen`, `Drafts (${drafts.length}): choose one as the template`)}</h4>
                    <button className="btn small ghost" disabled={busy}
                      onClick={() => run(() => api.loraDatasetDraftsClear(ds.id, ds.template_from ?? undefined))}>
                      {t('Übrige Entwürfe verwerfen', 'Discard the other drafts')}
                    </button>
                  </div>
                  <div className="lw-drafts">
                    {drafts.map((d, i) => (
                      <figure key={d.file} className={`lw-draft${ds.template_from === d.file ? ' on' : ''}`}>
                        <img src={fileUrl(d.file)} alt={d.file} loading="lazy"
                          onClick={() => setViewer({ urls: drafts.map((x) => fileUrl(x.file)), labels: drafts.map((x) => x.file), index: i })} />
                        <figcaption>
                          <span className="muted small">{d.file}</span>
                          {ds.template_from === d.file
                            ? <span className="lt-status done">{t('Vorlage', 'template')}</span>
                            : <button className="btn small" disabled={busy} onClick={() => run(() => api.loraTemplatePick(ds.id, d.file))}>{t('Als Vorlage', 'Use as template')}</button>}
                        </figcaption>
                      </figure>
                    ))}
                  </div>
                </>
              )}
              {ds.template && !drafts.some((d) => d.file === ds.template_from) && ds.template_from !== ds.sketch && (
                <p className="hint small">{t('Vorlage gesetzt.', 'Template set.')}
                  <img className="lw-mini" src={fileUrl(ds.template)} alt="" /></p>
              )}
            </>
          )}

          {step === 2 && ds && (
            <>
              <div className="lw-row">
                <div className="lw-sketch">
                  {ds.template ? <img src={fileUrl(ds.template)} alt={t('Vorlage', 'Template')}
                    onClick={() => setViewer({ urls: [fileUrl(ds.template!)], labels: [t('Vorlage', 'Template')], index: 0 })} />
                    : <span className="muted small">{t('keine Vorlage', 'no template')}</span>}
                </div>
                <div className="lw-col">
                  <strong>{t('Aus der Vorlage erzeugen', 'Generate from the template')}</strong>
                  {genProgress ? progressBar : (
                    <div className="lt-toolbar">
                      <input type="number" className="lt-num" min={1} max={st.poses.length} value={imageCount}
                        onChange={(e) => setImageCount(Math.max(1, Math.min(st.poses.length, Number(e.target.value) || 1)))} />
                      <button className="btn small primary" disabled={busy || genBusy || !ds.template || !st.template_ready}
                        onClick={() => run(async () => onJob(await api.loraDatasetGenerate(ds.id, { count: imageCount })))}>
                        {t(`${imageCount} Bilder erzeugen (rund ${fmtDuration(imageCount * st.timing.edit_seconds_per_image)})`,
                          `Generate ${imageCount} images (about ${fmtDuration(imageCount * st.timing.edit_seconds_per_image)})`)}
                      </button>
                      {!ds.template && <span className="hint small warn">{t('Erst eine Vorlage wählen (Schritt 2).', 'Choose a template first (step 2).')}</span>}
                    </div>
                  )}
                  <strong>{t('Eigene Bilder hinzufügen', 'Add images of your own')}</strong>
                  <div className="lt-toolbar">
                    <button className="btn small" disabled={busy} onClick={() => imagesInput.current?.click()}>{t('Vom Rechner …', 'From this computer …')}</button>
                    <input ref={imagesInput} type="file" accept="image/png,image/jpeg,image/webp" multiple hidden
                      onChange={(e) => { const f = Array.from(e.target.files ?? []); e.target.value = ''; if (f.length) run(async () => api.loraDatasetAddAssets(ds.id, await upload(f))) }} />
                    <button className="btn small" disabled={busy} onClick={() => setPicker('images')}>{t('Aus dem Verlauf …', 'From the history …')}</button>
                    <input className="lt-folder" value={folder} onChange={(e) => setFolder(e.target.value)} placeholder={t('Ordner mit Bildern und .txt (kohya) …', 'Folder with images and .txt (kohya) …')} />
                    <button className="btn small" disabled={busy || !folder.trim()} onClick={() => run(() => api.loraDatasetAddFolder(ds.id, folder))}>{t('Ordner übernehmen', 'Add folder')}</button>
                  </div>
                  {missingEdit}
                </div>
              </div>
              <div className="lt-grid-head">
                <h4>{t(`Bilder: ${images.length} (Ziel 20 bis 30)`, `Images: ${images.length} (aim for 20 to 30)`)}</h4>
                <div className="lt-toolbar">
                  <span className="muted small">{t(`${selected.length} ausgewählt`, `${selected.length} selected`)}</span>
                  {selected.length > 0 && <button className="btn small ghost" onClick={() => setSelected([])}>{t('Auswahl leeren', 'Clear selection')}</button>}
                  <input type="number" className="lt-num" min={1} max={24} value={moreCount} onChange={(e) => setMoreCount(Math.max(1, Math.min(24, Number(e.target.value) || 1)))} />
                  <button className="btn small primary" disabled={busy || genBusy || !selected.length || !st.template_ready}
                    onClick={() => run(async () => onJob(await api.loraDatasetGenerate(ds.id, { count: moreCount, sources: selected })))}>
                    {t(`${moreCount} weitere aus der Auswahl erzeugen`, `Generate ${moreCount} more from the selection`)}
                  </button>
                </div>
              </div>
              <div className="lt-images lw-images">
                {images.map((im, i) => (
                  <figure key={im.file} className={`lt-image${im.status === 'reject' ? ' rejected' : ''}${selected.includes(im.file) ? ' sel' : ''}`}>
                    <img src={loraFileUrl('datasets', ds.id, im.file)} alt={im.caption} loading="lazy" onClick={() => showImages(images, i, false)} />
                    <label className="lw-tick" title={t('für „weitere aus der Auswahl“', 'for “more from the selection”')}>
                      <input type="checkbox" checked={selected.includes(im.file)}
                        onChange={(e) => setSelected((sel) => (e.target.checked ? [...sel, im.file] : sel.filter((f) => f !== im.file)))} />
                    </label>
                    <figcaption><span className="muted small" title={im.caption}>{im.caption || im.file}</span></figcaption>
                  </figure>
                ))}
              </div>
            </>
          )}

          {step === 3 && ds && (
            <>
              <div className="lt-grid-head">
                <h4>{t(`${keep.length} behalten, ${rejected.length} aussortiert`, `${keep.length} kept, ${rejected.length} rejected`)}</h4>
                <div className="lt-toolbar">
                  {images.length > 0 && (
                    <button className="btn small primary" onClick={() => showImages(images, 0, true)}>{t('Alle in voller Größe durchgehen', 'Go through all at full size')}</button>
                  )}
                  {rejectedTemplate.length > 0 && !genProgress && (
                    <button className="btn small" disabled={busy || genBusy || !ds.template || !st.template_ready}
                      onClick={() => run(async () => onJob(await api.loraDatasetGenerate(ds.id, { replace: rejectedTemplate.map((im) => im.file) })))}>
                      {t(`Ersatz für ${rejectedTemplate.length} aussortierte`, `Replace ${rejectedTemplate.length} rejected`)}
                    </button>
                  )}
                  <label className="check small"><input type="checkbox" checked={hideRejected} onChange={(e) => setHideRejected(e.target.checked)} />{t('Aussortierte ausblenden', 'Hide rejected')}</label>
                </div>
              </div>
              {progressBar}
              <div className="lt-images">
                {(hideRejected ? keep : images).map((im) => {
                  const list = hideRejected ? keep : images
                  return (
                    <figure key={im.file} className={`lt-image${im.status === 'reject' ? ' rejected' : ''}`}>
                      <img src={loraFileUrl('datasets', ds.id, im.file)} alt={im.caption} loading="lazy" onClick={() => showImages(list, list.indexOf(im), true)} />
                      <figcaption>
                        <CaptionField key={`${im.file}-${im.caption}`} value={im.caption} onSave={(caption) => run(() => api.loraImageUpdate(ds.id, im.file, { caption }))} />
                        <div className="lt-image-actions">
                          <button className={`btn small${im.status !== 'reject' ? ' on' : ''}`} title={t('behalten', 'keep')} onClick={() => run(() => api.loraImageUpdate(ds.id, im.file, { status: 'keep' }))}>✓</button>
                          <button className={`btn small${im.status === 'reject' ? ' off' : ''}`} title={t('aussortieren', 'reject')} onClick={() => run(() => api.loraImageUpdate(ds.id, im.file, { status: 'reject' }))}>✕</button>
                          {im.license_note && <span className="hint small warn" title={im.license_note}>⚠</span>}
                          <button className="btn small ghost danger-text" title={t('aus dem Datensatz löschen', 'delete from the dataset')}
                            onClick={() => run(() => api.loraImageDelete(ds.id, im.file))}>{t('Löschen', 'Delete')}</button>
                        </div>
                      </figcaption>
                    </figure>
                  )
                })}
              </div>
            </>
          )}

          {step === 4 && ds && (
            <>
              <p>{t(`${keep.length} Bilder im Training, ${steps} Schritte, rund ${fmtDuration(estimate)}${test ? ' samt Probebildern' : ''}.`,
                `${keep.length} images in training, ${steps} steps, about ${fmtDuration(estimate)}${test ? ' including test images' : ''}.`)}</p>
              <details className="lw-details">
                <summary>{t(`Einstellungen: ${settings.epochs} Epochen, Lernrate ${settings.lr}, Rang ${settings.rank}, Alpha ${settings.alpha}, Zwischenstand alle ${settings.save_every}`,
                  `Settings: ${settings.epochs} epochs, learning rate ${settings.lr}, rank ${settings.rank}, alpha ${settings.alpha}, checkpoint every ${settings.save_every}`)}</summary>
                <div className="lt-fields">
                  <label>{t('Epochen', 'Epochs')}<input type="number" min={1} max={100} value={settings.epochs} onChange={(e) => setSettings({ ...settings, epochs: Number(e.target.value) || 1 })} /></label>
                  <label>{t('Lernrate', 'Learning rate')}<input value={settings.lr} onChange={(e) => setSettings({ ...settings, lr: e.target.value })} /></label>
                  <label>{t('Rang', 'Rank')}<input type="number" min={4} max={128} value={settings.rank} onChange={(e) => {
                    const rank = Number(e.target.value) || 16
                    setSettings({ ...settings, rank, alpha: settings.alpha === settings.rank ? rank : settings.alpha })
                  }} /></label>
                  <label>{t('Alpha', 'Alpha')}<input type="number" min={0.5} max={256} step={0.5} value={settings.alpha} onChange={(e) => setSettings({ ...settings, alpha: Number(e.target.value) || settings.rank })} /></label>
                  <label>{t('Zwischenstand alle … Epochen', 'Checkpoint every … epochs')}<input type="number" min={1} max={100} value={settings.save_every} onChange={(e) => setSettings({ ...settings, save_every: Number(e.target.value) || 1 })} /></label>
                </div>
                <button className="btn small ghost" onClick={() => setSettings({ ...st.defaults })}>{t('Empfohlene Werte', 'Recommended values')}</button>
              </details>
              <label className="check small"><input type="checkbox" checked={test} onChange={(e) => setTest(e.target.checked)} />
                {t('Danach Probebilder je Zwischenstand (gleicher Seed, dazu ohne LoRA)', 'Then test images per checkpoint (same seed, plus without LoRA)')}</label>
              {test && prompts.map((p, i) => (
                <input key={i} className="lt-prompt" value={p} onChange={(e) => setPrompts(prompts.map((x, j) => (j === i ? e.target.value : x)))}
                  placeholder={t('Probe-Prompt (Auslösewort und Gattung kommen davor)', 'Test prompt (trigger word and class go in front)')} />
              ))}
              <div className="lw-when">
                <label className="check"><input type="radio" checked={when === 'now'} onChange={() => setWhen('now')} />{t('Jetzt starten', 'Start now')}</label>
                <label className="check"><input type="radio" checked={when === 'night'} onChange={() => setWhen('night')} />
                  {t('Vormerken für', 'Schedule for')} <input type="time" value={nightTime} onChange={(e) => { setNightTime(e.target.value); setWhen('night') }} />
                  <span className="muted small">({fmtTime(nextNight(nightTime))})</span></label>
              </div>
              <div className="lt-toolbar">
                <button className="btn primary" disabled={busy || !st.ready || keep.length < st.min_images}
                  onClick={() => run(async () => {
                    const r = await api.loraTrain(ds.id, { ...settings, test, prompts: prompts.filter((p) => p.trim()),
                      ...(when === 'night' ? { start_at: nextNight(nightTime) } : {}) })
                    if ('scheduled' in r) {
                      setMessage(t(`Vorgemerkt: Das Training startet am ${fmtTime(r.start_at)}, sobald NVAI-open läuft. Bis dahin lässt sich weiter aussortieren.`,
                        `Scheduled: the training starts on ${fmtTime(r.start_at)}, as soon as NVAI-open is running. Until then you can keep sorting.`))
                      onTrainStarted(r.id)
                    } else {
                      onJob(r)
                      if (typeof r.params?.run_id === 'string') onTrainStarted(r.params.run_id)
                    }
                  })}>
                  {when === 'night'
                    ? t(`Training für ${nightTime} Uhr vormerken`, `Schedule training for ${nightTime}`)
                    : t(`Training starten (rund ${fmtDuration(estimate)})`, `Start training (about ${fmtDuration(estimate)})`)}
                </button>
                {!st.ready && <span className="hint small warn">{t('Erst oben einrichten.', 'Set up above first.')}</span>}
                {st.ready && keep.length < st.min_images && <span className="hint small warn">{t(`Mindestens ${st.min_images} Bilder (gut sind 20 bis 30).`, `At least ${st.min_images} images (20 to 30 work well).`)}</span>}
              </div>
              {dsRuns.length > 0 && (
                <div className="lw-runs">
                  <h4>{t('Trainings mit diesem Datensatz', 'Trainings with this dataset')}</h4>
                  {dsRuns.map((r) => (
                    <button key={r.id} className="lt-run-row" onClick={() => onTrainStarted(r.id)}>
                      <strong>{r.name}</strong><code>{r.id}</code>
                      <span className="muted small">{r.status === 'scheduled' ? t(`Start ${fmtTime(r.start_at)}`, `starts ${fmtTime(r.start_at)}`) : `${r.checkpoints.length} ${t('Zwischenstände', 'checkpoints')}`}</span>
                      <span className={`lt-status ${r.status}`}>{STATUS_LABEL[r.status] ?? r.status}</span>
                    </button>
                  ))}
                </div>
              )}
            </>
          )}

          {message && <p className="hint">{message}</p>}
          {error && <p className="error">{error}</p>}

          <div className="lw-nav">
            <button className="btn" disabled={step === 0} onClick={() => setStep((step - 1) as Step)}>← {t('Zurück', 'Back')}</button>
            {step < 4 && (
              <button className="btn" disabled={!ds} onClick={() => setStep((step + 1) as Step)}>{t('Weiter', 'Next')} →</button>
            )}
          </div>
        </div>

        <aside className="lw-tip">
          <strong>{t('Empfehlung', 'Recommendation')}</strong>
          {TIPS[step].map((tip, i) => <p key={i}>{tip}</p>)}
        </aside>
      </div>

      {picker && ds && (
        <AssetPicker multiple={picker === 'images'}
          title={picker === 'sketch' ? t('Ausgangsbild aus dem Verlauf', 'Starting image from the history') : undefined}
          onClose={() => setPicker(null)}
          onPick={(ids) => { const p = picker; setPicker(null); run(() => (p === 'images' ? api.loraDatasetAddAssets(ds.id, ids) : api.loraDatasetSketch(ds.id, ids[0]))) }} />
      )}
    </div>
  )
}
