// Prüf-App in der Mac-App (Bereich „Ton-Forensik“, seit Mac 0.5.7): Die Mac-App zeigt NVAI-Pruefer.html in einem
// WKWebView über ihren eigenen Server auf 127.0.0.1. WebKit kennt weder showDirectoryPicker noch showSaveFilePicker;
// die Mac-App hilft über die Nachricht „nvaiReview“ (Ordner- und Speichern-Dialog) und über ihren Server: Paketdateien
// lesen (mit Range), nach „bearbeitung/“ schreiben und Exporte stückweise in die gewählte Datei schreiben.

const ORIG_FETCH = window.fetch.bind(window)

interface Bridge {
  postMessage(message: unknown): Promise<unknown>
}

export function nativeBridge(): Bridge | null {
  const w = window as unknown as { webkit?: { messageHandlers?: { nvaiReview?: Bridge } } }
  return w.webkit?.messageHandlers?.nvaiReview ?? null
}

function cancelled(): DOMException {
  return new DOMException('cancelled', 'AbortError')
}

/** Ordner eines Prüfpakets über den Dialog der Mac-App wählen. Ergebnis: Adresse, unter der ihr Server das Paket liefert. */
export async function nativeOpen(): Promise<string> {
  const bridge = nativeBridge()
  if (!bridge) throw new Error('no native bridge')
  const r = (await bridge.postMessage({ op: 'open' })) as { base?: string; error?: string } | null
  if (r?.base) return r.base
  if (r?.error) throw new Error(r.error)
  throw cancelled()
}

/** Was die Exporte lesen: Blob oder eine Datei des Servers, die erst beim Lesen eines Ausschnitts geholt wird. */
export interface ByteSource {
  readonly size: number
  slice(start?: number, end?: number): ByteSource
  arrayBuffer(): Promise<ArrayBuffer>
}

export async function asBlob(x: ByteSource | Blob): Promise<Blob> {
  return x instanceof Blob ? x : new Blob([await x.arrayBuffer()])
}

/** Datei des Servers, stückweise per Range gelesen (ein 9-GB-Video läge sonst ganz im Speicher). */
export class RemoteFile implements ByteSource {
  constructor(private url: string, private fetcher: typeof fetch, readonly size: number, private from = 0) {}

  slice(start = 0, end = this.size): RemoteFile {
    const s = Math.max(0, Math.min(this.size, start < 0 ? this.size + start : start))
    const e = Math.max(s, Math.min(this.size, end < 0 ? this.size + end : end))
    return new RemoteFile(this.url, this.fetcher, e - s, this.from + s)
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    const out = new Uint8Array(this.size)
    let got = 0
    while (got < this.size) {
      const a = this.from + got
      const r = await this.fetcher(this.url, { headers: { Range: `bytes=${a}-${this.from + this.size - 1}` } })
      if (!r.ok) throw new Error(`${r.status} ${this.url}`)
      let data = new Uint8Array(await r.arrayBuffer())
      if (r.status === 200) data = data.subarray(a, this.from + this.size)  // Server ohne Range: ganze Datei
      if (!data.length) throw new Error(`short read ${this.url}`)
      out.set(data.subarray(0, this.size - got), got)
      got += Math.min(data.length, this.size - got)
    }
    return out.buffer
  }

  /** Antwortet der Server mit 206, wird stückweise gelesen; ohne Range (einfacher Webserver, Prüfstand) wie bisher die
   * ganze Datei als Blob. */
  static async open(url: string, fetcher: typeof fetch): Promise<RemoteFile | Blob | null> {
    const r = await fetcher(url, { headers: { Range: 'bytes=0-0' } })
    if (!r.ok) return null
    const total = Number((r.headers.get('content-range') ?? '').split('/')[1])
    if (r.status !== 206 || !Number.isFinite(total) || total <= 0) return r.blob()
    await r.body?.cancel().catch(() => undefined)
    return new RemoteFile(url, fetcher, total)
  }
}

const CHUNK = 4 << 20

/** Schreibziel wie FileSystemWritableFileStream: gesammelt in Stücken zu 4 MB, Nachträge an früherer Stelle. */
class NativeWritable {
  private parts: Blob[] = []
  private buffered = 0
  /** Dateistelle des ersten gesammelten Bytes */
  private at = 0

  constructor(private url: string) {}

  private async put(at: number, data: Blob): Promise<void> {
    const r = await ORIG_FETCH(`${this.url}?at=${at}`, { method: 'PUT', body: data })
    if (!r.ok) throw new Error(`${r.status} ${await r.text().catch(() => '')}`)
  }

  private async flush(): Promise<void> {
    if (!this.buffered) return
    const blob = new Blob(this.parts)
    const at = this.at
    this.parts = []
    this.at += this.buffered
    this.buffered = 0
    await this.put(at, blob)
  }

  async write(d: unknown): Promise<void> {
    let data = d
    if (d && typeof d === 'object' && !(d instanceof Blob) && !ArrayBuffer.isView(d) && !(d instanceof ArrayBuffer)
        && (d as { type?: string }).type === 'write') {
      const { position, data: inner } = d as { position?: number; data: unknown }
      if (position !== undefined) {
        await this.flush()
        const blob = await this.toBlob(inner)
        await this.put(position, blob)
        this.at = position + blob.size
        return
      }
      data = inner
    }
    const blob = await this.toBlob(data)
    this.parts.push(blob)
    this.buffered += blob.size
    if (this.buffered >= CHUNK) await this.flush()
  }

  private async toBlob(d: unknown): Promise<Blob> {
    if (d instanceof Blob) return d
    if (d && typeof d === 'object' && typeof (d as ByteSource).arrayBuffer === 'function' && !ArrayBuffer.isView(d)) {
      return new Blob([await (d as ByteSource).arrayBuffer()])
    }
    return new Blob([d as BlobPart])
  }

  async close(): Promise<void> {
    await this.flush()
    const r = await ORIG_FETCH(`${this.url}?done=1`, { method: 'POST' })
    if (!r.ok) throw new Error(`${r.status}`)
  }

  async abort(): Promise<void> {
    this.parts = []
    this.buffered = 0
    await ORIG_FETCH(this.url, { method: 'DELETE' }).catch(() => undefined)
  }
}

type PickerOptions = { suggestedName?: string; types?: { description?: string; accept?: Record<string, string[]> }[] }

/** „Speichern unter“ der Mac-App anstelle von showSaveFilePicker, das WebKit nicht hat. */
export function installNativeSave(): void {
  const bridge = nativeBridge()
  if (!bridge) return
  const w = window as unknown as { showSaveFilePicker?: unknown }
  w.showSaveFilePicker = async (o: PickerOptions) => {
    const ext = Object.values(o?.types?.[0]?.accept ?? {})[0]?.[0] ?? ''
    const r = (await bridge.postMessage({ op: 'save', name: o?.suggestedName ?? 'export', ext })) as { url?: string; name?: string; error?: string } | null
    if (!r?.url) {
      if (r?.error) throw new Error(r.error)
      throw cancelled()
    }
    const url = r.url
    return { name: r.name ?? o?.suggestedName ?? 'export', createWritable: async () => new NativeWritable(url) }
  }
}
