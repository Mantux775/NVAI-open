"""Prompt ausbauen jenseits von Bildern: Video, Soundeffekt, Musik und 3D.

Fuer Bilder nimmt NV-AI BFLs eigene Systemprompts des FLUX-3-Upsamplers
(flux3_prompt.py). Fuer die uebrigen Ziele laeuft dasselbe Sprachmodell (Qwen3.5-9B,
von BFL feinjustiert, Apache-2.0) mit den Systemprompts unten. Sie sind NV-AIs eigene
und folgen den Prompt-Regeln der jeweiligen Modelle: Wan und LTX wollen eine fliessende
Beschreibung mit Bewegung und Kamera, LTX-2.5 zusaetzlich den Ton; Stable Audio den
Klang statt Musik; ACE-Step kommagetrennte Genre-Tags; die 3D-Modelle ein einzelnes
Objekt ohne Boden und Schatten, weil das Bild das Mesh vollstaendig bestimmt.
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

SYSTEM: dict[str, str] = {
    "video": (
        "You turn a short idea into a prompt for a text-to-video model (Wan, LTX-Video). "
        "Write one flowing paragraph of 60 to 120 words in the present tense. Start with "
        "the visual style and the shot (for example: cinematic wide shot, handheld close-up). "
        "Then describe the subject with its appearance, and above all its motion: what moves, "
        "in which direction, how fast, what happens from beginning to end of the short clip. "
        "Describe one camera movement explicitly (slow push in, pan left, static camera, "
        "orbit). End with the setting, the lighting and the time of day. Describe a single "
        "continuous shot of about four seconds, no cuts. " + _COMMON
    ),
    "video_sound": (
        "You turn a short idea into a prompt for a video model that creates picture and "
        "sound together (LTX-2). Write one flowing paragraph of 80 to 150 words in the "
        "present tense. Start with the visual style and the shot. Describe the subject, its "
        "motion from beginning to end, one explicit camera movement, the setting, the "
        "lighting and the time of day. Finish with one or two sentences about what can be "
        "heard: the sounds of the actions, the ambience, music only if the idea asks for it, "
        "and spoken words in quotation marks only if the idea contains dialogue. Describe a "
        "single continuous shot of about four seconds, no cuts. " + _COMMON
    ),
    "video_start": (
        "The image shows the first frame of a short video. You turn the user's short idea "
        "into a motion prompt for an image-to-video model. Write 40 to 80 words in the "
        "present tense. Do not describe the image again: name only what moves, how and in "
        "which direction, how the motion develops over about four seconds, and one camera "
        "movement (or a static camera). Keep the people, objects, style and lighting of the "
        "image unchanged; do not add new objects. " + _COMMON
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
        "Write 50 to 100 words: the object type, its shape and proportions, the materials, "
        "colours and their condition, and how its parts are built and attached. Show the "
        "object closed and at rest in its simplest complete state, with nothing inside, on "
        "or around it, unless the idea asks for it. Keep a base "
        "or plinth only if it belongs to the object. Then state: the whole object is centered "
        "and fully visible in a three-quarter view, it floats in empty space against a plain "
        "flat light grey background, even diffuse shadowless studio light, no floor, no table, "
        "no cast shadow, no other objects, no text. " + _COMMON
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
    "video_start": ("Write 40 to 80 words that describe only the motion and the camera. Do not "
                    "mention clothing, background or anything that stays the same."),
}


def user_text(target: str, prompt: str) -> str:
    return f"Idea: {prompt.strip()}\n{FORMAT.get(target, 'Output the prompt.')}"


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
    if target == "music":
        out = " ".join(out.split())
    return out
