import { useEffect, useMemo, useRef, useState } from 'react'
import { isReview } from '../review/mode'
import {
  api, audioSourceUrl, audioVideoUrl, vdrImageUrl, type AudioProject, type AudioTrack, type TranscriptSegment, type VdrEvent, type VdrImages,
  type VdrSeries,
} from '../api'
import { t } from '../i18n'
import { clockAt, EVENT_COLOR, EVENT_LABEL } from './Lanes'

// Monitor der Ton-Forensik: zeigt zum Abspielkopf das Bild (Video der Aufnahme oder Radar-/ECDIS-Bild des
// Schiffsschreibers) und die Daten wie die Wiedergabe-Programme der Hersteller: Fahrstand (Conning), serielle Rohdaten,
// Ereignisse, AIS, Kurs auf einer schlichten Karte (ohne Online-Kartendienst, die Daten bleiben auf dem Rechner).

export type MonitorTab = 'video' | 'text' | 'radar' | 'conning' | 'serial' | 'events' | 'ais' | 'map'
export interface AisData { targets: Record<string, { name?: string; type?: string | number; track: [number, number, number, number | null, number | null][] }> }

/** Bild aus dem Server oder, in der Prüf-App, aus dem Fallordner (dort gibt es keine Server-Adresse für <img>) */
function PackedImage({ url }: { url: string }) {
  const [src, setSrc] = useState(isReview() ? '' : url)
  useEffect(() => {
    if (!isReview()) {
      setSrc(url)
      return
    }
    let alive = true
    let made = ''
    fetch(url).then((r) => (r.ok ? r.blob() : null)).then((b) => {
      if (!alive || !b) return
      made = URL.createObjectURL(b)
      setSrc(made)
    }).catch(() => {})
    return () => {
      alive = false
      if (made) URL.revokeObjectURL(made)
    }
  }, [url])
  return src ? <img className="fx-radar-img" src={src} alt="" /> : <p className="muted small">…</p>
}

export function valueAt(series: VdrSeries | null, key: string, time: number): number | null {
  const s = series?.series[key]
  if (!s) return null
  const i = Math.floor(time)
  // letzter Wert der vergangenen 10 s (Sensoren senden nicht jede Sekunde)
  for (let k = i; k >= Math.max(0, i - 10); k--) {
    const v = s.values[k]
    if (v != null) return v
  }
  return null
}

function fmtLat(v: number | null, lon = false): string {
  if (v == null) return '–'
  const hemi = lon ? (v < 0 ? 'W' : 'E') : (v < 0 ? 'S' : 'N')
  const a = Math.abs(v)
  const d = Math.floor(a)
  const m = (a - d) * 60
  return `${String(d).padStart(lon ? 3 : 2, '0')}° ${m.toFixed(3).padStart(6, '0')}′ ${hemi}`
}

function num(v: number | null, digits = 1, unit = ''): string {
  return v == null ? '–' : `${v.toFixed(digits)}${unit ? ` ${unit}` : ''}`
}

function Readout({ label, value, wide }: { label: string; value: string; wide?: boolean }) {
  return (
    <div className={`fx-ro${wide ? ' wide' : ''}`}>
      <span className="fx-ro-label">{label}</span>
      <span className="fx-ro-value">{value}</span>
    </div>
  )
}

