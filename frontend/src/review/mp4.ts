// MP4 (ISO BMFF) lesen und schreiben, ohne Bibliothek: für „Video mit Ton“ in der Prüf-App (Nutzer 18.11.2026: „die
// app soll alle fähigkeiten haben die keine KI benötigt und exportieren können“).
//
// Lesen: nur der moov-Kasten (Spuren und Probentabellen). Die Proben holt der Aufrufer selbst per Blob.slice, so geht
// auch ein Video mit 9 GB, ohne es zu laden. Fragmentierte MP4 (moof) und mehrere Formate in einer Spur gehen nicht.
// Schreiben: ftyp, ein mdat mit 64-Bit-Größe (am Ende eingetragen) und moov am Ende mit co64, stückweise in eine Datei.
// So gehen auch Stunden und Dateien über 4 GB.

const enc = new TextEncoder()

function fourcc(v: DataView, p: number): string {
  return String.fromCharCode(v.getUint8(p), v.getUint8(p + 1), v.getUint8(p + 2), v.getUint8(p + 3))
}

/** Kinder eines Kastens: Typ, Anfang des Kastens, Anfang der Nutzdaten, Ende */
function* kids(v: DataView, start: number, end: number): Generator<[string, number, number, number]> {
  let p = start
  while (p + 8 <= end) {
    let size = v.getUint32(p)
    let hdr = 8
    if (size === 1) {
      size = Number(v.getBigUint64(p + 8))
      hdr = 16
    } else if (size === 0) size = end - p
    if (size < hdr || p + size > end) throw new Error('MP4: box')
    yield [fourcc(v, p + 4), p, p + hdr, p + size]
    p += size
  }
}

function find(v: DataView, start: number, end: number, type: string): [number, number, number] | null {
  for (const [t, b, s, e] of kids(v, start, end)) if (t === type) return [b, s, e]
  return null
}

export interface Mp4Track {
  id: number
  /** 'vide', 'soun' … */
  handler: string
  timescale: number
  /** erstes Format in stsd, z. B. 'avc1' */
  codec: string
  /** der ganze stsd-Kasten, unverändert übernehmbar */
  stsd: Uint8Array
  width: number
  height: number
  /** 36 Bytes aus tkhd (Drehung des Bildes) */
  matrix: Uint8Array
  count: number
  /** Dekodierzeit je Probe (Zeitbasis der Spur) */
  dts: Float64Array
  /** Dekodierzeit hinter der letzten Probe */
  end: number
  /** Kompositionsversatz je Probe, null = keiner */
  cto: Int32Array | null
  size: Uint32Array
  offset: Float64Array
  /** 1 = Schlüsselbild; null = jede Probe ist eins */
  sync: Uint8Array | null
  /** aus der Schnittliste: Darstellungszeit = dts + cto − shift (Zeitbasis der Spur) */
  shift: number
}

export interface Mp4Info { timescale: number; duration: number; tracks: Mp4Track[] }

export class Mp4Error extends Error {}

/** moov einer MP4/MOV lesen; want wählt die Spuren nach Art ('vide', 'soun'), andere werden übergangen. */
export async function readMp4(file: Blob, want: (handler: string) => boolean = () => true): Promise<Mp4Info> {
  let pos = 0
  let moov: [number, number] | null = null
  while (pos + 8 <= file.size) {
    const h = new DataView(await file.slice(pos, pos + 16).arrayBuffer())
    let size = h.getUint32(0)
    const type = fourcc(h, 4)
    if (size === 1) size = Number(h.getBigUint64(8))
    else if (size === 0) size = file.size - pos
    if (size < 8) throw new Mp4Error('MP4: file')
    if (type === 'moov') {
      moov = [pos, size]
      break
    }
    pos += size
  }
  if (!moov) throw new Mp4Error('MP4: moov')
  const buf = await file.slice(moov[0], moov[0] + moov[1]).arrayBuffer()
  const v = new DataView(buf)
  const hdr = v.getUint32(0) === 1 ? 16 : 8
  const mvhd = find(v, hdr, buf.byteLength, 'mvhd')
  if (!mvhd) throw new Mp4Error('MP4: mvhd')
  if (find(v, hdr, buf.byteLength, 'mvex')) throw new Mp4Error('MP4: fragmented')
  const mver = v.getUint8(mvhd[1])
  const timescale = v.getUint32(mvhd[1] + (mver === 1 ? 20 : 12))
  const duration = mver === 1 ? Number(v.getBigUint64(mvhd[1] + 24)) : v.getUint32(mvhd[1] + 16)
  const tracks: Mp4Track[] = []
  for (const [t, , s, e] of kids(v, hdr, buf.byteLength)) {
    if (t !== 'trak') continue
    const tr = parseTrak(v, s, e, timescale, want)
    if (tr) tracks.push(tr)
  }
  return { timescale, duration, tracks }
}

