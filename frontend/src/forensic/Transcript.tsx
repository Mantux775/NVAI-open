import { useEffect, useMemo, useRef, useState } from 'react'
import type { AudioProject, AudioTrack, TranscriptCredits, TranscriptDoc, TranscriptSegment } from '../api'
import { t } from '../i18n'
import { clockAt } from './Lanes'
import { toSrt, toVtt } from './subtitles'

// Übersetzer-Spur der Ton-Forensik: Liste aller Blöcke zweispaltig (Original | Übersetzung) wie in Gerichts-
// Transkripten, Bearbeiten eines Blocks, Blöcke aus der Auswahl anlegen, Export als Text, SRT/VTT und CSV.
// Was die KI schreibt, bleibt „Entwurf“, bis ein Mensch den Block als geprüft markiert.

export const LANGS: [string, string, string][] = [
  ['tl', 'Tagalog / Filipino', 'Tagalog / Filipino'], ['ceb', 'Cebuano', 'Cebuano'], ['en', 'Englisch', 'English'],
  ['de', 'Deutsch', 'German'], ['es', 'Spanisch', 'Spanish'], ['fr', 'Französisch', 'French'], ['it', 'Italienisch', 'Italian'],
  ['nl', 'Niederländisch', 'Dutch'], ['pl', 'Polnisch', 'Polish'], ['ru', 'Russisch', 'Russian'], ['uk', 'Ukrainisch', 'Ukrainian'],
  ['zh', 'Chinesisch', 'Chinese'], ['ja', 'Japanisch', 'Japanese'], ['ko', 'Koreanisch', 'Korean'], ['id', 'Indonesisch', 'Indonesian'],
  ['vi', 'Vietnamesisch', 'Vietnamese'], ['hi', 'Hindi', 'Hindi'], ['tr', 'Türkisch', 'Turkish'],
]

/** Vermerke der Zweitmeinung zeigt die App nicht mehr: Im Schreiber-Fall war sie bei 52 % der Blöcke unbrauchbar und
 * widersprach bei weiteren 32 %, ihre Ähnlichkeit zu Whisper war gleich verteilt (18.11.); als Warnung taugt sie nicht. */
const HIDDEN_NOTES = new Set(['second_unusable', 'disputed'])

/** Prüfvermerke der KI lesbar machen */
function noteText(note: string): string {
  const map: Record<string, string> = {
    low_confidence: t('KI unsicher', 'AI unsure'), repetition: t('Wiederholung: möglicherweise erfunden', 'repetition: possibly invented'),
    untranslated: t('nicht übersetzt', 'not translated'),
    disputed: t('Zweitmeinung hört deutlich anderes', 'second opinion hears something clearly different'),
    second_unusable: t('Zweitmeinung unbrauchbar', 'second opinion unusable'),
  }
  return note.split(',').map((x) => x.trim()).filter((x) => x && !HIDDEN_NOTES.has(x)).map((x) => map[x] ?? x).join(' · ')
}

export async function download(name: string, text: string, type = 'text/plain'): Promise<void> {
  const blob = new Blob(['﻿' + text], { type: `${type};charset=utf-8` })
  // Speicherort wählen (Nutzer 18.11.): Chrome und Edge öffnen „Speichern unter“, sonst der übliche Download
  const picker = (window as unknown as { showSaveFilePicker?: (o: unknown) => Promise<{ createWritable: () => Promise<{ write: (b: Blob) => Promise<void>; close: () => Promise<void> }> }> }).showSaveFilePicker
  if (picker) {
    try {
      const ext = name.includes('.') ? name.slice(name.lastIndexOf('.')) : '.txt'
      const handle = await picker({ suggestedName: name, types: [{ description: ext.slice(1).toUpperCase(), accept: { [type]: [ext] } }] })
      const w = await handle.createWritable()
      await w.write(blob)
      await w.close()
      return
    } catch (e) {
      if ((e as DOMException)?.name === 'AbortError') return
    }
  }
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 2000)
}

