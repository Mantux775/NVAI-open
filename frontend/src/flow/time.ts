// Zeiten und Größen für die geführte Oberfläche (seit 0.5.42, Konzept „NVAI im Fluss“: „Ein Knopf sagt den nächsten
// Schritt, er nennt Aktion und Zeit“, „Ehrliche Zeit“). Überall gleich geschrieben: „≈ 40 s“, „≈ 1:50“, „≈ 13 min“,
// „≈ 1 h 40 min“.
import { locale, t } from '../i18n'

/** Dauer als Uhr: 218 → „3:38“, 3725 → „1:02:05“ */
export function fmtClock(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const r = s % 60
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`
}

/** Geschätzte Dauer ohne Zeichen davor: „40 s“, „1 min“, „1:50“, „13 min“, „1 h 40 min“ */
export function fmtSpan(seconds: number): string {
  const s = Math.max(1, seconds)
  if (s < 55) return `${Math.max(5, Math.round(s / 5) * 5)} s`
  if (s < 75) return '1 min'
  if (s < 600) return fmtClock(Math.round(s / 5) * 5)
  if (s < 3600) return `${Math.round(s / 60)} min`
  const h = Math.floor(s / 3600)
  const m = Math.round((s % 3600) / 60 / 5) * 5
  return m >= 60 ? `${h + 1} h` : m ? `${h} h ${m} min` : `${h} h`
}

/** Schätzung mit Ungefähr-Zeichen; ohne Zahl ein leerer Text */
export function fmtEta(seconds: number | null | undefined): string {
  return seconds == null || !isFinite(seconds) ? '' : `≈ ${fmtSpan(seconds)}`
}

/** Restzeit: „noch ≈ 1:05“ */
export function fmtLeft(seconds: number | null | undefined): string {
  return seconds == null || !isFinite(seconds) ? '' : t(`noch ≈ ${fmtSpan(seconds)}`, `≈ ${fmtSpan(seconds)} left`)
}

/** Gigabyte im Zahlenformat der Sprache: „37,5 GB“ */
export function fmtGb(gb: number): string {
  const v = gb >= 10 ? Math.round(gb * 10) / 10 : Math.round(gb * 100) / 100
  return `${v.toLocaleString(locale(), { maximumFractionDigits: gb >= 10 ? 1 : 2 })} GB`
}

/** Ladezeit bei einer angenommenen Leitung (Vorgabe 100 MBit/s), in Sekunden */
export function downloadSeconds(gb: number, mbit = 100): number {
  return (gb * 8000) / mbit
}