function parseTrak(v: DataView, s: number, e: number, movieTs: number, want: (h: string) => boolean): Mp4Track | null {
  const tkhd = find(v, s, e, 'tkhd')
  const mdia = find(v, s, e, 'mdia')
  if (!tkhd || !mdia) return null
  const hdlr = find(v, mdia[1], mdia[2], 'hdlr')
  const handler = hdlr ? fourcc(v, hdlr[1] + 8) : ''
  if (!want(handler)) return null
  const tv = v.getUint8(tkhd[1])
  let p = tkhd[1] + 4 + (tv === 1 ? 16 : 8)
  const id = v.getUint32(p)
  p += 4 + 4 + (tv === 1 ? 8 : 4) // track_ID, reserviert, Dauer
  p += 8 + 2 + 2 + 2 + 2 // reserviert, Ebene, Gruppe, Lautstärke, reserviert
  const matrix = new Uint8Array(v.buffer, v.byteOffset + p, 36).slice()
  const width = v.getUint32(p + 36) / 65536
  const height = v.getUint32(p + 40) / 65536
  const mdhd = find(v, mdia[1], mdia[2], 'mdhd')
  if (!mdhd) return null
  const mv = v.getUint8(mdhd[1])
  const ts = v.getUint32(mdhd[1] + (mv === 1 ? 20 : 12))
  // Schnittliste: leere Einträge verzögern, der erste volle legt den Anfang in der Spur fest
  let mediaTime = 0
  let emptyDelay = 0
  const edts = find(v, s, e, 'edts')
  const elst = edts && find(v, edts[1], edts[2], 'elst')
  if (elst) {
    const ev = v.getUint8(elst[1])
    const n = v.getUint32(elst[1] + 4)
    let q = elst[1] + 8
    for (let i = 0; i < n; i++) {
      const dur = ev === 1 ? Number(v.getBigUint64(q)) : v.getUint32(q)
      const mt = ev === 1 ? Number(v.getBigInt64(q + 8)) : v.getInt32(q + 4)
      q += ev === 1 ? 20 : 12
      if (mt === -1) {
        emptyDelay += dur
        continue
      }
      mediaTime = mt
      break
    }
  }
  const minf = find(v, mdia[1], mdia[2], 'minf')
  const stbl = minf && find(v, minf[1], minf[2], 'stbl')
  if (!stbl) return null
  const box = (t: string) => find(v, stbl[1], stbl[2], t)
  const stsdB = box('stsd')
  const stszB = box('stsz')
  const sttsB = box('stts')
  const stscB = box('stsc')
  const co = box('co64')
  const sc = box('stco')
  if (!stsdB || !sttsB || !stscB || (!co && !sc)) throw new Mp4Error('MP4: stbl')
  if (!stszB) throw new Mp4Error('MP4: stz2')
  const stsd = new Uint8Array(v.buffer, v.byteOffset + stsdB[0], stsdB[2] - stsdB[0]).slice()
  const codec = fourcc(v, stsdB[1] + 12)
  const fixed = v.getUint32(stszB[1] + 4)
  const count = v.getUint32(stszB[1] + 8)
  const size = new Uint32Array(count)
  if (fixed) size.fill(fixed)
  else for (let i = 0; i < count; i++) size[i] = v.getUint32(stszB[1] + 12 + 4 * i)
  const dts = new Float64Array(count)
  let tEnd = 0
  {
    const n = v.getUint32(sttsB[1] + 4)
    let i = 0
    for (let k = 0; k < n; k++) {
      const c = v.getUint32(sttsB[1] + 8 + 8 * k)
      const d = v.getUint32(sttsB[1] + 12 + 8 * k)
      for (let j = 0; j < c && i < count; j++) {
        dts[i++] = tEnd
        tEnd += d
      }
    }
    while (i < count) dts[i++] = tEnd
  }
  let cto: Int32Array | null = null
  const ct = box('ctts')
  if (ct) {
    cto = new Int32Array(count)
    const n = v.getUint32(ct[1] + 4)
    let i = 0
    for (let k = 0; k < n; k++) {
      const c = v.getUint32(ct[1] + 8 + 8 * k)
      const o = v.getInt32(ct[1] + 12 + 8 * k)
      for (let j = 0; j < c && i < count; j++) cto[i++] = o
    }
  }
  let sync: Uint8Array | null = null
  const ss = box('stss')
  if (ss) {
    sync = new Uint8Array(count)
    const n = v.getUint32(ss[1] + 4)
    for (let k = 0; k < n; k++) {
      const x = v.getUint32(ss[1] + 8 + 4 * k) - 1
      if (x >= 0 && x < count) sync[x] = 1
    }
  }
  const nChunks = co ? v.getUint32(co[1] + 4) : v.getUint32(sc![1] + 4)
  const chunkOff = (c: number) => (co ? Number(v.getBigUint64(co[1] + 8 + 8 * c)) : v.getUint32(sc![1] + 8 + 4 * c))
  const nsc = v.getUint32(stscB[1] + 4)
  const offset = new Float64Array(count)
  let i = 0
  for (let k = 0; k < nsc; k++) {
    const first = v.getUint32(stscB[1] + 8 + 12 * k) - 1
    const spc = v.getUint32(stscB[1] + 12 + 12 * k)
    if (v.getUint32(stscB[1] + 16 + 12 * k) !== 1) throw new Mp4Error('MP4: several formats')
    const next = k + 1 < nsc ? v.getUint32(stscB[1] + 8 + 12 * (k + 1)) - 1 : nChunks
    for (let c = first; c < next && c < nChunks; c++) {
      let off = chunkOff(c)
      for (let j = 0; j < spc && i < count; j++) {
        offset[i] = off
        off += size[i]
        i++
      }
    }
  }
  if (i < count) throw new Mp4Error('MP4: sample table')
  const shift = mediaTime - Math.round((emptyDelay * ts) / movieTs)
  return { id, handler, timescale: ts, codec, stsd, width, height, matrix, count, dts, end: tEnd, cto, size, offset, sync, shift }
}

