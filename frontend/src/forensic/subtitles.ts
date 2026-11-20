// Untertitel, die jeder Player liest, und eingebrannte Untertitel (Nutzer 20.11.2026: „die untertitel werden nicht in das
// video eingebaut und windows media player gibt einen fehler aus wenn ich versuche die exportierten dranzuhängen“).
//
// Gemessen mit dem Untertitel-Parser von Windows (Windows.Media.Core.TimedTextSource, den auch die Medienwiedergabe
// nutzt): Eine einzige Zeile ab 1024 Zeichen verwirft die ganze Datei (DataFormatError 0xC00D36B1, „Puffer zu klein“).
// Bis dahin stand jeder Block in einer Zeile, und Übersetzungen erreichten im Fall 2983 Zeichen. Überlappende Blöcke,
// LF-Zeilenenden, zwölf Stunden Länge und unsortierte Blöcke nahm der Parser an. Deshalb wie im Fernsehen höchstens zwei
// Zeilen zu 42 Zeichen je Block; längere Texte gehen auf aufeinanderfolgende Blöcke, die Zeit nach Textlänge verteilt.
// Dieselben Regeln gelten in NVAI-open (forensic_tools.sub_layout), damit SRT und eingebranntes Bild übereinstimmen.

export interface Cue {
  start: number
  end: number
  text: string
}

export interface LaidCue {
  start: number
  end: number
  lines: string[]
}

export const MAX_LINE = 42
export const MAX_LINES = 2

/** Text auf Zeilen von höchstens `max` Zeichen umbrechen (an Leerzeichen; überlange Wörter werden geteilt). */
export function wrapLines(text: string, max = MAX_LINE): string[] {
  const words = text.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean)
  const lines: string[] = []
  let cur = ''
  for (let w of words) {
    while (w.length > max) {
      if (cur) {
        lines.push(cur)
        cur = ''
      }
      lines.push(w.slice(0, max))
      w = w.slice(max)
    }
    if (!w) continue
    if (!cur) cur = w
    else if (cur.length + 1 + w.length <= max) cur += ' ' + w
    else {
      lines.push(cur)
      cur = w
    }
  }
  if (cur) lines.push(cur)
  return lines
}

/** Blöcke umbrechen, zu lange auf aufeinanderfolgende Blöcke verteilen (Zeit nach Textlänge), nach Beginn sortieren.
 * `clip` [von, bis]: Teile außerhalb fallen weg, angeschnittene werden gekürzt (ein Satz, der vor dem ersten Bild des
 * Videos begann, wird nicht in den sichtbaren Rest gestaucht). */
export function layoutCues(cues: Cue[], maxLine = MAX_LINE, maxLines = MAX_LINES, clip?: [number, number]): LaidCue[] {
  const out: LaidCue[] = []
  for (const c of cues) {
    const lines = wrapLines(c.text, maxLine)
    if (!lines.length) continue
    const chunks: string[][] = []
    for (let i = 0; i < lines.length; i += maxLines) chunks.push(lines.slice(i, i + maxLines))
    const weights = chunks.map((ch) => ch.join(' ').length)
    const total = weights.reduce((s, x) => s + x, 0) || 1
    const dur = Math.max(0, c.end - c.start)
    let t0 = c.start
    let acc = 0
    chunks.forEach((ch, i) => {
      acc += weights[i]
      const t1 = i === chunks.length - 1 ? Math.max(c.start, c.end) : c.start + (dur * acc) / total
      const a = clip ? Math.max(clip[0], t0) : t0
      const b = clip ? Math.min(clip[1], t1) : t1
      if (!clip || (b > a || (t1 === t0 && t0 >= clip[0] && t0 < clip[1]))) out.push({ start: a, end: b, lines: ch })
      t0 = t1
    })
  }
  // stabil: gleich beginnende Blöcke behalten ihre Reihenfolge
  return out.map((c, i) => [c, i] as const).sort((a, b) => a[0].start - b[0].start || a[1] - b[1]).map((x) => x[0])
}

export function subTime(x: number, sep = ','): string {
  const ms = Math.round(Math.max(0, x) * 1000)
  const p = (v: number, n = 2) => String(v).padStart(n, '0')
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)}${sep}${p(ms % 1000, 3)}`
}

/** SRT mit Windows-Zeilenenden, ohne BOM (die Aufrufer setzen es). */
export function toSrt(cues: Cue[], clip?: [number, number]): { text: string; cues: number } {
  const laid = layoutCues(cues, MAX_LINE, MAX_LINES, clip)
  const text = laid.map((c, i) => `${i + 1}\r\n${subTime(c.start)} --> ${subTime(c.end)}\r\n${c.lines.join('\r\n')}\r\n`).join('\r\n')
  return { text, cues: laid.length }
}

/** WebVTT; `voice` je Block als <v Name>, Hinweise als NOTE am Anfang. */
export function toVtt(cues: (Cue & { voice?: string })[], note: string[] = []): string {
  const laid: (LaidCue & { voice?: string })[] = []
  for (const c of cues) for (const l of layoutCues([c])) laid.push({ ...l, voice: c.voice })
  laid.sort((a, b) => a.start - b.start)
  const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  const head = note.length ? `NOTE\r\n${note.join('\r\n').replace(/-->/g, '->')}\r\n\r\n` : ''
  return `WEBVTT\r\n\r\n${head}${laid.map((c) => `${subTime(c.start, '.')} --> ${subTime(c.end, '.')}\r\n${c.voice ? `<v ${esc(c.voice)}>` : ''}${c.lines.map(esc).join('\r\n')}\r\n`).join('\r\n')}`
}

/** Aktive Blöcke zur Zeit `t` (höchstens `max`, die zuletzt begonnenen). `laid` nach Beginn sortiert. */
export function activeCues(laid: LaidCue[], t: number, max = 3): LaidCue[] {
  const on = laid.filter((c) => c.start <= t && t < c.end)
  return on.slice(Math.max(0, on.length - max))
}

/** Untertitel unten ins Bild zeichnen: weiße Schrift auf halbdurchsichtigem Schwarz, Größe nach der Bildhöhe;
 * gleichzeitig laufende Blöcke (mehrere Kanäle) stehen übereinander, der zuletzt begonnene unten. */
export function drawSubtitles(ctx: OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D, w: number, h: number, cues: LaidCue[]): void {
  if (!cues.length) return
  const size = Math.max(14, Math.round(h * 0.045))
  const lh = Math.round(size * 1.3)
  const padX = Math.round(size * 0.4)
  const gap = Math.round(size * 0.35)
  ctx.save()
  ctx.font = `600 ${size}px "Segoe UI", system-ui, -apple-system, Arial, sans-serif`
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  let y = h - Math.round(h * 0.06)
  for (let i = cues.length - 1; i >= 0; i--) {
    const lines = cues[i].lines
    for (let k = lines.length - 1; k >= 0; k--) {
      const tw = Math.min(w - 8, ctx.measureText(lines[k]).width)
      ctx.fillStyle = 'rgba(0, 0, 0, 0.62)'
      ctx.fillRect(Math.round(w / 2 - tw / 2 - padX), y - lh, Math.round(tw + 2 * padX), lh)
      ctx.fillStyle = '#ffffff'
      ctx.fillText(lines[k], w / 2, y - lh / 2, w - 8)
      y -= lh
    }
    y -= gap
  }
  ctx.restore()
}
