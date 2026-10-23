"""Prompt ausbauen jenseits von Bildern: Video, Soundeffekt, Musik und 3D.

Fuer Bilder nimmt NV-AI BFLs eigene Systemprompts des FLUX-3-Upsamplers
(flux3_prompt.py). Fuer die uebrigen Ziele laeuft dasselbe Sprachmodell (Qwen3.5-9B,
von BFL feinjustiert, Apache-2.0) mit den Systemprompts unten. Sie sind NV-AIs eigene
und folgen den Prompt-Regeln der jeweiligen Modelle: Wan und LTX wollen eine fliessende
Beschreibung mit Bewegung und Kamera, LTX-2.5 zusaetzlich den Ton; Stable Audio den
Klang statt Musik; ACE-Step kommagetrennte Genre-Tags; die 3D-Modelle ein einzelnes
Objekt ohne Boden und Schatten, weil das Bild das Mesh vollstaendig bestimmt.

Auch Bilder ohne Referenzbild und Boxen laufen seit 0.5.4 hier durch ("image"): BFLs
Systemprompt schreibt 100-350 Woerter und erfindet dabei viel, was Nutzer wieder loeschen.
Die Laenge ist dem feinjustierten Modell antrainiert: Wortgrenzen im Systemprompt, Beispiele
und selbst eine geaenderte Zahl in BFLs eigenem Systemprompt ("Typical length is 100 to 350
words") liess es gemessen unbeeindruckt (130-260 Woerter). shorten() kuerzt deshalb danach,
satzweise und nach Wichtigkeit.
"""
from __future__ import annotations

import re

TARGETS = ("image", "video", "video_sound", "video_start", "sfx", "music", "3d")

_COMMON = (
    "Output only the finished prompt in English, no heading, no quotation marks, no "
    "explanation, no lists. Keep every detail the user gave; where the user's words are "
    "not English, translate them. Invent only what is needed to make the result concrete, "
    "and nothing that contradicts the user's request."
)
# Nur fuer Bild, Video und 3D: bei Ton und Musik verleitete der Satz das Modell zu Prosa.
_NO_INVENT = (" Do not invent extra people, objects, text, clothing details or story that the "
              "idea does not imply.")

SYSTEM: dict[str, str] = {
    "image": (
        "You turn a short idea into a prompt for a text-to-image model that reads full "
        "English sentences (Qwen-Image, FLUX). Write 3 to 5 sentences, 40 to 80 words in "
        "total. Start with the medium and style (for example: studio photograph, oil "
        "painting, 3D render); keep the user's style if given, otherwise pick the one that "
        "fits. Then the subject with material, colour and condition, and how its parts are "
        "attached where that matters. End with the lighting and the background. Text that "
        "should appear in the image stays word for word in quotation marks. " + _COMMON + _NO_INVENT
    ),
    "video": (
        "You turn a short idea into a prompt for a text-to-video model (Wan, LTX-Video). "
        "Write one flowing paragraph of 40 to 70 words in the present tense. Start with "
        "the visual style and the shot (for example: cinematic wide shot, handheld close-up). "
        "Then describe the subject with its appearance, and above all its motion: what moves, "
        "in which direction, how fast, what happens from beginning to end of the short clip. "
        "Describe one camera movement explicitly (slow push in, pan left, static camera, "
        "orbit). End with the setting, the lighting and the time of day. Describe a single "
        "continuous shot of about four seconds, no cuts. " + _COMMON + _NO_INVENT
    ),
    "video_sound": (
        "You turn a short idea into a prompt for a video model that creates picture and "
        "sound together (LTX-2). Write one flowing paragraph of 50 to 90 words in the "
        "present tense. Start with the visual style and the shot. Describe the subject, its "
        "motion from beginning to end, one explicit camera movement, the setting, the "
        "lighting and the time of day. Finish with one sentence about what can be "
        "heard: the sounds of the actions, the ambience, music only if the idea asks for it, "
        "and spoken words in quotation marks only if the idea contains dialogue. Describe a "
        "single continuous shot of about four seconds, no cuts. " + _COMMON + _NO_INVENT
    ),
    "video_start": (
        "The image shows the first frame of a short video. You turn the user's short idea "
        "into a motion prompt for an image-to-video model. Write 25 to 50 words in the "
        "present tense. Do not describe the image again: name only what moves, how and in "
        "which direction, how the motion develops over about four seconds, and one camera "
        "movement (or a static camera). Keep the people, objects, style and lighting of the "
        "image unchanged; do not add new objects. " + _COMMON + _NO_INVENT
    ),
    "sfx": (
        "You turn a short idea into a prompt for a sound-effect model (Stable Audio Open). "
        "The model only hears, it does not see: describe what is audible, never what is "
        "visible. Name the sound source, the action, the material, how the sound develops "
        "(single hit, repeated, loop, rising), the acoustic space and the microphone distance. "
        "Write no sentences: output one line of 5 to 10 short comma-separated phrases, at "
        "most 35 words. Example: heavy wooden door creaks open slowly, rusty iron hinges, "
        "low groaning creak, stone dungeon reverb, close mic, no music. End with 'no music' "
        "unless the idea asks for music. " + _COMMON
    ),
    "music": (
        "You turn a short idea into tags for a music model (ACE-Step). Output a single line "
        "of 8 to 16 comma-separated lowercase tags, no sentences: genre and subgenre, the "
        "lead instruments, mood, energy, tempo feel, era or region if it fits, and the vocal "
        "type (male vocals, female vocals, choir) or 'instrumental' if the idea has no "
        "singing. Example: epic orchestral, choir, war drums, brass, cinematic, minor key, "
        "slow build, dark, heroic, instrumental. " + _COMMON
    ),
    "3d": (
        "You turn a short idea into an image prompt whose result is turned into a 3D model. "
        "The image alone decides the mesh, so it must show exactly one complete object. "
        "Write 40 to 70 words: the object type, its shape and proportions, the materials, "
        "colours and their condition, and how its parts are built and attached. Show the "
        "object closed and at rest in its simplest complete state, with nothing inside, on "
        "or around it, unless the idea asks for it. Keep a base "
        "or plinth only if it belongs to the object. Then state: the whole object is centered "
        "and fully visible in a three-quarter view, it floats in empty space against a plain "
        "flat light grey background, even diffuse shadowless studio light, no floor, no table, "
        "no cast shadow, no other objects, no text. " + _COMMON + _NO_INVENT
    ),
}

