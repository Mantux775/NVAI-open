// Prüfpaket lesen und Änderungen zurückschreiben (Prüf-App). Ein Prüfpaket ist ein Ordner:
//   NVAI-Pruefer.html (diese App), LIESMICH.txt, PRUEFSUMMEN.sha256,
//   fall/manifest.json, fall/projekt.json, fall/transkript.json,
//   fall/proxy/* (Ton zum Abspielen), fall/peaks/*, fall/spec/* (Wellenform, Spektrogramm, Sprachkarte),
//   fall/data/*.json (Schiffsdaten, Ereignisse, Bildliste, AIS), fall/images/** (Radar, ECDIS), fall/video/* (wahlweise),
//   bearbeitung/ (schreibt die Prüf-App: transkript.json, marken.json, spuren.json, protokoll.jsonl).
// Die gelieferten Dateien unter fall/ bleiben unverändert (PRUEFSUMMEN.sha256); Änderungen stehen nur in bearbeitung/.
// Die Arbeitsfläche spricht weiter ihre Server-Adressen an (/api/…): installFetch beantwortet sie aus dem Paket.

import { mediaHook, type AudioMarker, type AudioProject, type AudioTrack, type TranscriptDoc } from '../api'
import { t } from '../i18n'
import { RemoteFile, type ByteSource } from './native'

export interface Manifest {
  format: string
  version: number
  created: string
  program: string
  project_id: string
  name: string
  /** Spur → Datei unter fall/proxy */
  proxies: Record<string, string>
  /** Datei unter fall/video, wenn mitgenommen */
  video?: string | null
  images: boolean
  /** Spur → Originalton als WAV unter fall/original (bitgenau aus der Arbeitsdatei) */
  originals?: Record<string, { file: string; sample_rate: number; channels: number; frames: number }>
  files?: number
  bytes?: number
}

let current: Pkg | null = null
/** Das geöffnete Paket (für Exporte im Browser) */
export function reviewPackage(): Pkg | null {
  return current
}

/** Woher das Paket kommt: ein Ordner (File System Access, lesen und schreiben) oder eine Adresse (zum Testen nur lesen;
 * in der Mac-App liefert deren Server das Paket und nimmt Änderungen für „bearbeitung/“ an) */
export interface Source {
  label: string
  canWrite: boolean
  read(path: string): Promise<Blob | null>
  /** große Dateien für Exporte: erst beim Lesen eines Ausschnitts geholt */
  lazy(path: string): Promise<Blob | ByteSource | null>
  readRange(path: string, start: number, end: number): Promise<{ data: Blob; size: number } | null>
  mediaUrl(path: string): Promise<string | null>
  write?(path: string, data: string): Promise<void>
}

type Writable = { write: (d: string) => Promise<void>; close: () => Promise<void> }

export function dirSource(root: FileSystemDirectoryHandle): Source {
  const fileHandle = async (path: string, create = false): Promise<FileSystemFileHandle | null> => {
    const parts = path.split('/').filter(Boolean)
    let dir = root
    try {
      for (const part of parts.slice(0, -1)) dir = await dir.getDirectoryHandle(part, { create })
      return await dir.getFileHandle(parts[parts.length - 1], { create })
    } catch {
      return null
    }
  }
  const file = async (path: string): Promise<File | null> => {
    const h = await fileHandle(path)
    return h ? h.getFile() : null
  }
  return {
    label: root.name,
    canWrite: true,
    read: file,
    lazy: file,
    async readRange(path, start, end) {
      const f = await file(path)
      return f ? { data: f.slice(start, Math.min(f.size, end + 1)), size: f.size } : null
    },
    async mediaUrl(path) {
      const f = await file(path)
      return f ? URL.createObjectURL(f) : null
    },
    async write(path, data) {
      const h = await fileHandle(path, true)
      if (!h) throw new Error(t(`Kann nicht in den Fallordner schreiben: ${path}`, `Cannot write to the case folder: ${path}`))
      const w = await (h as unknown as { createWritable: () => Promise<Writable> }).createWritable()
      await w.write(data)
      await w.close()
    },
  }
}