function Conning({ series, events, time, origin }: { series: VdrSeries | null; events: VdrEvent[]; time: number; origin: number | null | undefined }) {
  const v = (k: string) => valueAt(series, k, time)
  const states = useMemo(() => {
    const m = new Map<string, VdrEvent>()
    for (const e of events) {
      if (e.t > time) break
      if (e.kind === 'digital' || e.kind === 'telegraph' || e.kind === 'autopilot') m.set(`${e.kind}:${e.label}`, e)
    }
    return [...m.values()]
  }, [events, time])
  const date = origin ? new Date((origin + time) * 1000) : null
  const rudder = v('rudder')
  return (
    <div className="fx-conning">
      <div className="fx-ro-grid">
        <Readout label={t('Zeit (UTC)', 'Time (UTC)')} value={clockAt(time, origin, true)} />
        <Readout label={t('Datum', 'Date')} value={date ? date.toISOString().slice(0, 10) : '–'} />
        <Readout label={t('Breite', 'Latitude')} value={fmtLat(v('lat'))} />
        <Readout label={t('Länge', 'Longitude')} value={fmtLat(v('lon'), true)} />
        <Readout label={t('Steuerkurs (HDG)', 'Heading (HDG)')} value={num(v('hdg'), 1, '°')} />
        <Readout label={t('Kurs über Grund (COG)', 'Course over ground')} value={num(v('cog'), 1, '°')} />
        <Readout label={t('Geschwindigkeit über Grund (SOG)', 'Speed over ground')} value={num(v('sog'), 1, 'kn')} />
        <Readout label={t('Geschwindigkeit durchs Wasser (STW)', 'Speed through water')} value={num(v('stw'), 1, 'kn')} />
        <Readout label={t('Drehrate (ROT)', 'Rate of turn')} value={num(v('rot'), 1, '°/min')} />
        <Readout label={t('Ruder', 'Rudder')} value={rudder == null ? '–' : `${Math.abs(rudder).toFixed(1)}° ${rudder < 0 ? t('Bb', 'port') : rudder > 0 ? t('Stb', 'stbd') : ''}`} />
        <Readout label={t('Ruder befohlen', 'Rudder order')} value={num(v('rudder_order'), 1, '°')} />
        <Readout label={t('Kurs befohlen', 'Heading order')} value={num(v('heading_order'), 1, '°')} />
        <Readout label={t('Drehzahl', 'Engine RPM')} value={num(v('rpm'), 0, 'rpm')} />
        <Readout label={t('Steigung', 'Pitch')} value={num(v('pitch'), 1, '%')} />
        <Readout label={t('Wind relativ', 'Relative wind')} value={`${num(v('wind_rel_dir'), 0, '°')} · ${num(v('wind_rel_speed'), 1, 'kn')}`} />
        <Readout label={t('Wind wahr', 'True wind')} value={`${num(v('wind_true_dir'), 0, '°')} · ${num(v('wind_true_speed'), 1, 'kn')}`} />
        <Readout label={t('Wassertiefe', 'Depth')} value={num(v('depth'), 1, 'm')} />
        <Readout label={t('Maschinentelegraf', 'Telegraph')} value={`${num(v('telegraph_order'), 0)} / ${num(v('telegraph_answer'), 0)}`} />
      </div>
      {states.length > 0 && (
        <div className="fx-states">
          {states.map((e) => (
            <div key={`${e.kind}:${e.label}`} className="fx-state">
              <span className="fx-dot" style={{ background: EVENT_COLOR[e.kind] ?? '#aaa' }} />
              <strong className="fx-state-label" title={e.detail}>{e.label}</strong>
              <span className="muted small">{t('seit', 'since')} {clockAt(e.t, origin)}</span>
            </div>
          ))}
        </div>
      )}
      {!series && <p className="muted small">{t('Keine Schiffsdaten in diesem Projekt.', 'No ship data in this project.')}</p>}
    </div>
  )
}