# Zum Ausbau eines Videos mit Startbild liest der Upsampler das Bild mit.
WITH_IMAGE = {"video_start"}


# Das feinjustierte Modell neigt zu langen Bildbeschreibungen; die Form steht deshalb
# auch in der Nutzernachricht, dort wirkt sie staerker als im Systemprompt.
FORMAT = {
    "sfx": ("Output one line of 6 to 12 comma-separated lowercase sound tags, no sentences, "
            "only what can be heard, ending with 'no music'."),
    "music": "Output one line of 8 to 16 comma-separated lowercase tags, no sentences.",
    "video_start": ("Write 25 to 50 words that describe only the motion and the camera. Do not "
                    "mention clothing, background or anything that stays the same."),
    "image": "Write 3 to 5 sentences, 40 to 80 words in total, no more.",
    "video": "Write one paragraph of 40 to 70 words, no more.",
    "video_sound": "Write one paragraph of 50 to 90 words, no more.",
    "3d": "Write 40 to 70 words, no more.",
}


def user_text(target: str, prompt: str) -> str:
    return f"Idea: {prompt.strip()}\n{FORMAT.get(target, 'Output the prompt.')}"


# Hoechstlaenge in Woertern nach dem Kuerzen. Ton und Musik bleiben ungekuerzt, sie sind kurz.
BUDGET = {"image": 75, "video": 70, "video_sound": 90, "video_start": 50, "3d": 80}
_SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"“])")
_SOUND = re.compile(r"\b(sounds?|hear|heard|audible|audio|noise|creak\w*|rattl\w*|thud\w*|echo\w*|"
                    r"music|voices?|says?|whisper\w*|hum\w*|roar\w*|clang\w*)\b", re.I)


def shorten(target: str, text: str) -> str:
    """Kuerzt auf BUDGET Woerter, ohne einen Satz zu zerschneiden.

    Immer bleiben: der erste Satz (Stil, Motiv), Saetze mit woertlichem Text in
    Anfuehrungszeichen und der Schlusssatz -- dorthin legen die Systemprompts Licht und
    Hintergrund, bei 3D "kein Boden, kein Schatten". Bei Video mit Ton statt des
    Schlusssatzes der letzte Satz ueber den Ton. Mit den uebrigen wird der Reihe nach
    aufgefuellt; gestrichen werden so vor allem erfundene Nebendetails aus der Mitte.
    """
    budget = BUDGET.get(target)
    sents = [x for x in _SENTENCE.split(text.strip()) if x]
    if not budget or sum(len(x.split()) for x in sents) <= budget:
        return text.strip()
    keep = {0} | {i for i, x in enumerate(sents) if '"' in x or "“" in x}
    sound = [i for i, x in enumerate(sents) if _SOUND.search(x)] if target == "video_sound" else []
    keep.add(sound[-1] if sound else len(sents) - 1)
    used = sum(len(sents[i].split()) for i in keep)
    for i, x in enumerate(sents):
        if i not in keep and used + len(x.split()) <= budget:
            keep.add(i)
            used += len(x.split())
    return " ".join(sents[i] for i in sorted(keep))


def clean(target: str, text: str) -> str:
    """Anfuehrungszeichen und eine vorangestellte Ueberschrift entfernen, die das Modell
    trotz Anweisung gelegentlich schreibt."""
    out = text.strip()
    for prefix in ("Prompt:", "Tags:", "Output:"):
        if out.lower().startswith(prefix.lower()):
            out = out[len(prefix):].strip()
    if len(out) > 1 and out[0] == out[-1] and out[0] in "\"'“”":
        out = out[1:-1].strip()
    # "Create a picture-and-sound video of a castle ..." -> "A castle ..." (gemessen bei video_sound)
    m = re.match(r"(?i)(create|generate|make|write)\s+(a|an)\s+[\w\s-]{0,40}?\b(video|clip|prompt)\s+(of|showing)\s+", out)
    if m and target.startswith("video"):
        rest = out[m.end():]
        out = rest[:1].upper() + rest[1:]
    if target in ("sfx", "music"):
        # Schreibt das Modell doch Prosa, haengt es die Tag-Zeile oft in Anfuehrungszeichen an.
        tags = [m for m in re.findall(r'["“]([^"”]{20,})["”]', out) if m.count(",") >= 3]
        if tags:
            out = tags[-1]
        out = " ".join(out.split())
    return shorten(target, out)