export function httpSource(base: string, fetcher: typeof fetch, writable = false): Source {
  const b = new URL(base.endsWith('/') ? base : `${base}/`, location.href).href
  return {
    label: b,
    canWrite: writable,
    async read(path) {
      const r = await fetcher(b + path)
      return r.ok ? r.blob() : null
    },
    lazy: (path) => RemoteFile.open(b + path, fetcher),
    ...(writable ? {
      async write(path: string, data: string) {
        const r = await fetcher(b + path, { method: 'PUT', body: data, headers: { 'Content-Type': 'application/octet-stream' } })
        if (!r.ok) throw new Error(t(`Kann nicht in den Fallordner schreiben: ${path}`, `Cannot write to the case folder: ${path}`))
      },
    } : {}),
    async readRange(path, start, end) {
      const r = await fetcher(b + path, { headers: { Range: `bytes=${start}-${end}` } })
      if (!r.ok) return null
      const data = await r.blob()
      if (r.status !== 206) return { data: data.slice(start, end + 1), size: data.size }
      const total = Number((r.headers.get('content-range') ?? '').split('/')[1])
      return { data, size: Number.isFinite(total) ? total : start + data.size }
    },
    async mediaUrl(path) {
      return b + path
    },
  }
}

export interface Pkg {
  source: Source
  manifest: Manifest
  project: AudioProject
  transcript: TranscriptDoc
  /** Server-Adresse → Objekt-URL (Ton, Video) */
  urls: Map<string, string>
  reviewer: string
  log: { last: string; lines: string[] }
  images?: { frames: Record<string, [number, string][]> }
}

async function readJson<T>(src: Source, path: string): Promise<T | null> {
  const b = await src.read(path)
  if (!b) return null
  try {
    return JSON.parse(await b.text()) as T
  } catch {
    return null
  }
}

export async function openPackage(source: Source, reviewer: string): Promise<Pkg> {
  const manifest = await readJson<Manifest>(source, 'fall/manifest.json')
  if (!manifest || manifest.format !== 'nvai-pruefpaket') {
    throw new Error(t('Das ist kein Prüfpaket von NVAI-open (fall/manifest.json fehlt). Bitte den Ordner wählen, in dem NVAI-Pruefer.html liegt.',
      'This is not an NVAI-open review package (fall/manifest.json missing). Please choose the folder that contains NVAI-Pruefer.html.'))
  }
  const project = await readJson<AudioProject>(source, 'fall/projekt.json')
  if (!project) throw new Error(t('fall/projekt.json fehlt oder ist beschädigt.', 'fall/projekt.json is missing or damaged.'))
  const transcript = (await readJson<TranscriptDoc>(source, 'bearbeitung/transkript.json'))
    ?? (await readJson<TranscriptDoc>(source, 'fall/transkript.json'))
    ?? { source_lang: '', target_lang: 'de', speakers: [], segments: [] }
  const markers = await readJson<AudioMarker[]>(source, 'bearbeitung/marken.json')
  if (markers) project.markers = markers
  const trackEdits = await readJson<Record<string, Partial<AudioTrack>>>(source, 'bearbeitung/spuren.json')
  if (trackEdits) project.tracks = project.tracks.map((x) => ({ ...x, ...(trackEdits[x.id] ?? {}) }))
  // Ton und Video als Objekt-URLs: Die Arbeitsfläche fragt die Vorschau einer Spur immer als „<Spur>.webm“ an
  const urls = new Map<string, string>()
  const base = `/api/audio/projects/${encodeURIComponent(project.id)}`
  for (const [tid, file] of Object.entries(manifest.proxies ?? {})) {
    const u = await source.mediaUrl(`fall/proxy/${file}`)
    if (u) urls.set(`${base}/files/proxy/${encodeURIComponent(`${tid}.webm`)}`, u)
  }
  if (manifest.video) {
    const u = await source.mediaUrl(`fall/video/${manifest.video}`)
    if (u) urls.set(`${base}/video`, u)
  }
  const prev = await source.read('bearbeitung/protokoll.jsonl')
  const lines = prev ? (await prev.text()).split('\n').filter(Boolean) : []
  let last = ''
  try {
    last = lines.length ? JSON.parse(lines[lines.length - 1]).hash ?? '' : ''
  } catch { /* beschädigte Zeile: Kette beginnt neu */ }
  return { source, manifest, project, transcript, urls, reviewer, log: { last, lines } }
}

