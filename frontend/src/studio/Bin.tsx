// Material (Nutzer 26.10.2026: „kompakter und aktueller ansicht, ich soll assets hier auch löschen können, genau so
// abspielen oder vorschau anzeigen wenn ich den anklicke“): alles aus dem Verlauf, neueste zuerst, als kompakte Liste
// oder als Kacheln, mit Filter und Suche. Fertige Aufträge, Hochladen und Löschen kommen live dazu. Ein Klick zeigt
// das Asset im Monitor und spielt es ab; Ziehen auf eine Spur legt einen Clip an, auf eine Szene einen Take. Rechtsklick
// (Nutzer 27.10.2026): an eine Spur senden, Speicherort öffnen, Datei öffnen, löschen. Löschen fragt im Knopf selbst
// nach (kein Browser-Dialog) und lässt, was im Schnitt liegt, stehen. Geladen werden je 100 (Nutzer 27.10.: „lädt nicht
// alle Assets … max 100, dann weitere 100. Suche soll alle durchsuchen“); Filter und Suche fragt der Server über alles.

import { useEffect, useRef, useState, type DragEvent as RDragEvent, type MouseEvent as RMouseEvent } from 'react'
import { api, type Asset } from '../api'
import { t } from '../i18n'
import type { MenuItem } from './ContextMenu'
import { ASSET_MIME } from './Timelines'
import { decimal } from './time'

type Filter = 'all' | 'image' | 'video' | 'audio'
type View = 'list' | 'grid'
// wie db.UPLOAD_VIDEO / UPLOAD_AUDIO auf dem Server
const VIDEO = /\.(mp4|webm|mov|mkv|avi|wmv|flv|mxf|mts|m2ts|ts)$/i
const AUDIO = /\.(mp3|wav|flac|ogg|m4a|aac|opus)$/i
const KEY_VIEW = 'nvai-studio-bin-view'
const PAGE = 100

/** Uploads tragen keine Art; die Endung sagt sie. */
export function mediaKind(a: Asset): 'image' | 'video' | 'audio' | null {
  if (a.kind === 'image' || a.kind === 'video' || a.kind === 'audio') return a.kind
  if (a.kind !== 'upload') return null
  if (VIDEO.test(a.filename)) return 'video'
  if (AUDIO.test(a.filename)) return 'audio'
  return 'image'
}

const NO_BROWSER = /\.(mkv|mov|avi|wmv|flv|mxf|mts|m2ts|ts)$/i

/** Was der Browser abspielt: die Datei selbst oder, bei MKV, MOV & Co., ihre H.264-Vorschau (meta.preview). FFV1
 * und ProRes spielt kein Browser; NVAI-open legt die Vorschau beim Export bzw. nach dem Hochladen an. */
export function previewUrl(a: Asset): string | null {
  if (a.meta?.preview) return `/files/${a.meta.preview}`
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

function stored(): View {
  try {
    return localStorage.getItem(KEY_VIEW) === 'grid' ? 'grid' : 'list'
  } catch {
    return 'list'
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
  onOpen: (a: Asset) => void
  onDeleted: (id: string) => void
  /** Einträge des Rechtsklick-Menüs, die das Studio beisteuert (an eine Spur senden …) */
  menuItems: (a: Asset) => MenuItem[]
  onMenu: (e: { clientX: number; clientY: number }, items: MenuItem[]) => void
}

export function Bin({ refreshKey, selectedId, usedIds, onOpen, onDeleted, menuItems, onMenu }: Props) {
  const [assets, setAssets] = useState<Asset[]>([])
  const [filter, setFilter] = useState<Filter>('all')
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('') // die Suche mit kurzer Pause nach dem Tippen
  const [more, setMore] = useState(false) // liefert der Server noch weitere?
  const [loading, setLoading] = useState(false)
  const [view, setView] = useState<View>(stored)
  const [confirm, setConfirm] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const count = useRef(0) // wie viele geladen sind: beim Auffrischen nicht wieder auf 100 schrumpfen
  const ask = useRef(0) // nur die Antwort auf die letzte Anfrage zählt

  /** Erste Seite neu (oder so viele wie schon geladen) bzw. die nächsten 100 dazu. */
  const load = (append: boolean, keep = false) => {
    const my = ++ask.current
    const offset = append ? count.current : 0
    const limit = append ? PAGE : keep ? Math.max(PAGE, Math.ceil(count.current / PAGE) * PAGE) : PAGE
    setLoading(true)
    api
      .assetPage({ media: filter, q: search || undefined, limit, offset })
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

  // neuer Filter oder neue Suche: von vorn; neue Aufträge, Hochladen, Löschen: so viele wie schon geladen
  useEffect(() => {
    count.current = 0
    load(false)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter, search])
  useEffect(() => {
    if (refreshKey) load(false, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshKey])

  const switchView = (v: View) => {
    setView(v)
    try {
      localStorage.setItem(KEY_VIEW, v)
    } catch {
      /* privates Fenster */
    }
  }

  const upload = async (files: FileList | null) => {
    if (!files) return
    try {
      for (const f of Array.from(files)) await api.upload(f)
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

  const shown = assets.filter((a) => mediaKind(a) !== null)
  const filters: [Filter, string][] = [
    ['all', t('Alle', 'All')],
    ['image', t('Bilder', 'Images')],
    ['video', t('Videos', 'Videos')],
    ['audio', t('Ton', 'Audio')],
  ]

  const item = (a: Asset) => {
    const kind = mediaKind(a)
    const used = usedIds.has(a.id)
    const lossless = !!a.meta?.master
    const asking = confirm === a.id
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
      title: assetLabel(a),
      onClick: () => onOpen(a),
      onContextMenu: (e: RMouseEvent) => {
        e.preventDefault()
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
          </span>
        </span>
        {del}
      </div>
    )
  }

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
        <label className="btn small" title={t('Bilder, Videos oder Ton hochladen', 'Upload images, videos or audio')}>
          ⭱
          <input type="file" multiple accept="image/*,video/*,audio/*" hidden onChange={(e) => upload(e.target.files)} />
        </label>
      </div>
      <div className="st-bin-filter">
        {filters.map(([id, label]) => (
          <button key={id} className={filter === id ? 'tab active' : 'tab'} onClick={() => setFilter(id)}>
            {label}
          </button>
        ))}
      </div>
      <input className="st-bin-search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t('Suchen …', 'Search …')} />
      {error && (
        <p className="warn-text small st-bin-error" onClick={() => setError(null)}>
          {error}
        </p>
      )}
      <div className={view === 'grid' ? 'st-bin-list' : 'st-bin-rows'}>
        {shown.map(item)}
        {shown.length === 0 && !loading && (
          <p className="muted small">{search ? t('Nichts gefunden.', 'Nothing found.') : t('Noch nichts da.', 'Nothing here yet.')}</p>
        )}
        {more && (
          <button className="btn small ghost st-bin-more" disabled={loading} onClick={() => load(true)}>
            {loading ? t('Lädt …', 'Loading …') : t(`Weitere ${PAGE} laden`, `Load ${PAGE} more`)}
          </button>
        )}
      </div>
    </div>
  )
}
