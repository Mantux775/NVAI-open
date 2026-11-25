// Supported languages: English, German, Chinese, French.
//
// The choice is stored in localStorage under 'nvai-lang'. Without a valid entry, English is used,
// even in a German/Chinese/French browser -- it is up to the user. The language is read once on
// load; switching reloads the page. Therefore, constants evaluated at module load time (Tabs, Formats, KIND_LABEL)
// should use t().
//
// Text from the server (Model descriptions, Prompt hints, Error messages) is already translated:
// api.ts sends the selected language as Accept-Language.

export type Lang = 'en' | 'de' | 'zh' | 'fr'

const STORAGE_KEY = 'nvai-lang'

function readStored(): Lang {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    if (v === 'en' || v === 'de' || v === 'zh' || v === 'fr') return v
  } catch {
    /* Storage blocked (private window, policy): use default */
  }
  return 'en'
}

let current: Lang = readStored()
const listeners = new Set<(l: Lang) => void>()

/** Switch language without reload (Review App: one reload would close the open folder). Components that redraw
 * hear via onLang; constants evaluated at load time remain in the old language until the next load. */
export function setLangLive(l: Lang): void {
  current = l
  try {
    localStorage.setItem(STORAGE_KEY, l)
  } catch {
    /* not storable: applies until close */
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

/** Save the choice and reload, so every component renders in the new language. */
export function setLang(l: Lang): void {
  try {
    localStorage.setItem(STORAGE_KEY, l)
  } catch {
    /* not storable: reload then shows default again */
  }
  window.location.reload()
}

/** Text in the current language. Order: English, German, Chinese, French. */
export function t(en: string, de: string, zh: string, fr: string): string {
  switch (current) {
    case 'de': return de
    case 'zh': return zh
    case 'fr': return fr
    default: return en
  }
}

/** Force toLocaleString and Intl: numbers and dates in the format of the selected language. */
export function locale(): string {
  switch (current) {
    case 'de': return 'de-DE'
    case 'zh': return 'zh-CN'
    case 'fr': return 'fr-FR'
    default: return 'en-US'
  }
}
