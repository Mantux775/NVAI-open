// Sprache der Oberflaeche: Englisch, Deutsch auf Wunsch.
//
// Die Wahl liegt in localStorage unter 'nvai-lang'. Ohne gueltigen Eintrag gilt Englisch,
// auch in einem deutschen Browser -- so will es der Nutzer. Die Sprache wird einmal beim
// Laden gelesen; ein Wechsel laedt die Seite neu. Deshalb duerfen Konstanten, die beim
// Modul-Laden ausgewertet werden (Tabs, Formate, KIND_LABEL), t() benutzen.
//
// Was vom Server kommt (Modellbeschreibungen, Prompt-Hinweise, Fehlermeldungen), ist dort
// schon uebersetzt: api.ts schickt die Sprache als Accept-Language mit.

export type Lang = 'en' | 'de'

const STORAGE_KEY = 'nvai-lang'

function readStored(): Lang {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    if (v === 'en' || v === 'de') return v
  } catch {
    /* Speicher gesperrt (privates Fenster, Richtlinie): Standard nehmen */
  }
  return 'en'
}

const current: Lang = readStored()

export function getLang(): Lang {
  return current
}

/** Speichert die Wahl und laedt neu, damit jede Komponente in der neuen Sprache rendert. */
export function setLang(l: Lang): void {
  try {
    localStorage.setItem(STORAGE_KEY, l)
  } catch {
    /* nicht speicherbar: der Neuladen zeigt dann wieder den Standard */
  }
  window.location.reload()
}

/** Text in der aktuellen Sprache. Reihenfolge wie in den anderen Apps: Deutsch, Englisch. */
export function t(de: string, en: string): string {
  return current === 'de' ? de : en
}

/** Fuer toLocaleString und Intl: Zahlen und Daten im Format der gewaehlten Sprache. */
export function locale(): string {
  return current === 'de' ? 'de-DE' : 'en-US'
}