function Serial({ pid, time, origin }: { pid: string; time: number; origin: number | null | undefined }) {
  const block = Math.floor(time / 15)
  const [data, setData] = useState<{ start: number; lines: { t: number; channel: string; text: string }[] } | null>(null)
  const [err, setErr] = useState('')
  const [filter, setFilter] = useState('')
  useEffect(() => {
    let alive = true
    const timer = window.setTimeout(() => {
      api.vdrRaw(pid, block * 15 + 0.5).then((d) => { if (alive) { setData(d); setErr('') } }).catch((e) => { if (alive) setErr(String(e.message ?? e)) })
    }, 120)
    return () => { alive = false; window.clearTimeout(timer) }
  }, [pid, block])
  const lines = (data?.lines ?? []).filter((l) => !filter || l.text.toUpperCase().includes(filter.toUpperCase()))
  const near = lines.findIndex((l) => l.t >= time)
  const listRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = listRef.current?.querySelector('.fx-raw.now') as HTMLElement | null
    if (el && listRef.current) listRef.current.scrollTop = el.offsetTop - listRef.current.clientHeight / 2
  }, [near, data])
  return (
    <div className="fx-serial">
      <div className="lt-toolbar">
        <input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder={t('Filter, z. B. HDT, ALR, RPM', 'Filter, e.g. HDT, ALR, RPM')} />
        <span className="muted small">{t(`${lines.length} Sätze in 15 s ab ${clockAt(block * 15, origin)}`, `${lines.length} sentences in 15 s from ${clockAt(block * 15, origin)}`)}</span>
      </div>
      {err && <p className="error small">{err}</p>}
      <div className="fx-raw-list" ref={listRef}>
        {lines.map((l, i) => (
          <div key={i} className={`fx-raw${i === near ? ' now' : ''}`}>
            <span className="muted">{clockAt(l.t, origin, true)}</span> <span className="fx-raw-ch">{l.channel}</span> {l.text}
          </div>
        ))}
      </div>
    </div>
  )
}

const EV_ROW = 24

/** Ereignisliste (Nutzer 18.11.: „wenn ich events einen event anklicke springt er so komisch ich verliere den focus“):
 * die ganze Liste mit fester Zeilenhöhe, gezeichnet wird nur, was zu sehen ist. Ein Klick hält die Liste fest und markiert
 * das Ereignis; die Liste folgt nur Sprüngen von außen (Zeitstrahl, Spur der Ereignisse) und nur, wenn die Stelle gerade
 * nicht zu sehen ist. Beim Abspielen bleibt sie stehen; „Abspielposition“ holt sie zurück. */
function EventList({ events, time, origin, onSeek }: { events: VdrEvent[]; time: number; origin: number | null | undefined; onSeek: (s: number) => void }) {
  const kinds = useMemo(() => [...new Set(events.map((e) => e.kind))], [events])
  const [off, setOff] = useState<Record<string, boolean>>({})
  const [q, setQ] = useState('')
  const list = useMemo(() => events.filter((e) => !off[e.kind] && (!q || `${e.label} ${e.detail}`.toLowerCase().includes(q.toLowerCase())))
    .sort((a, b) => a.t - b.t), [events, off, q])
  // letzte Zeile, die zur Abspielposition schon begonnen hat
  const nowIdx = useMemo(() => {
    let lo = 0
    let hi = list.length
    while (lo < hi) {
      const m = (lo + hi) >> 1
      if (list[m].t <= time) lo = m + 1
      else hi = m
    }
    return Math.max(0, lo - 1)
  }, [list, time])
  const box = useRef<HTMLDivElement>(null)
  const [top, setTop] = useState(0)
  const [height, setHeight] = useState(400)
  const [picked, setPicked] = useState<VdrEvent | null>(null)
  const own = useRef(false)
  const lastTime = useRef(time)
  const toRow = (i: number) => {
    const el = box.current
    if (el) el.scrollTop = Math.max(0, i * EV_ROW - el.clientHeight / 3)
  }
  useEffect(() => {
    const el = box.current
    if (!el) return
    const ro = new ResizeObserver(() => setHeight(el.clientHeight))
    ro.observe(el)
    setHeight(el.clientHeight)
    return () => ro.disconnect()
  }, [])
  // beim Öffnen und nach anderem Filter zur Abspielposition; nicht an der Liste selbst festmachen, die Arbeitsfläche
  // übergibt bei jedem Neuzeichnen eine neue (das ließ die Liste bei jedem Zeitschritt springen)
  useEffect(() => { toRow(nowIdx) }, [off, q, events.length]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const jump = Math.abs(time - lastTime.current) > 2
    lastTime.current = time
    if (own.current) {
      own.current = false
      return
    }
    const el = box.current
    if (!jump || !el) return
    const first = el.scrollTop / EV_ROW
    const last = (el.scrollTop + el.clientHeight) / EV_ROW - 1
    if (nowIdx < first || nowIdx > last) toRow(nowIdx)
  }, [time]) // eslint-disable-line react-hooks/exhaustive-deps
  const from = Math.max(0, Math.floor(top / EV_ROW) - 10)
  const to = Math.min(list.length, Math.ceil((top + height) / EV_ROW) + 10)
  return (
    <div className="fx-evlist">
      <div className="lt-toolbar">
        {kinds.map((k) => (
          <label key={k} className="check small"><input type="checkbox" checked={!off[k]} onChange={(e) => setOff({ ...off, [k]: !e.target.checked })} />
            <span className="fx-dot" style={{ background: EVENT_COLOR[k] ?? '#aaa' }} />{EVENT_LABEL[k] ?? k} ({events.filter((e) => e.kind === k).length})</label>
        ))}
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('Suchen …', 'Search …')} />
        <button className="btn small ghost" onClick={() => toRow(nowIdx)} title={t('Liste zur Abspielposition', 'Scroll the list to the playhead')}>⌖ {t('Abspielposition', 'Playhead')}</button>
      </div>
      <div className="fx-ev-rows" ref={box} onScroll={(e) => setTop(e.currentTarget.scrollTop)}>
        <div className="fx-ev-space" style={{ height: list.length * EV_ROW }}>
          {list.slice(from, to).map((e, k) => {
            const i = from + k
            return (
              <button key={i} style={{ top: i * EV_ROW }} title={`${clockAt(e.t, origin, true)} · ${e.label} · ${e.detail}`}
                className={`fx-ev-row${e.t <= time && (e.end ?? e.t + 2) >= time ? ' now' : ''}${picked === e ? ' picked' : ''}`}
                onClick={() => { own.current = true; setPicked(e); onSeek(Math.max(0, e.t - 2)) }}>
                <span className="fx-dot" style={{ background: EVENT_COLOR[e.kind] ?? '#aaa' }} />
                <span className="fx-ev-time">{clockAt(e.t, origin)}</span>
                <span className="fx-ev-label">{e.label}</span>
                <span className="muted small fx-ev-detail">{e.detail}{e.end != null ? ` · ${Math.round(e.end - e.t)} s` : ''}</span>
              </button>
            )
          })}
        </div>
        {list.length === 0 && <p className="muted small">{t('Keine Ereignisse.', 'No events.')}</p>}
      </div>
    </div>
  )
}

