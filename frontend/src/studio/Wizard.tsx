// Assistent im Studio (seit 0.5.28; Nutzer 14.11.2026: „im studio will ich eine art Wizzard … es soll mich durch den
// ganzen prozess durchführen … ich soll bestimmen protagonist, thema, szenen und so weiter, es soll auch ein bisschen
// wie ein tutorial wirken aber nicht zu umständlich“). Sieben kurze Schritte: Weg, Idee, Figur, Szenen, Ton, Modelle
// und Zeit, Los. Jeder Schritt erklärt in einem Satz, wozu er gut ist. Der Assistent legt ein normales Studio-Projekt an
// (Figur, Szenen mit fertigen Prompts, Sätze, Musik), erzeugt zuerst die Startbilder zum Auswählen und dann die Videos;
// danach geht es im Studio weiter wie gewohnt. Prompts entstehen aus festen englischen Bausteinen (Stil, Bildausschnitt,
// Licht, Kamera, Ton) und dem Text des Nutzers; Modelle und Zeiten kommen vom Server (wizard.py, Hardware-Katalog).
// Eine Figur ist nur bei „Figur spricht“ und „Gesicht aus einem Foto“ Pflicht (Nutzer 14.11.: „assistent soll in
// betracht ziehen, dass es keine figur gibt“). Die Modelle sind wählbar, das beste ist vorgewählt, fehlende lädt er nach
// Rückfrage (Nutzer 14.11.: „der assistent soll auch model auswählen lassen, aber der beste ist vorgewählt, und wenn
// kein noch da anfragen zum herunterladen“).

import { useEffect, useMemo, useRef, useState } from 'react'
import { api, SPEECH_LANGUAGES, type Asset, type SpeechLanguage, type StudioProject, type WizardModel, type WizardPlan, type WizardRole } from '../api'
import { hfGuideUrl } from '../components/GatedNotice'
import { fmtDuration } from '../components/HardwareInfo'
import { getLang, t } from '../i18n'

type PathId = 'oneshot' | 'story' | 'narration' | 'character' | 'face' | 'animation'
type StyleId = 'film' | 'anim3d' | 'cartoon' | 'ink' | 'anime'
type MoodId = 'dramatic' | 'happy' | 'cool' | 'calm' | 'tense'
type FramingId = 'wide' | 'medium' | 'close' | 'detail' | 'behind'
type VoiceId = 'warm_female' | 'calm_male' | 'old_rough' | 'young_bright'
type StepId = 'path' | 'idea' | 'character' | 'scenes' | 'sound' | 'models' | 'create'

interface SceneDraft {
  framing: FramingId
  action: string
  line: string
  seconds: number
  hint: string
}

interface PathDef {
  id: PathId
  icon: string
  title: string
  text: string
  /** Figur: nötig (spricht in die Kamera, Gesicht aus dem Foto), üblich (vorgewählt, ohne geht auch) oder freiwillig
   *  (ohne vorgewählt) */
  character: 'required' | 'usual' | 'optional'
  /** Beispiel im Schritt „Idee“, wenn es nicht um eine Figur geht */
  idea?: string
  /** gesprochene Sätze: keine, mit Lippen (Figur spricht) oder als Sprecher aus dem Off */
  lines: 'none' | 'lipsync' | 'narration'
  /** eine durchgehende Einstellung: Clip 2 und 3 setzen Clip 1 nahtlos fort (Anschluss) */
  chain: boolean
  style: StyleId
  /** Gesicht aus einem Foto: das Porträt ist Referenz jedes Startbilds, jeder Clip endet wieder im Startbild */
  photo?: boolean
  /** Vorschläge für die Anzahl der Szenen: kurz, empfohlen (Vorgabe), länger */
  counts: [number, number, number]
  /** Szenen für eine Anzahl (ohne Angabe die empfohlene), mit passenden Hinweisen; cast false: Hinweise ohne Figur */
  scenes: (n?: number, cast?: boolean) => SceneDraft[]
}

const sc = (framing: FramingId, seconds: number, hint: string): SceneDraft => ({ framing, action: '', line: '', seconds, hint })

/** Höchstens so viele Szenen im Assistenten (im Studio gehen mehr) */
const MAX_SCENES = 20

/** Szenen für eine Anzahl (Nutzer 14.11.: „der user soll auch szenen anzahl auswählen, du schlägst ein paar auswahl
 *  möglichkeiten vor und der user kann aber auch selbst bestimmen“): Anfang und Ende stehen fest, dazwischen kommt die
 *  Mitte in dieser Reihenfolge, danach `more` (bekommt die Nummer der Szene in der Mitte, ab 1); eine einzelne Szene
 *  bekommt einen eigenen Hinweis. */
const arc = (n: number, a: { single: SceneDraft; first: SceneDraft; middle: SceneDraft[]; more: (k: number) => SceneDraft; last: SceneDraft }) =>
  n <= 1 ? [a.single]
    : [a.first, ...Array.from({ length: n - 2 }, (_, k) => (k < a.middle.length ? { ...a.middle[k] } : a.more(k + 1))), a.last]

const PATHS: PathDef[] = [
  {
    id: 'oneshot', icon: '🌅', character: 'optional', lines: 'none', chain: true, style: 'film',
    title: t('Eine durchgehende Einstellung', 'One continuous shot'),
    text: t('Ein Moment ohne Schnitt, aus nahtlos verbundenen Clips. Gut für Orte, Stimmungen, ein Produkt.',
      'One moment without a cut, made of seamlessly joined clips. Good for places, moods, a product.'),
    idea: t('z. B. Ein Morgen an einem stillen See: Nebel, dann bricht die Sonne durch.', 'e.g. A morning at a quiet lake: mist, then the sun breaks through.'),
    counts: [2, 3, 4],
    scenes: (n = 3) => arc(n, {
      single: sc('wide', 5, t('Was sieht man, was passiert? z. B. „Nebel liegt über einem stillen See, die Sonne bricht durch.“', 'What do we see, what happens? e.g. "Mist lies over a quiet lake, the sun breaks through."')),
      first: sc('wide', 5, t('Anfang: Was sieht man zuerst? z. B. „Nebel liegt über einem stillen See im Morgenlicht.“', 'Start: what do we see first? e.g. "Mist lies over a quiet lake in the morning light."')),
      middle: [sc('wide', 5, t('Weiter: Was passiert dann? z. B. „Die Sonne bricht durch, ein Ruderboot treibt ins Bild.“', 'Next: what happens then? e.g. "The sun breaks through, a rowing boat drifts into view."'))],
      more: () => sc('wide', 5, t('Weiter: Was passiert dann?', 'Next: what happens then?')),
      last: sc('wide', 5, t('Ende: Wie hört der Moment auf? z. B. „Ein Reiher fliegt auf, das Licht wird golden.“', 'End: how does the moment end? e.g. "A heron takes off, the light turns golden."')),
    }),
  },
  {
    id: 'story', icon: '🎬', character: 'usual', lines: 'lipsync', chain: false, style: 'film',
    title: t('Kurzgeschichte in Szenen', 'A short story in scenes'),
    text: t('Mehrere Einstellungen wie in einem Kurzfilm: Einführung, Handlung, Ende.', 'Several shots like a short film: introduction, action, ending.'),
    counts: [3, 5, 8],
    scenes: (n = 5, cast = true) => arc(n, {
      single: sc('medium', 5, cast ? t('Die ganze Geschichte in einer Einstellung: Wer tut was?', 'The whole story in one shot: who does what?')
        : t('Die ganze Geschichte in einer Einstellung: Was passiert?', 'The whole story in one shot: what happens?')),
      first: sc('wide', 5, cast ? t('Einführung: Wo sind wir, wer ist da?', 'Introduction: where are we, who is there?')
        : t('Einführung: Wo sind wir, was sieht man?', 'Introduction: where are we, what do we see?')),
      middle: [
        sc('medium', 5, cast ? t('Handlung: Was tut die Figur?', 'Action: what does the character do?') : t('Handlung: Was passiert?', 'Action: what happens?')),
        sc('close', 5, cast ? t('Reaktion: Was fühlt sie? Hier passt ein Satz.', 'Reaction: what does it feel? A line fits here.')
          : t('Nah dran: Was sieht man aus der Nähe?', 'Close up: what do we see up close?')),
        sc('detail', 4, cast ? t('Detail: ein wichtiger Gegenstand oder eine Hand.', 'Detail: an important object or a hand.')
          : t('Detail: ein wichtiger Gegenstand.', 'Detail: an important object.')),
        sc('medium', 5, t('Wendung: Etwas Unerwartetes passiert.', 'Twist: something unexpected happens.')),
        sc('close', 5, t('Höhepunkt: der entscheidende Moment.', 'Climax: the decisive moment.')),
        sc('medium', 5, t('Auflösung: Wie geht es aus?', 'Resolution: how does it turn out?')),
      ],
      more: () => sc('medium', 5, t('Was passiert dann?', 'What happens then?')),
      last: sc('wide', 6, t('Ende: ein ruhiges Schlussbild.', 'Ending: a quiet final image.')),
    }),
  },
  {
    id: 'narration', icon: '🎙', character: 'optional', lines: 'narration', chain: false, style: 'film',
    title: t('Mit Sprecher', 'With a narrator'),
    text: t('Eine Stimme erzählt, dazu passende Bilder in Bewegung. Gut für Erklärvideos und kleine Dokus.', 'A voice tells the story over matching moving pictures. Good for explainers and small documentaries.'),
    idea: t('z. B. Wie aus einer Kaffeebohne ein Espresso wird.', 'e.g. How a coffee bean becomes an espresso.'),
    counts: [3, 4, 6],
    scenes: (n = 4) => arc(n, {
      single: sc('wide', 6, t('Das Bild zum Text: was man sieht, während der Sprecher erzählt.', 'The picture for the text: what we see while the narrator talks.')),
      first: sc('wide', 6, t('Einstieg: ein Bild, das neugierig macht.', 'Opening: a picture that makes you curious.')),
      middle: [sc('medium', 6, t('Punkt 1: was gezeigt wird, während der Sprecher erzählt.', 'Point 1: what we see while the narrator talks.'))],
      more: (k) => sc('medium', 6, t(`Punkt ${k}.`, `Point ${k}.`)),
      last: sc('wide', 6, t('Schluss: ein Bild zum Nachklingen.', 'Ending: a picture that lingers.')),
    }),
  },
  {
    id: 'character', icon: '🗣', character: 'required', lines: 'lipsync', chain: false, style: 'anim3d',
    title: t('Figur spricht', 'A character speaks'),
    text: t('Eine Figur spricht in die Kamera, die Lippen folgen jedem Satz. Gut für Begrüßungen und kurze Botschaften.', 'A character talks into the camera, the lips follow every line. Good for greetings and short messages.'),
    counts: [1, 3, 5],
    scenes: (n = 3) => arc(n, {
      single: sc('medium', 6, t('Begrüßung und Botschaft in einem: Was sagt sie?', 'Greeting and message in one: what does it say?')),
      first: sc('medium', 5, t('Begrüßung: Wie fängt sie an?', 'Greeting: how does it start?')),
      middle: [sc('medium', 5, t('Die Botschaft.', 'The message.'))],
      more: () => sc('medium', 5, t('Noch ein Gedanke.', 'One more thought.')),
      last: sc('close', 5, t('Abschluss: ein letzter Satz, ein Lächeln.', 'Ending: a last line, a smile.')),
    }),
  },
  {
    id: 'face', icon: '📷', character: 'required', lines: 'lipsync', chain: false, style: 'film', photo: true,
    title: t('Gesicht aus einem Foto', 'A face from a photo'),
    text: t('Ein Porträtfoto wird zur Hauptfigur: in einer Rolle, an einem Ort, mit Bewegung und Stimme.', 'A portrait photo becomes the main character: in a role, at a place, with movement and voice.'),
    counts: [1, 3, 5],
    scenes: (n = 3) => arc(n, {
      single: sc('medium', 5, t('Wo ist die Person, was tut sie? Gern mit einem Satz.', 'Where is the person, what does it do? A line works well here.')),
      first: sc('medium', 5, t('Erste Einstellung: Wo ist die Person, was tut sie?', 'First shot: where is the person, what does it do?')),
      middle: [],
      more: () => sc('medium', 5, t('Was passiert dann?', 'What happens next?')),
      last: sc('close', 5, t('Nah aufs Gesicht, gern mit einem Satz.', 'Close on the face, a line works well here.')),
    }),
  },
  {
    id: 'animation', icon: '🎨', character: 'usual', lines: 'lipsync', chain: false, style: 'cartoon',
    title: t('Animation', 'Animation'),
    text: t('Gezeichnet oder als 3D-Animation, mit eigener Figur oder ohne. Ein kleiner Gag oder eine Geschichte.', 'Drawn or as 3D animation, with a character of your own or without. A small gag or a story.'),
    counts: [3, 4, 6],
    scenes: (n = 4, cast = true) => arc(n, {
      single: sc('medium', 5, t('Der ganze Gag in einer Einstellung.', 'The whole gag in one shot.')),
      first: sc('wide', 5, cast ? t('Einführung: die Figur in ihrer Welt.', 'Introduction: the character in its world.')
        : t('Einführung: Wo sind wir, was sieht man?', 'Introduction: where are we, what do we see?')),
      middle: [
        sc('medium', 5, t('Handlung: Was passiert?', 'Action: what happens?')),
        sc('close', 4, cast ? t('Reaktion, gern mit einem Satz.', 'Reaction, a line works well here.')
          : t('Nah dran: Was sieht man aus der Nähe?', 'Close up: what do we see up close?')),
        sc('medium', 5, t('Es geht schief: Was passiert Unerwartetes?', 'It goes wrong: what unexpected thing happens?')),
        sc('close', 4, cast ? t('Noch eine Reaktion.', 'Another reaction.') : t('Noch ein Blick aus der Nähe.', 'Another look up close.')),
      ],
      more: () => sc('medium', 5, t('Was passiert dann?', 'What happens then?')),
      last: sc('wide', 6, t('Ende: die Pointe oder ein stilles Schlussbild.', 'Ending: the punchline or a quiet final image.')),
    }),
  },
]

