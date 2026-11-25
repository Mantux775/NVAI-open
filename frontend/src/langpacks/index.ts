// Sprachpakete der Weboberflaeche (Chinesisch, Franzoesisch) anmelden, bevor eine Komponente t() aufruft: main.tsx
// importiert diese Datei als erste. Die Pruef-App laedt sie nicht und bleibt bei Deutsch und Englisch.
import { getLang, registerPack } from '../i18n'
import fr from './fr.json'
import zh from './zh.json'

const PACKS: Record<string, Record<string, string>> = { zh, fr }
const pack = PACKS[getLang()]
if (pack) registerPack(getLang(), pack)
