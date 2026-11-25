// Sprache der Oberflaeche: Englisch, auf Wunsch Deutsch, Chinesisch (vereinfacht) oder Franzoesisch.
//
// Die Wahl liegt in localStorage unter 'nvai-lang'. Ohne gueltigen Eintrag gilt Englisch,
// auch in einem deutschen Browser -- so will es der Nutzer. Die Sprache wird einmal beim
// Laden gelesen; ein Wechsel laedt die Seite neu. Deshalb duerfen Konstanten, die beim
// Modul-Laden ausgewertet werden (Tabs, Formate, KIND_LABEL), t() benutzen.
//
// Jeder Text steht im Code als t('Deutsch', 'English'). Chinesisch und Franzoesisch (seit 0.5.39, Grundlage aus
// PR #4) schlagen den englischen Text in einem Sprachpaket nach: langpacks/zh.json und fr.json, angemeldet von
// langpacks/index.ts, das main.tsx vor allem anderen laedt. Vorlagen mit ${...} stehen dort als {0}, {1} ... in der
// Reihenfolge im englischen Text. Was fehlt, erscheint englisch. Pflege: packaging/tools/langpacks.py.
//
// Was vom Server kommt (Modellbeschreibungen, Prompt-Hinweise, Fehlermeldungen), ist dort
// schon uebersetzt: api.ts schickt die Sprache als Accept-Language mit.

export type Lang = 'en' | 'de' | 'zh' | 'fr'

const LANGS: readonly Lang[] = ['en', 'de', 'zh', 'fr']
const STORAGE_KEY = 'nvai-lang'

function readStored(): Lang {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    if (v && (LANGS as readonly string[]).includes(v)) return v as Lang
  } catch {
    /* Speicher gesperrt (privates Fenster, Richtlinie): Standard nehmen */
  }
  return 'en'
}

let current: Lang = readStored()
const listeners = new Set<(l: Lang) => void>()

/** Sprache ohne Neuladen wechseln (Prüf-App: Ein Neuladen schlösse den geöffneten Fallordner). Wer neu zeichnet, hört
 * über onLang mit; Konstanten, die beim Laden ausgewertet wurden, bleiben bis zum nächsten Laden in der alten Sprache. */
export function setLangLive(l: Lang): void {
  current = l
  try {
    localStorage.setItem(STORAGE_KEY, l)
  } catch {
    /* nicht speicherbar: gilt bis zum Schließen */
  }
  document.documentElement.lang = l
  for (const f of listeners) f(l)
}

export function onLang(f: (l: Lang) => void): () => void {
  listeners.add(f)
  return () => { listeners.delete(f) }
}

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

// ---------------------------------------------------------------- Sprachpakete (zh, fr)

type Template = { re: RegExp; order: number[]; tr: string; weight: number }
let packLang: Lang | null = null
const exact = new Map<string, string>()
let templates: Template[] = []
// Ergebnisse der Vorlagen-Suche; Texte mit Zahlen (Fortschritt, Zeiten) kommen immer neu, daher begrenzt
const found = new Map<string, string>()

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Sprachpaket anmelden: Schluessel = englischer Text, Wert = Uebersetzung. Gilt nur fuer die geladene Sprache. */
export function registerPack(l: Lang, pack: Record<string, string>): void {
  if (l !== current) return
  packLang = l
  exact.clear()
  found.clear()
  const list: Template[] = []
  for (const [en, tr] of Object.entries(pack)) {
    if (!/\{\d+\}/.test(en)) {
      exact.set(en, tr)
      continue
    }
    const parts = en.split(/\{\d+\}/)
    const literal = parts.join('')
    // „{0} {1}“ passt auf alles: nur Vorlagen mit eigenem Wortlaut
    if (!/\p{L}/u.test(literal)) continue
    list.push({
      re: new RegExp('^' + parts.map(escapeRe).join('([\\s\\S]*?)') + '$'),
      order: [...en.matchAll(/\{(\d+)\}/g)].map((m) => Number(m[1])),
      tr,
      weight: literal.length,
    })
  }
  // Die genaueste Vorlage zuerst („{0} images saved“ vor „{0} images“)
  templates = list.sort((a, b) => b.weight - a.weight)
}

function translate(en: string): string {
  const hit = exact.get(en) ?? found.get(en)
  if (hit !== undefined) return hit
  let out = en
  for (const tpl of templates) {
    const m = tpl.re.exec(en)
    if (!m) continue
    const value = new Map(tpl.order.map((n, i) => [n, m[i + 1]] as const))
    out = tpl.tr.replace(/\{(\d+)\}/g, (s, n) => value.get(Number(n)) ?? s)
    break
  }
  if (found.size > 5000) found.clear()
  found.set(en, out)
  return out
}

/** Text in der aktuellen Sprache. Reihenfolge wie in den anderen Apps: Deutsch, Englisch; Chinesisch und
 *  Franzoesisch kommen aus dem Sprachpaket (Schluessel: der englische Text). */
export function t(de: string, en: string): string {
  if (current === 'de') return de
  if (current !== packLang) return en
  return translate(en)
}

/** Fuer toLocaleString und Intl: Zahlen und Daten im Format der gewaehlten Sprache. */
export function locale(): string {
  return { de: 'de-DE', zh: 'zh-CN', fr: 'fr-FR', en: 'en-US' }[current]
}