function aisAt(ais: AisData | null, time: number): { mmsi: string; name: string; lat: number; lon: number; sog: number | null; cog: number | null; age: number }[] {
  if (!ais) return []
  const out = []
  for (const [mmsi, tg] of Object.entries(ais.targets)) {
    const tr = tg.track
    let lo = 0, hi = tr.length - 1, best = -1
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      if (tr[mid][0] <= time) { best = mid; lo = mid + 1 } else hi = mid - 1
    }
    if (best < 0) continue
    const p = tr[best]
    const age = time - p[0]
    if (age > 360) continue
    out.push({ mmsi, name: tg.name || '', lat: p[1], lon: p[2], sog: p[3], cog: p[4], age })
  }
  return out
}

function rangeBearing(lat1: number, lon1: number, lat2: number, lon2: number): [number, number] {
  const k = Math.PI / 180
  const dy = (lat2 - lat1) * 60
  const dx = (lon2 - lon1) * 60 * Math.cos(((lat1 + lat2) / 2) * k)
  return [Math.hypot(dx, dy), ((Math.atan2(dx, dy) / k) + 360) % 360]
}

function AisList({ ais, series, time }: { ais: AisData | null; series: VdrSeries | null; time: number }) {
  const lat = valueAt(series, 'lat', time)
  const lon = valueAt(series, 'lon', time)
  const list = aisAt(ais, time).map((x) => ({ ...x, rb: lat != null && lon != null ? rangeBearing(lat, lon, x.lat, x.lon) : null }))
    .sort((a, b) => (a.rb?.[0] ?? 1e9) - (b.rb?.[0] ?? 1e9)).slice(0, 80)
  if (!ais) return <p className="muted small">{t('Keine AIS-Daten.', 'No AIS data.')}</p>
  return (
    <table className="fx-ais">
      <thead><tr><th>MMSI</th><th>{t('Name', 'Name')}</th><th>{t('Abstand', 'Range')}</th><th>{t('Peilung', 'Bearing')}</th><th>SOG</th><th>COG</th><th>{t('Alter', 'Age')}</th></tr></thead>
      <tbody>
        {list.map((x) => (
          <tr key={x.mmsi}>
            <td>{x.mmsi}</td><td>{x.name}</td>
            <td>{x.rb ? `${x.rb[0].toFixed(2)} sm` : '–'}</td><td>{x.rb ? `${x.rb[1].toFixed(0)}°` : '–'}</td>
            <td>{num(x.sog, 1)}</td><td>{num(x.cog, 0)}</td><td>{Math.round(x.age)} s</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function TrackMap({ series, ais, time, duration }: { series: VdrSeries | null; ais: AisData | null; time: number; duration: number }) {
  const [radius, setRadius] = useState<number>(6)   // Seemeilen um das eigene Schiff, 0 = ganze Fahrt
  const pts = useMemo(() => {
    const la = series?.series.lat?.values, lo = series?.series.lon?.values
    if (!la || !lo) return [] as [number, number, number][]
    const step = Math.max(1, Math.floor(la.length / 3000))
    const out: [number, number, number][] = []
    for (let i = 0; i < la.length; i += step) if (la[i] != null && lo[i] != null) out.push([i, la[i] as number, lo[i] as number])
    return out
  }, [series])
  const lat = valueAt(series, 'lat', time)
  const lon = valueAt(series, 'lon', time)
  const hdg = valueAt(series, 'hdg', time)
  if (!pts.length) return <p className="muted small">{t('Keine Positionsdaten.', 'No position data.')}</p>
  const W = 520, H = 400
  let cLat: number, cLon: number, span: number
  if (radius > 0 && lat != null && lon != null) {
    cLat = lat; cLon = lon; span = (radius * 2) / 60
  } else {
    const las = pts.map((p) => p[1]), los = pts.map((p) => p[2])
    const minLa = Math.min(...las), maxLa = Math.max(...las), minLo = Math.min(...los), maxLo = Math.max(...los)
    cLat = (minLa + maxLa) / 2; cLon = (minLo + maxLo) / 2
    span = Math.max(maxLa - minLa, (maxLo - minLo) * Math.cos((cLat * Math.PI) / 180)) * 1.15 + 1e-4
  }
  const cos = Math.cos((cLat * Math.PI) / 180)
  const sc = Math.min(W, H) / span
  const X = (lo: number) => W / 2 + (lo - cLon) * cos * sc
  const Y = (la: number) => H / 2 - (la - cLat) * sc
  const past = pts.filter((p) => p[0] <= time)
  const path = (arr: [number, number, number][]) => arr.map((p, i) => `${i ? 'L' : 'M'}${X(p[2]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join('')
  const targets = aisAt(ais, time)
  const nm = span * 60
  const bar = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50].find((x) => x >= nm / 6) ?? 50
  return (
    <div className="fx-map">
      <div className="lt-toolbar">
        <select value={radius} onChange={(e) => setRadius(Number(e.target.value))}>
          <option value={1}>± 1 sm</option><option value={3}>± 3 sm</option><option value={6}>± 6 sm</option><option value={12}>± 12 sm</option>
          <option value={0}>{t('ganze Aufzeichnung', 'whole recording')}</option>
        </select>
        <span className="muted small">{t('Norden oben, ohne Seekarte (keine Daten verlassen den Rechner).', 'North up, no chart (no data leaves the computer).')} {duration ? '' : ''}</span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} className="fx-map-svg" preserveAspectRatio="xMidYMid slice">
        <rect x={0} y={0} width={W} height={H} fill="#0b1520" />
        <path d={path(pts)} stroke="rgba(124,196,255,0.25)" strokeWidth={1.5} fill="none" />
        <path d={path(past)} stroke="#7cc4ff" strokeWidth={2} fill="none" />
        {targets.map((x) => (
          <g key={x.mmsi} transform={`translate(${X(x.lon)},${Y(x.lat)})`}>
            <circle r={3.5} fill={x.age > 120 ? '#776' : '#b39ddb'} />
            {x.cog != null && x.sog != null && x.sog > 0.5 && (
              <line x1={0} y1={0} x2={Math.sin((x.cog * Math.PI) / 180) * 14} y2={-Math.cos((x.cog * Math.PI) / 180) * 14} stroke="#b39ddb" strokeWidth={1.2} />
            )}
            <text x={6} y={-5} fontSize={10} fill="#cbbbe8">{x.name || x.mmsi}</text>
          </g>
        ))}
        {lat != null && lon != null && (
          <g transform={`translate(${X(lon)},${Y(lat)}) rotate(${hdg ?? 0})`}>
            <path d="M0,-11 L6,8 L0,4 L-6,8 Z" fill="#76b900" stroke="#fff" strokeWidth={0.8} />
          </g>
        )}
        <g transform={`translate(14,${H - 16})`}>
          <line x1={0} y1={0} x2={(bar / 60) * sc} y2={0} stroke="#ddd" strokeWidth={2} />
          <text x={0} y={-5} fontSize={10} fill="#ddd">{bar} sm</text>
        </g>
        <text x={W - 16} y={18} fontSize={12} fill="#ddd">N</text>
      </svg>
    </div>
  )
}

function RadarView({ pid, images, time, origin }: { pid: string; images: VdrImages | null; time: number; origin: number | null | undefined }) {
  const [src, setSrc] = useState<string>('')
  useEffect(() => { if (images && !src && images.sources.length) setSrc(images.sources[0].id) }, [images, src])
  if (!images || !images.sources.length) return <p className="muted small">{t('Keine Bilder im Projekt.', 'No images in the project.')}</p>
  const frames = images.frames[src] ?? []
  let lo = 0, hi = frames.length - 1, idx = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (frames[mid][0] <= time) { idx = mid; lo = mid + 1 } else hi = mid - 1
  }
  return (
    <div className="fx-radar">
      <div className="lt-toolbar">
        {images.sources.map((s) => (
          <button key={s.id} className={`btn small${s.id === src ? ' primary' : ''}`} onClick={() => setSrc(s.id)}>{s.label || s.id}</button>
        ))}
        {idx >= 0 && <span className="muted small">{t('Bild von', 'Picture from')} {clockAt(frames[idx][0], origin)} {origin ? 'UTC' : ''} · {idx + 1}/{frames.length}</span>}
      </div>
      {idx >= 0 ? <PackedImage url={vdrImageUrl(pid, src, idx)} /> : <p className="muted small">{t('Zu dieser Zeit noch kein Bild.', 'No picture at this time yet.')}</p>}
    </div>
  )
}

function VideoView({ url, time, playing, rate, fit }: { url: string; time: number; playing: boolean; rate: number; fit: { a: number; b: number } }) {
  const ref = useRef<HTMLVideoElement>(null)
  useEffect(() => {
    const v = ref.current
    if (!v) return
    // Video-Zeit aus der Ausrichtung (Video-Zeit = a · Aufnahme-Zeit + b), ohne Zuordnung 1:1
    const want = fit.a * time + fit.b
    if (want < 0) { v.pause(); return }
    if (v.playbackRate !== rate * fit.a) v.playbackRate = rate * fit.a
    if (Math.abs(v.currentTime - want) > (playing ? 0.35 : 0.04)) v.currentTime = want
    if (playing && v.paused) void v.play().catch(() => {})
    if (!playing && !v.paused) v.pause()
  }, [time, playing, rate, fit])
  return <video ref={ref} className="fx-video" src={url} muted preload="metadata" />
}

/** Mitlesen: der Block am Abspielkopf groß, im Original und übersetzt, dazu die Blöcke davor und danach */
function ReadAlong({ segments, time, targetLang, tracks, origin, onSeek }: {
  segments: TranscriptSegment[]; time: number; targetLang: string; tracks: AudioTrack[]; origin: number | null | undefined; onSeek: (s: number) => void
}) {
  let i = segments.findIndex((s) => s.end >= time)
  if (i < 0) i = segments.length
  const list = segments.slice(Math.max(0, i - 2), i + 4)
  const name = (id: string) => tracks.find((x) => x.id === id)?.name ?? id
  if (!segments.length) return <p className="muted small">{t('Die Übersetzer-Spur ist noch leer.', 'The translation track is still empty.')}</p>
  return (
    <div className="fx-read">
      {list.map((s) => {
        const now = time >= s.start && time <= s.end
        const tr = s.translation?.[targetLang]
        return (
          <button key={s.id} className={`fx-read-row${now ? ' now' : ''}${time > s.end ? ' past' : ''}`} onClick={() => onSeek(s.start)}>
            <span className="fx-read-meta">{clockAt(s.start, origin)} · {s.speaker || name(s.track)}{s.status === 'draft' ? ` · ${t('Entwurf', 'draft')}` : ''}</span>
            <span className="fx-read-orig">{s.kind === 'sound' ? `[${s.text}]` : s.text}</span>
            {tr && <span className="fx-read-tr">{s.kind === 'sound' ? `[${tr}]` : tr}</span>}
          </button>
        )
      })}
    </div>
  )
}

export function ForensicMonitor({ proj, tab, setTab, time, playing, rate, series, events, images, ais, onSeek, segments, targetLang, tracks }: {
  proj: AudioProject
  tab: MonitorTab
  setTab: (t: MonitorTab) => void
  time: number
  playing: boolean
  rate: number
  series: VdrSeries | null
  events: VdrEvent[]
  images: VdrImages | null
  ais: AisData | null
  onSeek: (s: number) => void
  segments: TranscriptSegment[]
  targetLang: string
  tracks: AudioTrack[]
}) {
  const isVdr = proj.source.kind === 'vdr'
  const origin = proj.time_origin
  const tabs: [MonitorTab, string][] = [
    ...(proj.source.has_video || proj.video ? [['video', t('Video', 'Video')] as [MonitorTab, string]] : []),
    ['text', t('Mitlesen', 'Read along')],
    ...(isVdr ? ([['radar', t('Radar / ECDIS', 'Radar / ECDIS')], ['conning', t('Fahrstand', 'Conning')], ['map', t('Karte', 'Map')],
      ['ais', 'AIS'], ...(isReview() ? [] : [['serial', t('Seriell', 'Serial')]])] as [MonitorTab, string][]) : []),
    ['events', t('Ereignisse', 'Events')],
  ]
  const cur = tabs.some(([k]) => k === tab) ? tab : tabs[0][0]
  return (
    <div className="fx-monitor">
      <div className="fx-mon-tabs">
        {tabs.map(([k, l]) => <button key={k} className={`lr-tab${cur === k ? ' on' : ''}`} onClick={() => setTab(k)}>{l}</button>)}
        <span className="fx-mon-clock">{clockAt(time, origin, true)}{origin ? ' UTC' : ''}</span>
      </div>
      <div className="fx-mon-body">
        {cur === 'video' && <VideoView url={proj.video ? audioVideoUrl(proj.id) : audioSourceUrl(proj.id)} time={time} playing={playing} rate={rate}
          fit={proj.video?.fit ?? { a: 1, b: 0 }} />}
        {cur === 'text' && <ReadAlong segments={segments} time={time} targetLang={targetLang} tracks={tracks} origin={origin} onSeek={onSeek} />}
        {cur === 'radar' && <RadarView pid={proj.id} images={images} time={time} origin={origin} />}
        {cur === 'conning' && <Conning series={series} events={events} time={time} origin={origin} />}
        {cur === 'map' && <TrackMap series={series} ais={ais} time={time} duration={proj.duration ?? 0} />}
        {cur === 'ais' && <AisList ais={ais} series={series} time={time} />}
        {cur === 'serial' && <Serial pid={proj.id} time={time} origin={origin} />}
        {cur === 'events' && <EventList events={events} time={time} origin={origin} onSeek={onSeek} />}
      </div>
    </div>
  )
}