/** Anzahl ändern, ohne Geschriebenes zu verlieren: Ist noch nichts geschrieben, passen die Hinweise neu zur Anzahl;
 *  sonst kommen neue Szenen vor die letzte (das Ende bleibt das Ende), und entfernt werden nur leere, zuerst aus der
 *  Mitte von hinten. Sind zu viele beschrieben, bleibt die Liste länger als gewünscht. */
function resizeScenes(list: SceneDraft[], n: number, p: PathDef, cast: boolean): SceneDraft[] {
  const filled = (s: SceneDraft) => !!(s.action.trim() || s.line.trim())
  const tpl = p.scenes(n, cast)
  if (!list.some(filled)) return tpl
  if (list.length === 1 && n > 1) return [list[0], ...tpl.slice(1)]
  const out = [...list]
  while (out.length < n) out.splice(out.length - 1, 0, { ...tpl[out.length - 1] })
  while (out.length > n) {
    const order = [...Array.from({ length: Math.max(0, out.length - 2) }, (_, k) => out.length - 2 - k), out.length - 1, 0]
    const i = order.find((k) => !filled(out[k]))
    if (i === undefined) break
    out.splice(i, 1)
  }
  return out
}

const STYLES: Record<StyleId, { label: string; image: string; video: string }> = {
  film: {
    label: t('Realfilm', 'Live action'),
    image: 'Cinematic film still, photographed with natural light, realistic detail.',
    video: 'A cinematic live-action shot with natural light and realistic detail.',
  },
  anim3d: {
    label: t('3D-Animation', '3D animation'),
    image: '3D animated film still in the style of a modern animated feature film, soft warm lighting, rich colors.',
    video: 'A 3D animated film scene in the style of a modern animated feature film, soft warm lighting.',
  },
  cartoon: {
    label: t('Zeichentrick', 'Cartoon'),
    image: 'Hand-drawn 2D cartoon frame with clean black ink lines and flat colors, simple and expressive. No glossy highlights, no lens flare.',
    video: 'A hand-drawn 2D cartoon animation with clean black ink lines and flat colors.',
  },
  // Tusche: der Look des Kurzfilms (docs/SHORT_FILM.md), schwarz-weiß mit grauer Schraffur auf dunklem Grund
  ink: {
    label: t('Tusche', 'Ink'),
    image: 'Hand-drawn 2D cartoon frame, mostly black and white, with imperfect, slightly wobbly black ink lines and a few loose grey hatching strokes, on a diffuse black background with a faint grey glow.',
    video: 'A hand-drawn 2D cartoon animation, mostly black and white, with imperfect, slightly wobbly black ink lines and flat grey shading on a diffuse black background.',
  },
  anime: {
    label: t('Anime', 'Anime'),
    image: 'Anime illustration with clean line art and soft cel shading.',
    video: 'An anime-style animation with clean line art and soft cel shading.',
  },
}

const MOODS: Record<MoodId, { label: string; light: string; music: string; musicLabel: string }> = {
  dramatic: {
    label: t('Dramatisch', 'Dramatic'), light: 'Low-key light with deep shadows.',
    music: 'Slow dramatic cinematic score with deep cello drones, a lonely piano and soft timpani rolls, melancholic and heavy, slowly building and then fading into silence. BPM: 60.',
    musicLabel: t('Langsame Filmmusik mit Cello, Klavier und Pauken', 'Slow film score with cello, piano and timpani'),
  },
  happy: {
    label: t('Fröhlich', 'Cheerful'), light: 'Bright, warm daylight.',
    music: 'Bright playful score with plucked strings, glockenspiel, ukulele and light percussion, cheerful and bouncy. BPM: 120.',
    musicLabel: t('Verspielt mit Zupfstreichern, Glockenspiel und Ukulele', 'Playful with plucked strings, glockenspiel and ukulele'),
  },
  cool: {
    label: t('Lässig', 'Cool'), light: 'A single hard spotlight from above, deep black shadows all around.',
    music: 'Laid-back hip-hop beat with dusty vinyl crackle, a deep warm bass line, brushed drums and a muted jazz trumpet, cool and confident. BPM: 90.',
    musicLabel: t('Lässiger Hip-Hop-Beat mit Plattenknistern, Bass und gedämpfter Trompete', 'Laid-back hip-hop beat with vinyl crackle, bass and muted trumpet'),
  },
  calm: {
    label: t('Ruhig', 'Calm'), light: 'Soft, calm light.',
    music: 'Calm ambient score with soft piano, warm pads and gentle strings, peaceful and warm. BPM: 70.',
    musicLabel: t('Ruhiges Klavier mit warmen Flächen', 'Calm piano with warm pads'),
  },
  tense: {
    label: t('Spannend', 'Suspenseful'), light: 'Moody, high-contrast light.',
    music: 'Tense cinematic score with a pulsing synth bass, ticking percussion and rising strings, suspenseful. BPM: 100.',
    musicLabel: t('Spannung mit pulsierendem Bass und steigenden Streichern', 'Tension with pulsing bass and rising strings'),
  },
}

/** p: mit Figur; n: ohne Figur, denn „from the waist up“ und „of the face“ verlangen eine Person im Bild */
const FRAMINGS: Record<FramingId, { label: string; p: string; n: string }> = {
  wide: { label: t('Totale', 'Wide'), p: 'Wide shot', n: 'Wide shot' },
  medium: { label: t('Halbnah', 'Medium'), p: 'Medium shot from the waist up', n: 'Medium shot' },
  close: { label: t('Nah', 'Close-up'), p: 'Close-up of the face', n: 'Close-up' },
  detail: { label: t('Detail', 'Detail'), p: 'Detail shot', n: 'Detail shot' },
  behind: { label: t('Von hinten', 'From behind'), p: 'Shot from behind', n: 'Shot from behind' },
}

/** Musikvorschläge (Nutzer 14.11.: „assistent soll bei der musik viel mehr vorschläge und promt feld anbieten“). Ein
 *  Satz für Stable Audio 3: Gattung, Instrumente, Schlagwerk, Stimmung, dann das Tempo (CLAUDE.md, Audio). Die ersten
 *  fünf gehören zu den Stimmungen und stehen dort; die Stimmung wählt ihren Vorschlag vor. */
type MusicId = MoodId | 'epic' | 'lofi' | 'synthwave' | 'jazz' | 'rock' | 'folk' | 'techno' | 'ambient' | 'comedy'
  | 'western' | 'horror' | 'chiptune' | 'fantasy' | 'funk' | 'celtic' | 'action' | 'sad'