/** Übersetzer-Spur exportieren (Nutzer 17.11.: „erkannte und übersetzte sprache exportieren“): Text zweisprachig im
 * Gerichtsformat (Nr, Zeit, Kanal, Sprecher, Original, Übersetzung, Anmerkung), CSV, Untertitel SRT/VTT. opts: nur
 * geprüfte Blöcke, nur ein Zeitbereich. */
const CREDIT_ROLES: Record<string, [string, string]> = {
  asr: ['Spracherkennung', 'speech recognition'], translate: ['Übersetzung', 'translation'],
  second: ['Zweitmeinung', 'second opinion'], vad: ['Sprachfinder', 'speech detection'],
}

/** Hinweis, womit die Übersetzer-Spur berechnet wurde (Nutzer 18.11.: „bei der übersetzung soll ein hinweiss stehen,
 * mit welchem model auf lokaler hardware unter welcher lizenz wurden die berechnet“). Leer ohne Läufe. */
export function creditsLines(c: TranscriptCredits | null | undefined): string[] {
  if (!c || !c.models?.length) return []
  const order = ['asr', 'translate', 'second', 'vad']
  const models = [...c.models].sort((x, y) => order.indexOf(x.role) - order.indexOf(y.role)).map((m) => {
    const [de, en] = CREDIT_ROLES[m.role] ?? [m.role, m.role]
    const about = [m.by, m.license && t(`Lizenz ${m.license}`, `${m.license} license`)].filter(Boolean).join(', ')
    return `${t(de, en)}: ${m.name}${about ? ` (${about})` : ''}`
  })
  const gpus = [...new Set([...(c.gpus ?? []), ...(c.unrecorded ? c.gpus_now ?? [] : [])])]
  const where = gpus.length ? t(`auf einem Rechner mit ${gpus.join(', ')}`, `on a computer with ${gpus.join(', ')}`)
    : t('auf dem Auswerte-Rechner', 'on the analysis computer')
  const prog = c.programs?.length ? `, ${t('mit', 'with')} ${c.programs.join(', ')}` : ''
  return [t(`Berechnet lokal ${where}, ohne Internetdienste${prog}.`, `Computed locally ${where}, without internet services${prog}.`), `${models.join(' · ')}.`]
}