/** Objekt-URLs freigeben (Fall schließen) */
export function closePackage(pkg: Pkg): void {
  for (const u of pkg.urls.values()) if (u.startsWith('blob:')) URL.revokeObjectURL(u)
  mediaHook.url = undefined
}

async function sha256(text: string): Promise<string> {
  try {
    const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
    return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('')
  } catch {
    return ''
  }
}

// Alle schreibenden Schritte nacheinander: Zwei gleichzeitige Änderungen (Strg+Enter in einer Notiz speicherte zweimal)
// lasen sonst dieselbe letzte Prüfsumme (doppelte Nummer, scheinbar gebrochene Kette) und schrieben dieselben Dateien
// parallel; die zuletzt geschlossene gewann
let chain: Promise<unknown> = Promise.resolve()
function serial<T>(work: () => Promise<T>): Promise<T> {
  const next = chain.then(work, work)
  chain = next.catch(() => undefined)
  return next
}

/** Prüfer-Protokoll: jede Änderung eine Zeile in bearbeitung/protokoll.jsonl, verkettet über SHA-256 (eine nachträglich
 * geänderte Zeile bricht die Kette ab der Stelle) */
export function logEntry(pkg: Pkg, op: string, detail: Record<string, unknown>): Promise<void> {
  return serial(() => appendLog(pkg, op, detail))
}

async function appendLog(pkg: Pkg, op: string, detail: Record<string, unknown>): Promise<void> {
  const entry = { n: pkg.log.lines.length + 1, zeit: new Date().toISOString(), pruefer: pkg.reviewer, op, ...detail, vorher: pkg.log.last }
  const hash = await sha256(JSON.stringify(entry))
  pkg.log.lines.push(JSON.stringify({ ...entry, hash }))
  pkg.log.last = hash
  await pkg.source.write?.('bearbeitung/protokoll.jsonl', `${pkg.log.lines.join('\n')}\n`)
}

async function save(pkg: Pkg, path: string, data: unknown): Promise<void> {
  await pkg.source.write?.(path, JSON.stringify(data, null, 1))
}

const json = (x: unknown, status = 200): Response =>
  new Response(JSON.stringify(x), { status, headers: { 'Content-Type': 'application/json' } })
const unavailable = (): Response => json({ detail: t('In der Prüf-App nicht verfügbar.', 'Not available in the review app.') }, 404)
const SPEC: Record<string, string> = { 0: '.spec', 1: '.spec1', 2: '.spec2', 3: '.spec3', act: '.act', vad: '.vad' }

async function fileResponse(pkg: Pkg, path: string, init?: RequestInit): Promise<Response> {
  const range = new Headers(init?.headers).get('Range')
  const m = range ? /bytes=(\d+)-(\d*)/.exec(range) : null
  if (m) {
    const start = Number(m[1])
    const r = await pkg.source.readRange(path, start, m[2] ? Number(m[2]) : Number.MAX_SAFE_INTEGER)
    if (!r) return json({ detail: path }, 404)
    return new Response(r.data, { status: 206, headers: { 'Content-Range': `bytes ${start}-${start + r.data.size - 1}/${r.size}`, 'Content-Length': String(r.data.size) } })
  }
  const b = await pkg.source.read(path)
  return b ? new Response(b, { status: 200 }) : json({ detail: path }, 404)
}

