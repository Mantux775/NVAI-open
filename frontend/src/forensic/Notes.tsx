import { useEffect, useMemo, useRef, useState } from 'react'
import type { AudioMarker, AudioProject } from '../api'
import { fmtClock } from '../audio/Timeline'
import { t } from '../i18n'
import { clockAt } from './Lanes'
import { download } from './Transcript'

// Notizen der Ton-Forensik (Nutzer 17.11.: „Ganz oben brauche ich eine Spur - Notizen … recht oben hinter Protokoll soll
// ein reiter Notizen sein mit der Liste Zeitstempel usw. es soll sich exportieren lassen“). Notizen sind Marken der
// Art „note“ mit Text, Verfasser und Zeitpunkt; sie stehen in der Notizen-Spur ganz oben im Zeitstrahl.

const AUTHOR_KEY = 'nvai.forensic.author'

export function noteAuthor(): string {
  try { return localStorage.getItem(AUTHOR_KEY) ?? '' } catch { return '' }
}

export function newNote(start: number, end: number, label = ''): AudioMarker {
  return { id: Math.random().toString(36).slice(2, 10), start, end, kind: 'note', label, author: noteAuthor(), created: Date.now() / 1000 }
}

export function exportNotes(proj: AudioProject, notes: AudioMarker[], fmt: 'csv' | 'txt'): void {
  const origin = proj.time_origin
  const base = (proj.name || 'notizen').replace(/[^\w\-. ]+/g, '_')
  const list = [...notes].sort((a, b) => a.start - b.start)
  if (fmt === 'csv') {
    const q = (v: string) => `"${(v ?? '').replace(/"/g, '""')}"`
    download(`${base}_${t('notizen', 'notes')}.csv`, ['nr;start_s;end_s;time_start;time_end;duration_s;author;created;note',
      ...list.map((m, i) => [i + 1, m.start.toFixed(2), m.end.toFixed(2), clockAt(m.start, origin, true), clockAt(m.end, origin, true),
        (m.end - m.start).toFixed(1), q(m.author ?? ''), m.created ? new Date(m.created * 1000).toISOString() : '', q(m.label)].join(';'))].join('\n'), 'text/csv')
  } else {
    const head = t(`Notizen: ${proj.name}\nZeiten ${origin ? 'in UTC' : 'ab Beginn der Aufnahme'}.\n`, `Notes: ${proj.name}\nTimes ${origin ? t('in UTC', 'in UTC') : t('ab Beginn der Aufnahme', 'from the start of the recording')}.\n`)
    download(`${base}_${t('notizen', 'notes')}.txt`, head + '\n' + list.map((m, i) =>
      `${i + 1}. ${clockAt(m.start, origin, true)}${m.end > m.start ? ` – ${clockAt(m.end, origin, true)} (${fmtClock(m.end - m.start, true)})` : ''}${m.author ? ` · ${m.author}` : ''}\n   ${(m.label || '').replace(/\n/g, '\n   ')}`).join('\n\n'))
  }
}