export function exportTranscript(proj: AudioProject, tracks: AudioTrack[], doc: TranscriptDoc, fmt: 'txt' | 'srt' | 'vtt' | 'csv',
  useTr: boolean, opts: { checkedOnly?: boolean; region?: [number, number] | null }): number {
  const origin = proj.time_origin
  const tl = doc.target_lang || 'de'
  const trackName = (id: string) => tracks.find((x) => x.id === id)?.name ?? id
  const base = (proj.name || 'transkript').replace(/[^\w\-. ]+/g, '_')
  const text = (s: TranscriptSegment) => {
    const v = useTr ? (s.translation?.[tl] || '') : s.text
    return s.kind === 'sound' ? `[${v}]` : v
  }
  const lines = doc.segments.filter((s) => (!opts.checkedOnly || s.status === 'checked')
    && (!opts.region || (s.end > opts.region[0] && s.start < opts.region[1])))
  const rel = (x: number) => (opts.region ? x - opts.region[0] : x)
  if (fmt === 'srt') {
    // höchstens zwei Zeilen zu 42 Zeichen je Block, lange Blöcke aufgeteilt (subtitles.ts): Eine Zeile ab 1024 Zeichen
    // ließ den Windows Media Player die ganze Datei ablehnen; leere Blöcke (nicht übersetzt) fallen weg
    download(`${base}_${useTr ? tl : 'original'}.srt`, toSrt(lines.filter((s) => text(s).trim() && text(s) !== '[]')
      .map((s) => ({ start: rel(s.start), end: rel(s.end), text: `${s.speaker ? `${s.speaker}: ` : ''}${text(s)}` }))).text)
  } else if (fmt === 'vtt') {
    const note = creditsLines(doc.credits)
    download(`${base}_${useTr ? tl : 'original'}.vtt`, toVtt(lines.filter((s) => text(s).trim() && text(s) !== '[]')
      .map((s) => ({ start: rel(s.start), end: rel(s.end), text: text(s), voice: s.speaker || undefined })), note), 'text/vtt')
  } else if (fmt === 'csv') {
    const q = (v: string) => `"${(v ?? '').replace(/"/g, '""')}"`
    download(`${base}_${t('transkript', 'transcript')}.csv`, ['nr;start_s;end_s;time;channel;speaker;kind;status;confidence;original;translation_en;translation;second_opinion;note',
      ...lines.map((s, i) => [i + 1, s.start.toFixed(2), s.end.toFixed(2), clockAt(s.start, origin, true), q(trackName(s.track)), q(s.speaker), s.kind, s.status,
        s.conf == null ? '' : s.conf.toFixed(2), q(s.text), q(s.translation?.en || ''), q(s.translation?.[tl] || ''), q(s.alt_text || ''), q(noteText(s.note || ''))].join(';'))].join('\n'), 'text/csv')
  } else {
    const head = t(`Transkript: ${proj.name}\nZeiten ${origin ? 'in UTC' : 'ab Beginn der Aufnahme'}. Blöcke mit „Entwurf“ stammen von der KI und sind ungeprüft; die Übersetzung ist ein Entwurf und ersetzt keine beeidigte Übersetzung.\n`,
      `Transcript: ${proj.name}\nTimes ${origin ? t('in UTC', 'in UTC') : t('ab Beginn der Aufnahme', 'from the start of the recording')}. Blocks marked “draft” come from the AI and are unchecked; the translation is a draft and does not replace a certified translation.\n`)
    const note = creditsLines(doc.credits)
    download(`${base}_${t('transkript', 'transcript')}.txt`, head + (note.length ? note.join('\n') + '\n' : '') + '\n' + lines.map((s, i) => [
      `${i + 1}. [${clockAt(s.start, origin, true)} – ${clockAt(s.end, origin, true)}] ${trackName(s.track)}${s.speaker ? ` · ${s.speaker}` : ''} · ${s.status === 'checked' ? t('geprüft', 'checked') : t('Entwurf', 'draft')}${s.conf != null ? ` · ${Math.round(s.conf * 100)} %` : ''}`,
      `  ${t('Original', 'Original')} (${s.lang || '?'}): ${s.kind === 'sound' ? `[${s.text}]` : s.text}`,
      ...(tl !== 'en' && s.translation?.en ? [`  ${t('Englisch (Entwurf)', 'English (draft)')}: ${s.translation.en}`] : []),
      ...(s.translation?.[tl] ? [`  ${t('Übersetzung', 'Translation')} (${tl}): ${s.kind === 'sound' ? `[${s.translation[tl]}]` : s.translation[tl]}`] : []),
      ...(noteText(s.note || '') ? [`  ${t('Anmerkung', 'Note')}: ${noteText(s.note || '')}`] : []),
    ].join('\n')).join('\n\n'))
  }
  return lines.length
}

