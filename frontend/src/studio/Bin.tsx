// Material (Nutzer 26.10.2026: „kompakter und aktueller ansicht, ich soll assets hier auch löschen können, genau so
// abspielen oder vorschau anzeigen wenn ich den anklicke“): alles aus dem Verlauf, neueste zuerst, als kompakte Liste
// oder als Kacheln, mit Filter und Suche. Fertige Aufträge, Hochladen und Löschen kommen live dazu. Ein Klick zeigt
// das Asset im Monitor und spielt es ab; Ziehen auf eine Spur legt einen Clip an, auf eine Szene einen Take. Rechtsklick
// (Nutzer 27.10.2026): an eine Spur senden, Speicherort öffnen, Datei öffnen, löschen. Löschen fragt im Knopf selbst
// nach (kein Browser-Dialog) und lässt, was im Schnitt liegt, stehen. Geladen werden je 100 (Nutzer 27.10.: „lädt nicht
// alle Assets … max 100, dann weitere 100. Suche soll alle durchsuchen“); Filter und Suche fragt der Server über alles.
//
// Ordner (seit 0.5.15, Nutzer 27.10.2026: „jedes Projekt in Studio soll einen eigenen Unterordner für seine Assets
// bekommen … neben dem Upload-Button brauche ich einen Ordner-Button, der Ordner einblendet oder ausblendet, ich kann
// mit dem ersten Ordner „..“ nach oben klettern, mit einem Doppelklick öffnet es den Ordner. Beim Wechseln des
// Projekts soll sein Projektordner automatisch öffnen“): Oben stehen die Projektordner, darunter der allgemeine
// Verlauf. Ausgeblendet fehlen nur die Ordnereinträge, die Liste bleibt im geöffneten Ordner (Nutzer: „es sollte schon
// da bleiben, wo das Projekt ist … oder den Ordner halt, den ich gerade benutze“); die Suche sucht immer überall.

import { useEffect, useRef, useState, type DragEvent as RDragEvent, type MouseEvent as RMouseEvent } from 'react'
import { api, fileUrl, type Asset, type AssetFolder } from '../api'
import { FolderIcon } from '../components/FolderIcon'
import { t } from '../i18n'
import type { MenuItem } from './ContextMenu'
import { ASSET_MIME } from './Timelines'
import { decimal } from './time'

type Filter = 'all' | 'image' | 'video' | 'audio'
type View = 'list' | 'grid'
// wie db.UPLOAD_VIDEO / UPLOAD_AUDIO auf dem Server
const VIDEO = /\.(mp4|webm|mov|mkv|avi|wmv|flv|mxf|mts|m2ts|ts|mpg|mpeg|m2v|vob|dv|m4v)$/i
const AUDIO = /\.(mp3|wav|flac|ogg|m4a|aac|opus)$/i
const KEY_VIEW = 'nvai-studio-bin-view'
const KEY_FOLDERS = 'nvai-studio-bin-folders'
const PAGE = 100

/** Uploads tragen keine Art; die Endung sagt sie. */
export function mediaKind(a: Asset): 'image' | 'video' | 'audio' | null {
  if (a.kind === 'image' || a.kind === 'video' || a.kind === 'audio') return a.kind
  if (a.kind !== 'upload') return null
  if (VIDEO.test(a.filename)) return 'video'
  if (AUDIO.test(a.filename)) return 'audio'
  return 'image'
}

const NO_BROWSER = /\.(mkv|mov|avi|wmv|flv|mxf|mts|m2ts|ts|mpg|mpeg|m2v|vob|dv)$/i

/** Was der Browser abspielt: die Datei selbst oder, bei MKV, MOV & Co., ihre H.264-Vorschau (meta.preview). FFV1
 * und ProRes spielt kein Browser; NVAI-open legt die Vorschau beim Export bzw. nach dem Hochladen an. */
export function previewUrl(a: Asset): string | null {
  if (a.meta?.preview) return fileUrl(a.meta.preview)
  return NO_BROWSER.test(a.filename) ? null : a.url
}

export function browserPlayable(a: Asset): boolean {
  return previewUrl(a) !== null
}

/** Beschriftung: der Prompt, bei Uploads der ursprüngliche Dateiname. */
export function assetLabel(a: Asset): string {
  return a.prompt || a.meta?.original_name || a.filename
}

