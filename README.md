# NVAI-open

Images, videos with sound, music and 3D models, made on your own computer. Free, private, no account, no subscription, no cloud.

<p align="center"><img src="docs/images/photo-video-king.gif" width="420" alt="A generated portrait becomes a king who says his line, then the camera zooms out to the film set"></p>
<p align="center"><sub>Made with NVAI-open: a generated portrait becomes a king who speaks, then the camera zooms out to the film set. <a href="docs/videos/photo-video-king.mp4">With sound</a></sub></p>

## Download

| | |
|---|---|
| Windows 10/11, NVIDIA or AMD Radeon | [NVAI-open-Setup-0.5.10.exe](https://github.com/Mantux775/NVAI-open/releases/download/v0.5.10/NVAI-open-Setup-0.5.10.exe) |
| macOS 15+ on Apple Silicon, signed and notarized | [NVAI-open-0.4.5.dmg](https://github.com/Mantux775/NVAI-open/releases/download/v0.5.10/NVAI-open-0.4.5.dmg) |

Install, open, download a model under "Models", generate. The setup brings everything else along. [Installation details](docs/INSTALL.md) · [All releases](https://github.com/Mantux775/NVAI-open/releases)

## What's new? / Was gibt's Neues?

October 2026: NVAI-open 0.5.10 for Windows and 0.4.5 for the Mac ([release notes](https://github.com/Mantux775/NVAI-open/releases/tag/v0.5.10))

- **Krea 2 with a style template:** one or two images set the way of painting, the colors and the light, the prompt sets the content
- **3D with readable lettering:** "Take the front from the image" puts the source image onto the front of the mesh
- **Extend a video:** LTX-2.5 continues a clip from its last frame, sound included
- **The right format for your card:** INT8 on RTX 20/30/40, NVFP4 there only on a slow connection such as a riser

Neu: **Krea 2 mit Stilvorlage** (ein oder zwei Bilder geben Malweise, Farben und Licht vor), **3D mit lesbarer Schrift** (Vorderseite aus dem Bild), **Video verlängern** (LTX-2.5 setzt einen Clip samt Ton fort), **das richtige Format für die Karte** (INT8 auf RTX 20/30/40, NVFP4 dort nur an einem langsamen Anschluss). 0.5.9 brachte Krea 2 und schärfere Videos ([Notizen](https://github.com/Mantux775/NVAI-open/releases/tag/v0.5.9)).

[English](#english) · [Video](#video) · [Deutsch](#deutsch)

---

## English

### Hi

I built this app because I needed it myself: images, sounds and 3D models for my game projects, without paying per picture or sending everything to the cloud. Now I'm sharing it. Everything runs on your own graphics card, and nothing leaves your computer.

It is tested on my own hardware: Windows with an RTX 5060 Ti (16 GB) and a Mac mini M1 (8 GB). Feedback is very welcome as an [issue](https://github.com/Mantux775/NVAI-open/issues), easiest with "Report a problem" in the app, which attaches an anonymized report. I have a full-time job, so answers can take a while. All apps are in English and German.

### What you can do

- **Images:** FLUX 3, Qwen-Image-2512, Krea 2 and many more. Edit with reference images, fill in or extend a picture.
- **Video with sound:** LTX-2.5 makes the picture and the sound in one pass, speech included, up to 20 s and 1080p.
- **Music and sounds:** songs with vocals, instrumental music up to 5 minutes, sound effects.
- **3D models:** from an image to a textured model for Unity, Blender or any engine.
- **A few words are enough:** "Expand prompt" writes the full description for you.
- **Claude Code:** Claude creates your assets while it works on your project.
- **No filter of its own:** uncensored models are one click away. You are responsible for what you make.
- **Windows and Mac**, NVIDIA and AMD Radeon, and an add-on for the photo editor PhotoCraft.

### From a portrait to a video

![A portrait, the start image from FLUX 3 and three frames of the video from LTX-2.5](docs/images/photo-video-chain.jpg)

1. **Generate → Image:** create a portrait, or use a photo of someone who agreed to it.
2. **Generate → Video:** pick the portrait as the start image.
3. **Person from a photo:** describe the role. FLUX 3 keeps the face and makes four start images; pick the one that looks most alike.
4. **Prompt:** describe what moves, what the camera does and what the person says. LTX-2.5 makes the video with speech and sound.

Step by step with screenshots: [docs/PHOTO_TO_VIDEO.md](docs/PHOTO_TO_VIDEO.md)

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

FLUX 3 Image Klein is fast and edits a picture while keeping the rest intact. Qwen-Image-2512 is best at lettering and at how things are built, and its license (Apache-2.0) allows almost anything. Krea 2 looks the most like a photo and takes about 20 s per image. Same prompt and seed:

![Explorer, full body: Qwen-Image-2512, FLUX 3 and Krea 2](docs/images/compare-krea2.jpg)

Krea 2 also takes an image as a style template: the lighthouse keeps its content and takes on the watercolor or the woodcut.

![Two templates made with FLUX 3, Krea 2 without and with a style template](docs/images/krea2-style-reference.jpg)

![Crate with stencilled lettering: FLUX 3 and Qwen-Image-2512](docs/images/compare-crate.jpg)

Editing with FLUX 3: "replace the rope handles with iron handles, keep everything else unchanged".

![Editing with a reference image in FLUX 3](docs/images/flux3-edit.jpg)

LoRAs teach a model a style, for example a more photographic look:

![Portrait without LoRA, with Boreal and with Lenovo UltraReal](docs/images/lora-realism.jpg)

More comparisons, prompt tips and test results: [docs/MODELS.md](docs/MODELS.md). All images in this README were generated with NVAI-open.

### Edit pictures: extend and fill

Make a picture wider or taller, and NVAI-open paints the new border to match. Or mark an area and fill it: remove things, add new ones. The rest of the picture stays as it was.

![Outpainting all around: original, NVAI-open 0.5.4 and 0.5.5](docs/images/outpaint-before-after.jpg)

![Fill with FLUX 3: crates removed, a seagull added](docs/images/fill-flux3.jpg)

### Expand prompt

Type a few words, click "Expand prompt", and NVAI-open writes the full description: setting, materials, light, what happens. Read it, delete what you don't want, generate. Works for images, video, sounds, music and 3D.

![Qwen-Image-2512 with "a medieval blacksmith" and with the expanded prompt](docs/images/expand-prompt.jpg)

### Claude Code: your assets on request

NVAI-open comes with an MCP server. Register it once:

```
claude mcp add --scope user nvai -- "<install folder>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

Then just ask: "Make a weathered wooden barrel as a 3D model and put it into Assets/Generated/Meshes". Claude picks a model, asks before a download, generates, and copies the result into your project. Setup and all tools: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md)

### Graphics cards and uncensored models

NVAI-open picks the right model versions for your card: NVFP4 on an RTX 50, INT8 on RTX 20, 30 and 40 (on a slow connection such as a riser, NVFP4 where only that fits into the memory). With several cards it uses the strongest one. AMD Radeon works experimentally; testers are very welcome in [#2](https://github.com/Mantux775/NVAI-open/issues/2). Details: [docs/INSTALL.md](docs/INSTALL.md)

NVAI-open has no content filter of its own. The model list marks every model as censored, partly censored or uncensored, and uncensored ones such as Chroma, Pony and NoobAI are one click away. More, including LoRAs from Hugging Face and Civitai, under "Models" → "Search models and LoRAs". Respect the law and each model's license; the FLUX 3 license, for example, requires a review of every image before it is published. Overview: [docs/MODELS.md](docs/MODELS.md#censored-or-uncensored)

### Mac app, PhotoCraft add-on, iOS

- **Mac:** a native app for Apple Silicon with FLUX.2 Klein: generate, refine, fill, reference images, expand prompts.
- **[PhotoCraft](https://github.com/storytold/photocraft) add-on:** select an area in this great open-source photo editor, fill it or rework it, and the result comes back as a layer. Needs PhotoCraft 0.10.0 or newer. Thanks to the PhotoCraft developers for such a well-scriptable editor.
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

- **Bilder:** FLUX 3, Qwen-Image-2512, Krea 2 und viele weitere. Mit Referenzbildern bearbeiten, Bereiche füllen, Bilder erweitern.
- **Video mit Ton:** LTX-2.5 macht Bild und Ton in einem Durchgang, samt Sprache, bis 20 s und 1080p.
- **Musik und Sounds:** Lieder mit Gesang, instrumentale Musik bis 5 Minuten, Soundeffekte.
- **3D-Modelle:** aus einem Bild ein texturiertes Modell für Unity, Blender oder jede Engine.
- **Ein paar Worte reichen:** „Prompt ausbauen“ schreibt die volle Beschreibung für dich.
- **Claude Code:** Claude erzeugt deine Assets, während es an deinem Projekt arbeitet.
- **Kein eigener Filter:** unzensierte Modelle sind einen Klick entfernt. Für das, was du erzeugst, bist du selbst verantwortlich.
- **Windows und Mac**, NVIDIA und AMD Radeon, dazu ein Add-on für den Bildeditor PhotoCraft.

### Vom Porträt zum Video

![Ein Porträt, das Startbild von FLUX 3 und drei Frames aus dem Video von LTX-2.5](docs/images/photo-video-chain-de.jpg)

1. **Generieren → Bild:** ein Porträt erzeugen oder das Foto eines Menschen nehmen, der damit einverstanden ist.
2. **Generieren → Video:** das Porträt als Startbild wählen.
3. **Person aus einem Foto:** die Rolle beschreiben. FLUX 3 übernimmt das Gesicht und macht vier Startbilder; das ähnlichste auswählen.
4. **Prompt:** beschreiben, was sich bewegt, was die Kamera macht und was die Person sagt. LTX-2.5 macht daraus das Video mit Sprache und Ton.

Schritt für Schritt mit Screenshots: [docs/de/FOTO_ZU_VIDEO.md](docs/de/FOTO_ZU_VIDEO.md)

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

FLUX 3 Image Klein ist schnell und bearbeitet ein Bild, ohne den Rest zu verändern. Qwen-Image-2512 ist am besten bei Schrift und Konstruktion, und seine Lizenz (Apache-2.0) erlaubt fast alles. Krea 2 wirkt am ehesten wie ein Foto und braucht rund 20 s je Bild. Gleicher Prompt und Seed:

![Entdeckerin, ganze Figur: Qwen-Image-2512, FLUX 3 und Krea 2](docs/images/compare-krea2.jpg)

Krea 2 nimmt auch ein Bild als Stilvorlage: Der Leuchtturm behält seinen Inhalt und wird zum Aquarell oder zum Holzschnitt.

![Zwei Vorlagen von FLUX 3, Krea 2 ohne und mit Stilvorlage](docs/images/krea2-style-reference-de.jpg)

![Kiste mit Schablonenschrift: FLUX 3 und Qwen-Image-2512](docs/images/compare-crate.jpg)

Bearbeiten mit FLUX 3: „replace the rope handles with iron handles, keep everything else unchanged“.

![Bearbeiten mit Referenzbild in FLUX 3](docs/images/flux3-edit.jpg)

LoRAs bringen einem Modell einen Stil bei, zum Beispiel einen fotografischeren Look:

![Porträt ohne LoRA, mit Boreal und mit Lenovo UltraReal](docs/images/lora-realism.jpg)

Weitere Vergleiche, Prompt-Tipps und Testergebnisse: [docs/de/MODELLE.md](docs/de/MODELLE.md). Alle Bilder in diesem README hat NVAI-open erzeugt.

### Bilder bearbeiten: erweitern und füllen

Ein Bild breiter oder höher machen, und NVAI-open malt den neuen Rand passend dazu. Oder einen Bereich markieren und füllen: Dinge entfernen, neue hinzufügen. Der Rest des Bildes bleibt, wie er war.

![Rundum erweitert: Original, NVAI-open 0.5.4 und 0.5.5](docs/images/outpaint-before-after.jpg)

![Füllen mit FLUX 3: Kisten entfernt, Möwe hinzugefügt](docs/images/fill-flux3.jpg)

### Prompt ausbauen

Ein paar Worte eintippen, auf „Prompt ausbauen“ klicken, und NVAI-open schreibt die volle Beschreibung: Ort, Material, Licht, was passiert. Lesen, Ungewolltes streichen, generieren. Das geht für Bilder, Video, Sounds, Musik und 3D.

![Qwen-Image-2512 mit „a medieval blacksmith“ und mit ausgebautem Prompt](docs/images/expand-prompt.jpg)

### Claude Code: Assets auf Zuruf

NVAI-open bringt einen MCP-Server mit. Einmal eintragen:

```
claude mcp add --scope user nvai -- "<Installationsordner>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

Dann einfach sagen: „Mach ein verwittertes Holzfass als 3D-Modell und leg es nach Assets/Generated/Meshes“. Claude wählt ein Modell, fragt vor einem Download, generiert und kopiert das Ergebnis ins Projekt. Einrichtung und alle Werkzeuge: [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md) (englisch)

### Grafikkarten und unzensierte Modelle

NVAI-open wählt die passenden Modellfassungen für deine Karte: NVFP4 auf einer RTX 50, INT8 auf RTX 20, 30 und 40 (an einem langsamen Anschluss wie einem Riser NVFP4, wenn nur das in den Speicher passt). Mit mehreren Karten rechnet die stärkste. AMD Radeon läuft experimentell; Tester sind in [#2](https://github.com/Mantux775/NVAI-open/issues/2) sehr willkommen. Details: [docs/de/INSTALL.md](docs/de/INSTALL.md)

NVAI-open hat keinen eigenen Inhaltsfilter. Die Modellliste kennzeichnet jedes Modell als zensiert, teilweise zensiert oder unzensiert, und unzensierte wie Chroma, Pony und NoobAI sind einen Klick entfernt. Weitere, auch LoRAs von Hugging Face und Civitai, unter „Modelle“ → „Modelle und LoRAs suchen“. Gesetze und die Lizenz des Modells gelten; die FLUX-3-Lizenz etwa verlangt, jedes Bild vor der Veröffentlichung zu prüfen. Überblick: [docs/de/MODELLE.md](docs/de/MODELLE.md#zensiert-oder-unzensiert)

### Mac-App, PhotoCraft-Add-on, iOS

- **Mac:** eine native App für Apple Silicon mit FLUX.2 Klein: generieren, überarbeiten, füllen, Referenzbilder, Prompt ausbauen.
- **Add-on für [PhotoCraft](https://github.com/storytold/photocraft):** in diesem tollen Open-Source-Bildeditor einen Bereich auswählen, füllen oder überarbeiten, das Ergebnis kommt als Ebene zurück. Braucht PhotoCraft ab 0.10.0. Danke an die PhotoCraft-Entwickler für einen so gut steuerbaren Editor.
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
- [docs/CLAUDE_CODE.md](docs/CLAUDE_CODE.md): NVAI-open aus Claude Code nutzen (englisch)
- [photocraft-addon/](photocraft-addon/): Quelltext des PhotoCraft-Add-ons
