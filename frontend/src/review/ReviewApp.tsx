import { useEffect, useRef, useState } from 'react'
import { type AudioProject, type AudioStatus } from '../api'
import { Workspace } from '../forensic/Workspace'
import { getLang, onLang, setLangLive, t, type Lang } from '../i18n'
import { closePackage, dirSource, httpSource, installFetch, logEntry, openPackage, type Pkg } from './local'
import { nativeBridge, nativeOpen } from './native'

// Rahmen der Prüf-App: Startseite (Name, Fall öffnen, Sprache), danach die Arbeitsfläche der Ton-Forensik im Player-Modus
// mit dem Fall aus dem Ordner. Plan: notizen/pruef-player.md. In der Mac-App (Bereich „Ton-Forensik“) öffnet deren
// Dialog den Ordner, und ihr Server liefert das Paket (native.ts).

const ORIG_FETCH = window.fetch.bind(window)
const AUTHOR_KEY = 'nvai.forensic.author'
const STATUS: AudioStatus = { root: '', models_dir: '', env_ready: false, env: '', nvidia: false, free_gb: 0, models: [], recommended: {},
  projects: [], tasks: {} } as unknown as AudioStatus
const noop = () => {}

function storeName(n: string): void {
  try {
    if (n) localStorage.setItem(AUTHOR_KEY, n)
    else localStorage.removeItem(AUTHOR_KEY)
  } catch { /* ohne Speicher */ }
}