/** Kurzangaben für die Liste: Länge und Größe, soweit bekannt. */
export function assetFacts(a: Asset): string[] {
  const m = a.meta ?? {}
  const facts: string[] = []
  const secs = m.duration_s ?? m.seconds
  if (typeof secs === 'number' && secs > 0) facts.push(`${decimal(secs.toFixed(1))} s`)
  if (m.width && m.height) facts.push(`${m.width}×${m.height}`)
  return facts
}

const KIND_ICON = { image: '▣', video: '▶', audio: '♪' }

/** Eine Ebene höher: Projektordner (Studio/<Name>) liegen in der Ansicht direkt unter der obersten Ebene. */
function parentOf(folder: string): string {
  const parts = folder.split('/')
  return parts.length <= 2 ? '' : parts.slice(0, -1).join('/')
}

function folderName(folder: string): string {
  return folder.split('/').pop() ?? folder
}

function stored(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function store(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* privates Fenster */
  }
}

/** Vorschaubild eines Videos, erst geladen, wenn es sichtbar wird (die Liste kann Hunderte enthalten). */
function VideoThumb({ url }: { url: string }) {
  const ref = useRef<HTMLVideoElement>(null)
  const [src, setSrc] = useState<string | undefined>(undefined)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        setSrc(`${url}#t=0.1`)
        io.disconnect()
      }
    })
    io.observe(el)
    return () => io.disconnect()
  }, [url])
  return <video ref={ref} src={src} preload="metadata" muted playsInline />
}

function Thumb({ a }: { a: Asset }) {
  const kind = mediaKind(a)
  if (kind === 'image') return <img src={a.thumb_url ?? a.url} alt="" draggable={false} loading="lazy" />
  const url = previewUrl(a)
  if (kind === 'video' && !url) return <span className="st-bin-audio st-bin-ext">{a.filename.split('.').pop()?.toUpperCase()}</span>
  if (kind === 'video') return <VideoThumb url={url!} />
  return <span className="st-bin-audio">♪</span>
}

interface Props {
  refreshKey: number
  selectedId: string | null
  /** Assets, die als Clip im Schnitt liegen: nicht löschbar */
  usedIds: Set<string>
  /** Das offene Projekt und sein Ordner: Beim Wechsel öffnet die Liste diesen Ordner */
  projectId: string
  home?: string
  onOpen: (a: Asset) => void
  onDeleted: (id: string) => void
  /** Einträge des Rechtsklick-Menüs, die das Studio beisteuert (an eine Spur senden …) */
  menuItems: (a: Asset) => MenuItem[]
  onMenu: (e: { clientX: number; clientY: number }, items: MenuItem[]) => void
}

