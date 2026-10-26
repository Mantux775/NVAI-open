"""Prompt ausbauen jenseits von Bildern: Video, Soundeffekt, Musik und 3D.

Fuer Bilder nimmt NVAI-open BFLs eigene Systemprompts des FLUX-3-Upsamplers
(flux3_prompt.py). Fuer die uebrigen Ziele laeuft dasselbe Sprachmodell (Qwen3.5-9B,
von BFL feinjustiert, Apache-2.0) mit den Systemprompts unten. Sie sind NVAI-opens eigene
und folgen den Prompt-Regeln der jeweiligen Modelle: Wan und LTX wollen eine fliessende
Beschreibung mit Bewegung und Kamera, LTX-2.5 zusaetzlich den Ton; Stable Audio den
Klang statt Musik; Stable Audio 3 einen Satz mit BPM; die 3D-Modelle ein einzelnes
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

TARGETS = ("image", "video", "video_sound", "video_multishot", "video_start", "sfx", "music", "music_sa3", "3d")
# „music“ war das Ziel für ACE-Step (am 26.10.2026 entfernt); es bleibt für ältere Clients und meint jetzt Stable Audio 3
ALIASES = {"music": "music_sa3"}

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
    # Nach Lightricks' Prompt-Anleitung fuer LTX-2.5 (docs.ltx.io): Einstellung, Ort und Licht,
    # Handlung mit Verben, Figuren mit koerperlichen Merkmalen, Kamera, zuletzt der Ton; Tempo
    # ausschreiben, weil die Laengenvorhersage sich an der beschriebenen Handlung orientiert.
    "video_sound": (
        "You turn a short idea into a prompt for a video model that creates picture and "
        "sound together (LTX-2.5). Write one flowing paragraph of 50 to 90 words in the "
        "present tense, in this order: the shot and visual style, the setting and lighting, "
        "the action from beginning to end with a verb in every sentence, the people with "
        "visible physical cues instead of named emotions, one explicit camera movement, and "
        "last one sentence about what can be heard: the sounds of the actions, the ambience, "
        "music only if the idea asks for it, and spoken words in quotation marks only if the "
        "idea contains dialogue. Describe a single continuous shot, no cuts. " + _COMMON + _NO_INVENT
    ),
    "video_multishot": (
        "You turn a short idea into a multi-shot prompt for a video model that creates picture "
        "and sound together (LTX-2.5) and cuts between shots within one clip. Write one "
        "chronological paragraph of 90 to 160 words in the present tense with two to four shots, "
        "for example a wide establishing shot, then a medium shot, then a close-up. Open with "
        "the visual style. At every cut name the transition in words (\"A hard cut transitions "
        "to ...\", \"The view cuts to a close-up of ...\"), re-establish the new shot with its "
        "scale, angle and who or what is in frame, call recurring people and objects by the same "
        "words, and state what happens to the sound across the cut (\"the music continues\", "
        "\"only the wind remains\"). Spoken words go in quotation marks. No shot list, no "
        "numbering. " + _COMMON + _NO_INVENT
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
    # Stable Audio 3 ist auf einen fliessenden Satz plus "BPM: X. Length: Y seconds" trainiert
    # (Systemprompt der ComfyUI-Vorlage audio_stable_audio_3_medium). Die Laenge haengt der
    # Graph selbst an, passend zur eingestellten Dauer (workflows, stable_audio_3).
    "music_sa3": (
        "You turn a short idea into a prompt for an instrumental music model (Stable Audio 3). "
        "The model only hears, it does not see: describe only what is audible (instruments, "
        "sounds, rhythm, mood), never people, places, colours, light, weather or scenery. "
        "Write one natural, fluid sentence: start with the genre or style and a few adjectives, "
        "name the main instruments, then supporting layers such as pads, drones or effects, then "
        "rhythm and percussion, and weave the mood and energy into the sentence. The model cannot "
        "sing words: if the idea asks for a choir or voices, describe them as wordless (humming, "
        "chanting invented syllables). End with 'BPM: <number>.' Example: Dark cinematic march "
        "with low brass and trombones, a wordless male choir chanting in unison, booming war drums "
        "and snare rolls creating menacing, unstoppable power. BPM: 100. " + _COMMON
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
    "music_sa3": ("Output one sentence of 25 to 50 words about what can be heard only, then "
                  "'BPM: <number>.' and nothing else."),
    "video_start": ("Write 25 to 50 words that describe only the motion and the camera. Do not "
                    "mention clothing, background or anything that stays the same."),
    "image": "Write 3 to 5 sentences, 40 to 80 words in total, no more.",
    "video": "Write one paragraph of 40 to 70 words, no more.",
    "video_sound": "Write one paragraph of 50 to 90 words, no more.",
    "video_multishot": ("Write one paragraph of 90 to 160 words with two to four shots; describe every "
                        "cut in words, no list."),
    "3d": "Write 40 to 70 words, no more.",
}


def user_text(target: str, prompt: str) -> str:
    return f"Idea: {prompt.strip()}\n{FORMAT.get(target, 'Output the prompt.')}"


# Hoechstlaenge in Woertern nach dem Kuerzen. Ton und Musik bleiben ungekuerzt, sie sind kurz.
BUDGET = {"image": 75, "video": 70, "video_sound": 90, "video_multishot": 170, "video_start": 50, "3d": 80}
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


# Gemessen 23.10.: trotz Anweisung 4 Saetze und ~90 Woerter, darunter "dark infantry silhouettes
# carrying torn flags", "smoke-darkened storm clouds", "amber window lights" -- Bildbeschreibung,
# die ein Musikmodell nur verwirrt. Satzteile (zwischen Kommas) mit solchen Woertern fliegen raus,
# wenn darin nichts Hoerbares steht; ganze Saetze zu streichen nahm auch Trommeln und Chor mit.
_VISUAL = re.compile(r"\b(silhouettes?|sky|skies|clouds?|lights?|lit|window\w*|roofs?|reflect\w*|"
                     r"colou?rs?|blue|amber|navy|grey|gray|smoke\w*|flags?|background|foreground|"
                     r"shadows?|scenery|landscape|horizon|lighthouse|buildings?|streets?)\b", re.I)
_AUDIBLE = re.compile(r"\b(drums?|percussion|snares?|cymbals?|timpani|brass|horns?|trombones?|trumpets?|"
                      r"tubas?|strings?|violins?|cellos?|bass\w*|piano|synth\w*|pads?|drones?|choir|"
                      r"voices?|vocals?|chant\w*|humm\w*|guitars?|organ|bells?|chimes?|beats?|rhythm\w*|"
                      r"tempo|melod\w*|harmon\w*|chords?|sounds?|tones?|notes?)\b", re.I)
_BPM = re.compile(r"\bBPM:\s*(\d{2,3})\b\.?", re.I)
SA3_WORDS = 70


def music_sa3(text: str) -> str:
    """Hoerbare Saetze (hoechstens SA3_WORDS Woerter), danach "BPM: N."."""
    flat = " ".join(text.split())
    m = _BPM.search(flat)
    body = _BPM.sub("", flat).strip()
    body = re.sub(r"(?i)[\s.]*Length:\s*\d+\s*(?:seconds|s)\b\.?", "", body).strip()
    keep, used = [], 0
    for sent in (x for x in _SENTENCE.split(body) if x):
        parts = [x for x in sent.rstrip(" .").split(",")
                 if not (_VISUAL.search(x) and not _AUDIBLE.search(x))]
        x = ",".join(parts).strip(" ,")
        if not x:
            continue
        if keep and used + len(x.split()) > SA3_WORDS:
            break
        keep.append(x)
        used += len(x.split())
    out = ". ".join(keep) + "."
    return f"{out} BPM: {m.group(1)}." if m else out


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
    if target == "music_sa3":
        return music_sa3(out)
    if target == "sfx":
        # Schreibt das Modell doch Prosa, haengt es die Tag-Zeile oft in Anfuehrungszeichen an.
        tags = [m for m in re.findall(r'["“]([^"”]{20,})["”]', out) if m.count(",") >= 3]
        if tags:
            out = tags[-1]
        out = " ".join(out.split())
    return shorten(target, out)