export function NotesTool({ proj, markers, save, onSeek, onSelect, focus, onFocused, playhead, selection, onAdd }: {
  proj: AudioProject
  markers: AudioMarker[]
  save: (list: AudioMarker[]) => void
  onSeek: (s: number) => void
  onSelect: (a: number, b: number) => void
  /** Notiz, deren Textfeld den Fokus bekommen soll (gerade angelegt oder per Doppelklick) */
  focus: string | null
  onFocused: () => void
  playhead: number
  selection: [number, number] | null
  onAdd: () => void
}) {
  const origin = proj.time_origin
  const notes = useMemo(() => markers.filter((m) => m.kind === 'note').sort((a, b) => a.start - b.start), [markers])
  const [q, setQ] = useState('')
  const [author, setAuthor] = useState(noteAuthor)
  const [draft, setDraft] = useState<Record<string, string>>({})
  const listRef = useRef<HTMLDivElement>(null)
  const shown = notes.filter((m) => !q || `${m.label} ${m.author ?? ''}`.toLowerCase().includes(q.toLowerCase()))
  useEffect(() => {
    if (!focus) return
    const el = listRef.current?.querySelector(`[data-note="${focus}"] textarea`) as HTMLTextAreaElement | null
    if (el) {
      el.focus()
      el.scrollIntoView({ block: 'nearest' })
      onFocused()
    }
  }, [focus, notes, onFocused])
  const commit = (m: AudioMarker) => {
    const v = draft[m.id]
    if (v === undefined || v === m.label) return
    save(markers.map((x) => (x.id === m.id ? { ...x, label: v } : x)))
    setDraft((d) => { const n = { ...d }; delete n[m.id]; return n })
  }
  return (
    <div className="au-tool fx-notes-tool">
      <p className="hint small">{t('Notizen halten Stellen mit Text fest; sie stehen ganz oben im Zeitstrahl. Neue Notiz: Knopf „Notiz“ unter dem Monitor, Rechtsklick im Zeitstrahl oder Taste N. Ist etwas ausgewählt, gilt die Notiz für die Auswahl.',
        'Notes keep places with text; they appear at the top of the timeline. New note: the “Note” button below the monitor, right-click in the timeline or the N key. With a selection, the note covers the selection.')}</p>
      <div className="lt-toolbar">
        <button className="btn small primary" onClick={onAdd}>+ {selection ? t('Notiz zur Auswahl', 'Note for selection') : t(`Notiz bei ${clockAt(playhead, origin)}`, `Note at ${clockAt(playhead, origin)}`)}</button>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('Suchen …', 'Search …')} />
        <label className="lr-inline small" title={t('Wird bei neuen Notizen eingetragen', 'Recorded with new notes')}>{t('Verfasser', 'Author')}
          <input className="fx-author" value={author} onChange={(e) => { setAuthor(e.target.value); try { localStorage.setItem(AUTHOR_KEY, e.target.value) } catch { /* ohne Speicher */ } }} /></label>
        <span className="au-spacer" />
        <button className="btn small" disabled={!notes.length} onClick={() => exportNotes(proj, notes, 'txt')}>{t('Als Text', 'As text')}</button>
        <button className="btn small" disabled={!notes.length} onClick={() => exportNotes(proj, notes, 'csv')}>CSV</button>
      </div>
      <div className="fx-notelist" ref={listRef}>
        {shown.map((m, i) => {
          const now = playhead >= m.start - 0.05 && playhead <= Math.max(m.end, m.start + 1)
          return (
            <div key={m.id} data-note={m.id} className={`fx-noterow${now ? ' now' : ''}`}>
              <div className="fx-note-meta">
                <span className="muted small">{i + 1}</span>
                <button className="linklike" onClick={() => { onSeek(m.start); if (m.end > m.start) onSelect(m.start, m.end) }}
                  title={t('hinspringen', 'jump there')}>{clockAt(m.start, origin, true)}{origin ? ' UTC' : ''}</button>
                {m.end > m.start && <span className="muted small">{fmtClock(m.end - m.start, true)}</span>}
                {m.author && <span className="muted small">· {m.author}</span>}
                <span className="au-spacer" />
                <button className="au-x" title={t('Notiz löschen', 'delete note')} onClick={() => save(markers.filter((x) => x.id !== m.id))}>✕</button>
              </div>
              <textarea rows={2} value={draft[m.id] ?? m.label} placeholder={t('Notiz …', 'Note …')}
                onChange={(e) => setDraft((d) => ({ ...d, [m.id]: e.target.value }))} onBlur={() => commit(m)}
                onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); (e.target as HTMLTextAreaElement).blur() } }} />
            </div>
          )
        })}
        {notes.length === 0 && <p className="muted small">{t('Noch keine Notizen.', 'No notes yet.')}</p>}
      </div>
    </div>
  )
}