export function TranscriptTool({ proj, tracks, doc, setDoc, save, selection, selected, setSelected, onSeek, showTranslation,
  setShowTranslation, playhead, onTranscribe, canTranscribe, busy, blind, setBlind, onInstallAsr, ai = true }: {
  proj: AudioProject
  tracks: AudioTrack[]
  doc: TranscriptDoc
  setDoc: (d: TranscriptDoc) => void
  save: (d: TranscriptDoc) => void
  selection: [number, number] | null
  selected: string | null
  setSelected: (id: string | null) => void
  onSeek: (s: number) => void
  showTranslation: boolean
  setShowTranslation: (v: boolean) => void
  playhead: number
  onTranscribe: (o: { tracks: string[]; source_lang: string; target_lang: string; region: [number, number] | null; force?: boolean }) => void
  canTranscribe: { ok: boolean; why: string; install?: boolean }
  busy: boolean
  onInstallAsr: () => void
  /** false im Player-Modus: ohne KI-Start */
  ai?: boolean
  blind: boolean
  setBlind: (v: boolean) => void
}) {
  const origin = proj.time_origin
  const tl = doc.target_lang || 'de'
  const [srcLang, setSrcLang] = useState(doc.source_lang || 'tl')
  useEffect(() => { if (doc.source_lang) setSrcLang(doc.source_lang) }, [doc.source_lang])
  const [which, setWhich] = useState<string[]>(() => tracks.filter((x) => x.kind === 'original').map((x) => x.id))
  const [onlySel, setOnlySel] = useState(false)
  // Feste Spur für den markierten Bereich (Nutzer 17.11.: „nach der sirene hört man die auf der anderen spur besser“)
  const [fixed, setFixed] = useState('')
  const [filter, setFilter] = useState<'all' | 'draft' | 'checked'>('all')
  const seg = doc.segments.find((s) => s.id === selected) ?? null
  const listRef = useRef<HTMLDivElement>(null)
  const segs = useMemo(() => doc.segments.filter((s) => filter === 'all' || s.status === filter), [doc.segments, filter])
  useEffect(() => {
    const el = listRef.current?.querySelector('.fx-tr-row.on') as HTMLElement | null
    if (el && listRef.current) {
      const top = el.offsetTop - listRef.current.offsetTop
      if (top < listRef.current.scrollTop || top > listRef.current.scrollTop + listRef.current.clientHeight - 40) listRef.current.scrollTop = top - 60
    }
  }, [selected])
  const trackName = (id: string) => tracks.find((x) => x.id === id)?.name ?? id

  const patch = (id: string, fields: Partial<TranscriptSegment>) => {
    const human = 'text' in fields || 'translation' in fields || 'speaker' in fields || 'note' in fields || 'kind' in fields
    const next = { ...doc, segments: doc.segments.map((s) => (s.id === id ? { ...s, ...fields, ...(human ? { origin: 'human' as const } : {}) } : s)) }
    setDoc(next)
    return next
  }
  const add = () => {
    if (!selection) return
    const s: TranscriptSegment = {
      id: Math.random().toString(36).slice(2, 12), start: selection[0], end: selection[1], track: which[0] ?? '', speaker: '',
      kind: 'speech', text: '', lang: srcLang, translation: {}, conf: null, status: 'checked', note: '',
    }
    const next = { ...doc, segments: [...doc.segments, s].sort((a, b) => a.start - b.start) }
    setDoc(next)
    save(next)
    setSelected(s.id)
  }
  const remove = (id: string) => {
    const next = { ...doc, segments: doc.segments.filter((s) => s.id !== id) }
    setDoc(next)
    save(next)
    setSelected(null)
  }
  const exportAs = (fmt: 'txt' | 'srt' | 'vtt' | 'csv', useTr: boolean) => exportTranscript(proj, tracks, doc, fmt, useTr, {})

  return (
    <div className="au-tool fx-tr">
      <p className="hint small">{t('Die KI hört je Kanal, schreibt das Gesprochene in der Originalsprache und übersetzt es. Jeder Block bleibt „Entwurf“, bis du ihn geprüft hast; im Zeitstrahl wechselt der Knopf am Block zwischen Original und Übersetzung.',
        'The AI listens per channel, writes what is said in the original language and translates it. Each block stays a “draft” until you have checked it; in the timeline the button on a block switches between original and translation.')}</p>
      {creditsLines(doc.credits).length > 0 && (
        <p className="muted small fx-credits">{creditsLines(doc.credits).map((l, i) => <span key={i}>{l}<br /></span>)}</p>
      )}
      <div className="lt-toolbar">
        <label className="lr-inline">{t('Gesprochen', 'Spoken')}
          <select value={srcLang} onChange={(e) => setSrcLang(e.target.value)}>
            <option value="auto">{t('erkennen', 'detect')}</option>
            {LANGS.map(([k, de, en]) => <option key={k} value={k}>{t(de, en)}</option>)}
          </select></label>
        <label className="lr-inline">{t('Übersetzen in', 'Translate into')}
          <select value={tl} onChange={(e) => { const next = { ...doc, target_lang: e.target.value }; setDoc(next); save(next) }}>
            {LANGS.map(([k, de, en]) => <option key={k} value={k}>{t(de, en)}</option>)}
          </select></label>
        <label className="check small"><input type="checkbox" checked={showTranslation} onChange={(e) => setShowTranslation(e.target.checked)} />{t('Übersetzung zeigen', 'Show translation')}</label>
        <label className="check small" title={t('Blendet den Text der KI (Entwurf) im Zeitstrahl aus, damit er beim Hören nicht vorgibt, was man zu hören meint', 'Hides the AI text (draft) in the timeline so it does not suggest what you think you hear')}>
          <input type="checkbox" checked={blind} onChange={(e) => setBlind(e.target.checked)} />{t('blind hören', 'listen blind')}</label>
      </div>
      {ai && <details className="fx-tr-run">
        <summary>{t('KI: transkribieren und übersetzen', 'AI: transcribe and translate')}</summary>
        <label className="lr-inline small">{t('Spur', 'Track')}
          <select value={fixed} onChange={(e) => setFixed(e.target.value)}>
            <option value="">{t('automatisch: je Abschnitt die deutlichste', 'automatic: the clearest per section')}</option>
            {tracks.map((x) => <option key={x.id} value={x.id}>{t(`fest: ${x.name}`, `fixed: ${x.name}`)}</option>)}
          </select></label>
        {fixed ? (
          <p className="hint small">{selection
            ? t(`Nur der markierte Bereich (${Math.round(selection[1] - selection[0])} s) wird auf dieser Spur erkannt. Entwürfe der KI von anderen Mikrofonen an dieser Stelle werden ersetzt, geprüfte Blöcke bleiben. Ein späterer Lauf mit Automatik lässt diese Blöcke stehen.`,
              `Only the marked range (${Math.round(selection[1] - selection[0])} s) is recognised on this track. AI drafts from other microphones there are replaced, checked blocks stay. A later automatic run leaves these blocks alone.`)
            : t('Erst im Zeitstrahl den Bereich ziehen, für den diese Spur gelten soll.', 'First drag the range in the timeline that this track should apply to.')}</p>
        ) : (
          <>
            <p className="hint small">{t('Die Mikrofone hören dasselbe Gespräch: Je Sprechabschnitt nimmt die KI das angehakte Mikrofon mit der deutlichsten Sprache, das zweitbeste dient als Gegenprobe. Liegt ein anderes Mikrofon mindestens 2 s klar vorn (z. B. bei einer Sirene), wechselt sie dort die Spur. Funkkanäle laufen je für sich.',
              'The microphones hear the same conversation: per speech section the AI takes the ticked microphone with the clearest speech, the runner-up serves as cross-check. If another microphone is clearly ahead for at least 2 s (e.g. during a siren), it switches track there. Radio channels run on their own.')}</p>
            <div className="fx-tr-tracks">
              {tracks.map((x) => (
                <label key={x.id} className="check small"><input type="checkbox" checked={which.includes(x.id)}
                  onChange={(e) => setWhich(e.target.checked ? [...which, x.id] : which.filter((y) => y !== x.id))} />{x.name}</label>
              ))}
            </div>
            <label className="check small"><input type="checkbox" checked={onlySel && !!selection} disabled={!selection} onChange={(e) => setOnlySel(e.target.checked)} />
              {selection ? t(`nur die Auswahl (${Math.round(selection[1] - selection[0])} s)`, `only the selection (${Math.round(selection[1] - selection[0])} s)`) : t('nur eine Auswahl (erst ziehen)', 'only a selection (drag first)')}</label>
          </>
        )}
        <div className="lt-toolbar">
          <button className="btn primary" disabled={!canTranscribe.ok || busy || (fixed ? !selection : !which.length)}
            onClick={() => onTranscribe(fixed && selection
              ? { tracks: [fixed], source_lang: srcLang, target_lang: tl, region: selection, force: true }
              : { tracks: which, source_lang: srcLang, target_lang: tl, region: onlySel && selection ? selection : null })}>
            {t('Transkribieren und übersetzen', 'Transcribe and translate')}</button>
          {!canTranscribe.ok && <span className="hint small warn">{canTranscribe.why}</span>}
          {!canTranscribe.ok && canTranscribe.install && <button className="btn small" onClick={onInstallAsr}>{t('Modelle laden', 'Download models')}</button>}
          {busy && <span className="hint small">{t('läuft …', 'running …')}</span>}
        </div>
        <p className="muted small">{t('Ablauf: Silero VAD prüft jede Stelle auf echte Sprache (sonst erfindet Whisper Sätze auf Lärm), je Stelle hört Whisper den klarsten Kanal, Qwen3.5-9B übersetzt erst nach Englisch und dann in die Zielsprache. Geprüfte Blöcke bleiben unangetastet; ein neuer Lauf ersetzt nur ungeänderte Entwürfe.',
          'Process: Silero VAD checks each place for real speech (otherwise Whisper invents sentences on noise), per place Whisper listens to the clearest channel, Qwen3.5-9B translates to English first and then into the target language. Checked blocks stay untouched; a new run only replaces unchanged drafts.')}</p>
        <div className="lt-toolbar">
        </div>
      </details>}

      <div className="lt-toolbar">
        <button className="btn small" disabled={!selection} onClick={add} title={t('Eigenen Block für die Auswahl anlegen (von Hand schreiben)', 'Add your own block for the selection (write by hand)')}>
          + {t('Block aus Auswahl', 'Block from selection')}</button>
        <select value={filter} onChange={(e) => setFilter(e.target.value as 'all' | 'draft' | 'checked')}>
          <option value="all">{t(`alle (${doc.segments.length})`, `all (${doc.segments.length})`)}</option>
          <option value="draft">{t(`Entwurf (${doc.segments.filter((s) => s.status === 'draft').length})`, `draft (${doc.segments.filter((s) => s.status === 'draft').length})`)}</option>
          <option value="checked">{t(`geprüft (${doc.segments.filter((s) => s.status === 'checked').length})`, `checked (${doc.segments.filter((s) => s.status === 'checked').length})`)}</option>
        </select>
        <span className="au-spacer" />
        <select value="" onChange={(e) => { const [f, u] = e.target.value.split(':'); if (f) exportAs(f as 'txt' | 'srt' | 'vtt' | 'csv', u === 'tr'); e.target.value = '' }}>
          <option value="">{t('Export …', 'Export …')}</option>
          <option value="txt:">{t('Text, zweisprachig', 'Text, bilingual')}</option>
          <option value="csv:">{t('Tabelle (CSV)', 'Table (CSV)')}</option>
          <option value="srt:">{t('Untertitel SRT, Original', 'Subtitles SRT, original')}</option>
          <option value="srt:tr">{t('Untertitel SRT, Übersetzung', 'Subtitles SRT, translation')}</option>
          <option value="vtt:tr">{t('Untertitel VTT, Übersetzung', 'Subtitles VTT, translation')}</option>
        </select>
      </div>

      {seg && (
        <div className="fx-tr-edit">
          <div className="lt-toolbar">
            <button className="linklike" onClick={() => onSeek(seg.start)}>{clockAt(seg.start, origin, true)} – {clockAt(seg.end, origin, true)}</button>
            <select value={seg.kind} onChange={(e) => save(patch(seg.id, { kind: e.target.value as TranscriptSegment['kind'] }))}>
              <option value="speech">{t('Sprache', 'speech')}</option><option value="radio">{t('Funk (UKW)', 'radio (VHF)')}</option>
              <option value="sound">{t('Geräusch / Laut', 'sound')}</option><option value="note">{t('Notiz', 'note')}</option>
            </select>
            <input className="fx-tr-speaker" value={seg.speaker} placeholder={t('Sprecher', 'Speaker')} onChange={(e) => patch(seg.id, { speaker: e.target.value })} onBlur={() => save(doc)} />
            <label className="check small"><input type="checkbox" checked={seg.status === 'checked'} onChange={(e) => save(patch(seg.id, { status: e.target.checked ? 'checked' : 'draft' }))} />{t('geprüft', 'checked')}</label>
            {seg.conf != null && <span className="muted small">{t('Sicherheit', 'confidence')} {Math.round(seg.conf * 100)} %</span>}
            <button className="au-x" title={t('Block löschen', 'delete block')} onClick={() => remove(seg.id)}>✕</button>
          </div>
          <label className="fx-tr-field">{t('Original', 'Original')} ({seg.lang || '?'})
            <textarea value={seg.text} rows={2} onChange={(e) => patch(seg.id, { text: e.target.value })} onBlur={() => save(doc)} /></label>
          <label className="fx-tr-field">{t('Übersetzung', 'Translation')} ({tl})
            <textarea value={seg.translation?.[tl] ?? ''} rows={2} onChange={(e) => patch(seg.id, { translation: { ...seg.translation, [tl]: e.target.value } })} onBlur={() => save(doc)} /></label>
          {(seg.words?.length ?? 0) > 0 && seg.words!.some((w) => w.length > 4) && (
            <div className="fx-tr-words">
              <span className="muted small">{t('Wort-Ampel (Klick: hinhören):', 'Word check (click: listen):')} </span>
              {seg.words!.map((w, i) => {
                // grün: Whisper ab 0,9 und von der Zweitmeinung bestätigt; rot: Whisper unter 0,5 (FLEURS: 57 % falsch)
                const sure = (w[3] ?? 0) >= 0.9 && !!w[4]
                const weak = (w[3] ?? 0) < 0.5
                return (
                  <button key={i} className={`fx-w ${sure ? 'sure' : weak ? 'weak' : 'check'}`}
                    title={t(`Whisper sicher zu ${Math.round((w[3] ?? 0) * 100)} %${w[4] ? ', Zweitmeinung hört dasselbe' : seg.alt_text ? ', Zweitmeinung hört es anders' : ''}`,
                      `Whisper ${Math.round((w[3] ?? 0) * 100)} % sure${w[4] ? t(', Zweitmeinung hört dasselbe', ', second opinion hears the same') : seg.alt_text ? t(', Zweitmeinung hört es anders', ', second opinion hears it differently') : ''}`)}
                    onClick={() => { if (w[0] != null) onSeek(Math.max(0, w[0] - 0.3)) }}>{w[2]}</button>
                )
              })}
              <p className="muted small fx-tr-legend">{t('grün: Whisper sicher (ab 90 %) und die Zweitmeinung hört dasselbe · gelb: prüfen · rot: Whisper unsicher (unter 50 %). Gelb heißt „hinhören“, nicht „falsch“.',
                'green: Whisper sure (90 % or more) and the second opinion hears the same · yellow: check · red: Whisper unsure (below 50 %). Yellow means “listen”, not “wrong”.')}</p>
            </div>
          )}
          {seg.alt_text && seg.origin === 'ai' && (
            <p className="muted small fx-tr-en">{t('Zweitmeinung (Omnilingual)', 'Second opinion (Omnilingual)')}{seg.second_sim != null ? t(`, ${Math.round(seg.second_sim * 100)} % gleich`, `, ${Math.round(seg.second_sim * 100)} % alike`) : ''}: {seg.alt_text}</p>
          )}
          {tl !== 'en' && seg.translation?.en && (
            <p className="muted small fx-tr-en">{t('Englischer Entwurf', 'English draft')}: {seg.translation.en}</p>
          )}
          {seg.note && seg.origin === 'ai' && <p className="small fx-tr-flags">{noteText(seg.note)}</p>}
          {seg.second && <p className="muted small">{t(`Gehört auf ${trackName(seg.track)}, Gegenprobe auf ${trackName(seg.second)}.`, `Heard on ${trackName(seg.track)}, cross-check on ${trackName(seg.second)}.`)}</p>}
          {seg.pinned && <p className="muted small">{t(`Spur von Hand festgelegt (${trackName(seg.track)}); ein Lauf mit Automatik lässt diesen Block stehen.`, `Track fixed by hand (${trackName(seg.track)}); an automatic run leaves this block alone.`)}</p>}
          <label className="fx-tr-field">{t('Notiz (Übersetzer, Unsicherheit)', 'Note (translator, uncertainty)')}
            <input value={seg.note} onChange={(e) => patch(seg.id, { note: e.target.value })} onBlur={() => save(doc)} /></label>
          <p className="muted small fx-tr-legend">{t('Schreibweise: [unverständlich] bzw. [unverständlich, ca. 2 Wörter] · [?Wort?] unsicher · //…// gleichzeitig gesprochen · [Alarm], [Funkrauschen] für Geräusche. Unverständliches nie mit einer Vermutung der KI füllen.',
            'Notation: [unintelligible] or [unintelligible, approx. 2 words] · [?word?] uncertain · //…// overlapping speech · [alarm], [radio static] for sounds. Never fill unintelligible parts with an AI guess.')}</p>
        </div>
      )}

      <div className="fx-tr-list" ref={listRef}>
        {segs.map((s) => (
          <div key={s.id} className={`fx-tr-row ${s.status}${s.id === selected ? ' on' : ''}${playhead >= s.start && playhead <= s.end ? ' now' : ''}${s.origin === 'ai' && /low_confidence|repetition/.test(s.note) ? ' unsure' : ''}`}
            title={s.origin === 'ai' && s.note ? noteText(s.note) : undefined}
            onClick={() => { setSelected(s.id); onSeek(s.start) }}>
            <span className="fx-tr-time">{clockAt(s.start, origin)}<br /><span className="muted small">{s.speaker || trackName(s.track)}</span>
              {(() => {
                const n = (s.words ?? []).filter((w) => w.length > 4 && !((w[3] ?? 0) >= 0.9 && w[4])).length
                return n > 0 && s.status === 'draft' ? <><br /><span className="fx-tr-check">{t(`${n} prüfen`, `${n} to check`)}</span></> : null
              })()}</span>
            <span className="fx-tr-orig">{s.kind === 'sound' ? `[${s.text}]` : s.text || <em className="muted">{t('(leer)', '(empty)')}</em>}</span>
            <span className="fx-tr-trans">{s.translation?.[tl] ? (s.kind === 'sound' ? `[${s.translation[tl]}]` : s.translation[tl]) : <em className="muted">–</em>}</span>
          </div>
        ))}
        {doc.segments.length === 0 && <p className="muted small">{t('Noch keine Blöcke. Mit der KI erzeugen oder eine Auswahl ziehen und „Block aus Auswahl“.', 'No blocks yet. Create them with the AI or drag a selection and use “Block from selection”.')}</p>}
      </div>
    </div>
  )
}