export function ReviewApp() {
  const [pkg, setPkg] = useState<Pkg | null>(null)
  const [proj, setProj] = useState<AudioProject | null>(null)
  const [name, setName] = useState(() => { try { return localStorage.getItem(AUTHOR_KEY) ?? '' } catch { return '' } })
  // Name oben rechts, jederzeit änderbar (Nutzer 18.11.: „ober rechts soll ich den Namen von dem Bearbeiter ändern
  // können“); jeder Wechsel steht im Prüfprotokoll
  const [nameDraft, setNameDraft] = useState(name)
  const escaped = useRef(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [lang, setLangState] = useState<Lang>(getLang())
  useEffect(() => onLang(setLangState), [])
  const langSwitch = (
    <span className="rv-langs">
      {(['de', 'en'] as const).map((l) => (
        <button key={l} className={`btn small${lang === l ? ' primary' : ' ghost'}`} onClick={() => setLangLive(l)}
          title={l === 'de' ? 'Deutsch' : 'English'}>{l.toUpperCase()}</button>
      ))}
    </span>
  )
  const native = nativeBridge() !== null
  const canPick = native || typeof (window as unknown as { showDirectoryPicker?: unknown }).showDirectoryPicker === 'function'

  const reviewer = (): string => {
    const n = name.trim()
    if (n) storeName(n)
    return n
  }
  const start = async (make: () => Promise<Pkg>) => {
    setError('')
    setBusy(true)
    try {
      const p = await make()
      installFetch(p, ORIG_FETCH)
      document.title = `${p.project.name} · ${t('NVAI-open Prüf-App', 'NVAI-open review app')}`
      setNameDraft(p.reviewer)
      setPkg(p)
      setProj(p.project)
    } catch (e) {
      if ((e as DOMException)?.name !== 'AbortError') setError(String((e as Error).message ?? e))
    } finally {
      setBusy(false)
    }
  }
  const openFolder = () => start(async () => {
    if (native) return openPackage(httpSource(await nativeOpen(), ORIG_FETCH, true), reviewer())
    const pick = (window as unknown as { showDirectoryPicker: (o: unknown) => Promise<FileSystemDirectoryHandle> }).showDirectoryPicker
    return openPackage(dirSource(await pick({ id: 'nvai-pruefpaket', mode: 'readwrite' })), reviewer())
  })
  const close = () => {
    if (pkg) closePackage(pkg)
    // In der Mac-App führt ← zur Fallliste des Bereichs „Ton-Forensik“ (seit Mac 0.5.11); sonst Startseite neu laden
    const bridge = nativeBridge()
    if (bridge) void bridge.postMessage({ op: 'close' })
    else location.reload()
  }
  // Testweg über einen Webserver: NVAI-Pruefer.html?paket=<Adresse des Paketordners> (nur lesen); in der Mac-App mit
  // &schreiben=1 (ihr Server nimmt Änderungen für „bearbeitung/“ an, Prüfstand `--review-package`)
  useEffect(() => {
    const params = new URLSearchParams(location.search)
    const q = params.get('paket')
    if (q !== null) void start(() => openPackage(httpSource(q || './', ORIG_FETCH, native && params.get('schreiben') === '1'), reviewer()))
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const commitName = async () => {
    if (!pkg) return
    const n = nameDraft.trim()
    setNameDraft(n)
    if (n === pkg.reviewer) return
    const before = pkg.reviewer
    pkg.reviewer = n
    setName(n)
    storeName(n)
    try {
      await logEntry(pkg, 'pruefer', { alt: before, neu: n })
      setNotice(n ? t(`Bearbeiter: ${n}. Neue Notizen und das Prüfprotokoll tragen ab jetzt diesen Namen.`, `Reviewer: ${n}. New notes and the review log carry this name from now on.`)
        : t('Bearbeiter ohne Namen.', 'Reviewer without a name.'))
    } catch (e) {
      setError(String((e as Error).message ?? e))
    }
  }

  if (!pkg || !proj) {
    return (
      <div className="rv-start">
        <div className="rv-start-box panel">
          <div className="rv-lang">{langSwitch}</div>
          <h1>NVAI-open · {t('Prüf-App', 'review app')}</h1>
          <p>{t('Öffnet einen Fall, den NVAI-open als Prüfpaket exportiert hat: alle Spuren zum Anhören, die Übersetzer-Spur mit allen Übersetzungen, Notizen, Ereignisse und Schiffsdaten. Ohne KI, ohne Internet, ohne Installation.',
            'Opens a case that NVAI-open exported as a review package: all tracks to listen to, the translation track with all translations, notes, events and ship data. No AI, no internet, no installation.')}</p>
          <label className="rv-field">{t('Ihr Name (steht bei Notizen und im Prüfprotokoll, später oben rechts änderbar)', 'Your name (shown with notes and in the review log, can be changed later at the top right)')}
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder={t('z. B. Kanzlei, Name', 'e.g. firm, name')} /></label>
          {canPick ? (
            <button className="btn primary rv-open" disabled={busy} onClick={() => void openFolder()}>{busy ? t('Öffnet …', 'Opening …') : t('Fall öffnen …', 'Open case …')}</button>
          ) : (
            <p className="error">{t('Dieser Browser kann keine Ordner öffnen. Bitte die Datei NVAI-Pruefer.html in Microsoft Edge oder Google Chrome öffnen.',
              'This browser cannot open folders. Please open the file NVAI-Pruefer.html in Microsoft Edge or Google Chrome.')}</p>
          )}
          <p className="hint small">{native
            ? t('Im Dialog den Ordner des Prüfpakets wählen (den Ordner, in dem NVAI-Pruefer.html liegt). Ihre Änderungen (geprüfte Blöcke, Korrekturen, Notizen) speichert NVAI-open im Unterordner „bearbeitung“; die gelieferten Dateien bleiben unverändert und lassen sich mit PRUEFSUMMEN.sha256 prüfen.',
              'In the dialog, choose the folder of the review package (the folder that contains NVAI-Pruefer.html). NVAI-open saves your changes (checked blocks, corrections, notes) in the subfolder “bearbeitung”; the delivered files stay unchanged and can be verified with PRUEFSUMMEN.sha256.')
            : t('Im Dialog den Ordner des Prüfpakets wählen (den Ordner, in dem NVAI-Pruefer.html liegt) und das Bearbeiten erlauben. Ihre Änderungen (geprüfte Blöcke, Korrekturen, Notizen) speichert die App im Unterordner „bearbeitung“; die gelieferten Dateien bleiben unverändert und lassen sich mit PRUEFSUMMEN.sha256 prüfen.',
              'In the dialog, choose the folder of the review package (the folder that contains NVAI-Pruefer.html) and allow editing. Your changes (checked blocks, corrections, notes) are saved in the subfolder “bearbeitung”; the delivered files stay unchanged and can be verified with PRUEFSUMMEN.sha256.')}</p>
          {error && <p className="error">{error}</p>}
        </div>
      </div>
    )
  }
  // Ganzer Bildschirm für die Arbeit (Nutzer 18.11.: „braucht ja garkeine Leiste … es soll den maximalen platz nutzen“):
  // keine App-Leiste, Speicherort als Vermerk in der Kopfzeile, ← schließt den Fall; oben rechts Bearbeiter und Sprache
  const saved = pkg.source.canWrite
  const extra = (
    <span className={`au-chip${saved ? '' : ' warn'}`}
      title={saved ? t('Änderungen werden im Fallordner unter „bearbeitung“ gespeichert; die gelieferten Dateien bleiben unverändert.', 'Changes are saved in the case folder under “bearbeitung”; the delivered files stay unchanged.')
        : t('Nur lesen: Änderungen werden nicht gespeichert.', 'Read only: changes are not saved.')}>
      {saved ? t('speichert in „bearbeitung“', 'saves to “bearbeitung”') : t('nur lesen', 'read only')}
    </span>
  )
  const headerEnd = (
    <span className="rv-head-end">
      <label className="rv-name" title={t('Name des Bearbeiters: steht bei neuen Notizen und im Prüfprotokoll. Ein Wechsel wird im Protokoll vermerkt.',
        'Name of the reviewer: shown with new notes and in the review log. A change is recorded in the log.')}>
        {t('Bearbeiter', 'Reviewer')}
        <input value={nameDraft} onChange={(e) => setNameDraft(e.target.value)}
          onBlur={() => { if (escaped.current) escaped.current = false; else void commitName() }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') e.currentTarget.blur()
            if (e.key === 'Escape') { escaped.current = true; setNameDraft(pkg.reviewer); e.currentTarget.blur() }
          }}
          placeholder={t('Name eintragen', 'enter name')} />
      </label>
      {langSwitch}
    </span>
  )
  return (
    <div className="rv-app">
      {error && <p className="error fx-msg" onClick={() => setError('')}>{error}</p>}
      {notice && <p className="hint fx-msg" onClick={() => setNotice('')}>{notice}</p>}
      <Workspace st={STATUS} proj={proj} running={[]} progress={{}} paused={[]} active mode="player" event={null}
        onResume={noop} onDismiss={noop} onInstall={noop} setupBusy={false} onError={setError} onNotice={setNotice}
        onReload={() => setProj(pkg.project)} onDeleted={noop} onBack={close} headerExtra={extra} headerEnd={headerEnd} key={lang} />
    </div>
  )
}