export function Bin({ refreshKey, selectedId, usedIds, projectId, home, onOpen, onDeleted, menuItems, onMenu }: Props) {
  const [assets, setAssets] = useState<Asset[]>([])
  const [folders, setFolders] = useState<AssetFolder[]>([])
  const [filter, setFilter] = useState<Filter>('all')
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('') // die Suche mit kurzer Pause nach dem Tippen
  const [more, setMore] = useState(false) // liefert der Server noch weitere?
  const [loading, setLoading] = useState(false)
  const [view, setView] = useState<View>(() => (stored(KEY_VIEW) === 'grid' ? 'grid' : 'list'))
  const [showFolders, setShowFolders] = useState(() => stored(KEY_FOLDERS) !== '0')
  const [cwd, setCwd] = useState(home ?? '') // der geöffnete Ordner, '' = oberste Ebene
  const [picked, setPicked] = useState<string | null>(null) // markierter Ordner (oder '..')
  const [confirm, setConfirm] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const count = useRef(0) // wie viele geladen sind: beim Auffrischen nicht wieder auf 100 schrumpfen
  const ask = useRef(0) // nur die Antwort auf die letzte Anfrage zählt
  const lastHome = useRef(home)

  // Ordnereinträge („..“, Projektordner): nur eingeblendet und ohne Suche (die Suche sucht überall). Gelistet wird
  // immer der geöffnete Ordner, auch mit ausgeblendeten Ordnern.
  const inFolders = showFolders && !search

  /** Erste Seite neu (oder so viele wie schon geladen) bzw. die nächsten 100 dazu. */
  const load = (append: boolean, keep = false) => {
    const my = ++ask.current
    const offset = append ? count.current : 0
    const limit = append ? PAGE : keep ? Math.max(PAGE, Math.ceil(count.current / PAGE) * PAGE) : PAGE
    setLoading(true)
    if (!append && inFolders && cwd === '') {
      api.assetFolders().then((list) => my === ask.current && setFolders(list)).catch(() => {})
    }
    api
      .assetPage({ media: filter, q: search || undefined, folder: search ? undefined : cwd, limit, offset })
      .then((list) => {
        if (my !== ask.current) return
        const next = append ? [...assets, ...list.filter((a) => !assets.some((x) => x.id === a.id))] : list
        count.current = next.length
        setAssets(next)
        setMore(list.length === limit)
        setError(null)
      })
      .catch((e) => my === ask.current && setError(String(e.message ?? e)))
      .finally(() => my === ask.current && setLoading(false))
  }

  useEffect(() => {
    const id = setTimeout(() => setSearch(query.trim()), 250)
    return () => clearTimeout(id)
  }, [query])

  // Projektwechsel öffnet dessen Ordner; heißt das Projekt nur anders, folgt die Liste, wenn sie dort stand
  useEffect(() => {
    setCwd(home ?? '')
    setPicked(null)
    lastHome.current = home
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId])
  useEffect(() => {
    if (home !== lastHome.current) {
      if (cwd === lastHome.current) setCwd(home ?? '')
      lastHome.current = home
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [home])

  // neuer Filter, neue Suche, anderer Ordner: von vorn; neue Aufträge, Hochladen, Löschen: so viele wie schon geladen
  useEffect(() => {
    count.current = 0
    load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter, search, showFolders, cwd])
  useEffect(() => {
    if (refreshKey) load(false, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshKey])

  const switchView = (v: View) => {
    setView(v)
    store(KEY_VIEW, v)
  }

  const toggleFolders = () => {
    setShowFolders(!showFolders)
    store(KEY_FOLDERS, showFolders ? '0' : '1')
  }

  const openFolder = (folder: string) => {
    setPicked(null)
    setCwd(folder)
  }

  const goUp = () => {
    setPicked(cwd) // der Ordner, aus dem man kommt, bleibt markiert
    setCwd(parentOf(cwd))
  }

  // Hochgeladenes landet im geöffneten Ordner
  const uploadFolder = cwd
  const upload = async (files: FileList | null) => {
    if (!files) return
    try {
      for (const f of Array.from(files)) await api.upload(f, uploadFolder || undefined)
      load(false, true)
    } catch (e: any) {
      setError(String(e.message ?? e))
    }
  }

  const remove = async (a: Asset) => {
    if (usedIds.has(a.id)) {
      setError(t('Liegt im Schnitt: erst den Clip löschen.', 'It is in the edit: delete the clip first.'))
      return
    }
    if (confirm !== a.id) {
      setConfirm(a.id)
      setTimeout(() => setConfirm((c) => (c === a.id ? null : c)), 4000)
      return
    }
    setConfirm(null)
    try {
      await api.deleteAsset(a.id)
      setAssets((list) => list.filter((x) => x.id !== a.id))
      count.current = Math.max(0, count.current - 1)
      onDeleted(a.id)
    } catch (e: any) {
      setError(String(e.message ?? e))
    }
  }

  const revealFolder = async (folder: string) => {
    try {
      await api.revealFolder(folder)
    } catch (e: any) {
      setError(String(e.message ?? e))
    }
  }

  const shown = assets.filter((a) => mediaKind(a) !== null)
  const filters: [Filter, string][] = [
    ['all', t('Alle', 'All')],
    ['image', t('Bilder', 'Images')],
    ['video', t('Videos', 'Videos')],
    ['audio', t('Ton', 'Audio')],
  ]

  const files = (n: number) => t(`${n} ${n === 1 ? 'Datei' : 'Dateien'}`, `${n} ${n === 1 ? 'file' : 'files'}`)

  /** Ordnereintrag (auch „..“): Klick markiert, Doppelklick öffnet. */
  const folderItem = (key: string, label: string, sub: string, title: string, open: () => void, extra?: {
    current?: boolean
    orphan?: boolean
    menu?: MenuItem[]
  }) => {
    const sel = picked === key ? ' st-sel' : ''
    const cls = `${extra?.current ? ' current' : ''}${extra?.orphan ? ' orphan' : ''}`
    const common = {
      title,
      onClick: () => setPicked(key),
      onDoubleClick: open,
      onContextMenu: (e: RMouseEvent) => {
        e.preventDefault()
        setPicked(key)
        onMenu(e, extra?.menu ?? [{ label: t('Öffnen', 'Open'), onClick: open }])
      },
    }
    if (view === 'grid') {
      return (
        <div key={key} {...common} className={`st-bin-item st-bin-folder${cls}${sel}`}>
          <span className="st-bin-folder-big">{key === '..' ? '..' : <FolderIcon size={30} />}</span>
          <span className="st-bin-label small">{label}</span>
        </div>
      )
    }
    return (
      <div key={key} {...common} className={`st-bin-row st-bin-folder${cls}${sel}`}>
        <span className="st-bin-thumb">{key === '..' ? <b>..</b> : <FolderIcon size={18} />}</span>
        <span className="st-bin-text">
          <span className="st-bin-name">{label}</span>
          <span className="st-bin-meta">{sub}</span>
        </span>
      </div>
    )
  }

  const folderEntries = () => {
    if (!inFolders) return null
    if (cwd !== '') {
      return folderItem('..', '..', t('Eine Ebene hoch', 'Up one level'), t('Doppelklick: eine Ebene hoch', 'Double-click: up one level'), goUp)
    }
    return folders.map((f) => {
      const current = f.path === home
      const orphan = !f.project_id
      const sub = `${files(f.items)}${current ? t(' · offenes Projekt', ' · open project') : orphan ? t(' · ohne Projekt', ' · no project') : ''}`
      return folderItem(f.path, f.name, sub, t(`Doppelklick: öffnen (${f.path})`, `Double-click: open (${f.path})`), () => openFolder(f.path), {
        current,
        orphan,
        menu: [
          { label: t('Öffnen', 'Open'), onClick: () => openFolder(f.path) },
          { label: t('Speicherort öffnen', 'Show in folder'), separator: true, onClick: () => revealFolder(f.path) },
        ],
      })
    })
  }

  const item = (a: Asset) => {
    const kind = mediaKind(a)
    const used = usedIds.has(a.id)
    const lossless = !!a.meta?.master
    const asking = confirm === a.id
    // in der Suche: wo es liegt
    const where = search && a.folder ? folderName(a.folder) : null
    const del = (
      <button
        className={`st-bin-del${asking ? ' asking' : ''}`}
        onClick={(e) => {
          e.stopPropagation()
          remove(a)
        }}
        title={used ? t('Liegt im Schnitt', 'In the edit') : t('Löschen (Datei weg)', 'Delete (removes the file)')}
      >
        {asking ? t('Löschen?', 'Delete?') : '✕'}
      </button>
    )
    const common = {
      draggable: true,
      title: assetLabel(a) + (a.folder ? `\n${t('Ordner', 'Folder')}: ${folderName(a.folder)}` : ''),
      onClick: () => {
        setPicked(null)
        onOpen(a)
      },
      onContextMenu: (e: RMouseEvent) => {
        e.preventDefault()
        setPicked(null)
        onOpen(a)
        onMenu(e, [
          ...menuItems(a),
          {
            label: used ? t('Löschen (liegt im Schnitt)', 'Delete (in the edit)') : t('Löschen …', 'Delete …'),
            disabled: used,
            danger: true,
            separator: true,
            onClick: () => remove(a), // der Knopf in der Zeile fragt noch einmal nach
          },
        ])
      },
      onDragStart: (e: RDragEvent) => {
        e.dataTransfer.setData(ASSET_MIME, JSON.stringify({ id: a.id, kind }))
        e.dataTransfer.effectAllowed = 'copy'
      },
    }
    const sel = selectedId === a.id ? ' st-sel' : ''
    if (view === 'grid') {
      return (
        <div key={a.id} {...common} className={`st-bin-item${sel}`}>
          <Thumb a={a} />
          <span className="st-bin-label small">{assetLabel(a)}</span>
          {lossless && <span className="st-bin-flag" title={t('Verlustfreie Fassung vorhanden', 'Lossless copy available')}>◆</span>}
          {del}
        </div>
      )
    }
    return (
      <div key={a.id} {...common} className={`st-bin-row${sel}`}>
        <span className="st-bin-thumb">
          <Thumb a={a} />
        </span>
        <span className="st-bin-text">
          <span className="st-bin-name">{assetLabel(a)}</span>
          <span className="st-bin-meta">
            {kind && KIND_ICON[kind]} {assetFacts(a).join(' · ')}
            {lossless && <span className="st-bin-mark" title={t('Verlustfreie Kopie (FFV1) für Schnitt und Export', 'Lossless copy (FFV1) for editing and export')}>◆</span>}
            {used && <span className="st-bin-mark used" title={t('Liegt im Schnitt', 'In the edit')}>●</span>}
            {where && <span className="st-bin-where" title={a.folder}><FolderIcon size={10} /> {where}</span>}
          </span>
        </span>
        {del}
      </div>
    )
  }

  const emptyText = search
    ? t('Nichts gefunden.', 'Nothing found.')
    : cwd !== ''
      ? t('Der Ordner ist leer. Was das Projekt erzeugt, exportiert oder hier hochlädt, landet hier.',
        'The folder is empty. What the project generates, exports or uploads here lands here.')
      : t('Noch nichts da.', 'Nothing here yet.')
  const uploadTitle = uploadFolder
    ? t(`Bilder, Videos oder Ton hochladen, in den Ordner „${folderName(uploadFolder)}“`, `Upload images, videos or audio into the folder "${folderName(uploadFolder)}"`)
    : t('Bilder, Videos oder Ton hochladen, in den allgemeinen Verlauf', 'Upload images, videos or audio into the general history')

  return (
    <div className="st-bin">
      <div className="st-bin-head">
        <b>{t('Material', 'Media')}</b>
        <span className="muted small" title={more ? t('Weitere lassen sich nachladen', 'More can be loaded') : undefined}>
          {shown.length}{more ? '+' : ''}
        </span>
        <span className="st-spacer" />
        <button className={`btn small ghost${view === 'list' ? ' active' : ''}`} onClick={() => switchView('list')} title={t('Liste', 'List')}>☰</button>
        <button className={`btn small ghost${view === 'grid' ? ' active' : ''}`} onClick={() => switchView('grid')} title={t('Kacheln', 'Tiles')}>▦</button>
        <button
          className={`btn small ghost st-bin-folders${showFolders ? ' active' : ''}`}
          onClick={toggleFolders}
          title={showFolders ? t('Ordner ausblenden: nur das Material des geöffneten Ordners', 'Hide folders: only the media of the open folder') : t('Ordner einblenden: „..“, die Projektordner und der Verlauf', 'Show folders: "..", the project folders and the history')}
        >
          <FolderIcon />
        </button>
        <label className="btn small" title={uploadTitle}>
          ⭱
          <input type="file" multiple accept="image/*,video/*,audio/*" hidden onChange={(e) => { upload(e.target.files); e.target.value = '' }} />
        </label>
      </div>
      <div className="st-bin-filter">
        {filters.map(([id, label]) => (
          <button key={id} className={filter === id ? 'tab active' : 'tab'} onClick={() => setFilter(id)}>
            {label}
          </button>
        ))}
      </div>
      <input className="st-bin-search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t('Suchen (in allen Ordnern) …', 'Search (all folders) …')} />
      {!search && cwd !== '' && (
        <div className="st-bin-path">
          <button className="st-bin-crumb" onClick={() => openFolder('')} title={t('Oberste Ebene: Projektordner und Verlauf', 'Top level: project folders and history')}>
            {t('Material', 'Media')}
          </button>
          <span className="muted">›</span>
          <FolderIcon size={12} />
          <span className="st-bin-cwd" title={cwd}>{folderName(cwd)}</span>
        </div>
      )}
      {error && (
        <p className="warn-text small st-bin-error" onClick={() => setError(null)}>
          {error}
        </p>
      )}
      <div className={view === 'grid' ? 'st-bin-list' : 'st-bin-rows'}>
        {folderEntries()}
        {inFolders && cwd === '' && folders.length > 0 && shown.length > 0 && (
          <div className="st-bin-section">{t('Verlauf', 'History')}</div>
        )}
        {shown.map(item)}
        {shown.length === 0 && !loading && !(inFolders && cwd === '' && folders.length > 0) && <p className="muted small">{emptyText}</p>}
        {more && (
          <button className="btn small ghost st-bin-more" disabled={loading} onClick={() => load(true)}>
            {loading ? t('Lädt …', 'Loading …') : t(`Weitere ${PAGE} laden`, `Load ${PAGE} more`)}
          </button>
        )}
      </div>
    </div>
  )
}
