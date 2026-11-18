// „Speichern unter“ der Prüf-App (File System Access): stückweise schreiben, auch mehrere GB, mit Nachtrag an einer
// früheren Stelle (MP4: mdat-Größe) und Verwerfen bei Abbruch.

import type { Sink } from './mp4'

export interface SaveFile extends Sink {
  name: string
  close: () => Promise<void>
  /** halb geschriebene Datei verwerfen */
  abort: () => Promise<void>
}

interface Writable {
  write: (d: unknown) => Promise<void>
  close: () => Promise<void>
  abort: () => Promise<void>
}

type Picker = (o: unknown) => Promise<{ name: string; createWritable: () => Promise<Writable> }>

export async function saveFile(suggested: string, description: string, mime: string, ext: string): Promise<SaveFile> {
  const picker = (window as unknown as { showSaveFilePicker: Picker }).showSaveFilePicker
  const handle = await picker({ suggestedName: suggested, types: [{ description, accept: { [mime]: [ext] } }] })
  const w = await handle.createWritable()
  return {
    name: handle.name,
    write: (d) => w.write(d),
    writeAt: (pos, d) => w.write({ type: 'write', position: pos, data: d }),
    close: () => w.close(),
    abort: () => w.abort(),
  }
}

/** kleine Textdatei (z. B. Untertitel) über „Speichern unter“ */
export async function saveText(suggested: string, text: string, description: string, mime: string, ext: string): Promise<string> {
  const f = await saveFile(suggested, description, mime, ext)
  try {
    await f.write(new Blob([text], { type: mime }))
    await f.close()
  } catch (e) {
    await f.abort().catch(() => undefined)
    throw e
  }
  return f.name
}