// ------------------------------------------------------------------------------------------------- Schreiben

export interface Sink {
  write: (d: Uint8Array | Blob) => Promise<void>
  /** an eine frühere Stelle schreiben (nur für die mdat-Größe am Ende) */
  writeAt: (pos: number, d: Uint8Array) => Promise<void>
}

function cat(parts: Uint8Array[]): Uint8Array {
  let n = 0
  for (const p of parts) n += p.length
  const out = new Uint8Array(n)
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

function num(bytes: number, x: number, signed = false): Uint8Array {
  const out = new Uint8Array(bytes)
  const v = new DataView(out.buffer)
  if (bytes === 1) v.setUint8(0, x)
  else if (bytes === 2) v.setUint16(0, x)
  else if (bytes === 3) {
    v.setUint8(0, (x >>> 16) & 255)
    v.setUint16(1, x & 0xffff)
  } else if (bytes === 4) {
    if (signed) v.setInt32(0, x)
    else v.setUint32(0, x)
  } else if (signed) v.setBigInt64(0, BigInt(Math.round(x)))
  else v.setBigUint64(0, BigInt(Math.round(x)))
  return out
}
const u8 = (x: number) => num(1, x)
const u16 = (x: number) => num(2, x)
const u24 = (x: number) => num(3, x)
const u32 = (x: number) => num(4, x)
const u64 = (x: number) => num(8, x)
const i64 = (x: number) => num(8, x, true)
const zeros = (n: number) => new Uint8Array(n)
const str = (s: string) => enc.encode(s)

function box(type: string, ...parts: Uint8Array[]): Uint8Array {
  const body = cat(parts)
  const out = new Uint8Array(8 + body.length)
  new DataView(out.buffer).setUint32(0, out.length)
  out.set(str(type), 4)
  out.set(body, 8)
  return out
}

function full(type: string, version: number, flags: number, ...parts: Uint8Array[]): Uint8Array {
  return box(type, u32(((version << 24) | flags) >>> 0), ...parts)
}

/** Tabelle mit festen Feldern je Eintrag als Kasten (schnell auch für Millionen Einträge) */
function table(type: string, version: number, rows: number, fields: number[], get: (row: number, field: number) => number, prefix: Uint8Array[] = []): Uint8Array {
  const rowBytes = fields.reduce((a, b) => a + b, 0)
  const pre = cat(prefix)
  const out = new Uint8Array(12 + pre.length + 4 + rows * rowBytes)
  const v = new DataView(out.buffer)
  v.setUint32(0, out.length)
  out.set(str(type), 4)
  v.setUint32(8, (version << 24) >>> 0)
  out.set(pre, 12)
  let o = 12 + pre.length
  v.setUint32(o, rows)
  o += 4
  for (let r = 0; r < rows; r++) {
    for (let f = 0; f < fields.length; f++) {
      const x = get(r, f)
      if (fields[f] === 4) {
        if (x < 0) v.setInt32(o, x)
        else v.setUint32(o, x)
      } else v.setBigUint64(o, BigInt(Math.round(x)))
      o += fields[f]
    }
  }
  return out
}

const MATRIX = cat([u32(0x00010000), u32(0), u32(0), u32(0), u32(0x00010000), u32(0), u32(0), u32(0), u32(0x40000000)])

interface WTrack {
  handler: string
  ts: number
  stsd: Uint8Array
  width: number
  height: number
  matrix: Uint8Array
  shift: number
  /** Darstellungsdauer (Zeitbasis der Spur) für die Schnittliste; null = Summe der Probendauern */
  presentation: number | null
  sizes: number[]
  durs: number[]
  ctos: number[] | null
  syncs: number[]
  chunkOff: number[]
  chunkN: number[]
}

/** MP4 stückweise schreiben: start(), sample() … flush() …, finish(). */
export class Mp4Writer {
  private pos = 0
  private mdat = 0
  private buf: Uint8Array[] = []
  private bufBytes = 0
  private tracks: WTrack[] = []
  private last = -1

  constructor(private sink: Sink) {}

  track(o: { handler: 'vide' | 'soun'; timescale: number; stsd?: Uint8Array; width?: number; height?: number; matrix?: Uint8Array; shift?: number }): number {
    this.tracks.push({ handler: o.handler, ts: o.timescale, stsd: o.stsd ?? new Uint8Array(0), width: o.width ?? 0, height: o.height ?? 0,
      matrix: o.matrix ?? MATRIX, shift: o.shift ?? 0, presentation: null, sizes: [], durs: [], ctos: null, syncs: [], chunkOff: [], chunkN: [] })
    return this.tracks.length - 1
  }

  /** stsd, Anfang in der Spur (Vorlauf des Kodierers) und Darstellungsdauer nachtragen, solange moov nicht geschrieben ist */
  set(k: number, o: { stsd?: Uint8Array; shift?: number; presentation?: number }): void {
    const t = this.tracks[k]
    if (o.stsd) t.stsd = o.stsd
    if (o.shift != null) t.shift = o.shift
    if (o.presentation != null) t.presentation = o.presentation
  }

  /** Negative Kompositionsversätze (B-Frames eines neuen Kodierers) aufheben: alle um D anheben, die Schnittliste
   * beginnt D später. Manche Abspieler lesen ctts nur ohne Vorzeichen. */
  liftCto(k: number): void {
    const t = this.tracks[k]
    if (!t.ctos) return
    let low = 0
    for (const c of t.ctos) if (c < low) low = c
    if (low >= 0) return
    for (let i = 0; i < t.ctos.length; i++) t.ctos[i] -= low
    t.shift -= low
  }

  /** Zahl der Proben einer Spur */
  count(k: number): number {
    return this.tracks[k].sizes.length
  }

  async start(brands: string[] = []): Promise<void> {
    const ftyp = box('ftyp', str('isom'), u32(0x200), ...['isom', 'iso2', ...brands, 'mp41'].map(str))
    this.mdat = ftyp.length
    await this.sink.write(cat([ftyp, u32(1), str('mdat'), u64(0)]))
    this.pos = ftyp.length + 16
  }

  /** eine Probe anhängen (gepuffert bis flush) */
  sample(k: number, data: Uint8Array, duration: number, sync = true, cto = 0): void {
    const t = this.tracks[k]
    if (this.last !== k || t.chunkN[t.chunkN.length - 1] >= 2048) {
      t.chunkOff.push(this.pos + this.bufBytes)
      t.chunkN.push(0)
      this.last = k
    }
    t.chunkN[t.chunkN.length - 1]++
    t.sizes.push(data.byteLength)
    t.durs.push(duration)
    if (cto !== 0 && !t.ctos) t.ctos = new Array(t.sizes.length - 1).fill(0)
    if (t.ctos) t.ctos.push(cto)
    if (sync) t.syncs.push(t.sizes.length)
    this.buf.push(data)
    this.bufBytes += data.byteLength
  }

  get buffered(): number {
    return this.bufBytes
  }

  async flush(): Promise<void> {
    if (!this.bufBytes) return
    const parts = this.buf
    const n = this.bufBytes
    this.buf = []
    this.bufBytes = 0
    await this.sink.write(new Blob(parts as BlobPart[]))
    this.pos += n
  }

  /** moov schreiben und die mdat-Größe eintragen; gibt die Dateigröße zurück */
  async finish(movieTs = 1000): Promise<number> {
    await this.flush()
    const mdatSize = this.pos - this.mdat
    const traks: Uint8Array[] = []
    let maxDur = 0
    this.tracks.forEach((t, i) => {
      let media = 0
      for (const d of t.durs) media += d
      const pres = t.presentation ?? media
      const presM = Math.round((pres * movieTs) / t.ts)
      maxDur = Math.max(maxDur, presM)
      traks.push(this.trak(t, i + 1, media, presM))
    })
    const mvhd = full('mvhd', 1, 0, u64(0), u64(0), u32(movieTs), u64(maxDur), u32(0x00010000), u16(0x0100), zeros(10), MATRIX, zeros(24), u32(this.tracks.length + 1))
    const moov = box('moov', mvhd, ...traks)
    await this.sink.write(moov)
    await this.sink.writeAt(this.mdat + 8, u64(mdatSize))
    this.pos += moov.length
    return this.pos
  }

  private trak(t: WTrack, id: number, media: number, presM: number): Uint8Array {
    const vid = t.handler === 'vide'
    const tkhd = full('tkhd', 1, 3, u64(0), u64(0), u32(id), u32(0), u64(presM), zeros(8), u16(0), u16(vid ? 0 : 1), u16(vid ? 0 : 0x0100), u16(0),
      t.matrix, u32(Math.round(t.width * 65536)), u32(Math.round(t.height * 65536)))
    const edts = box('edts', full('elst', 1, 0, u32(1), u64(presM), i64(t.shift), u16(1), u16(0)))
    const mdhd = full('mdhd', 1, 0, u64(0), u64(0), u32(t.ts), u64(media), u16(0x55c4), u16(0))
    const hdlr = full('hdlr', 0, 0, u32(0), str(t.handler), zeros(12), str(vid ? 'VideoHandler\0' : 'SoundHandler\0'))
    const xmhd = vid ? full('vmhd', 0, 1, zeros(8)) : full('smhd', 0, 0, zeros(4))
    const dinf = box('dinf', full('dref', 0, 0, u32(1), full('url ', 0, 1)))
    // Laufweise zusammengefasst: Dauern (stts), Versätze (ctts), Proben je Block (stsc)
    const runs = (xs: number[]): [number, number][] => {
      const out: [number, number][] = []
      for (const x of xs) {
        const l = out[out.length - 1]
        if (l && l[1] === x) l[0]++
        else out.push([1, x])
      }
      return out
    }
    const stts = runs(t.durs)
    const parts = [t.stsd, table('stts', 0, stts.length, [4, 4], (r, f) => stts[r][f])]
    if (t.ctos) {
      const c = runs(t.ctos)
      parts.push(table('ctts', c.some((x) => x[1] < 0) ? 1 : 0, c.length, [4, 4], (r, f) => c[r][f]))
    }
    if (t.syncs.length < t.sizes.length) parts.push(table('stss', 0, t.syncs.length, [4], (r) => t.syncs[r]))
    const sc: [number, number][] = []
    t.chunkN.forEach((n, i) => {
      if (!sc.length || sc[sc.length - 1][1] !== n) sc.push([i + 1, n])
    })
    parts.push(table('stsc', 0, sc.length, [4, 4, 4], (r, f) => (f === 2 ? 1 : sc[r][f])))
    parts.push(table('stsz', 0, t.sizes.length, [4], (r) => t.sizes[r], [u32(0)]))
    parts.push(table('co64', 0, t.chunkOff.length, [8], (r) => t.chunkOff[r]))
    return box('trak', tkhd, edts, box('mdia', mdhd, hdlr, box('minf', xmhd, dinf, box('stbl', ...parts))))
  }
}

/** stsd für AAC-LC (mp4a mit esds) */
/** stsd für neu kodiertes H.264 (eingebrannte Untertitel): avc1 mit dem avcC des Kodierers */
export function avcStsd(width: number, height: number, avcC: Uint8Array): Uint8Array {
  const name = zeros(32)
  const label = str('NVAI-open')
  name[0] = label.length
  name.set(label, 1)
  const avc1 = box('avc1', zeros(6), u16(1), u16(0), u16(0), zeros(12), u16(width), u16(height), u32(0x00480000), u32(0x00480000),
    u32(0), u16(1), name, u16(0x0018), u16(0xffff), box('avcC', avcC))
  return full('stsd', 0, 0, u32(1), avc1)
}

/** Inhalt des avcC- bzw. hvcC-Kastens aus einem stsd (für VideoDecoder.configure) und der Codec-Text dazu */
export function videoConfig(stsd: Uint8Array): { codec: string; description: Uint8Array } | null {
  for (let i = 4; i + 4 <= stsd.length; i++) {
    const tag = String.fromCharCode(stsd[i], stsd[i + 1], stsd[i + 2], stsd[i + 3])
    if (tag !== 'avcC') continue
    const size = new DataView(stsd.buffer, stsd.byteOffset + i - 4, 4).getUint32(0)
    const body = stsd.slice(i + 4, i - 4 + size)
    if (body.length < 4) return null
    const hex = (x: number) => x.toString(16).padStart(2, '0')
    return { codec: `avc1.${hex(body[1])}${hex(body[2])}${hex(body[3])}`, description: body }
  }
  return null
}

export function aacStsd(sampleRate: number, channels: number, asc: Uint8Array, bitrate: number): Uint8Array {
  const desc = (tag: number, body: Uint8Array) => cat([u8(tag), u8(body.length), body])
  const dcd = desc(0x04, cat([u8(0x40), u8(0x15), u24(0), u32(bitrate), u32(bitrate), desc(0x05, asc)]))
  const es = desc(0x03, cat([u16(0), u8(0), dcd, desc(0x06, u8(0x02))]))
  const mp4a = box('mp4a', zeros(6), u16(1), zeros(8), u16(channels), u16(16), u16(0), u16(0), u32(sampleRate * 65536), full('esds', 0, 0, es))
  return full('stsd', 0, 0, u32(1), mp4a)
}

/** AudioSpecificConfig aus der description des Kodierers: Chrome liefert die ASC selbst (bei 48 kHz Stereo 11 90),
 * WebKit (Mac-App 0.5.7) einen ganzen ES-Deskriptor (03 … 04 … 05 <ASC> 06 …). Ungeprüft eingebettet lag der
 * Deskriptor im esds der MP4, und Abspieler lasen 22 050 Hz mit 0 Kanälen (gefunden am 18.11. mit PyAV). Auch eine
 * esds-Box wird ausgepackt. Ergebnis null, wenn keine ASC zu finden ist (dann aacAsc). */
export function ascFrom(d: Uint8Array): Uint8Array | null {
  if (d.length >= 12 && String.fromCharCode(d[4], d[5], d[6], d[7]) === 'esds') d = d.subarray(12)
  // Eine ASC beginnt mit dem Objekttyp in 5 Bit (AAC-LC = 2, also 0x10–0x17); 0x03–0x05 wären Typ 0 = ungültig
  if (d.length >= 2 && (d[0] < 0x03 || d[0] > 0x05)) return d
  const size = (p: number): [number, number] => {
    let n = 0
    let i = p
    for (let k = 0; k < 4 && i < d.length; k++) {
      const b = d[i++]
      n = (n << 7) | (b & 0x7f)
      if (!(b & 0x80)) break
    }
    return [n, i]
  }
  const find = (p: number, end: number): Uint8Array | null => {
    while (p + 1 < end) {
      const tag = d[p]
      const [n, q] = size(p + 1)
      if (tag === 0x05) return d.slice(q, Math.min(end, q + n))
      if (tag === 0x03) {
        const flags = d[q + 2]
        let r = q + 3
        if (flags & 0x80) r += 2
        if (flags & 0x40) r += 1 + d[r]
        if (flags & 0x20) r += 2
        const x = find(r, Math.min(end, q + n))
        if (x) return x
      } else if (tag === 0x04) {
        const x = find(q + 13, Math.min(end, q + n))
        if (x) return x
      }
      p = q + n
    }
    return null
  }
  const asc = find(0, d.length)
  return asc && asc.length >= 2 ? asc : null
}

/** AudioSpecificConfig für AAC-LC, falls der Kodierer keine liefert */
export function aacAsc(sampleRate: number, channels: number): Uint8Array {
  const rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
  const fi = Math.max(0, rates.indexOf(sampleRate))
  const x = (2 << 11) | (fi << 7) | (channels << 3)
  return new Uint8Array([x >> 8, x & 255])
}