const MUSIC_MORE: Record<Exclude<MusicId, MoodId>, { label: string; p: string }> = {
  epic: { label: t('Episches Orchester', 'Epic orchestra'), p: 'Epic orchestral score with powerful brass, soaring strings, a choir and thundering taiko drums, heroic and uplifting. BPM: 110.' },
  action: { label: t('Action-Trailer', 'Action trailer'), p: 'Intense action trailer music with pulsing hybrid synths, staccato strings, booming percussion hits and rising brass, urgent and powerful. BPM: 120.' },
  sad: { label: t('Traurig', 'Sad'), p: 'Melancholic solo piano with a soft cello, slow and tender, sad and reflective. BPM: 65.' },
  fantasy: { label: t('Märchen', 'Fairy tale'), p: 'Magical fantasy score with harp, celesta, soft flutes and warm strings, enchanting and full of wonder. BPM: 80.' },
  ambient: { label: t('Ambient', 'Ambient'), p: 'Atmospheric ambient soundscape with slowly evolving synth pads, soft drones and distant chimes, spacious and peaceful. BPM: 60.' },
  lofi: { label: t('Lo-Fi', 'Lo-fi'), p: 'Lo-fi hip-hop beat with mellow Rhodes chords, soft vinyl crackle, a muffled kick and a lazy snare, relaxed and dreamy. BPM: 75.' },
  jazz: { label: t('Jazz-Trio', 'Jazz trio'), p: 'Smooth jazz trio with a walking upright bass, brushed drums and a mellow piano, warm and late-night. BPM: 95.' },
  funk: { label: t('Funk', 'Funk'), p: 'Groovy funk with slap bass, wah-wah guitar, tight drums and a punchy brass section, upbeat and cheeky. BPM: 110.' },
  synthwave: { label: t('Synthwave', 'Synthwave'), p: 'Retro synthwave with a pulsing analog bass, bright arpeggios, gated reverb drums and a warm lead synth, nostalgic and driving. BPM: 105.' },
  techno: { label: t('Techno', 'Techno'), p: 'Driving techno with a deep four-on-the-floor kick, a rolling bass line and hypnotic synth stabs, dark and energetic. BPM: 126.' },
  rock: { label: t('Rock', 'Rock'), p: 'Energetic indie rock with crunchy electric guitars, a punchy bass and driving live drums, bold and confident. BPM: 130.' },
  folk: { label: t('Akustik-Folk', 'Acoustic folk'), p: 'Warm acoustic folk with fingerpicked guitar, a soft mandolin and light hand percussion, gentle and hopeful. BPM: 90.' },
  celtic: { label: t('Keltisch', 'Celtic'), p: 'Lively Celtic folk with tin whistle, fiddle, bodhrán and acoustic guitar, adventurous and joyful. BPM: 115.' },
  western: { label: t('Western', 'Western'), p: 'Dusty western score with twangy electric guitar, a whistled melody, harmonica and a slow galloping rhythm, lonely and wide. BPM: 85.' },
  comedy: { label: t('Komödie', 'Comedy'), p: 'Quirky comedy score with pizzicato strings, bassoon, xylophone and playful woodwinds, bouncy and mischievous. BPM: 125.' },
  horror: { label: t('Grusel', 'Horror'), p: 'Dark horror score with eerie string clusters, low drones, distant metallic scrapes and sudden deep hits, unsettling. BPM: 70.' },
  chiptune: { label: t('8-Bit', '8-bit'), p: 'Upbeat 8-bit chiptune with a square-wave melody, bubbly arpeggios and punchy retro drums, playful and fast. BPM: 140.' },
}
const MUSIC: { id: MusicId; label: string; p: string; title?: string }[] = [
  ...(Object.keys(MOODS) as MoodId[]).map((k) => ({ id: k as MusicId, label: MOODS[k].label, p: MOODS[k].music, title: MOODS[k].musicLabel })),
  ...(Object.keys(MUSIC_MORE) as Exclude<MusicId, MoodId>[]).map((k) => ({ id: k as MusicId, ...MUSIC_MORE[k] })),
]

const VOICES: Record<VoiceId, { label: string; p: string }> = {
  warm_female: { label: t('Warme Frauenstimme', 'Warm female voice'), p: 'A warm, clear female voice, about thirty-five, calm and friendly.' },
  calm_male: { label: t('Ruhige Männerstimme', 'Calm male voice'), p: 'A calm, deep male voice, about forty-five, warm and steady.' },
  old_rough: { label: t('Alt und rau', 'Old and rough'), p: 'An old man with a rough, gravelly, deep voice, speaking slowly and wearily.' },
  young_bright: { label: t('Jung und fröhlich', 'Young and cheerful'), p: 'A bright, cheerful young voice, lively and friendly.' },
}

const STEP_LABEL: Record<StepId, string> = {
  path: t('Weg', 'Path'), idea: t('Idee', 'Idea'), character: t('Figur', 'Character'), scenes: t('Szenen', 'Scenes'),
  sound: t('Ton', 'Sound'), models: t('Modelle', 'Models'), create: t('Los', 'Go'),
}

const STEP_HELP: Record<StepId, string> = {
  path: t('Wähle, was für ein Video es werden soll. Du kannst alles später im Studio ändern.',
    'Choose what kind of video you want. You can change everything in the Studio later.'),
  idea: t('Stil und Stimmung gelten für alle Szenen, so passt am Ende alles zusammen.',
    'Style and mood apply to every scene, so everything fits together in the end.'),
  character: t('Zuerst die Figur: Aus dem gewählten Entwurf entstehen alle Startbilder, so sieht sie in jeder Szene gleich aus.',
    'The character first: every start image is made from the chosen draft, so it looks the same in every scene.'),
  scenes: t('Wie viele Szenen? Nimm einen Vorschlag oder bestimme die Anzahl selbst. Eine Szene ist eine Einstellung von 4 bis 6 Sekunden; eine klare Handlung je Szene klappt am besten.',
    'How many scenes? Take a suggestion or choose the number yourself. A scene is one shot of 4 to 6 seconds; one clear action per scene works best.'),
  sound: t('Stimme und Musik entstehen auf deinem Rechner. Geräusche macht das Videomodell selbst.',
    'Voice and music are made on your computer. The video model makes the sounds by itself.'),
  models: t('Vorgewählt sind die besten Modelle für deine Karte; je Aufgabe kannst du ein anderes wählen. Die besten brauchen länger, sehen aber am besten aus.',
    'The best models for your card are preselected; you can pick another one for each task. The best ones take longer but look best.'),
  create: t('Zuerst die Startbilder: Sie gehen schnell und legen fest, wie jede Szene aussieht. Gefällt eins nicht, nimm das andere.',
    'Start images first: they are quick and decide how each scene looks. If you don\'t like one, take the other.'),
}

const FACE_HELP = t('Ein Foto von Kopf und Schultern, frontal und gut beleuchtet, trifft das Gesicht am besten. Damit es im ganzen Clip gleich bleibt, endet jeder Clip wieder im Startbild; ein bewegter Hintergrund (Wasser, Rauch) steht dann eher still. Das Foto bleibt auf deinem Rechner.',
  'A head-and-shoulders photo, frontal and well lit, gets the face best. To keep it the same through the whole clip, every clip ends in its start image again; a moving background (water, smoke) then stays rather still. The photo stays on your computer.')

/** Hilfe im Schritt „Figur“, wenn es auch ohne geht */
const CAST_HELP = t('Gibt es eine Hauptfigur? Dann zuerst sie: Aus dem gewählten Entwurf entstehen alle Startbilder, so sieht sie in jeder Szene gleich aus. Ohne Figur geht es gleich weiter zu den Szenen.',
  'Is there a main character? Then it comes first: every start image is made from the chosen draft, so it looks the same in every scene. Without a character you go straight on to the scenes.')

const ROLE_LABEL: Record<WizardRole, string> = {
  image: t('Bilder', 'Images'), video: t('Videos', 'Videos'), speech: t('Stimme', 'Voice'), music: t('Musik', 'Music'),
}

/** Ein Download aus dem Assistenten: Auftrag, Fortschritt (0 bis 1), Fehler */
interface Fetch { job: string | null; progress: number; error: string | null; done: boolean }

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function waitJob(id: string): Promise<Asset[]> {
  for (;;) {
    const j = await api.job(id)
    if (j.status === 'done') return api.jobAssets(id)
    if (j.status === 'error' || j.status === 'cancelled') throw new Error(j.error || j.status)
    await sleep(1500)
  }
}

/** Sieht der Text nicht englisch aus? Umlaute, ß und deutsche Wörter, die es im Englischen nicht gibt (gemessen 14.11.:
 * „an Deck eines alten Segelschiffs bei hellem Tageslicht“ fiel durch die erste, kürzere Liste). Bei deutscher Oberfläche
 * wird ohnehin immer übertragen. */
const NON_EN = /[äöüßÄÖÜ]|\b(der|das|und|ein|eine|einen|eines|einem|einer|mit|auf|bei|vom|zum|zur|dem|des|ist|sind|nicht|sich|unter|hinter|nach|aus|wird|steht|geht|zieht|hebt|langsam|seine|ihre|alten|alte|kleine|kleiner|große|großen|hellem|dunklen)\b/i

/** Freie Texte treu ins Englische (Ziel „translate“ des lokalen Sprachmodells, ein Aufruf für alle, nummeriert). Bild-
 * und Videomodelle verstehen Englisch am besten; ein deutscher Szenentext kam bei FLUX sogar als Schrift ins Bild.
 * Gesprochene Sätze bleiben, wie sie sind. Klappt es nicht, bleibt der Originaltext. */
async function toEnglish(texts: string[]): Promise<string[]> {
  const need = texts.map((x) => !!x.trim() && (getLang() === 'de' || NON_EN.test(x)))
  if (!need.some(Boolean)) return texts
  const numbered = texts.map((x, i) => (need[i] ? `[${i + 1}] ${x.trim().replace(/\s+/g, ' ')}` : '')).filter(Boolean).join('\n')
  const out = [...texts]
  try {
    const r = await api.expandPrompt({ prompt: numbered, target: 'translate', width: 1024, height: 1024 })
    for (const line of r.expanded.split(/\n+/)) {
      const m = line.match(/^\s*\[(\d+)\]\s*(.+)$/)
      if (m && need[Number(m[1]) - 1]) out[Number(m[1]) - 1] = m[2].trim()
    }
    // Hat das Modell die Nummern verloren: einzeln übersetzen
    for (const [i, x] of texts.entries()) {
      if (need[i] && out[i] === x) {
        const one = await api.expandPrompt({ prompt: x.trim(), target: 'translate', width: 1024, height: 1024 })
        if (one.expanded.trim()) out[i] = one.expanded.trim()
      }
    }
  } catch {
    /* ohne Sprachmodell (FLUX 3 nicht geladen): Originaltext */
  }
  return out
}

interface BoardItem {
  sceneId: string
  /** null: diese Szene bekommt kein eigenes Startbild (setzt die vorige fort) */
  job: string | null
  variants: Asset[]
  chosen: string | null
  error: string | null
}