async function route(pkg: Pkg, path: string, init?: RequestInit): Promise<Response> {
  const method = (init?.method ?? 'GET').toUpperCase()
  const base = `/api/audio/projects/${encodeURIComponent(pkg.project.id)}`
  if (!path.startsWith(base)) return unavailable()
  const rest = path.slice(base.length)
  const body = () => JSON.parse(String(init?.body ?? '{}'))
  if (rest === '' && method === 'GET') return json(pkg.project)
  if (rest === '/transcript' && method === 'GET') return json(pkg.transcript)
  if (rest === '/transcript' && method === 'PUT') {
    const doc = body()
    delete doc.client
    pkg.transcript = doc
    await save(pkg, 'bearbeitung/transkript.json', doc)
    const segs = (doc.segments ?? []) as { status?: string }[]
    await appendLog(pkg, 'transkript', { bloecke: segs.length, geprueft: segs.filter((s) => s.status === 'checked').length })
    return json(doc)
  }
  if (rest === '/markers' && method === 'PUT') {
    const markers = body().markers as AudioMarker[]
    pkg.project = { ...pkg.project, markers }
    await save(pkg, 'bearbeitung/marken.json', markers)
    await appendLog(pkg, 'marken', { anzahl: markers.length, notizen: markers.filter((x) => x.kind === 'note').length })
    return json(pkg.project)
  }
  const tr = /^\/tracks\/([^/]+)$/.exec(rest)
  if (tr && method === 'PUT') {
    const tid = decodeURIComponent(tr[1])
    const fields = body() as Partial<AudioTrack>
    pkg.project = { ...pkg.project, tracks: pkg.project.tracks.map((x) => (x.id === tid ? { ...x, ...fields } : x)) }
    const edits = Object.fromEntries(pkg.project.tracks.map((x) => [x.id, { name: x.name, gain_db: x.gain_db, mute: x.mute, solo: x.solo, color: x.color }]))
    await save(pkg, 'bearbeitung/spuren.json', edits)
    return json(pkg.project)
  }
  if (method !== 'GET') return unavailable()
  const file = /^\/files\/(peaks|data|proxy)\/(.+)$/.exec(rest)
  if (file) return fileResponse(pkg, `fall/${file[1]}/${decodeURIComponent(file[2])}`, init)
  const spec = /^\/spec\/([^/]+)\/(\w+)$/.exec(rest)
  if (spec && SPEC[spec[2]]) return fileResponse(pkg, `fall/spec/${decodeURIComponent(spec[1])}${SPEC[spec[2]]}`, init)
  const img = /^\/vdr\/image\/([^/]+)\/(\d+)$/.exec(rest)
  if (img) {
    if (!pkg.manifest.images) return unavailable()
    if (!pkg.images) pkg.images = (await readJson<{ frames: Record<string, [number, string][]> }>(pkg.source, 'fall/data/images.json')) ?? { frames: {} }
    const frame = pkg.images.frames[decodeURIComponent(img[1])]?.[Number(img[2])]
    return frame ? fileResponse(pkg, `fall/images/${frame[1]}`) : json({ detail: 'image' }, 404)
  }
  return unavailable()
}

/** Server-Anfragen der Arbeitsfläche aus dem Paket beantworten; alles andere geht unverändert hinaus (beim Öffnen von
 * der Platte gibt es kein Netz: Die Seite verbietet es per Content-Security-Policy) */
export function installFetch(pkg: Pkg, origFetch: typeof fetch): void {
  current = pkg
  mediaHook.url = (path) => pkg.urls.get(path)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    const u = new URL(raw, location.href)
    const i = u.pathname.indexOf('/api/')
    if (i < 0) return origFetch(input, init)
    try {
      const write = (init?.method ?? 'GET').toUpperCase() !== 'GET'
      return await (write ? serial(() => route(pkg, u.pathname.slice(i), init)) : route(pkg, u.pathname.slice(i), init))
    } catch (e) {
      return json({ detail: String((e as Error).message ?? e) }, 500)
    }
  }
}
