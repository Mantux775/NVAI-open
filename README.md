# NVAI-open

Images, videos with sound, music and 3D models, made on your own computer. Free, private, no account, no subscription, no cloud.

<p align="center"><img src="docs/images/photo-to-video-captain.gif" width="420" alt="A generated photo becomes a ship captain in a storm who says his line"></p>
<p align="center"><sub>Made with NVAI-open: a generated photo becomes a ship captain who speaks in a storm. <a href="docs/videos/photo-to-video-captain.mp4">With sound</a></sub></p>

## Download

| | |
|---|---|
| Windows 10/11, NVIDIA or AMD Radeon | [NVAI-open-Setup-0.5.12.exe](https://github.com/Mantux775/NVAI-open/releases/download/v0.5.12/NVAI-open-Setup-0.5.12.exe) |
| macOS 15+ on Apple Silicon, signed and notarized | [NVAI-open-0.4.8.dmg](https://github.com/Mantux775/NVAI-open/releases/download/v0.5.12/NVAI-open-0.4.8.dmg) |

Install, open, download a model under "Models", generate. The setup brings everything else along. [Installation details](docs/INSTALL.md) · [All releases](https://github.com/Mantux775/NVAI-open/releases)

## What's new? / Was gibt's Neues?

October 2026: NVAI-open 0.5.13 for Windows ([release notes](https://github.com/Mantux775/NVAI-open/releases/tag/v0.5.13)), the Mac stays at 0.4.8

- **Studio:** a full-screen editor for whole videos, with scenes and prompts, markers, real cuts and an export with your graphics card's encoder ([guide](docs/STUDIO.md))
- **Lossless copy of every AI video:** the Studio edits and exports from it, so only the export compresses (42.3 instead of 37.7 dB PSNR for a YouTube export)
- **Export:** YouTube 1080p at 24 Mbit/s, a lossless master (MKV) and ProRes 4444, with a preview in the browser
- **ACE-Step removed:** music comes from Stable Audio 3 Medium (instrumental, up to 5 minutes)

Neu: das **Studio**, ein Schnittplatz über den ganzen Bildschirm für ganze Videos mit Szenen und Prompts, Markern, echten Schnitten und einem Export mit dem Encoder deiner Grafikkarte ([Anleitung](docs/de/STUDIO.md)); von jedem KI-Video eine **verlustfreie Kopie**, aus der das Studio schneidet und exportiert (42,3 statt 37,7 dB PSNR bei einem YouTube-Export); **Export** als YouTube 1080p mit 24 Mbit/s, verlustfreier Master (MKV) und ProRes 4444, mit Vorschau im Browser; **ACE-Step** ist raus, Musik kommt von Stable Audio 3 Medium (instrumental, bis 5 Minuten). 0.5.12 brachte AMD Radeon und auf dem Mac Z-Image Turbo und Video ([Notizen](https://github.com/Mantux775/NVAI-open/releases/tag/v0.5.12)).

[English](#english) · [Video](#video) · [Deutsch](#deutsch)

---

## English

### Hi

I built this app because I needed it myself: images, sounds and 3D models for my game projects, without paying per picture or sending everything to the cloud. Now I'm sharing it. Everything runs on your own graphics card, and nothing leaves your computer.

It is tested on my own hardware: Windows with an RTX 5060 Ti (16 GB) and a Mac mini M1 (8 GB). Feedback is very welcome as an [issue](https://github.com/Mantux775/NVAI-open/issues), easiest with "Report a problem" in the app, which attaches an anonymized report. I have a full-time job, so answers can take a while. All apps are in English and German.

### What you can do

- **Images:** FLUX 3, Qwen-Image-2512, Krea 2, MOSS-Image and many more. Edit with reference images, fill in or extend a picture.
- **Video with sound:** LTX-2.5 makes the picture and the sound in one pass, speech included, up to 20 s and 1080p.
- **Studio:** compose a whole video from scenes, cut it and export it with your graphics card's encoder.
- **Music and sounds:** instrumental music up to 5 minutes, sound effects.
- **3D models:** from an image to a textured model for Unity, Blender or any engine.
- **Old photos:** remove scratches, tears and water stains, colorize, sharpen.
- **A few words are enough:** "Expand prompt" writes the full description for you.
- **Claude Code:** Claude creates your assets while it works on your project.
- **No filter of its own:** uncensored models are one click away. You are responsible for what you make.
- **Windows and Mac**, NVIDIA and AMD Radeon, and an add-on for the photo editor PhotoCraft.

### From a portrait to a video

![A photo, the start image from FLUX 3 and two frames of the video from LTX-2.5](docs/images/photo-to-video-captain.jpg)

1. **Generate → Image:** create a portrait, or use a photo of someone who agreed to it.
2. **Generate → Video:** pick the portrait as the start image.
3. **Person from a photo:** describe the role. FLUX 3 keeps the face and makes four start images; pick the one that looks most alike.
4. **Prompt:** describe what moves, what the camera does and what the person says. LTX-2.5 makes the video with speech and sound.

Step by step with screenshots: [docs/PHOTO_TO_VIDEO.md](docs/PHOTO_TO_VIDEO.md)

### Studio: whole videos from scenes

A full-screen editor for whole videos. At the top you compose: scenes with a prompt on lanes for picture, voice, music and sound, plus markers that say what goes where. At the bottom you edit the real clips: cut, trim, dissolve, set the volume. "Generate scenes" makes every clip, still image and piece of music with your local models, "Conform" puts the takes into the edit, and the export uses the video encoder of your graphics card at YouTube loudness.

![The Studio: media on the left, the monitor in the middle, the project settings on the right, the composition and the edit below](docs/images/studio.jpg)

- **Markers:** a chain marker makes a clip start with the last frame of the one before it, so two shots join seamlessly; transition markers add dissolves; an AI task marker leaves Claude a note in the timeline.
- **Media:** everything you generated, as a compact list with search. Click a file to play it in the monitor, drag it onto a track, delete it right there.
- **High-quality 1080p:** video scenes run in the best LTX-2.5 quality, every AI video is also kept losslessly, and only the export compresses: measured 42.3 instead of 37.7 dB PSNR for a YouTube export.
- **Export:** YouTube 1080p and 4K, Shorts, AV1, a lossless master (MKV) or ProRes 4444 for other editing software.
- **Claude Code** builds the whole video for you over MCP while you watch it in the Studio.

Step by step: [docs/STUDIO.md](docs/STUDIO.md)

### Video with sound

LTX-2.5 by Lightricks makes picture and sound together: speech, footsteps, wind, music. Start from a text, a start image or a start and an end image, make a seamless loop, let the picture follow a sound you give it, or extend a clip you already have.

![A knight says "Hold the wall. They come at dawn.", four frames of a clip with sound](docs/images/ltx25-knight.jpg)

Under the video model, "Recommended LoRAs" adds styles with one click, such as painted fantasy or anime:

![The same fox without a LoRA and with three style LoRAs](docs/images/ltx25-loras.jpg)

All ways and measured times: [docs/MODELS.md](docs/MODELS.md#new-in-058)

### 3D: from an image to a model

Generate an image of an object and turn it into a GLB model. TRELLIS.2 paints the textures too, TripoSG builds the shape only.

<p align="center">
  <img src="docs/images/image-to-3d-source.jpg" width="400" alt="Weathered wooden crate with iron handles, generated with FLUX 3">
  <img src="docs/images/image-to-3d-turntable.gif" width="400" alt="The same crate as a textured 3D model, turning">
</p>

Lettering does not survive the mesh stage on its own. "Take the front from the image" puts the source image onto the front of the mesh:

![A direction sign: source image, TripoSG mesh, with the front from the image, and its back](docs/images/front-projection.jpg)

### Images

Four models are recommended, each for something else. **Krea 2** looks the most like a photo and is the fastest, about 18 s per image. **MOSS-Image** is strongest at lettering and layout, about 57 s, under Apache-2.0. **Qwen-Image-2512** gets details and construction right, about 100 s, also Apache-2.0. **FLUX 3 Image Klein** takes about 28 s and edits a picture while keeping the rest intact. Same prompt and seed, one image each:

![An astronaut with a mission patch: Qwen-Image-2512, FLUX 3, Krea 2 and MOSS-Image, same prompt and seed](docs/images/compare-astronaut.jpg)

The patch should read "ARES VII": MOSS-Image wrote it the cleanest, Krea 2 wrote "ARES VIII". In the full comparison, only Qwen-Image-2512 set a pocket watch to ten past ten as asked.

Krea 2 also takes an image as a style template: the lighthouse keeps its content and takes on the watercolor or the woodcut.

![Two templates made with FLUX 3, Krea 2 without and with a style template](docs/images/krea2-style-reference.jpg)

![Crate with stencilled lettering: FLUX 3 and Qwen-Image-2512](docs/images/compare-crate.jpg)

MOSS-Image writes posters and signs letter-perfect. With its 50 steps the crate's rope handles pass through drilled holes; with the 25 of ComfyUI's template they hung without a hold in one of three images:

![MOSS-Image: a poster with lettering, a crate with 25 and with 50 steps](docs/images/moss-image-en.jpg)

Editing with FLUX 3: "replace the rope handles with iron handles, keep everything else unchanged".

![Editing with a reference image in FLUX 3](docs/images/flux3-edit.jpg)

LoRAs teach a model a style, for example a more photographic look:

![Portrait without LoRA, with Boreal and with Lenovo UltraReal](docs/images/lora-realism.jpg)

The four recommended models side by side, with prompts and times: [docs/MODEL_COMPARISON.md](docs/MODEL_COMPARISON.md). More comparisons, prompt tips and test results: [docs/MODELS.md](docs/MODELS.md). All images in this README were generated with NVAI-open.

### Edit pictures: extend and fill

Make a picture wider or taller, and NVAI-open paints the new border to match. Or mark an area and fill it: remove things, add new ones. The rest of the picture stays as it was.

![Outpainting all around: original, NVAI-open 0.5.4 and 0.5.5](docs/images/outpaint-before-after.jpg)

![Fill with FLUX 3: crates removed, a seagull added](docs/images/fill-flux3.jpg)

### Restore old photos

Scratches, dust, tears, stains and fading go, the photo gets color if you like, and SeedVR2 sharpens and enlarges it. "Thorough" redraws the whole photo, which suits overall aging such as water stains and fading; "Gentle" only replaces the damaged spots and keeps sharpness and faces exactly as they are, which suits dust, scratches and tears on an otherwise good photo. "Automatic" (the default) lets the image model look at the photo and choose; it picked the better one on 20 of 21 test photos. Colorizing takes only the color from FLUX 3, brightness and detail stay the photo's. Known colors in the hints make it more accurate. NVAI-open for Mac (0.4.7) does all of it natively on Apple Silicon: "Automatic" with Qwen3.5 4B, sharpening with SeedVR2 3B (on a Mac with 8 GB, doubling a 1 MP photo takes about 9 minutes). Details: [docs/MODELS.md](docs/MODELS.md#new-in-0511).

![An aged test photo, restored and colorized by NVAI-open, next to the color original it was aged from](docs/images/restore-car.jpg)

### Expand prompt

Type a few words, click "Expand prompt", and NVAI-open writes the full description: setting, materials, light, what happens. Read it, delete what you don't want, generate. Works for images, video, sounds, music and 3D.

![Qwen-Image-2512 with "a medieval blacksmith" and with the expanded prompt](docs/images/expand-prompt.jpg)

### Tips

Every tab in NVAI-open has a **Recommended settings** box with what was measured. The most important ones:

- **Images:** choose the size by the silhouette (standing figure 832 × 1216, vehicle 1216 × 832), write full English sentences with the style first, and make 4 images at once to pick from.
- **Krea 2:** name the framing ("medium shot from the waist up, his whole head inside the frame"); without it the head was cut off in 3 of 3 test images.
- **MOSS-Image:** describe the finished picture and put the text in quotation marks with position and typeface; leave it on 50 steps.
- **Video:** name loud sounds explicitly, sounds described as soft come out almost inaudible. For a fixed shot write "Static camera, a locked-off medium shot". A spoken line takes about 2 words per second: 15 words ran past the end of a 6 s shot, 11 fit; leave gestures out (even "a single quick wave" lasted 2.5 s). Write timing out ("For the first two seconds nothing happens: …"). Leave "Lossless copy for editing" on if you cut the clips later; it costs about 32 MB per second at 1080p.
- **3D:** one object on a plain background, without floor or shadow; both would end up in the mesh.
- **FLUX 3 and LTX-2.5:** accept the license on Hugging Face and store a read token under "Models"; the model card shows whether access works. Step by step: [docs/HUGGINGFACE.md](docs/HUGGINGFACE.md)
- **Old photos:** leave it on "Automatic"; it chooses "Thorough" for overall aging (water stains, crack networks) and "Gentle" for separate damage on an otherwise good photo (dust, scratches, tears). Put known colors into the hints ("his suit is dark brown") and compare the two variants at full size.

The same list with the measurements, written for Claude Code: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md#recommended-settings-at-a-glance)

### Claude Code: your assets on request

NVAI-open comes with an MCP server. Register it once:

```
claude mcp add --scope user nvai -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

Then just ask: "Make a weathered wooden barrel as a 3D model and put it into Assets/Generated/Meshes". Claude picks a model, asks before a download, generates, and copies the result into your project. Setup and all tools: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md)

### Graphics cards and uncensored models

NVAI-open picks the right model versions for your card: NVFP4 on an RTX 50, INT8 on RTX 20, 30 and 40 (on a slow connection such as a riser, NVFP4 where only that fits into the memory). With several cards it uses the strongest one. AMD Radeon works experimentally (PyTorch with ROCm 10; on a Radeon RX 9000 the FP8 and bf16 versions); testers are very welcome in [#2](https://github.com/Mantux775/NVAI-open/issues/2). Details: [docs/INSTALL.md](docs/INSTALL.md)

NVAI-open has no content filter of its own. The model list marks every model as censored, partly censored or uncensored, and uncensored ones such as Chroma, Pony and NoobAI are one click away. More, including LoRAs from Hugging Face and Civitai, under "Models" → "Search models and LoRAs". Respect the law and each model's license; the FLUX 3 license, for example, requires a review of every image before it is published. Overview: [docs/MODELS.md](docs/MODELS.md#censored-or-uncensored)

### Mac app, PhotoCraft add-on, iOS

- **Mac:** a native app for Apple Silicon with FLUX.2 Klein and Z-Image Turbo: generate, refine, fill, reference images, expand prompts, LoRAs, restore old photos, music and sounds with Stable Audio 3 (30 seconds in about 13 seconds on an M1), and short videos with LTX-Video 2B from text or a start image (2 seconds at 768 × 512 in about 95 seconds on an M1 with 8 GB).
- **[PhotoCraft](https://github.com/storytold/photocraft) add-on:** select an area in this great open-source photo editor, fill it, rework it or restore it, and the result comes back as a layer. Needs PhotoCraft 0.10.0 or newer. Thanks to the PhotoCraft developers for such a well-scriptable editor.
- **iOS (closed beta):** a 3D scanner that turns photos of real objects into models. Tell me in an issue if you would use it.

### Requirements

| | Windows | macOS |
|---|---|---|
| System | Windows 10 (2004+) or 11, 64-bit | macOS 15 or newer, Apple Silicon |
| Graphics / memory | 12 GB+ VRAM recommended (8 GB works with the INT8 models). NVIDIA: driver 580.88+. AMD Radeon: driver 26.2.2+ | 16 GB RAM or more recommended (8 GB works for small images) |
| Disk | about 10 GB for the program, plus 5 to 40 GB per model | about 1 GB for the app, plus about 10 GB for FLUX.2 Klein |
| Internet | for setup (about 3 GB) and model downloads | for model downloads |

The Windows setup is not code-signed, so Windows may show "Windows protected your PC": click "More info", then "Run anyway".

### Licenses

The code is under the [MIT License](LICENSE): do whatever you want with it. Third-party components keep their own licenses, see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt); ComfyUI (GPL-3.0) is shipped as a separate program with its full source. Models are not part of this repository, and each has its own license, shown in the model list.

### More

- [docs/INSTALL.md](docs/INSTALL.md): installing, building from source, the PhotoCraft add-on
- [docs/MODELS.md](docs/MODELS.md): the models in detail, prompt tips, test results
- [docs/PHOTO_TO_VIDEO.md](docs/PHOTO_TO_VIDEO.md): from a photo to a video, step by step
- [docs/STUDIO.md](docs/STUDIO.md): the Studio, whole videos from scenes
- [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md): using NVAI-open from Claude Code
- [photocraft-addon/](photocraft-addon/): source of the PhotoCraft add-on

---

## Video

<p align="center">
  <a href="https://www.youtube.com/shorts/e9jSTwgwnrI"><img src="docs/images/video-short.jpg" width="320" alt="YouTube Short: NVAI-open and the PhotoCraft add-on"></a>
</p>

<p align="center">NVAI-open and the PhotoCraft add-on in action, a short on YouTube.<br>
NVAI-open und das PhotoCraft-Add-on in Aktion, ein kurzes Video auf YouTube.<br>
<a href="https://www.youtube.com/shorts/e9jSTwgwnrI">youtube.com/shorts/e9jSTwgwnrI</a></p>

---

## Deutsch

### Hallo

Ich habe diese App gebaut, weil ich sie selbst brauchte: Bilder, Sounds und 3D-Modelle für meine Spieleprojekte, ohne pro Bild zu zahlen oder alles in die Cloud zu schicken. Jetzt teile ich sie. Alles rechnet auf deiner eigenen Grafikkarte, nichts verlässt deinen Rechner.

Getestet ist sie auf meiner eigenen Hardware: Windows mit RTX 5060 Ti (16 GB) und ein Mac mini M1 (8 GB). Über Feedback als [Issue](https://github.com/Mantux775/NVAI-open/issues) freue ich mich sehr, am einfachsten mit „Problem melden“ in der App, das hängt einen anonymisierten Bericht an. Ich habe einen Vollzeitjob, Antworten können also dauern. Alle Apps gibt es auf Deutsch und Englisch.

### Was geht damit?

- **Bilder:** FLUX 3, Qwen-Image-2512, Krea 2, MOSS-Image und viele weitere. Mit Referenzbildern bearbeiten, Bereiche füllen, Bilder erweitern.
- **Video mit Ton:** LTX-2.5 macht Bild und Ton in einem Durchgang, samt Sprache, bis 20 s und 1080p.
- **Studio:** ein ganzes Video aus Szenen komponieren, schneiden und mit dem Encoder der Grafikkarte exportieren.
- **Musik und Sounds:** instrumentale Musik bis 5 Minuten, Soundeffekte.
- **3D-Modelle:** aus einem Bild ein texturiertes Modell für Unity, Blender oder jede Engine.
- **Alte Fotos:** Kratzer, Risse und Wasserflecken entfernen, einfärben, schärfen.
- **Ein paar Worte reichen:** „Prompt ausbauen“ schreibt die volle Beschreibung für dich.
- **Claude Code:** Claude erzeugt deine Assets, während es an deinem Projekt arbeitet.
- **Kein eigener Filter:** unzensierte Modelle sind einen Klick entfernt. Für das, was du erzeugst, bist du selbst verantwortlich.
- **Windows und Mac**, NVIDIA und AMD Radeon, dazu ein Add-on für den Bildeditor PhotoCraft.

### Vom Porträt zum Video

![Ein Foto, das Startbild von FLUX 3 und zwei Bilder aus dem Video von LTX-2.5](docs/images/photo-to-video-captain-de.jpg)

1. **Generieren → Bild:** ein Porträt erzeugen oder das Foto eines Menschen nehmen, der damit einverstanden ist.
2. **Generieren → Video:** das Porträt als Startbild wählen.
3. **Person aus einem Foto:** die Rolle beschreiben. FLUX 3 übernimmt das Gesicht und macht vier Startbilder; das ähnlichste auswählen.
4. **Prompt:** beschreiben, was sich bewegt, was die Kamera macht und was die Person sagt. LTX-2.5 macht daraus das Video mit Sprache und Ton.

Schritt für Schritt mit Screenshots: [docs/de/FOTO_ZU_VIDEO.md](docs/de/FOTO_ZU_VIDEO.md)

### Studio: ganze Videos aus Szenen

Ein Schnittplatz über den ganzen Bildschirm für ganze Videos. Oben komponierst du: Szenen mit Prompt auf Bahnen für Bild, Sprecher, Musik und Klang, dazu Marker, die sagen, was wohin kommt. Unten schneidest du die echten Clips: schneiden, trimmen, überblenden, Lautstärke. „Szenen erzeugen“ macht alle Clips, Standbilder und Musikstücke mit deinen lokalen Modellen, „Übernehmen“ legt die Takes in den Schnitt, und der Export nutzt den Video-Encoder deiner Grafikkarte, in der Lautheit von YouTube.

![Das Studio: links das Material, in der Mitte der Monitor, rechts die Projekteinstellungen, unten Komposition und Schnitt](docs/images/studio-de.jpg)

- **Marker:** Ein Anschluss-Marker lässt einen Clip mit dem letzten Bild des vorigen beginnen, so gehen zwei Einstellungen nahtlos ineinander über; Übergang-Marker setzen Überblendungen; ein KI-Auftrag hinterlässt Claude eine Notiz in der Zeitleiste.
- **Material:** alles, was du erzeugt hast, als kompakte Liste mit Suche. Ein Klick spielt die Datei im Monitor ab, auf eine Spur gezogen wird sie zum Clip, gelöscht wird sie direkt dort.
- **Hochwertiges 1080p:** Videoszenen laufen in der höchsten Qualität von LTX-2.5, jedes KI-Video wird zusätzlich verlustfrei aufbewahrt, und komprimiert wird erst beim Export: gemessen 42,3 statt 37,7 dB PSNR bei einem YouTube-Export.
- **Export:** YouTube 1080p und 4K, Shorts, AV1, ein verlustfreier Master (MKV) oder ProRes 4444 für andere Schnittprogramme.
- **Claude Code** baut dir das ganze Video per MCP, während du im Studio zusiehst.

Schritt für Schritt: [docs/de/STUDIO.md](docs/de/STUDIO.md)

### Video mit Ton

LTX-2.5 von Lightricks macht Bild und Ton zusammen: Sprache, Schritte, Wind, Musik. Starten lässt es sich mit einem Text, einem Startbild oder einem Start- und einem Endbild; es macht nahtlose Schleifen, das Bild kann einem vorgegebenen Ton folgen, und ein vorhandener Clip lässt sich verlängern.

![Ein Ritter sagt „Hold the wall. They come at dawn.“, vier Frames eines Clips mit Ton](docs/images/ltx25-knight-de.jpg)

Unter dem Videomodell fügt „Empfohlene LoRAs“ Stile mit einem Klick hinzu, etwa gemalte Fantasy oder Anime:

![Derselbe Fuchs ohne LoRA und mit drei Stil-LoRAs](docs/images/ltx25-loras-de.jpg)

Alle Wege und gemessenen Zeiten: [docs/de/MODELLE.md](docs/de/MODELLE.md#neu-in-058)

### 3D: vom Bild zum Modell

Ein Bild eines Objekts erzeugen und daraus ein GLB-Modell machen. TRELLIS.2 malt die Texturen gleich mit, TripoSG baut nur die Form.

<p align="center">
  <img src="docs/images/image-to-3d-source.jpg" width="400" alt="Verwitterte Holzkiste mit Eisengriffen, erzeugt mit FLUX 3">
  <img src="docs/images/image-to-3d-turntable.gif" width="400" alt="Dieselbe Kiste als texturiertes 3D-Modell, drehend">
</p>

Schrift übersteht den Weg zum Mesh nicht von allein. „Vorderseite aus dem Bild übernehmen“ legt das Quellbild auf die Vorderseite des Meshes:

![Ein Wegweiser: Quellbild, Mesh von TripoSG, mit der Vorderseite aus dem Bild und von hinten](docs/images/front-projection-de.jpg)

### Bilder

Vier Modelle sind empfohlen, jedes für etwas anderes. **Krea 2** wirkt am ehesten wie ein Foto und ist am schnellsten, rund 18 s je Bild. **MOSS-Image** ist am stärksten bei Schrift und Layout, rund 57 s, unter Apache-2.0. **Qwen-Image-2512** trifft Details und Konstruktion, rund 100 s, ebenfalls Apache-2.0. **FLUX 3 Image Klein** braucht rund 28 s und bearbeitet ein Bild, ohne den Rest zu verändern. Gleicher Prompt und Seed, je ein Bild:

![Eine Astronautin mit Aufnäher: Qwen-Image-2512, FLUX 3, Krea 2 und MOSS-Image, gleicher Prompt und Seed](docs/images/compare-astronaut-de.jpg)

Auf dem Aufnäher soll „ARES VII“ stehen: MOSS-Image schrieb es am saubersten, Krea 2 schrieb „ARES VIII“. Im ganzen Vergleich stellte nur Qwen-Image-2512 eine Taschenuhr wie verlangt auf zehn nach zehn.

Krea 2 nimmt auch ein Bild als Stilvorlage: Der Leuchtturm behält seinen Inhalt und wird zum Aquarell oder zum Holzschnitt.

![Zwei Vorlagen von FLUX 3, Krea 2 ohne und mit Stilvorlage](docs/images/krea2-style-reference-de.jpg)

![Kiste mit Schablonenschrift: FLUX 3 und Qwen-Image-2512](docs/images/compare-crate.jpg)

MOSS-Image schreibt Plakate und Schilder buchstabengenau. Mit seinen 50 Schritten laufen die Seilgriffe der Kiste durch Bohrungen; mit den 25 aus ComfyUIs Vorlage hingen sie in einem von drei Bildern ohne Halt:

![MOSS-Image: Plakat mit Schrift, Kiste mit 25 und mit 50 Schritten](docs/images/moss-image-de.jpg)

Bearbeiten mit FLUX 3: „replace the rope handles with iron handles, keep everything else unchanged“.

![Bearbeiten mit Referenzbild in FLUX 3](docs/images/flux3-edit.jpg)

LoRAs bringen einem Modell einen Stil bei, zum Beispiel einen fotografischeren Look:

![Porträt ohne LoRA, mit Boreal und mit Lenovo UltraReal](docs/images/lora-realism.jpg)

Die vier empfohlenen Modelle nebeneinander, mit Prompts und Zeiten (englisch): [docs/MODEL_COMPARISON.md](docs/MODEL_COMPARISON.md). Weitere Vergleiche, Prompt-Tipps und Testergebnisse: [docs/de/MODELLE.md](docs/de/MODELLE.md). Alle Bilder in diesem README hat NVAI-open erzeugt.

### Bilder bearbeiten: erweitern und füllen

Ein Bild breiter oder höher machen, und NVAI-open malt den neuen Rand passend dazu. Oder einen Bereich markieren und füllen: Dinge entfernen, neue hinzufügen. Der Rest des Bildes bleibt, wie er war.

![Rundum erweitert: Original, NVAI-open 0.5.4 und 0.5.5](docs/images/outpaint-before-after.jpg)

![Füllen mit FLUX 3: Kisten entfernt, Möwe hinzugefügt](docs/images/fill-flux3.jpg)

### Alte Fotos restaurieren

Kratzer, Staub, Risse, Flecken und Ausbleichen verschwinden, auf Wunsch bekommt das Foto Farbe, und SeedVR2 schärft und vergrößert es. „Gründlich“ rechnet das ganze Foto neu, das passt zu flächiger Alterung wie Wasserflecken und Ausbleichen; „Schonend“ ersetzt nur die beschädigten Stellen und lässt Schärfe und Gesichter genau, wie sie waren, das passt zu Staub, Kratzern und Rissen auf einem sonst guten Foto. „Automatisch“ (Vorgabe) lässt das Bildmodell das Foto ansehen und wählen; bei 20 von 21 Testfotos traf es die bessere Art. Beim Einfärben kommt nur die Farbe von FLUX 3, Helligkeit und Detail bleiben die des Fotos. Bekannte Farben in den Hinweisen machen es genauer. NVAI-open für Mac (0.4.7) kann alles davon nativ auf Apple Silicon: „Automatisch“ mit Qwen3.5 4B, Schärfen mit SeedVR2 3B (auf einem Mac mit 8 GB dauert das Doppelte eines 1-MP-Fotos rund 9 Minuten). Mehr dazu: [docs/de/MODELLE.md](docs/de/MODELLE.md#neu-in-0511).

![Ein gealtertes Testfoto, von NVAI-open restauriert und eingefärbt, neben der Farbvorlage, aus der es gealtert wurde](docs/images/restore-car-de.jpg)

### Prompt ausbauen

Ein paar Worte eintippen, auf „Prompt ausbauen“ klicken, und NVAI-open schreibt die volle Beschreibung: Ort, Material, Licht, was passiert. Lesen, Ungewolltes streichen, generieren. Das geht für Bilder, Video, Sounds, Musik und 3D.

![Qwen-Image-2512 mit „a medieval blacksmith“ und mit ausgebautem Prompt](docs/images/expand-prompt.jpg)

### Tipps

In jedem Reiter von NVAI-open stehen unter **Empfohlene Einstellungen** die gemessenen Erfahrungen. Die wichtigsten:

- **Bilder:** das Format nach der Silhouette wählen (stehende Figur 832 × 1216, Fahrzeug 1216 × 832), ganze englische Sätze mit dem Stil vorn schreiben und 4 Bilder auf einmal zum Auswählen machen.
- **Krea 2:** den Bildausschnitt nennen („medium shot from the waist up, his whole head inside the frame“); ohne fehlte im Test in 3 von 3 Bildern der Kopf.
- **MOSS-Image:** das fertige Bild beschreiben und die Schrift in Anführungszeichen mit Ort und Schriftart angeben; bei 50 Schritten lassen.
- **Video:** laute Geräusche ausdrücklich nennen, leise beschriebene kommen fast unhörbar. Für eine feste Einstellung „Static camera, a locked-off medium shot“ schreiben. Ein gesprochener Satz braucht rund 2 Wörter je Sekunde: 15 Wörter liefen über das Ende einer 6-s-Szene hinaus, 11 passten; Gesten weglassen (selbst „a single quick wave“ dauerte 2,5 s). Zeiten ausschreiben („For the first two seconds nothing happens: …“). „Verlustfreie Kopie für den Schnitt“ anlassen, wenn du die Clips später schneidest; kostet rund 32 MB je Sekunde bei 1080p.
- **3D:** ein Objekt vor schlichtem Hintergrund, ohne Boden und Schatten; beides landet sonst im Mesh.
- **FLUX 3 und LTX-2.5:** die Lizenz auf Hugging Face annehmen und unter „Modelle“ einen Token mit Leserecht eintragen; die Modellkarte zeigt, ob der Zugriff klappt. Schritt für Schritt: [docs/de/HUGGINGFACE.md](docs/de/HUGGINGFACE.md)
- **Alte Fotos:** auf „Automatisch“ lassen; es wählt „Gründlich“ bei flächiger Alterung (Wasserflecken, Rissnetze) und „Schonend“ bei einzelnen Schäden auf einem sonst guten Foto (Staub, Kratzer, Risse). Bekannte Farben in die Hinweise („his suit is dark brown“) und die zwei Varianten in voller Größe vergleichen.

Dieselbe Liste mit den Messwerten, geschrieben für Claude Code: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md#recommended-settings-at-a-glance) (englisch)

### Claude Code: Assets auf Zuruf

NVAI-open bringt einen MCP-Server mit. Einmal eintragen:

```
claude mcp add --scope user nvai -- "<Installationsordner>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

Dann einfach sagen: „Mach ein verwittertes Holzfass als 3D-Modell und leg es nach Assets/Generated/Meshes“. Claude wählt ein Modell, fragt vor einem Download, generiert und kopiert das Ergebnis ins Projekt. Einrichtung und alle Werkzeuge: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md) (englisch)

### Grafikkarten und unzensierte Modelle

NVAI-open wählt die passenden Modellfassungen für deine Karte: NVFP4 auf einer RTX 50, INT8 auf RTX 20, 30 und 40 (an einem langsamen Anschluss wie einem Riser NVFP4, wenn nur das in den Speicher passt). Mit mehreren Karten rechnet die stärkste. AMD Radeon läuft experimentell (PyTorch mit ROCm 10; auf einer Radeon RX 9000 die FP8- und bf16-Fassungen); Tester sind in [#2](https://github.com/Mantux775/NVAI-open/issues/2) sehr willkommen. Details: [docs/de/INSTALL.md](docs/de/INSTALL.md)

NVAI-open hat keinen eigenen Inhaltsfilter. Die Modellliste kennzeichnet jedes Modell als zensiert, teilweise zensiert oder unzensiert, und unzensierte wie Chroma, Pony und NoobAI sind einen Klick entfernt. Weitere, auch LoRAs von Hugging Face und Civitai, unter „Modelle“ → „Modelle und LoRAs suchen“. Gesetze und die Lizenz des Modells gelten; die FLUX-3-Lizenz etwa verlangt, jedes Bild vor der Veröffentlichung zu prüfen. Überblick: [docs/de/MODELLE.md](docs/de/MODELLE.md#zensiert-oder-unzensiert)

### Mac-App, PhotoCraft-Add-on, iOS

- **Mac:** eine native App für Apple Silicon mit FLUX.2 Klein und Z-Image Turbo: generieren, überarbeiten, füllen, Referenzbilder, Prompt ausbauen, LoRAs, alte Fotos restaurieren, Musik und Klänge mit Stable Audio 3 (30 Sekunden in rund 13 Sekunden auf einem M1) sowie kurze Videos mit LTX-Video 2B aus Text oder einem Startbild (2 Sekunden in 768 × 512 in rund 95 Sekunden auf einem M1 mit 8 GB).
- **Add-on für [PhotoCraft](https://github.com/storytold/photocraft):** in diesem tollen Open-Source-Bildeditor einen Bereich auswählen, füllen, überarbeiten oder restaurieren, das Ergebnis kommt als Ebene zurück. Braucht PhotoCraft ab 0.10.0. Danke an die PhotoCraft-Entwickler für einen so gut steuerbaren Editor.
- **iOS (geschlossene Beta):** ein 3D-Scanner, der aus Fotos echter Gegenstände Modelle macht. Schreibt mir gern in einem Issue, wenn ihr ihn nutzen würdet.

### Voraussetzungen

| | Windows | macOS |
|---|---|---|
| System | Windows 10 (ab 2004) oder 11, 64 Bit | macOS 15 oder neuer, Apple Silicon |
| Grafik / Speicher | empfohlen ab 12 GB VRAM (8 GB gehen mit den INT8-Modellen). NVIDIA: Treiber ab 580.88. AMD Radeon: Treiber ab 26.2.2 | empfohlen ab 16 GB RAM (8 GB reichen für kleine Bilder) |
| Platte | rund 10 GB für das Programm, dazu 5 bis 40 GB pro Modell | rund 1 GB für die App, dazu etwa 10 GB für FLUX.2 Klein |
| Internet | fürs Einrichten (rund 3 GB) und die Modelle | für die Modelle |

Das Windows-Setup ist nicht signiert. Windows zeigt deshalb eventuell „Der Computer wurde durch Windows geschützt“: auf „Weitere Informationen“ und dann „Trotzdem ausführen“ klicken.

### Lizenzen

Der Code steht unter der [MIT-Lizenz](LICENSE): Jeder darf damit machen, was er will. Fremde Komponenten behalten ihre eigenen Lizenzen, siehe [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt); ComfyUI (GPL-3.0) wird als eigenständiges Programm mit vollständigem Quelltext mitgeliefert. Modelle sind nicht Teil dieses Repos, jedes hat seine eigene Lizenz, die die Modellliste anzeigt.

### Weiterlesen

- [docs/de/INSTALL.md](docs/de/INSTALL.md): Installation, Bauen aus dem Quelltext, PhotoCraft-Add-on
- [docs/de/MODELLE.md](docs/de/MODELLE.md): die Modelle im Detail, Prompt-Tipps, Testergebnisse
- [docs/de/FOTO_ZU_VIDEO.md](docs/de/FOTO_ZU_VIDEO.md): vom Foto zum Video, Schritt für Schritt
- [docs/de/STUDIO.md](docs/de/STUDIO.md): das Studio, ganze Videos aus Szenen
- [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md): NVAI-open aus Claude Code nutzen (englisch)
- [photocraft-addon/](photocraft-addon/): Quelltext des PhotoCraft-Add-ons