export function Wizard({ project, onClose, onOpenProject, onDone }: {
  /** offenes Projekt: Ist es leer, baut der Assistent darin, sonst legt er ein neues an */
  project: StudioProject | null
  onClose: () => void
  onOpenProject: (id: string) => void
  /** Videos laufen: Assistent zu, Hinweise im Studio zeigen */
  onDone: () => void
}) {
  const [step, setStep] = useState<StepId>('path')
  const [pathId, setPathId] = useState<PathId>('story')
  const path = PATHS.find((x) => x.id === pathId)!
  // Idee
  const [idea, setIdea] = useState('')
  const [place, setPlace] = useState('')
  const [style, setStyle] = useState<StyleId>('film')
  const [mood, setMood] = useState<MoodId>('dramatic')
  const [portrait, setPortrait] = useState(false)
  // Figur
  const [useCharacter, setUseCharacter] = useState(true)
  const [charName, setCharName] = useState('')
  const [look, setLook] = useState('')
  const [refAsset, setRefAsset] = useState<Asset | null>(null)
  const [drafts, setDrafts] = useState<Asset[]>([])
  const [chosenDraft, setChosenDraft] = useState<string | null>(null)
  // Szenen und Ton
  const [scenes, setScenes] = useState<SceneDraft[]>(() => PATHS[1].scenes())
  const [voice, setVoice] = useState<VoiceId>('warm_female')
  const [lang, setLang] = useState<SpeechLanguage>(getLang() === 'de' ? 'de' : 'en')
  const [music, setMusic] = useState(true)
  // Musik: ohne eigene Wahl der Vorschlag der Stimmung; musicText = eigener oder geänderter Prompt
  const [musicPick, setMusicPick] = useState<MusicId | null>(null)
  const [musicText, setMusicText] = useState<string | null>(null)
  const [best, setBest] = useState(true)
  // Modelle: eigene Wahl je Aufgabe (sonst die beste), Downloads aus dem Assistenten
  const [choice, setChoice] = useState<Partial<Record<WizardRole, string>>>({})
  const [fetches, setFetches] = useState<Record<string, Fetch>>({})
  const [refresh, setRefresh] = useState(0)
  const alive = useRef(true)
  useEffect(() => () => { alive.current = false }, [])
  // Server und Ablauf
  const [plan, setPlan] = useState<WizardPlan | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [stage, setStage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [board, setBoard] = useState<BoardItem[]>([])
  const pidRef = useRef<string | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)

  const characterOn = path.character === 'required' || useCharacter
  /** Wie die Sätze klingen: Ohne Figur spricht niemand im Bild, dann liest sie ein Sprecher aus dem Off */
  const lineMode = path.lines === 'lipsync' && !characterOn ? 'narration' : path.lines
  /** Nimmt das gewählte Videomodell den Satz als Ton (die Lippen folgen ihm)? Sonst bleibt er auf der Spur „Stimme“ */
  const lipsOk = plan?.models.video?.lipsync !== false
  /** Bildausschnitt im Prompt: ohne Figur ohne Körperteile */
  const frame = (f: FramingId) => (characterOn ? FRAMINGS[f].p : FRAMINGS[f].n)
  const musicId: MusicId = musicPick ?? mood
  const musicPreset = MUSIC.find((x) => x.id === musicId) ?? MUSIC[0]
  const lines = path.lines === 'none' ? [] : scenes.map((s) => s.line.trim()).filter(Boolean)
  const startScenes = path.chain ? 1 : scenes.length
  const totalSeconds = scenes.reduce((n, s) => n + s.seconds, 0)
  const steps: StepId[] = ['path', 'idea', 'character', 'scenes', 'sound', 'models', 'create']
  const at = steps.indexOf(step)

  // Plan vom Server: Karte, Modelle, Größe, Zeiten; neu, sobald sich das Vorhaben ändert
  const planBody = useMemo(() => ({
    format: portrait ? 'portrait' : 'landscape', quality: best ? 'best' : 'fast',
    character: characterOn && !path.photo && drafts.length === 0, character_ref: !!refAsset, cast: characterOn,
    start_images: startScenes, video_seconds: totalSeconds, voice_lines: lines.length, music, models: choice,
  }), [portrait, best, characterOn, path.photo, drafts.length, refAsset, startScenes, totalSeconds, lines.length, music, choice])
  // Wofür der Plan gerechnet ist: Er kommt etwas nach jeder Änderung, die Hochrechnung braucht seine eigene Grundlage
  const planFor = useRef(planBody)
  useEffect(() => {
    let live = true
    api.studioWizardPlan(planBody).then((p) => {
      if (!live) return
      planFor.current = planBody
      setPlan(p)
    }).catch(() => {})
    return () => { live = false }
  }, [planBody, refresh])

  /** Aufgaben, die dieses Video braucht */
  const usedRoles: WizardRole[] = ['image', 'video', ...(lines.length ? ['speech' as const] : []), ...(music ? ['music' as const] : [])]
  /** Gewählte Modelle dieser Aufgaben, die noch nicht geladen sind */
  const missing = (roles: WizardRole[]) => roles.map((r) => plan?.models[r]).filter((m): m is WizardModel => !!m && !m.installed)
  const gbText = (gb: number) => `${gb.toLocaleString(getLang() === 'de' ? 'de-DE' : 'en-US', { maximumFractionDigits: 1 })} GB`

  /** Fehlende Modelle laden, wenn der Nutzer Ja sagt: der normale Download-Auftrag (eigene Warteschlange), Fortschritt
   *  hier; danach den Plan neu holen, er meldet das Modell dann als geladen */
  const fetchModels = (ids: string[]) => {
    for (const id of ids) {
      const f = fetches[id]
      if (f && !f.error) continue
      setFetches((x) => ({ ...x, [id]: { job: null, progress: 0, error: null, done: false } }))
      api.downloadModel(id).then(async (job) => {
        for (;;) {
          if (!alive.current) return
          const j = await api.job(job.id)
          if (j.status === 'done') {
            setFetches((x) => ({ ...x, [id]: { job: job.id, progress: 1, error: null, done: true } }))
            setRefresh((r) => r + 1)
            return
          }
          if (j.status === 'error' || j.status === 'cancelled') throw new Error(j.error || j.status)
          setFetches((x) => ({ ...x, [id]: { job: job.id, progress: j.progress || 0, error: null, done: false } }))
          await sleep(2000)
        }
      }).catch((e) => setFetches((x) => ({ ...x, [id]: { job: null, progress: 0, error: String(e?.message ?? e), done: false } })))
    }
  }

  /** Rechenzeit für eine andere Szenenliste, hochgerechnet aus dem Plan des Servers: Startbilder je Szene, Videos und
   *  Export je Sekunde Film; Figur, Stimme und Musik bleiben gleich. Ohne Messung für ein gewähltes Modell: keine Zahl */
  const estimateFor = (list: SceneDraft[]): number | null => {
    if (!plan || plan.steps.some((x) => x.seconds == null)) return null
    const get = (key: string) => plan.steps.find((x) => x.key === key)?.seconds ?? 0
    const base = planFor.current
    const secs = list.reduce((n, s) => n + s.seconds, 0)
    const starts = path.chain ? 1 : list.length
    return get('character') + get('voice') + get('music')
      + (base.start_images ? (get('start_images') / base.start_images) * starts : 0)
      + (base.video_seconds ? ((get('videos') + get('export')) / base.video_seconds) * secs : 0)
  }

  // Anzahl der Szenen: drei Vorschläge je Weg oder eine eigene Zahl
  const [ownCount, setOwnCount] = useState<string | null>(null)
  const [countNote, setCountNote] = useState<string | null>(null)
  const setCount = (n: number) => {
    const want = Math.max(1, Math.min(MAX_SCENES, Math.round(n)))
    const next = resizeScenes(scenes, want, path, characterOn)
    setScenes(next)
    setCountNote(next.length <= want ? null : path.chain
      ? t('Teile mit Text bleiben stehen; entferne sie einzeln mit ✕.', 'Parts with text stay; remove them one by one with ✕.')
      : t('Szenen mit Text bleiben stehen; entferne sie einzeln mit ✕.', 'Scenes with text stay; remove them one by one with ✕.'))
  }
  const countLabel = (n: number) => path.chain
    ? t(`${n} ${n === 1 ? 'Teil' : 'Teile'}`, `${n} ${n === 1 ? 'part' : 'parts'}`)
    : t(`${n} ${n === 1 ? 'Szene' : 'Szenen'}`, `${n} ${n === 1 ? 'scene' : 'scenes'}`)
  const COUNT_TAGS = [t('kurz', 'short'), t('empfohlen', 'recommended'), t('länger', 'longer')]

  const choosePath = (id: PathId) => {
    const p = PATHS.find((x) => x.id === id)!
    const cast = p.character !== 'optional'
    setPathId(id)
    setStyle(p.style)
    setScenes(p.scenes(undefined, cast))
    setCountNote(null)
    setUseCharacter(cast)
  }

  /** Mit oder ohne Figur: Die Hinweise der Szenen passen sich an, Geschriebenes bleibt */
  const setCast = (on: boolean) => {
    setUseCharacter(on)
    setScenes((list) => {
      const tpl = path.scenes(list.length, on)
      return list.map((s, i) => ({ ...s, hint: tpl[i]?.hint ?? s.hint }))
    })
  }

  /** Name aus dem ersten Satzteil der Idee (bis . ! ? : ;), lange Namen an einer Wortgrenze gekürzt; sonst
   *  wurde aus „Somi is in a really good mood today: the sun is …“ ein mitten im Satz abgeschnittener Name */
  const projectName = () => {
    let name = idea.split(/[.!?:;\n]/)[0].trim() || charName.trim() || t('Mein Video', 'My video')
    if (name.length > 48) name = name.slice(0, 48).replace(/[\s,]+\S*$/, '')
    return name
  }

  /** Projekt erst beim ersten Rechenschritt anlegen: das offene, wenn es leer ist, sonst ein neues */
  const ensureProject = async (): Promise<string> => {
    if (pidRef.current) return pidRef.current
    const [w, h] = portrait ? [1080, 1920] : [1920, 1080]
    let id: string
    if (project && project.scenes.length === 0 && project.clips.length === 0) {
      id = project.id
      await api.studioCommand(id, 'project.update', { name: projectName(), width: w, height: h })
    } else {
      id = (await api.studioCreate(projectName(), w, h)).id
    }
    pidRef.current = id
    onOpenProject(id)
    return id
  }

  const cmd = async (pid: string, command: string, params: Record<string, unknown>) =>
    (await api.studioCommand(pid, command, params)).result

  const run = async (name: string, fn: () => Promise<void>) => {
    setBusy(name)
    setError(null)
    try {
      await fn()
    } catch (e: any) {
      setError(String(e?.message ?? e))
    } finally {
      setBusy(null)
    }
  }

  const uploadRef = (file?: File) => file && run('upload', async () => {
    const pid = await ensureProject()
    const p = await api.studioProject(pid)
    setRefAsset(await api.upload(file, p.folder || undefined))
  })

  const makeDrafts = () => run('drafts', async () => {
    const pid = await ensureProject()
    const who = charName.trim() || 'the main character'
    const prompt = refAsset
      ? `${STYLES[style].image} Character design of ${who}, based on the first image: ${look.trim() || 'the same character'}. Full body, standing upright, facing the viewer, plain neutral background, nothing else in the picture.`
      : `${STYLES[style].image} Character design of ${who}: ${look.trim()}. Full body, standing upright, facing the viewer, plain neutral background, nothing else in the picture.`
    const jobs = await Promise.all([0, 1].map(() => api.generateImage({
      prompt, model_id: plan?.models.image?.id ?? null, width: 896, height: 1152, batch_size: 2,
      reference_asset_ids: refAsset ? [refAsset.id] : [], project_id: pid,
    })))
    const out = (await Promise.all(jobs.map((j) => waitJob(j.id)))).flat()
    setDrafts(out)
    setChosenDraft(out[0]?.id ?? null)
  })

  /** Texte für die Prompts, schon ins Englische übertragen (toEnglish) */
  interface Tx { idea: string; place: string; look: string; actions: string[] }
  const dot = (x: string) => x.trim().replace(/[ .]+$/, '')
  /** Eigene Sätze im Video-Prompt groß beginnen („Wide shot. A dark empty stage …“ statt „… a dark …“) */
  const cap = (x: string) => (x ? x[0].toUpperCase() + x.slice(1) : x)

  const startPrompt = (s: SceneDraft, i: number, tx: Tx) => {
    const action = dot(tx.actions[i] || tx.idea)
    const setting = dot(tx.place) ? ` Setting: ${dot(tx.place)}.` : ''
    // „Cinematic film still“ gab FLUX 3 schwarze Balken oben und unten (gemessen 14.11. ohne Figur, gleiche Seeds:
    // 4 von 12 Startbildern, mit diesem Satz 0 von 12, Bild sonst fast gleich)
    const full = style === 'film' ? ' The picture fills the whole frame from edge to edge.' : ''
    if (path.photo) {
      // wie „Person aus einem Foto“ im Reiter Generieren (gemessen 24.10.: Gesicht gehalten), dazu Ausschnitt und Ort
      return `${STYLES[style].image} The person from the first image, with exactly the same face, eyes, nose, mouth and hair color: ${dot(tx.look)}. ${frame(s.framing)}: ${action}, the face clearly visible.${setting} ${MOODS[mood].light}${full}`
    }
    const who = charName.trim() || 'the character'
    const char = characterOn && chosenDraft
      ? `The character is ${who} from the first image: the same face, the same body and the same clothes, in the same style. ` : ''
    return `${STYLES[style].image} ${char}${frame(s.framing)}: ${action}.${setting} ${MOODS[mood].light}${full}`
  }

  /** lips: Das Videomodell nimmt den Satz als Ton, die Figur spricht ihn im Bild */
  const videoPrompt = (s: SceneDraft, i: number, tx: Tx, lips: boolean) => {
    const who = charName.trim() || 'The character'
    const speaks = lineMode === 'lipsync' && lips && s.line.trim() ? ` ${who} looks into the camera and says: "${s.line.trim()}"` : ''
    // Ein Satz ohne Lippen (Sprecher aus dem Off, Videomodell ohne Satz als Ton): Das Video bleibt leise, sonst spräche
    // es womöglich selbst etwas dazu
    const quiet = path.lines === 'narration' || (lineMode !== 'none' && !!s.line.trim() && !speaks)
    const sound = quiet ? 'Quiet ambient sound, no speech.' : speaks ? '' : 'Natural sounds of the scene.'
    return [`${STYLES[style].video} ${frame(s.framing)}.`, dot(tx.place) ? `${cap(dot(tx.place))}.` : '', MOODS[mood].light,
      `${cap(dot(tx.actions[i] || tx.idea))}.${speaks}`, 'The camera holds steady.', sound].filter(Boolean).join(' ')
  }

  /** Projekt füllen: Figur, Szenen, Sätze, Musik; dann die Startbilder anstoßen */
  const build = () => run('build', async () => {
    const pid = await ensureProject()
    setStage(t('Texte werden ins Englische übertragen …', 'Translating the texts into English …'))
    // Der Musik-Prompt nur, wenn er nicht englisch aussieht (die Vorschläge sind englisch und bleiben wörtlich)
    const ownMusic = musicText?.trim() ?? ''
    const musicIn = ownMusic && NON_EN.test(ownMusic) ? ownMusic : ''
    const en = await toEnglish([idea, place, look, musicIn, ...scenes.map((s) => s.action)])
    const tx: Tx = { idea: en[0], place: en[1], look: en[2], actions: en.slice(4) }
    const musicPrompt = musicIn ? en[3] : ownMusic || musicPreset.p
    setStage(t('Szenen werden angelegt …', 'Setting up the scenes …'))
    const p = plan ?? (await api.studioWizardPlan(planBody))
    const [w, h] = portrait ? [1080, 1920] : [1920, 1080]
    await cmd(pid, 'project.update', { name: projectName(), width: w, height: h, video_quality: p.quality })
    const voiceNeeded = lines.length > 0
    let cid: string | null = null
    if ((characterOn && (chosenDraft || (path.photo && refAsset))) || voiceNeeded) {
      const r = await cmd(pid, 'character.add', {
        name: charName.trim() || (lineMode === 'narration' ? t('Sprecher', 'Narrator') : t('Figur', 'Character')),
        voice: VOICES[voice].p, language: lang,
      })
      cid = r?.id ?? null
    }
    const inPicture = cid && characterOn && (chosenDraft || path.photo) ? [cid] : []
    const faceRef = path.photo && refAsset ? [refAsset.id] : characterOn && chosenDraft ? [chosenDraft] : []
    // Was das gewählte Videomodell nicht kann, wird nicht verlangt (sonst bricht die Szene mit einer Meldung ab)
    const lips = p.models.video?.lipsync !== false
    const loop = path.photo && p.models.video?.loop !== false
    const ids: string[] = []
    let start = 0
    let firstVoice: string | null = null
    for (const [i, s] of scenes.entries()) {
      const r = await cmd(pid, 'scene.add', {
        lane: 'video', kind: 'video', model_id: p.models.video?.id ?? null,
        title: `${i + 1} ${FRAMINGS[s.framing].label}`, prompt: videoPrompt(s, i, tx, lips), start_s: start, duration_s: s.seconds,
        params: { characters: inPicture, ...(loop ? { loop: true } : {}) }, chain_from: path.chain && i > 0 ? ids[i - 1] : null,
      })
      ids.push(r.id)
      if (path.lines !== 'none' && s.line.trim()) {
        const words = s.line.trim().split(/\s+/).length
        const v = await cmd(pid, 'scene.add', {
          lane: 'voice', model_id: p.models.speech?.id ?? null, title: t(`Satz ${i + 1}`, `Line ${i + 1}`),
          prompt: s.line.trim(), start_s: start + (lineMode === 'narration' ? 0.3 : 0.2),
          duration_s: Math.min(s.seconds, 0.6 + words / 2.4), params: cid ? { character: cid } : {},
        })
        if (lineMode === 'lipsync' && lips) await cmd(pid, 'scene.update', { id: r.id, params: { audio_from: v.id } })
        firstVoice = firstVoice ?? v.id
      }
      start += s.seconds
    }
    // Alle Sätze in derselben Stimme: der erste gibt sie vor (dieselbe Beschreibung klingt je Seed anders)
    if (cid && firstVoice && lines.length > 1) await cmd(pid, 'character.update', { id: cid, voice_from: firstVoice })
    if (music) {
      await cmd(pid, 'scene.add', {
        lane: 'music', model_id: p.models.music?.id ?? null, title: t('Musik', 'Music'),
        prompt: musicPrompt, start_s: 0, duration_s: totalSeconds + 0.5,
      })
    }
    // Startbilder: je Szene zwei zum Auswählen (bei einer durchgehenden Einstellung nur für den Anfang)
    const items: BoardItem[] = []
    for (const [i, s] of scenes.entries()) {
      if (path.chain && i > 0) {
        items.push({ sceneId: ids[i], job: null, variants: [], chosen: null, error: null })
        continue
      }
      const job = await api.generateImage({
        prompt: startPrompt(s, i, tx), model_id: p.models.image?.id ?? null, width: p.width, height: p.height, batch_size: 2,
        reference_asset_ids: faceRef, upsample_prompt: false, project_id: pid,
      })
      items.push({ sceneId: ids[i], job: job.id, variants: [], chosen: null, error: null })
    }
    setBoard(items)
    setStage(null)
    items.forEach((it, i) => {
      if (!it.job) return
      waitJob(it.job).then(async (variants) => {
        setBoard((b) => b.map((x, k) => (k === i ? { ...x, variants, chosen: variants[0]?.id ?? null } : x)))
        if (variants[0]) await cmd(pid, 'scene.update', { id: it.sceneId, params: { image_asset_id: variants[0].id } })
      }).catch((e) => setBoard((b) => b.map((x, k) => (k === i ? { ...x, error: String(e?.message ?? e) } : x))))
    })
  })

  const pick = async (i: number, assetId: string) => {
    const pid = pidRef.current
    if (!pid) return
    setBoard((b) => b.map((x, k) => (k === i ? { ...x, chosen: assetId } : x)))
    await cmd(pid, 'scene.update', { id: board[i].sceneId, params: { image_asset_id: assetId } }).catch(() => {})
  }

  const boardReady = board.length > 0 && board.every((x) => !x.job || x.variants.length > 0 || x.error)

  const generateVideos = () => run('videos', async () => {
    const pid = pidRef.current
    if (!pid) return
    await api.studioGenerate(pid)
    onDone()
  })

  // ------------------------------------------------------------------------------------------- Prüfen und Weiter
  const canNext = (): boolean => {
    if (step === 'idea') return idea.trim().length > 0
    if (step === 'character') return path.photo ? !!refAsset && look.trim().length > 0 : !characterOn || !!chosenDraft
    if (step === 'scenes') return scenes.every((s) => s.action.trim().length > 0)
    return true
  }
  const next = () => setStep(steps[Math.min(steps.length - 1, at + 1)])
  const back = () => setStep(steps[Math.max(0, at - 1)])
  const planStep = (key: string) => plan?.steps.find((x) => x.key === key)

  const setScene = (i: number, patch: Partial<SceneDraft>) => setScenes((list) => list.map((s, k) => (k === i ? { ...s, ...patch } : s)))

  /** Was ein gewähltes Videomodell für diesen Weg nicht kann (nur bei einer eigenen Wahl, die beste kann alles) */
  const videoLacks = (m: WizardModel): string[] => [
    ...(!m.sound ? [t('Ohne Ton: Geräusche fehlen, Stimme und Musik bleiben.', 'No sound: no sound effects, voice and music stay.')] : []),
    ...(lineMode === 'lipsync' && lines.length && !m.lipsync ? [t('Die Lippen folgen den Sätzen nicht.', 'The lips do not follow the lines.')] : []),
    ...(path.photo && !m.loop ? [t('Ohne Schleife hält es das Gesicht weniger sicher.', 'Without a loop the face is held less reliably.')] : []),
  ]

  /** Zeile unter „Modelle“: Aufgabe, Modell (zur Wahl, wenn es mehrere gibt; die beste ist vorgewählt), Zeit */
  const modelRow = (label: string, role: WizardRole, key: string | null, opts: { select?: boolean; extra?: string } = {}) => {
    const st = key ? planStep(key) : undefined
    const m = plan?.models[role] ?? null
    const list = plan?.options?.[role] ?? []
    const f = m ? fetches[m.id] : undefined
    return (
      <tr>
        <td>{label}</td>
        <td>
          {opts.select && list.length > 1 ? (
            <select value={m?.id ?? ''} onChange={(e) => setChoice((c) => ({ ...c, [role]: e.target.value }))}>
              {list.map((o) => (
                <option key={o.id} value={o.id}>
                  {o.name}{o.id === plan?.best[role] ? t(' (empfohlen)', ' (recommended)') : ''}{o.installed ? '' : t(` – nicht geladen, ${gbText(o.size_gb)}`, ` – not downloaded, ${gbText(o.size_gb)}`)}
                </option>
              ))}
            </select>
          ) : m ? m.name : t('kein Modell', 'no model')}
          {m && !m.installed && (
            <div className={f?.error ? 'warn-text small' : 'muted small'}>
              {f?.error ? f.error : f ? t(`lädt … ${Math.round(f.progress * 100)} %`, `downloading … ${Math.round(f.progress * 100)} %`)
                : t(`noch nicht geladen (${gbText(m.size_gb)})`, `not downloaded yet (${gbText(m.size_gb)})`)}
            </div>
          )}
          {m && !m.commercial_ok && <div className="warn-text small">{t('Lizenz: nicht für kommerzielle Nutzung', 'License: not for commercial use')}</div>}
          {opts.select && role === 'video' && m && videoLacks(m).map((x) => <div key={x} className="warn-text small">{x}</div>)}
          {opts.extra && <div className="muted small">{opts.extra}</div>}
        </td>
        <td className="wz-time">{st?.seconds != null ? fmtDuration(st.seconds) : '–'}
          {st && <div className="muted small">{{
            history: t('gemessen bei dir', 'measured here'), estimate: t('geschätzt', 'estimated'),
            rough: t('grob geschätzt', 'rough estimate'), unknown: t('keine Messung', 'not measured'),
          }[st.source]}</div>}
        </td>
      </tr>
    )
  }

  /** Fehlen gewählte Modelle, fragt der Assistent, ob er sie laden soll; danach zeigt er den Fortschritt */
  const fetchBox = (roles: WizardRole[], why: string) => {
    const list = missing(roles)
    if (!list.length) return null
    const open = list.filter((m) => !fetches[m.id] || fetches[m.id].error)
    const gb = open.reduce((n, m) => n + (m.size_gb || 0), 0)
    return (
      <div className="wz-fetch">
        <p className="small"><strong>{why}</strong></p>
        <ul>
          {list.map((m) => {
            const f = fetches[m.id]
            return (
              <li key={m.id} className="small">
                {ROLE_LABEL[roles.find((r) => plan?.models[r]?.id === m.id) ?? 'image']}: {m.name} ({gbText(m.size_gb)})
                {f && !f.error && <span className="muted"> · {f.done ? '✓' : t(`lädt … ${Math.round(f.progress * 100)} %`, `downloading … ${Math.round(f.progress * 100)} %`)}</span>}
                {f?.error && <span className="warn-text"> · {f.error}</span>}
                {m.gated.length > 0 && !f?.done && (
                  <div className="muted">
                    {t('Gesperrtes Repo: vorher auf Hugging Face die Lizenz annehmen und unter „Modelle“ einen Token hinterlegen. ', 'Gated repo: first accept the license on Hugging Face and store a token under "Models". ')}
                    <a href={hfGuideUrl()} target="_blank" rel="noreferrer">{t('Anleitung', 'Guide')}</a>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
        {open.length > 0 && (
          <button className="btn small primary" onClick={() => fetchModels(open.map((m) => m.id))}>
            {t(`Ja, jetzt laden (${gbText(gb)})`, `Yes, download now (${gbText(gb)})`)}
          </button>
        )}
      </div>
    )
  }

  return (
    <div className="wz-layer" onPointerDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div className="wz" role="dialog" aria-label={t('Assistent', 'Assistant')}>
        <div className="wz-head">
          <strong>✨ {t('Assistent', 'Assistant')}</strong>
          <ol className="wz-steps">
            {steps.map((s, i) => (
              <li key={s} className={i === at ? 'now' : i < at ? 'done' : ''}>{STEP_LABEL[s]}</li>
            ))}
          </ol>
          <button className="btn small ghost" onClick={onClose} title={t('Schließen; alles Angelegte bleibt im Studio', 'Close; everything created stays in the Studio')}>✕</button>
        </div>
        <p className="wz-help">{step !== 'character' ? STEP_HELP[step] : path.photo ? FACE_HELP : path.character === 'required' ? STEP_HELP.character : CAST_HELP}</p>

        <div className="wz-body">
          {step === 'path' && (
            <div className="wz-cards">
              {PATHS.map((p) => (
                <button key={p.id} className={`wz-card${p.id === pathId ? ' sel' : ''}`} onClick={() => choosePath(p.id)}>
                  <span className="wz-card-icon">{p.icon}</span>
                  <strong>{p.title}</strong>
                  <span className="small">{p.text}</span>
                  <span className="muted small">{t(`${p.scenes().length} Szenen · ≈ ${p.scenes().reduce((n, s) => n + s.seconds, 0)} s`, `${p.scenes().length} scenes · ≈ ${p.scenes().reduce((n, s) => n + s.seconds, 0)} s`)}</span>
                </button>
              ))}
            </div>
          )}

          {step === 'idea' && (
            <div className="wz-form">
              <label className="wz-field">
                <span>{t('Worum geht es? Ein, zwei Sätze reichen.', 'What is it about? One or two sentences are enough.')}</span>
                <textarea rows={2} value={idea} onChange={(e) => setIdea(e.target.value)}
                  placeholder={path.idea ?? t('z. B. Ein müder Hase zieht eine alte, fast leere Batterie durch die Dunkelheit.', 'e.g. A tired rabbit drags an old, almost empty battery through the dark.')} />
              </label>
              <label className="wz-field">
                <span>{t('Wo spielt es? (gilt für alle Szenen)', 'Where does it take place? (for all scenes)')}</span>
                <input value={place} onChange={(e) => setPlace(e.target.value)}
                  placeholder={t('z. B. ein diffuser schwarzer Raum, nur eine dünne weiße Linie am Boden', 'e.g. a diffuse black void with a thin white line on the floor')} />
              </label>
              <div className="wz-field">
                <span>{t('Stil', 'Style')}</span>
                <div className="wz-chips">
                  {(Object.keys(STYLES) as StyleId[]).map((k) => (
                    <button key={k} className={`wz-chip${style === k ? ' sel' : ''}`} onClick={() => setStyle(k)}>{STYLES[k].label}</button>
                  ))}
                </div>
              </div>
              <div className="wz-field">
                <span>{t('Stimmung (Licht und Musik)', 'Mood (light and music)')}</span>
                <div className="wz-chips">
                  {(Object.keys(MOODS) as MoodId[]).map((k) => (
                    <button key={k} className={`wz-chip${mood === k ? ' sel' : ''}`} onClick={() => setMood(k)}>{MOODS[k].label}</button>
                  ))}
                </div>
              </div>
              <div className="wz-field">
                <span>{t('Format', 'Format')}</span>
                <div className="wz-chips">
                  <button className={`wz-chip${!portrait ? ' sel' : ''}`} onClick={() => setPortrait(false)}>{t('Quer 16:9 (YouTube)', 'Landscape 16:9 (YouTube)')}</button>
                  <button className={`wz-chip${portrait ? ' sel' : ''}`} onClick={() => setPortrait(true)}>{t('Hochkant 9:16 (Shorts)', 'Portrait 9:16 (Shorts)')}</button>
                </div>
              </div>
            </div>
          )}

          {step === 'character' && (
            <div className="wz-form">
              {path.character !== 'required' && (
                <div className="wz-chips">
                  <button className={`wz-chip wz-opt${characterOn ? ' sel' : ''}`} onClick={() => setCast(true)}>
                    <strong>{t('Mit Figur', 'With a character')}</strong>
                    <span className="muted small">{t('Eine Hauptfigur, die in jeder Szene gleich aussieht', 'A main character who looks the same in every scene')}</span>
                  </button>
                  <button className={`wz-chip wz-opt${!characterOn ? ' sel' : ''}`} onClick={() => setCast(false)}>
                    <strong>{t('Ohne Figur', 'Without a character')}</strong>
                    <span className="muted small">{t('Orte, Dinge, Natur: Die Szenen zeigen, was du beschreibst', 'Places, things, nature: the scenes show what you describe')}</span>
                  </button>
                </div>
              )}
              {!characterOn && (
                <p className="muted small">
                  {t('Ohne Figur gibt es keine Entwürfe: Die Startbilder entstehen direkt aus deinen Szenen. Kommen Menschen oder Tiere vor, nenn sie in der Szene; sie sehen dann von Szene zu Szene etwas anders aus.',
                    'Without a character there are no drafts: the start images are made straight from your scenes. If people or animals appear, name them in the scene; they will then look a little different from scene to scene.')}
                  {path.lines === 'lipsync' ? ' ' + t('Sätze spricht ein Sprecher aus dem Off.', 'Lines are spoken by a narrator off screen.') : ''}
                </p>
              )}
              {path.photo && (
                <>
                  <div className="wz-grid2">
                    <label className="wz-field">
                      <span>{t('Name (freiwillig)', 'Name (optional)')}</span>
                      <input value={charName} onChange={(e) => setCharName(e.target.value)} placeholder={t('z. B. Kapitän Lena', 'e.g. Captain Lena')} />
                    </label>
                    <div className="wz-field">
                      <span>{t('Porträtfoto', 'Portrait photo')}</span>
                      <div className="wz-chips">
                        <button className="wz-chip" disabled={!!busy} onClick={() => fileInput.current?.click()}>
                          {busy === 'upload' ? t('Lädt …', 'Uploading …') : refAsset ? t('✓ Foto geladen, anderes wählen', '✓ Photo loaded, choose another') : t('Foto wählen …', 'Choose a photo …')}
                        </button>
                      </div>
                      <input ref={fileInput} type="file" accept="image/*" hidden onChange={(e) => { uploadRef(e.target.files?.[0]); e.target.value = '' }} />
                    </div>
                  </div>
                  {refAsset && (
                    <div className="wz-photo"><img src={refAsset.thumb_url || refAsset.url} alt="" /></div>
                  )}
                  <label className="wz-field">
                    <span>{t('Wer soll die Person sein? Rolle und Kleidung', 'Who should the person be? Role and clothes')}</span>
                    <textarea rows={2} value={look} onChange={(e) => setLook(e.target.value)}
                      placeholder={t('z. B. eine Kapitänin in dunkelblauer Uniform mit weißer Mütze', 'e.g. a ship captain in a dark blue uniform with a white cap')} />
                  </label>
                </>
              )}
              {characterOn && !path.photo && (
                <>
                  <div className="wz-grid2">
                    <label className="wz-field">
                      <span>{t('Name', 'Name')}</span>
                      <input value={charName} onChange={(e) => setCharName(e.target.value)} placeholder={t('z. B. Somi', 'e.g. Somi')} />
                    </label>
                    <div className="wz-field">
                      <span>{t('Eigene Vorlage (freiwillig)', 'Your own template (optional)')}</span>
                      <div className="wz-chips">
                        <button className="wz-chip" disabled={!!busy} onClick={() => fileInput.current?.click()}>
                          {refAsset ? t('✓ Vorlage geladen', '✓ Template loaded') : t('Skizze oder Foto …', 'Sketch or photo …')}
                        </button>
                        {refAsset && <button className="wz-chip" onClick={() => setRefAsset(null)}>{t('ohne Vorlage', 'no template')}</button>}
                      </div>
                      <input ref={fileInput} type="file" accept="image/*" hidden onChange={(e) => { uploadRef(e.target.files?.[0]); e.target.value = '' }} />
                    </div>
                  </div>
                  <label className="wz-field">
                    <span>{t('Wie sieht sie oder er aus?', 'What does the character look like?')}</span>
                    <textarea rows={2} value={look} onChange={(e) => setLook(e.target.value)}
                      placeholder={t('z. B. ein kleiner weißer Hase mit langen Ohren, müden Augen und hängenden Schultern', 'e.g. a small white rabbit with long ears, tired eyes and slumped shoulders')} />
                  </label>
                  <p className="muted small">
                    {refAsset
                      ? t('Mit Vorlage bleibt der Entwurf nah an deinem Bild. Für eine ganz neue Figur ohne Vorlage beschreiben.', 'With a template the draft stays close to your picture. For a completely new character, describe it without one.')
                      : t('Tipp: Gib der Figur ein, zwei Erkennungszeichen (eine Farbe, ein Kleidungsstück). Dann erkennt man sie in jeder Szene.', 'Tip: give the character one or two distinctive marks (a colour, a piece of clothing). Then it is recognizable in every scene.')}
                  </p>
                  {fetchBox(['image'], t('Für die Entwürfe fehlt noch das Bildmodell. Soll ich es laden?', 'The image model for the drafts is not downloaded yet. Shall I download it?'))}
                  <div className="wz-actions-left">
                    <button className="btn small primary" disabled={!!busy || (!look.trim() && !refAsset) || missing(['image']).length > 0} onClick={makeDrafts}>
                      {busy === 'drafts' ? t('Entwürfe entstehen …', 'Making drafts …') : drafts.length ? t('Neue Entwürfe', 'New drafts') : t('4 Entwürfe erzeugen', 'Make 4 drafts')}
                    </button>
                    {planStep('character')?.seconds != null && !drafts.length && <span className="muted small">{fmtDuration(planStep('character')!.seconds!)}</span>}
                  </div>
                  {drafts.length > 0 && (
                    <div className="wz-pick wz-pick-4">
                      {drafts.map((a) => (
                        <button key={a.id} className={`wz-pick-item${a.id === chosenDraft ? ' sel' : ''}`} onClick={() => setChosenDraft(a.id)}>
                          <img src={a.thumb_url || a.url} alt="" />
                        </button>
                      ))}
                    </div>
                  )}
                </>
              )}
            </div>
          )}

          {step === 'scenes' && (
            <div className="wz-form">
              <div className="wz-field">
                <span>{path.chain ? t('Wie viele Teile?', 'How many parts?') : t('Wie viele Szenen?', 'How many scenes?')}</span>
                <div className="wz-chips">
                  {path.counts.map((n, k) => {
                    const list = resizeScenes(scenes, n, path, characterOn)
                    const est = estimateFor(list)
                    return (
                      <button key={n} className={`wz-chip wz-count${scenes.length === n ? ' sel' : ''}`} onClick={() => { setOwnCount(null); setCount(n) }}>
                        <span><strong>{countLabel(n)}</strong> · {COUNT_TAGS[k]}</span>
                        <span className="muted small">{t(`${list.reduce((x, s) => x + s.seconds, 0)} s Film`, `${list.reduce((x, s) => x + s.seconds, 0)} s of film`)}{est != null ? ` · ${fmtDuration(est)}` : ''}</span>
                      </button>
                    )
                  })}
                  <label className={`wz-chip wz-count wz-count-own${path.counts.includes(scenes.length) ? '' : ' sel'}`}>
                    <strong>{t('Eigene Anzahl', 'Custom number')}</strong>
                    <input type="number" min={1} max={MAX_SCENES} value={ownCount ?? String(scenes.length)}
                      onChange={(e) => {
                        setOwnCount(e.target.value)
                        const n = Number(e.target.value)
                        if (Number.isInteger(n) && n >= 1 && n <= MAX_SCENES) setCount(n)
                      }}
                      onBlur={() => setOwnCount(null)} title={t(`1 bis ${MAX_SCENES}`, `1 to ${MAX_SCENES}`)} />
                  </label>
                </div>
                {countNote && <span className="warn-text small">{countNote}</span>}
              </div>
              {scenes.map((s, i) => (
                <div key={i} className="wz-scene">
                  <div className="wz-scene-head">
                    <strong>{path.chain ? t(`Teil ${i + 1}`, `Part ${i + 1}`) : t(`Szene ${i + 1}`, `Scene ${i + 1}`)}</strong>
                    {!(path.chain && i > 0) && (
                      <select value={s.framing} onChange={(e) => setScene(i, { framing: e.target.value as FramingId })} title={t('Bildausschnitt', 'Framing')}>
                        {(Object.keys(FRAMINGS) as FramingId[]).map((k) => <option key={k} value={k}>{FRAMINGS[k].label}</option>)}
                      </select>
                    )}
                    <select value={s.seconds} onChange={(e) => setScene(i, { seconds: Number(e.target.value) })} title={t('Länge', 'Length')}>
                      {[4, 5, 6].map((n) => <option key={n} value={n}>{n} s</option>)}
                    </select>
                    {scenes.length > 1 && (
                      <button className="btn small ghost" onClick={() => { setScenes((l) => l.filter((_, k) => k !== i)); setCountNote(null) }}
                        title={path.chain ? t('Teil entfernen', 'Remove part') : t('Szene entfernen', 'Remove scene')}>✕</button>
                    )}
                  </div>
                  <textarea rows={2} value={s.action} onChange={(e) => setScene(i, { action: e.target.value })} placeholder={s.hint} />
                  {path.lines !== 'none' && (
                    <input value={s.line} onChange={(e) => setScene(i, { line: e.target.value })}
                      placeholder={path.lines === 'narration' ? t('Sprecher sagt …', 'The narrator says …')
                        : lineMode === 'narration' ? t('Sprecher aus dem Off sagt (freiwillig) …', 'Narrator off screen says (optional) …')
                          : t('Sagt (freiwillig) …', 'Says (optional) …')} />
                  )}
                </div>
              ))}
              {scenes.length < MAX_SCENES && (
                <button className="btn small ghost" onClick={() => {
                  setScenes((l) => [...l, path.chain ? sc('wide', 5, t('Weiter: Was passiert dann?', 'Next: what happens then?')) : sc('medium', 5, t('Was passiert dann?', 'What happens then?'))])
                  setCountNote(null)
                }}>+ {path.chain ? t('Teil', 'Part') : t('Szene', 'Scene')}</button>
              )}
              <p className="muted small">
                {t(`Zusammen ${totalSeconds} s Film`, `${totalSeconds} s of film in total`)}
                {estimateFor(scenes) != null ? t(`, Rechenzeit ${fmtDuration(estimateFor(scenes)!)}.`, `, computing time ${fmtDuration(estimateFor(scenes)!)}.`) : '.'}
                {lineMode === 'lipsync' ? ' ' + (lipsOk
                  ? t('Ein Satz wird gesprochen, die Lippen folgen ihm. Kurze Sätze wirken am besten.', 'A line is spoken and the lips follow it. Short lines work best.')
                  : t('Die Sätze liegen auf der Spur „Stimme“; das gewählte Videomodell bewegt die Lippen nicht dazu.', 'The lines go on the "Voice" track; the chosen video model does not move the lips to them.'))
                  : path.lines === 'lipsync' ? ' ' + t('Ohne Figur spricht ein Sprecher aus dem Off.', 'Without a character a narrator speaks off screen.') : ''}
              </p>
            </div>
          )}

          {step === 'sound' && (
            <div className="wz-form">
              {lines.length > 0 ? (
                <>
                  <div className="wz-field">
                    <span>{t('Stimme', 'Voice')}</span>
                    <div className="wz-chips">
                      {(Object.keys(VOICES) as VoiceId[]).map((k) => (
                        <button key={k} className={`wz-chip${voice === k ? ' sel' : ''}`} onClick={() => setVoice(k)}>{VOICES[k].label}</button>
                      ))}
                    </div>
                  </div>
                  <label className="wz-field wz-narrow">
                    <span>{t('Sprache der Sätze', 'Language of the lines')}</span>
                    <select value={lang} onChange={(e) => setLang(e.target.value as SpeechLanguage)}>
                      {SPEECH_LANGUAGES.filter((l) => l.id !== 'auto').map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                    </select>
                  </label>
                  <p className="muted small">{t('Der erste Satz gibt die Stimme vor, alle weiteren klingen genauso. Hör sie dir im Studio an; gefällt sie nicht, erzeuge den ersten Satz neu.', 'The first line sets the voice, all others sound the same. Listen to it in the Studio; if you don\'t like it, generate the first line again.')}</p>
                </>
              ) : (
                <p className="muted small">{t('Keine gesprochenen Sätze: Das Video bekommt die Geräusche aus dem Videomodell und, wenn du willst, Musik.', 'No spoken lines: the video gets its sounds from the video model and, if you like, music.')}</p>
              )}
              <label className="st-check">
                <input type="checkbox" checked={music} onChange={(e) => setMusic(e.target.checked)} />
                <span>{t('Musik', 'Music')}</span>
              </label>
              {music && (
                <>
                  <div className="wz-field">
                    <span>{t('Vorschläge (die Stimmung hat einen vorgewählt)', 'Suggestions (the mood picked one)')}</span>
                    <div className="wz-chips">
                      {MUSIC.map((x) => (
                        <button key={x.id} title={x.title ?? x.p} className={`wz-chip${musicText === null && musicId === x.id ? ' sel' : ''}`}
                          onClick={() => { setMusicPick(x.id); setMusicText(null) }}>{x.label}</button>
                      ))}
                    </div>
                  </div>
                  <label className="wz-field">
                    <span>{t('Musik-Prompt: ändern oder selbst schreiben', 'Music prompt: change it or write your own')}</span>
                    <textarea rows={3} value={musicText ?? musicPreset.p} onChange={(e) => setMusicText(e.target.value)} />
                  </label>
                  <p className="muted small">{t('Am besten ein Satz: Gattung, Instrumente, Schlagwerk und Stimmung, am Ende das Tempo („BPM: 90.“). Nur Instrumentalmusik, ohne Gesang. Deutscher Text wird vor dem Erzeugen ins Englische übertragen.',
                    'Best as one sentence: genre, instruments, percussion and mood, the tempo at the end ("BPM: 90."). Instrumental music only, no singing.')}</p>
                </>
              )}
            </div>
          )}

          {step === 'models' && (
            <div className="wz-form">
              {plan ? (
                <>
                  <p className="small">
                    {plan.device.name
                      ? t(`Deine Karte: ${plan.device.name}${plan.device.vram_gb ? `, ${Math.round(plan.device.vram_gb)} GB` : ''}.`, `Your card: ${plan.device.name}${plan.device.vram_gb ? `, ${Math.round(plan.device.vram_gb)} GB` : ''}.`)
                      : t('Keine Grafikkarte erkannt.', 'No graphics card detected.')}{' '}
                    {plan.device.speed && plan.device.catalog_id !== 'rtx-5060-ti-16'
                      ? t(`Im Vergleich zur gemessenen RTX 5060 Ti etwa ${plan.device.speed.toLocaleString('de-DE')}-mal so schnell.`, `About ${plan.device.speed}× the speed of the measured RTX 5060 Ti.`)
                      : ''}
                  </p>
                  {fetchBox(usedRoles, t('Noch nicht geladen. Soll ich die Modelle jetzt laden?', 'Not downloaded yet. Shall I download the models now?'))}
                  <table className="wz-table">
                    <thead><tr><th>{t('Aufgabe', 'Task')}</th><th>{t('Modell', 'Model')}</th><th>{t('Zeit', 'Time')}</th></tr></thead>
                    <tbody>
                      {characterOn && !drafts.length && modelRow(t('Figur', 'Character'), 'image', 'character', { select: true })}
                      {modelRow(t(`Startbilder (${startScenes} × 2)`, `Start images (${startScenes} × 2)`), 'image', 'start_images', { select: !(characterOn && !drafts.length) })}
                      {lines.length > 0 && modelRow(t(`Stimme (${lines.length} ${lines.length === 1 ? 'Satz' : 'Sätze'})`, `Voice (${lines.length} ${lines.length === 1 ? 'line' : 'lines'})`), 'speech', 'voice', { select: true })}
                      {music && modelRow(t('Musik', 'Music'), 'music', 'music', { select: true })}
                      {modelRow(t(`Videos (${totalSeconds} s)`, `Videos (${totalSeconds} s)`), 'video', 'videos', {
                        select: true,
                        extra: plan.quality === 'dfr' ? t('höchste Qualität (DFR), Bild in voller Größe', 'best quality (DFR), full-size picture') : `${plan.width} × ${plan.height}`,
                      })}
                    </tbody>
                    <tfoot><tr><td colSpan={2}>{t('Zusammen', 'Total')}</td><td className="wz-time">{fmtDuration(plan.total_seconds)}{plan.notes.includes('time_unknown') ? ' +' : ''}</td></tr></tfoot>
                  </table>
                  {plan.notes.includes('time_unknown') && <p className="muted small">{t('Für ein gewähltes Modell gibt es noch keine Messung; seine Zeit fehlt in der Summe.', 'There is no measurement for a chosen model yet; its time is missing from the total.')}</p>}
                  <label className="st-check">
                    <input type="checkbox" checked={best} onChange={(e) => setBest(e.target.checked)} />
                    <span>{t('Beste Qualität (empfohlen, dauert länger)', 'Best quality (recommended, takes longer)')}</span>
                  </label>
                  {plan.notes.includes('vram_video') && <p className="warn-text small">{t('Das Videomodell passt nicht ganz in den Grafikspeicher und wird je Schritt nachgeladen; das kostet Zeit.', 'The video model does not quite fit into the graphics memory and is reloaded for each step; that costs time.')}</p>}
                  {plan.notes.includes('unknown_gpu') && <p className="muted small">{t('Deine Karte steht noch nicht im Hardware-Katalog; die Zeiten gelten für eine RTX 5060 Ti.', 'Your card is not in the hardware catalog yet; the times are for an RTX 5060 Ti.')}</p>}
                  {plan.notes.includes('amd_rough') && <p className="muted small">{t('Radeon: grobe Schätzung, gemessen ist bisher nur NVIDIA.', 'Radeon: rough estimate, so far only NVIDIA has been measured.')}</p>}
                  <p className="muted small">{t('Die Zeiten sind Schätzungen; nach den ersten Läufen rechnet der Assistent mit deinen echten Zeiten.', 'The times are estimates; after your first runs the assistant uses your real times.')}</p>
                </>
              ) : (
                <p className="muted small">{t('Lädt …', 'Loading …')}</p>
              )}
            </div>
          )}

          {step === 'create' && (
            <div className="wz-form">
              {board.length === 0 ? (
                <>
                  <p className="small">
                    {t(`${path.title}: ${scenes.length} Szenen, ${totalSeconds} s, ${portrait ? 'hochkant' : 'quer'}, ${STYLES[style].label}${characterOn && chosenDraft ? ', mit Figur' : !characterOn ? ', ohne Figur' : ''}${lines.length ? `, ${lines.length} ${lines.length === 1 ? 'Satz' : 'Sätze'}` : ''}${music ? ', mit Musik' : ''}.`,
                      `${path.title}: ${scenes.length} scenes, ${totalSeconds} s, ${portrait ? 'portrait' : 'landscape'}, ${STYLES[style].label}${characterOn && chosenDraft ? ', with a character' : !characterOn ? ', without a character' : ''}${lines.length ? `, ${lines.length} ${lines.length === 1 ? 'line' : 'lines'}` : ''}${music ? ', with music' : ''}.`)}
                  </p>
                  {fetchBox(usedRoles, t('Noch nicht geladen. Soll ich die Modelle jetzt laden?', 'Not downloaded yet. Shall I download the models now?'))}
                  <div className="wz-actions-left">
                    <button className="btn primary" disabled={!!busy || missing(['image']).length > 0} onClick={build}>
                      {busy === 'build' ? t('Wird angelegt …', 'Setting up …') : t('Projekt anlegen und Startbilder erzeugen', 'Set up the project and make the start images')}
                    </button>
                    {busy === 'build' && stage && <span className="muted small">{stage}</span>}
                    {planStep('start_images')?.seconds != null && <span className="muted small">{fmtDuration(planStep('start_images')!.seconds!)}</span>}
                  </div>
                </>
              ) : (
                <>
                  <div className="wz-board">
                    {board.map((it, i) => (
                      <div key={it.sceneId} className="wz-board-row">
                        <span className="wz-board-num">{i + 1}</span>
                        {!it.job ? (
                          <span className="muted small">{t('setzt die Szene davor nahtlos fort', 'continues the scene before seamlessly')}</span>
                        ) : it.error ? (
                          <span className="warn-text small">{it.error}</span>
                        ) : it.variants.length === 0 ? (
                          <span className="muted small">{t('Startbild entsteht …', 'Making the start image …')}</span>
                        ) : (
                          <div className="wz-pick wz-pick-2">
                            {it.variants.map((a) => (
                              <button key={a.id} className={`wz-pick-item${a.id === it.chosen ? ' sel' : ''}`} onClick={() => pick(i, a.id)}>
                                <img src={a.thumb_url || a.url} alt="" />
                              </button>
                            ))}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                  {fetchBox(usedRoles, t('Für die Videos fehlt noch etwas. Soll ich es jetzt laden?', 'Something is still missing for the videos. Shall I download it now?'))}
                  <div className="wz-actions-left">
                    <button className="btn primary" disabled={!!busy || !boardReady || missing(usedRoles).length > 0} onClick={generateVideos}>
                      {boardReady ? t('Videos erzeugen', 'Generate the videos') : t('Warte auf die Startbilder …', 'Waiting for the start images …')}
                    </button>
                    {planStep('videos')?.seconds != null && <span className="muted small">{fmtDuration((planStep('videos')?.seconds ?? 0) + (planStep('voice')?.seconds ?? 0) + (planStep('music')?.seconds ?? 0))}</span>}
                  </div>
                </>
              )}
            </div>
          )}
          {error && <p className="warn-text small">{error}</p>}
        </div>

        <div className="wz-foot">
          <button className="btn small ghost" disabled={at === 0 || !!busy || (step === 'create' && board.length > 0)} onClick={back}>← {t('Zurück', 'Back')}</button>
          <span className="muted small">{t(`Schritt ${at + 1} von ${steps.length}`, `Step ${at + 1} of ${steps.length}`)}</span>
          {step !== 'create' && (
            <button className="btn small primary" disabled={!canNext() || !!busy} onClick={next}>{t('Weiter', 'Next')} →</button>
          )}
        </div>
      </div>
    </div>
  )
}

const ASK_KEY = 'nvai-wizard-ask'

/** Ob beim Start und bei neuen Projekten gefragt wird (Kästchen „Nicht mehr anzeigen“) */
export function wizardAskWanted(): boolean {
  try {
    return localStorage.getItem(ASK_KEY) !== 'never'
  } catch {
    return true
  }
}

/** Frage beim Start des Studios und bei einem neuen Projekt: geführt werden oder nicht */
export function WizardAsk({ onStart, onClose }: { onStart: () => void; onClose: (never: boolean) => void }) {
  const [never, setNever] = useState(false)
  const close = (start: boolean) => {
    if (never) {
      try {
        localStorage.setItem(ASK_KEY, 'never')
      } catch {
        /* nicht speicherbar: dann fragt es beim nächsten Start wieder */
      }
    }
    if (start) onStart()
    onClose(never)
  }
  return (
    <div className="st-dialog-layer">
      <div className="st-dialog st-dialog-small wz-ask" role="dialog" aria-label={t('Assistent', 'Assistant')}>
        <h3>✨ {t('Soll ich dich durch dein Video führen?', 'Shall I guide you through your video?')}</h3>
        <p className="small">{t('In sieben kurzen Schritten: Idee, Szenen und, wenn du willst, eine Figur wählst du; Modelle und Prompts schlägt der Assistent vor.', 'In seven short steps: you choose the idea, the scenes and, if you like, a character; the assistant suggests the models and prompts.')}</p>
        <label className="st-check">
          <input type="checkbox" checked={never} onChange={(e) => setNever(e.target.checked)} />
          <span>{t('Nicht mehr anzeigen', 'Don\'t show again')}</span>
        </label>
        <div className="st-dialog-choices st-dialog-actions">
          <button className="btn small ghost" onClick={() => close(false)}>{t('Nein, danke', 'No, thanks')}</button>
          <button className="btn small primary" onClick={() => close(true)}>{t('Ja, führ mich', 'Yes, guide me')}</button>
        </div>
      </div>
    </div>
  )
}

/** Kurze Hinweise nach dem Assistenten: was jetzt im Studio passiert und wie es weitergeht */
export function WizardCoach({ running, onClose }: { running: number; onClose: () => void }) {
  return (
    <div className="wz-coach" role="status">
      <div className="wz-coach-head">
        <strong>✨ {t('So geht es weiter', 'What happens next')}</strong>
        <button className="btn small ghost" onClick={onClose}>✕</button>
      </div>
      <ol>
        <li className={running ? 'now' : 'done'}>{running
          ? t(`Die Szenen entstehen (${running} offen). Den Fortschritt siehst du oben neben „Übernehmen“.`, `The scenes are being made (${running} left). You see the progress at the top next to "Conform".`)
          : t('Die Szenen sind fertig.', 'The scenes are done.')}</li>
        <li>{t('Takes prüfen: eine Szene anklicken, rechts unter „Takes“. Gefällt einer nicht: „Neu erzeugen“.', 'Check the takes: click a scene, see "Takes" on the right. Don\'t like one: "Generate again".')}</li>
        <li>{t('„Übernehmen ↓“ legt alles in den Schnitt.', '"Conform ↓" puts everything into the edit.')}</li>
        <li>{t('Format wählen und „Exportieren“.', 'Pick a format and "Export".')}</li>
      </ol>
    </div>
  )
}
