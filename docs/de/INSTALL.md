# NVAI-open installieren

*English: [../INSTALL.md](../INSTALL.md)*

NVAI-open erzeugt Medien lokal auf deiner eigenen Hardware:

- **Windows:** Bilder, Video mit Ton, Musik, 3D-Modelle und restaurierte Fotos auf deiner Grafikkarte, dazu das Studio
  für ganze Videos, eine Weboberfläche und ein MCP-Server für Claude Code.
- **macOS:** eine native App für Apple Silicon mit Bildern, Video, Musik, Fotorestaurierung und dem Studio.

Beide bieten dieselbe REST-API unter `http://127.0.0.1:8100`.

- [Windows: Installation mit dem Setup](#windows-installation-mit-dem-setup)
- [macOS: Installation aus der DMG](#macos-installation-aus-der-dmg)
- [Aus dem Quelltext bauen](#aus-dem-quelltext-bauen)
- [Optional: PhotoCraft-Add-on](#optional-photocraft-add-on)

---

## Windows: Installation mit dem Setup

`NVAI-open-Setup-<Version>.exe` braucht weder Python noch git. Es bringt eine eigene Kopie von uv mit und installiert
damit Python, ComfyUI und PyTorch in den getesteten Versionen. Es installiert nur für den aktuellen Benutzer, ohne
Administratorrechte.

### Voraussetzungen

| | |
|---|---|
| **Windows** | Windows 10 (ab Version 2004) oder Windows 11, 64 Bit |
| **Grafikkarte** | NVIDIA oder AMD Radeon (experimentell, siehe unten); 8 GB VRAM gehen, 12–16 GB sind bequem |
| **Treiber** | NVIDIA ab 580.88 (nötig für PyTorch mit CUDA 13): https://www.nvidia.com/drivers. AMD: Adrenalin ab 26.2.2 |
| **Internet** | rund 3 GB beim Einrichten (vor allem PyTorch), dazu 5–40 GB pro Modell |
| **Platte** | rund 10 GB für das Programm, dazu Platz für die Modelle |

Das Setup prüft Grafikkarte und Treiber und warnt, wenn es keine passende Karte findet oder der Treiber zu alt ist.

### AMD Radeon und mehrere Grafikkarten (experimentell)

- **AMD Radeon:** Findet das Setup eine Radeon und keine NVIDIA-Karte, installiert es PyTorch mit ROCm 10 aus AMDs
  Paketen, prüft das mit einer kleinen Rechnung auf der Karte und nimmt ROCm 7.2.1, wenn das scheitert. Unter
  „Modelle“ zeigt „Für deine Karte“ die passenden Fassungen: FP8 und bf16 auf einer Radeon RX 9000, INT8 auf anderen
  Radeons. 3D braucht NVIDIA. Auf einer echten Radeon ist noch nichts gemessen, Rückmeldungen in
  [#2](https://github.com/Mantux775/NVAI-open/issues/2) helfen deshalb sehr. `install-runtime.ps1 -Gpu amd|nvidia` oder
  `-Rocm 10.0|7.2` erzwingt eine Wahl.
- **Mehrere NVIDIA-Karten:** Alles rechnet auf der stärksten Karte. Unter „Modelle“ → „Grafikkarten“ (oder per Klick
  auf eine Karte in der Kopfzeile) bekommen Bildmodelle, Sprachmodelle und 3D auf Wunsch eine eigene Karte; die Wahl
  steht in `gpus.json` im Datenordner. In unserem Test mit zwei Karten brachte das Aufteilen keinen Gewinn
  ([Issue #1](https://github.com/Mantux775/NVAI-open/issues/1#issuecomment-6373776729)).

### Windows SmartScreen

Das Setup ist nicht signiert. Windows zeigt deshalb eventuell **„Der Computer wurde durch Windows geschützt“**: auf
**„Weitere Informationen“** und dann auf **„Trotzdem ausführen“** klicken.

### Installieren

1. `NVAI-open-Setup-<Version>.exe` starten.
2. Den Programmordner wählen (Vorgabe `%LOCALAPPDATA%\Programs\NV-AI`).
3. Die Ordner für Daten (Bilder, Einstellungen, Protokolle; Vorgabe `%LOCALAPPDATA%\NV-AI`) und Modelle (Vorgabe
   `%LOCALAPPDATA%\NV-AI\models`) wählen. Ein Modell hat 5 bis 40 GB, eine große Platte lohnt sich. Beide Ordner müssen
   außerhalb des Programmordners liegen, damit Modelle und Bilder eine Deinstallation überstehen.
4. Die Installationsart wählen. **Vollständige Installation** bringt die 3D-Komponente (TripoSG; das Modell selbst,
   7,4 GB, lädst du später) und das PhotoCraft-Add-on mit. **Nur NVAI-open** deckt Bilder, Ton und Video ab.
   **Benutzerdefiniert** lässt dich auswählen.
5. Danach installiert das Setup Python, ComfyUI und PyTorch (rund 3 GB) in einem Konsolenfenster, das sich am Ende
   selbst schließt. Das dauert 5 bis 20 Minuten.

Scheitert der letzte Schritt, zeigt das Setup den Pfad zu `install.log`. Später lässt er sich mit
**„NVAI-open reparieren“** im Startmenü wiederholen.

### Erste Schritte

1. **NVAI-open** im Startmenü öffnen. Der Browser zeigt die App unter `http://127.0.0.1:8100`.
2. Unter **„Modelle“** ein Modell laden. Modelle, die zu deiner Grafikkarte passen, sind als *empfohlen* markiert.
3. Unter **„Generieren“** einen Prompt eingeben. Der erste Auftrag nach dem Start dauert 30 bis 60 Sekunden länger,
   weil das Modell lädt.

**„NVAI-open beenden“** im Startmenü fährt alles herunter und gibt die Grafikkarte frei. NVAI-open aus Claude Code
nutzen: [CLAUDE_CODE.md](../CLAUDE_CODE.md) (englisch).

### FLUX 3 und LTX-2.5 (Zugang zu Hugging Face)

Black Forest Labs (FLUX 3 Image Klein) und Lightricks (LTX-2.5) verlangen, dass du ihre Lizenz vorher annimmst. Mit
einem kostenlosen Konto auf https://huggingface.co:

1. Die Lizenz annehmen unter https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy und
   https://huggingface.co/Lightricks/LTX-2.5.
2. Einen Token mit Leserecht anlegen unter https://huggingface.co/settings/tokens.
3. Den Token in NVAI-open unter **„Modelle“** im Kasten „Hugging Face“ eintragen. Die Modellkarte zeigt danach, ob der
   Zugriff klappt.

Schritt für Schritt mit Bildern: [HUGGINGFACE.md](HUGGINGFACE.md). Lizenzen: FLUX 3 kommerziell nur unter 5 Mio. US-$
Jahresumsatz, und jedes Bild muss vor der Veröffentlichung geprüft werden; LTX-2.5 kostenlos unter 10 Mio. US-$.

### Modelle

NVAI-open enthält keine Modelle; zusammen wären es mehrere hundert Gigabyte. Du lädst sie unter **„Modelle“**, wo jedes
seine Größe, seinen Speicherbedarf und seine Lizenz zeigt. Die richtigen Fassungen für deine Karte sind als *empfohlen*
markiert:

| Grafikkarte | Bilder | Video | Fotos (schärfen) |
|---|---|---|---|
| RTX 50 | Qwen-Image-2512, FLUX 3 Image Klein und Krea 2 in NVFP4, MOSS-Image INT8 | LTX-2.5 NVFP4 | SeedVR2 7B NVFP4 |
| RTX 20, 30, 40 | dieselben in INT8, dazu Z-Image INT8 | LTX-2.5 INT8 | SeedVR2 7B INT8 |
| Radeon RX 9000 | FP8- und bf16-Fassungen | LTX-2.5 INT8 | SeedVR2 7B FP8 |

Für 3D bringt die vollständige Installation TripoSG mit. TRELLIS.2 (mit Texturen) braucht eine Installation aus dem
Quelltext (siehe [Optional: 3D-Worker](#optional-3d-worker)).

Ein Modell, das größer ist als der Grafikspeicher, läuft trotzdem: ComfyUI lädt Teile aus dem Arbeitsspeicher nach. An
einem normalen Anschluss kostete das wenig (Krea 2 INT8 mit 8 GB: 13,0 statt 12,2 s), an einem langsamen wie einem
Riser viel. Jedes Bild- und Videomodell ist als *unzensiert*, *teilweise zensiert* oder *zensiert* gekennzeichnet, die
Quelle steht im Tooltip.

### LoRAs (Hugging Face und Civitai)

„Modelle“ → „Modelle und LoRAs suchen“ findet auch LoRAs, auf Hugging Face und auf Civitai. Vor dem Download liest
NVAI-open den Dateikopf und sagt, zu welchem Modell eine LoRA passt. Civitai verlangt für die meisten Downloads einen
eigenen API-Schlüssel (civitai.com → Settings → API Keys). Eine selbst trainierte LoRA-Datei kommt über „Modelle“ →
„LoRA-Datei hinzufügen“ dazu.

Auf der Seite „Generieren“ steht jede passende LoRA unter dem gewählten Modell: anhaken, Stärke wählen (0,6–1,0 ist
üblich) und die Trigger-Wörter mit „+ Trigger“ in den Prompt holen. LoRAs für Wan 2.2 A14B kommen meist als High- und
Low-Noise-Datei: beide laden. Welche Modelle LoRAs nehmen, die getesteten und die REST-Aufrufe:
[LORAS.md](LORAS.md).

Lizenz und Inhalt einer LoRA stehen nur auf ihrer Seite; dort prüfen, bevor du etwas veröffentlichst.

### Speicherorte

„Modelle“ → „Speicherorte“ zeigt den Datenordner und den Modellordner mit dem freien Platz. „Durchsuchen …“ wählt
einen neuen Ordner, „NVAI-open jetzt neu starten“ übernimmt ihn. Vorhandene Dateien bleiben, wo sie sind: Zum
Mitnehmen NVAI-open beenden, die Dateien verschieben und wieder starten.

### Abbrechen

Jeder Download und jede Generierung lässt sich abbrechen, auch solange sie in der Warteschlange stehen: in der
Download-Leiste, auf den Seiten „Modelle“ und „Generieren“ oder mit „Stopp“ in der Kopfzeile. Ein abgebrochener
Download behält seine fertigen Dateien, „Fortsetzen“ unter „Modelle“ lädt nur, was fehlt. REST:
`POST /api/jobs/{id}/cancel`.

### Problem melden

„Problem melden“ oben rechts: In einem Satz beschreiben, was passiert ist, und NVAI-open schreibt einen Bericht mit
Version, Windows, Grafikkarte, Treiber, installierten Modellen, den letzten Aufträgen und den Enden der Protokolle. Du
siehst ihn, bevor du ihn weitergibst. Er ist anonymisiert: Namen, Pfade, E-Mail-, IP- und MAC-Adressen und Tokens sind
ersetzt, Prompts und Bilder fehlen. „Auf GitHub melden“ öffnet ein vorausgefülltes Issue; die gespeicherte Datei dort
hineinziehen.

### Protokolle und Reparatur

Die Protokolle liegen im Datenordner (Vorgabe `%LOCALAPPDATA%\NV-AI`): `install.log` (Setup), `nvai-server.log`
(Server) und `comfyui.log` (Generierung). **„NVAI-open reparieren“** im Startmenü installiert Python, ComfyUI und
PyTorch neu. Die Einstellungen stehen in der Registry unter `HKCU\Software\NV-AI`; belegt ein anderes Programm Port
8100, dort einen anderen `Port` eintragen.

### Aktualisieren und deinstallieren

- **Aktualisieren:** das neuere Setup starten. Es beendet ein laufendes NVAI-open und behält deine Daten- und
  Modellordner. (Bis 0.5.7 hieß die App NV-AI; Ordner und Einstellungen behielten den Namen.)
- **Deinstallieren:** **Einstellungen → Apps → NVAI-open**. Das entfernt den Programmordner und fragt dann, ob auch
  Daten und Modelle weg sollen. Mit **„Nein“** bleiben sie.

---

## macOS: Installation aus der DMG

NVAI-open für Mac ist eine native App für Apple Silicon. Sie bietet dieselbe REST-API wie unter Windows, das
PhotoCraft-Add-on und Claude Code arbeiten also genauso mit ihr.

### Voraussetzungen

| | |
|---|---|
| **Mac** | Apple Silicon, macOS 15 oder neuer (LTX-2.3 und LTX-2.5 brauchen macOS 26.3) |
| **Arbeitsspeicher** | 8 GB für Bilder und kurze Videos, ab 16 GB bequem |
| **Platte** | rund 1 GB für die App, dazu etwa 10 GB für FLUX.2 Klein |

### Installieren

Die DMG ist von Apple signiert und notarisiert.

1. `NVAI-open-<Version>.dmg` öffnen und **NVAI-open** in den Ordner „Programme“ ziehen; für PhotoCraft auch die
   Add-on-App **NVAI-open für PhotoCraft**.
2. NVAI-open öffnen. Unter **„Modelle“** FLUX.2 Klein laden (rund 10 GB, einmalig): ab 24 GB Arbeitsspeicher die
   8-Bit-Fassung, darunter die 4-Bit-Fassung.
3. Unter **„Generieren“** einen Prompt eingeben. Das erste Bild dauert länger, weil das Modell lädt.

Der Server startet mit der App, unabhängig vom Fenster, und lauscht nur auf `127.0.0.1:8100`.

### Was auf dem Mac läuft

| Was | Modelle | Speicher |
|---|---|---|
| Bilder | FLUX.2 Klein 4B (generieren, überarbeiten, füllen, erweitern, bis zu 3 Referenzbilder), Z-Image Turbo, Stable Diffusion als Core ML | ab 8 GB |
| Video | LTX-Video 2B aus Text oder einem Startbild, ohne Ton | ab 8 GB, bis 768 × 512 × 97 Bilder |
| | LTX-Video 13B | ab 16 GB (4 Bit) oder 24 GB (8 Bit) |
| | LTX-2.3 und LTX-2.5 mit Ton | ab 32 bzw. 64 GB, macOS 26.3 |
| Musik und Klänge | Stable Audio 3 | ab 8 GB |
| Alte Fotos | FLUX.2 Klein, „Automatisch“ mit Qwen3.5 4B, Schärfen mit SeedVR2 3B | ab 8 GB |
| Prompt ausbauen | der Qwen3-4B-Text-Encoder von FLUX.2 Klein, ohne eigenen Download | ab 8 GB |

Gemessen ist nur, was auf einen Mac mini M1 mit 8 GB passt: ein 512 × 512-Bild mit FLUX.2 Klein in 4 Bit in rund
40 s, 30 s Musik in rund 13 s, 2 s Video in 768 × 512 in rund 95 s. Die größeren Videomodelle sind nach den Angaben
ihrer Autoren je Speicher empfohlen, nicht gemessen.

Qwen-Image und FLUX 3 laufen nicht auf dem Mac; native, freie Portierungen gibt es dafür noch nicht. Core-ML-Modelle
haben eine feste Größe; andere Größen werden gestreckt.

### Dateien und Rückmeldung

- Daten: `~/Library/Application Support/NV-AI`. Protokoll: `~/Library/Logs/NV-AI/nvai.log`.
- **Einstellungen → „Problem melden“** schreibt einen anonymisierten Bericht wie unter Windows und öffnet ein
  vorausgefülltes Issue.

---

## Aus dem Quelltext bauen

### Windows: Entwicklungsumgebung

| | |
|---|---|
| **NVIDIA-Grafikkarte** | 8 GB VRAM gehen, 12–16 GB sind bequem; Treiber ab 580.88 |
| **Windows 10/11** | die Skripte sind PowerShell |
| **git** | https://git-scm.com/download/win |
| **uv** | `winget install astral-sh.uv`, legt die Python-Umgebungen an |
| **Node.js** | `npm` baut die Weboberfläche |
| **Platte** | 30 GB für die Installation, dazu 5–40 GB pro Modell |

```powershell
git clone https://github.com/Mantux775/NVAI-open.git
cd NVAI-open
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

Das Skript holt ComfyUI in der getesteten Version, legt zwei Python-Umgebungen an (den Server und das GPU-Backend mit
PyTorch für CUDA 13), baut die Weboberfläche und listet die Modelle, die zu deiner Karte passen. Rechne mit 10–20
Minuten.

```powershell
scripts\start.ps1     # danach http://127.0.0.1:8100 öffnen
scripts\stop.ps1      # beendet NVAI-open und ComfyUI
```

ComfyUI startet mit dem ersten Auftrag (rund 30 s, einmalig). Ist Port 8100 belegt, nennt `start.ps1` den Prozess,
statt einen zweiten Server zu starten.

**Zugriff von anderen Geräten:** `scripts\start.ps1 -Lan` lauscht auch im Netz. Andere Geräte schicken dann einen
Token im Header `X-NVAI-Token` (aus `$env:NVAI_TOKEN` oder `data\api_token`, das `-Lan` bei Bedarf anlegt). Die
Verbindung ist einfaches HTTP, von außen also über ein VPN.

**Claude Code:**

```powershell
claude mcp add --scope user nvai -- "<Repository-Ordner>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

#### Optional: 3D-Worker

```powershell
scripts\setup_triposg.ps1     # Geometrie, MIT-Lizenz
scripts\setup_trellis2.ps1    # Geometrie und PBR-Texturen, braucht einen C++-Compiler
```

Vorher das Original-Repository nach `external\triposg` bzw. `external\trellis2` klonen. TRELLIS.2 kompiliert eine
CUDA-Erweiterung und braucht die Visual Studio 2022 Build Tools mit den C++-Werkzeugen.

#### Was wo liegt

```
server/             Server (FastAPI), MCP-Server, 3D-Worker (server/workers)
frontend/           Weboberfläche (React/Vite), gebaut nach frontend/dist/
scripts/            Einrichten, Starten, Beenden
packaging/windows/  Windows-Setup (Inno Setup)
packaging/tools/    Helfer für Releases
mac/NVAIMac/        NVAI-open für Mac (SwiftUI)
photocraft-addon/   PhotoCraft-Add-on
docs/               Dokumentation
```

### Das Windows-Setup bauen

```powershell
cd frontend; npm install; npm run build; cd ..
packaging\windows\build-setup.ps1 [-Addon <Ordner>]
```

Dazu braucht es Inno Setup 6 (`winget install JRSoftware.InnoSetup --scope user`), uv und Python 3 im `PATH` und die
gebaute Weboberfläche. Das Skript sammelt den Servercode, die Weboberfläche, ComfyUI und TripoSG in festen Versionen,
uv und die gesperrten Paketlisten aus `packaging\windows\locks` und ruft dann Inno Setup auf. Ergebnis ist
`packaging\windows\build\NVAI-open-Setup-<Version>.exe`; die Version kommt aus `server\nvai\__init__.py`.

- Das PhotoCraft-Add-on wird zur wählbaren Komponente, wenn ein gebauter Add-on-Ordner da ist (`-Addon`,
  `$env:NVAI_ADDON_DIR` oder `photocraft-addon\dist\addon`).
- Auf dem Ziel-PC installiert das Setup genau die Paketversionen aus `locks\`, geprüft über ihre Prüfsummen.
- Die mitgelieferten `.ps1`-Skripte müssen reines ASCII sein (Windows PowerShell 5.1 liest sie als ANSI); das
  Bauskript prüft das.

### Die Mac-App bauen

Du brauchst einen Mac mit Apple Silicon, Xcode mit der Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`,
einmalig) und XcodeGen. Gebaut wird mit **xcodebuild**, nicht mit `swift build`: Nur Xcode übersetzt die Metal-Shader
von MLX. `project.yml` ist die XcodeGen-Vorlage, die Paketversionen stehen fest in `Package.resolved`.

Die Skripte in `mac/NVAIMac/scripts` erwarten das Projekt unter `~/NVAIMac` auf dem Mac:

| Skript | Was es tut |
|---|---|
| `sync.sh` | Von Windows (Git Bash): kopiert die Quellen per SSH nach `~/NVAIMac` auf einen Mac namens `macmini` und ruft dort `xcodegen generate` auf |
| `build.sh` | baut `~/NVAIMac/dd/Build/Products/Release/NVAI-open.app` (Release, arm64, ad hoc signiert) |
| `release.sh` | baut die DMG |

Direkt auf einem Mac: `mac/NVAIMac` nach `~/NVAIMac` kopieren, dort `xcodegen generate` ausführen und
`Package.resolved` nach `NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` kopieren. Danach
`zsh ~/NVAIMac/scripts/build.sh`.

Ein Testlauf mit eigenem Port: `open -n ~/NVAIMac/dd/Build/Products/Release/NVAI-open.app --args -serverPort 8110`.
`NVAI-open --snapshot <png> [--tab studio|generate|history|models|settings] --quit` speichert ein Bild des Fensters,
auch ohne Bildschirm.

#### Die DMG bauen

`zsh ~/NVAIMac/scripts/release.sh` baut `~/NVAIMac/release/NVAI-open-<Version>.dmg` mit der App, dem PhotoCraft-Add-on
(wenn die Umgebungsvariable `ADDON_DIR` auf den Ordner mit dessen `build-app.sh` zeigt) und einer Kurzanleitung. Mit
einem Zertifikat „Developer ID Application“ werden die Apps und die DMG signiert, notarisiert und gestapelt (für
`notarytool` braucht es einen API-Schlüssel von App Store Connect); ohne Zertifikat ist die DMG nur ad hoc signiert, für
interne Tests. In einer SSH-Sitzung mit gesperrtem Schlüsselbund das Kennwort über stdin übergeben und
`--unlock-from-stdin` anhängen.

---

## Optional: PhotoCraft-Add-on

**NVAI-open für PhotoCraft** verbindet PhotoCraft mit einem lokalen NVAI-open. Es braucht PhotoCraft ab 0.10.0:
https://github.com/storytold/photocraft/releases/latest

- **Windows:** Teil der vollständigen Installation. Fehlt PhotoCraft, bietet das Setup die Download-Seite an und
  installiert bei Bedarf die WebView2-Laufzeit. Das Add-on startet aus dem Startmenü (**NVAI-open für PhotoCraft**) und
  startet NVAI-open bei Bedarf mit.
- **macOS:** in der DMG als **NVAI-open für PhotoCraft**. Es startet NVAI-open ebenfalls selbst.

Das Add-on spricht über die REST-API unter `http://127.0.0.1:8100` mit NVAI-open und arbeitet deshalb unter Windows und
auf dem Mac gleich. Sein Quelltext liegt in [`photocraft-addon/`](../../photocraft-addon/).
