# NV-AI installieren

*English: [../INSTALL.md](../INSTALL.md)*

NV-AI erzeugt Medien lokal auf der eigenen Hardware:

- **Windows:** Bilder, Audio, Video und 3D-Meshes auf der eigenen Grafikkarte, bedienbar über
  eine Weboberfläche und als MCP-Server für Claude Code.
- **macOS:** eine native App für Apple Silicon, die Bilder erzeugt.

Beide bieten dieselbe REST-Schnittstelle unter `http://127.0.0.1:8100`.

- [Windows: Installation mit dem Setup](#windows-installation-mit-dem-setup)
- [macOS: Installation aus der DMG](#macos-installation-aus-der-dmg)
- [Aus dem Quelltext bauen](#aus-dem-quelltext-bauen)
- [Optional: PhotoCraft-Add-on](#optional-photocraft-add-on)

---

## Windows: Installation mit dem Setup

`NV-AI-Setup-<Version>.exe` braucht weder Python noch git: Es bringt uv mit und richtet
Python, ComfyUI und PyTorch in den getesteten Paketständen selbst ein. Es installiert nur für
den eigenen Benutzer und braucht keine Adminrechte.

### Voraussetzungen

| | |
|---|---|
| **Windows** | Windows 10 (2004 oder neuer) oder Windows 11, 64 Bit |
| **Grafikkarte** | NVIDIA oder AMD Radeon (experimentell, siehe unten); ab 8 GB VRAM sinnvoll, 12–16 GB komfortabel |
| **Treiber** | NVIDIA: ab 580.88 (Zweig R580, den PyTorch mit CUDA 13 braucht): https://www.nvidia.com/drivers. AMD: ab 26.2.2 |
| **Internet** | rund 3 GB beim Einrichten (vor allem PyTorch), dazu 5–30 GB pro Modell |
| **Platte** | rund 10 GB für das Programm, dazu Platz für die Modelle |

Das Setup prüft Grafikkarte und Treiber und warnt, wenn keine NVIDIA-Karte gefunden wird oder
der Treiber zu alt ist. Ohne NVIDIA-Karte lässt sich NV-AI installieren, erzeugt aber nichts.

### Experimentell (seit 0.5): AMD Radeon und mehrere Grafikkarten

- **AMD Radeon:** Das Setup erkennt eine Radeon (und keine NVIDIA-Karte) und installiert PyTorch
  mit ROCm 7.2.1 von AMD (`locks\comfyui-amd-base.lock` plus `locks\comfyui-rocm.lock`, beide
  mit Hashes). Nötig ist der AMD-Treiber 26.2.2 oder neuer. 3D wird auf AMD übersprungen.
  „NV-AI reparieren“ erkennt die Karte erneut; `install-runtime.ps1 -Gpu amd|nvidia` erzwingt
  eine Seite.
- **Mehrere NVIDIA-Karten:** Unter „Modelle“ → „Grafikkarten“ für Bildmodelle, Sprachmodelle und
  3D je eine Karte wählen. Seit 0.5.1 auch direkt in der Kopfleiste: Karte anklicken und anhaken,
  was sie machen soll. Bekommen die Sprachmodelle eine eigene Karte, startet NV-AI dafür ein
  zweites ComfyUI (Port 8189, Protokoll in `comfyui-text.log`). Die Wahl steht in `gpus.json` im
  Datenordner. Ohne eigene Wahl oder nach „Automatisch verteilen“ rechnet alles auf der stärksten
  Karte (seit 0.5.6). Messwerte mit zwei Karten stehen in
  [Issue #1](https://github.com/Mantux775/NVAI-open/issues/1#issuecomment-6373776729): Eine zweite Karte schaffte keinen
  Platz für größere Modelle, und das Aufteilen brachte in diesem PC keinen Gewinn.
- Zum Testen ohne die Hardware: `NVAI_SIMULATE_GPUS=2` meldet die eine Karte doppelt, und
  `NVAI_TEXT_BACKEND=separate` erzwingt das zweite ComfyUI auf einer einzigen Karte.

### Windows SmartScreen

Das Setup ist nicht signiert. Windows zeigt deshalb eventuell **„Der Computer wurde
durch Windows geschützt“**. Auf **„Weitere Informationen“** und dann auf **„Trotzdem
ausführen“** klicken.

### Installieren

1. `NV-AI-Setup-<Version>.exe` starten.
2. Den Programmordner wählen (Vorgabe `%LOCALAPPDATA%\Programs\NV-AI`).
3. Die Ordner für Daten (Bilder, Einstellungen, Protokolle; Vorgabe `%LOCALAPPDATA%\NV-AI`)
   und Modelle (Vorgabe `%LOCALAPPDATA%\NV-AI\models`) wählen. Jedes Modell ist 5 bis 30 GB
   groß, ein Ordner auf einer großen Platte ist sinnvoll. Beide Ordner müssen außerhalb des
   Programmordners liegen: Die Deinstallation entfernt den Programmordner, Modelle und Bilder
   sollen dabei erhalten bleiben.
4. Die Installationsart wählen. **Vollständige Installation** bringt zusätzlich die
   3D-Komponente (TripoSG, macht aus Bildern 3D-Modelle; das Modell selbst, 7,4 GB, lädt NV-AI
   bei Bedarf) und, falls im Setup enthalten, das PhotoCraft-Add-on (siehe
   [Optional: PhotoCraft-Add-on](#optional-photocraft-add-on)). **Nur NV-AI** umfasst Bilder,
   Audio und Video. **Benutzerdefiniert** lässt die Komponenten einzeln wählen.
5. Nach dem Kopieren richtet das Setup Python, ComfyUI und PyTorch ein (rund 3 GB), mit der
   3D-Komponente auch die Umgebung für TripoSG, die dasselbe PyTorch nutzt. Dabei ist ein
   Konsolenfenster offen; es schließt sich am Ende selbst. Das dauert 5 bis 20 Minuten.

Scheitert dieser letzte Schritt, nennt das Setup den Pfad von `install.log`. Später erneut
versuchen: Startmenü → „NV-AI reparieren“.

### Erste Schritte

1. Im Startmenü „NV-AI“ öffnen. Der Browser zeigt die Weboberfläche unter
   `http://127.0.0.1:8100`.
2. Unter **Modelle** ein Bildmodell laden. NV-AI markiert passende Modelle für die eigene
   Grafikkarte als *empfohlen* (siehe [Modelle](#modelle)).
3. Unter **Generieren** einen Prompt eingeben. Der erste Auftrag nach dem Start braucht
   zusätzlich 30 bis 60 Sekunden, weil das Modell geladen wird.

„NV-AI beenden“ im Startmenü fährt alles herunter und gibt die Grafikkarte frei. Außerdem gibt
es dort „NV-AI reparieren“, „Erste Schritte“ und mit dem Add-on „NV-AI für PhotoCraft“.

Für Claude Code siehe [CLAUDE_CODE.md](../CLAUDE_CODE.md) (englisch).

### FLUX 3 Image Klein (Zugang zu Hugging Face)

Dieses Modell liegt bei Black Forest Labs hinter einer Lizenzbestätigung. Dafür braucht es ein
kostenloses Konto bei https://huggingface.co:

1. Auf https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy die Lizenz bestätigen.
2. Unter https://huggingface.co/settings/tokens einen Token (Lesen) anlegen.
3. Den Token in NV-AI unter **Modelle** eintragen.

Lizenz: kommerziell nur unter 5 Mio. US-$ Jahresumsatz, jedes Bild vor der Veröffentlichung
prüfen. Einzelheiten in [MODELLE.md](MODELLE.md).

### Modelle

**NV-AI enthält keine Modelle** — sie wiegen zusammen mehr als hundert Gigabyte. Geladen werden
sie in der Weboberfläche unter **Modelle**; dort ist jedes Modell mit Größe, VRAM-Bedarf und
Lizenz beschrieben.

- NV-AI erkennt die Grafikkarte und markiert passende Modelle als *empfohlen*: auf RTX 50
  Qwen-Image-2512 und FLUX 3 Image Klein in NVFP4, auf RTX 20/30/40 FLUX 3 Image Klein INT8
  und Z-Image INT8.
- Modelle, die nicht in den Videospeicher der erkannten Karte passen, sind ausdrücklich
  markiert („knapp für diese Karte“ bzw. „zu groß für diese Karte“). Ein Modell, das nicht
  hineinpasst, läuft zwar, muss aber bei jedem Schritt nachgeladen werden und ist dadurch um
  ein Vielfaches langsamer.
- „Auf Hugging Face suchen“ auf derselben Seite findet weitere Modelle. NV-AI prüft jede Datei
  vor dem Laden; laden lassen sich SDXL- und SD-1.5-Checkpoints.
- Jedes Bild- und Videomodell trägt ein Abzeichen *unzensiert*, *teilweise zensiert*,
  *zensiert* oder *Zensur unbekannt*, mit Quelle im Tooltip (siehe [MODELLE.md](MODELLE.md)).

**Ein guter Einstieg je nach Karte:**

| VRAM | Bild | Video | 3D |
|---|---|---|---|
| 16 GB | `chroma1-hd-fp8` | `wan22-ti2v-5b` | `trellis2-4b` |
| 12 GB | `z-image` | `wan21-t2v-1.3b` | `triposg` |
| 8 GB | `z-image-int8` | `ltxv-2b-095` | `triposg` (knapp) |

Für 3D enthält die vollständige Installation des Setups TripoSG. TRELLIS.2 (`trellis2-4b`, mit
PBR-Texturen) gibt es nur bei der Installation aus dem Quelltext (siehe
[Optional: 3D-Worker](#optional-3d-worker)).

Die beiden empfohlenen Bildmodelle, Qwen-Image-2512 und FLUX 3 Image Klein, beschreibt
[MODELLE.md](MODELLE.md) ausführlich.

### LoRAs (Hugging Face und Civitai)

Seit 0.5.3 findet „Modelle“ → „Modelle und LoRAs suchen“ auch LoRAs: auf Hugging Face mit dem
Umschalter „LoRAs“, auf Civitai im eigenen Kasten darunter. Vor jedem Download liest NV-AI nur
den Dateikopf und erkennt daran, zu welchem Modell die LoRA passt: SDXL (Pony, Illustrious,
NoobAI …), SD 1.5, Qwen-Image, Z-Image, FLUX.1/Chroma, Wan (1.3B, 5B, 14B) und LTX-2/2.3.
Getestet an 79 LoRAs von Hugging Face, alle richtig erkannt. LoRAs landen in `loras` im
Modellordner.

Beim Generieren steht jede passende LoRA unter dem gewählten Bild- oder Videomodell: anhaken,
Stärke einstellen (üblich 0,6–1,0) und mit „+ Trigger“ ihre Trigger-Wörter in den Prompt
übernehmen. LoRAs für Wan 2.2 A14B kommen meist als High-Noise- und Low-Noise-Datei: beide laden,
NV-AI hängt jede an ihren Experten. REST und MCP: `loras=[{"model_id": "…", "strength": 0.8}]`.

Civitai verlangt für fast jeden Download einen eigenen API-Schlüssel (civitai.com → Settings →
API Keys); er liegt im Datenordner. Ohne Schlüssel funktioniert die Suche, und NV-AI verlässt
sich auf Civitais Angabe zum Basismodell; mit Schlüssel prüft es den Dateikopf wie bei Hugging
Face. Lizenzen und Inhalte von LoRAs stehen nur auf deren Seiten — dort prüfen, bevor etwas
veröffentlicht wird.

**Getestete LoRAs (RTX 5060 Ti, Qwen-Image-2512 voll, gleicher Seed, Stärke 0,9).** Alle erlauben,
die erzeugten Bilder zu verkaufen. Einmal geladen kostet eine LoRA kaum Zeit (94–106 statt 100 s).

| LoRA | Quelle, Lizenz | Ergebnis |
|---|---|---|
| Boreal (Boring Reality) v3 | Civitai, Bilder dürfen verkauft werden | Wirkt am ehesten wie ein echtes Foto: natürliche Haut, kein HDR-Look. Empfohlen |
| Lenovo UltraReal | Hugging Face `Danrisi/Lenovo_Qwen`, Apache-2.0, 47 MB | Natürlicher und fotografischer, hält sich am engsten an den Prompt. Empfohlen |
| Real Life | Civitai, Bilder dürfen verkauft werden | Natürlich, ersetzte aber den verlangten schlichten Hintergrund |
| flymy Realism | Hugging Face, Apache-2.0 | Kaum anders als ohne LoRA; ersetzte ebenfalls den Hintergrund |
| Skin Fix | Civitai, Bilder dürfen verkauft werden | Sichtbar weich, weniger Detail |
| Wuli Turbo 4 Schritte | Hugging Face, Apache-2.0 | Kein Stil: Schritte 4 und cfg 1 einstellen, 18 statt 100 s bei fast gleicher Qualität |

Für Video: **Wan2.2-Lightning I2V** (`lightx2v/Wan2.2-Lightning`, Apache-2.0, High- und Low-Datei)
an Wan 2.2 I2V A14B mit Schritten 4 und cfg 1 brauchte 90 statt 585 s (640 × 640, 49 Frames) bei
vergleichbarer Qualität; nur die Kamerafahrt fiel schwächer aus. **LTX-2.3 Crisp Enhance** zeichnete
Flamme und Stein schärfer, veränderte aber den Bildaufbau, und ihre Seite nennt keine Lizenz.

### Speicherorte

„Modelle“ → „Speicherorte“ (seit 0.5.2) zeigt Datenordner (Verlauf, Bilder, Protokolle) und
Modellordner (die großen Modelldateien) mit freiem Platz. „Durchsuchen …“ öffnet den
Ordnerdialog von Windows; NV-AI prüft, ob es dort schreiben kann, und speichert die Wahl in
`HKCU\Software\NV-AI`. „NV-AI jetzt neu starten“ übernimmt sie. Vorhandene Dateien bleiben im
alten Ordner: Zum Mitnehmen NV-AI beenden, den Inhalt in den neuen Ordner verschieben und neu
starten.

### Abbrechen

Jeder laufende oder wartende Download hat einen Abbrechen-Knopf, in der Download-Leiste oben auf
jeder Seite und auf der Modellseite. Er stoppt nach dem aktuellen Datenblock (wenige Sekunden);
fertige Teile bleiben, ein neuer Download setzt dort fort. Generierungen lassen sich auf der
Generieren-Seite abbrechen, auch wartende, oder mit „Stopp“ in der Kopfleiste. REST:
`POST /api/jobs/{id}/cancel`.

### Problem melden

„Problem melden“ oben rechts in der Weboberfläche (seit 0.5.1): in ein, zwei Sätzen beschreiben,
was passiert ist, und NV-AI erstellt einen Bericht mit Zeitstempel, Systemangaben (Version,
Windows, Grafikkarte und Treiber, installierte Modelle), den letzten Aufträgen und den Enden der
Protokolle. Man sieht ihn, bevor man ihn weitergibt. Er ist anonymisiert: Benutzer- und
Rechnername, Ordnerpfade, E-Mail-, IP- und MAC-Adressen und Token werden ersetzt; Prompts und
Bilder sind nicht enthalten. „Bericht herunterladen“ speichert ihn als
`nvai-report-<Zeit>.txt`, „Auf GitHub melden“ öffnet ein vorausgefülltes Issue; die Datei dort
hineinziehen. Skripte bekommen denselben Bericht über `POST /api/report`.

### Protokolle und Reparatur

Wenn etwas nicht klappt, helfen diese Dateien. Sie liegen im Datenordner (Vorgabe
`%LOCALAPPDATA%\NV-AI`):

| Datei | Inhalt |
|---|---|
| `install.log` | Einrichtung |
| `nvai-server.log` | Server |
| `comfyui.log` | Rechnen (ComfyUI) |

„NV-AI reparieren“ im Startmenü wiederholt die Einrichtung von Python, ComfyUI und PyTorch.

Seine Einstellungen legt das Setup in der Registry unter `HKCU\Software\NV-AI` ab: Programm-,
Daten- und Modellordner sowie den Port (8100). Belegt ein anderes Programm Port 8100, dort unter
`Port` einen anderen eintragen.

### Aktualisieren und deinstallieren

- **Aktualisieren:** das neuere Setup starten. Es beendet zuerst ein noch laufendes NV-AI der
  alten Installation und schlägt die bisherigen Daten- und Modellordner vor.
- **Deinstallieren:** über **Einstellungen → Apps → NV-AI**. Die Deinstallation entfernt den
  Programmordner und fragt danach, ob auch Daten und Modelle gelöscht werden sollen. Bei „Nein“
  bleiben sie für eine spätere Installation erhalten.

---

## macOS: Installation aus der DMG

NV-AI für Mac ist eine native App (SwiftUI), die Bilder lokal erzeugt. Sie bietet dieselbe
REST-Schnittstelle wie NV-AI unter Windows; das PhotoCraft-Add-on arbeitet deshalb unverändert
mit ihr.

### Voraussetzungen

| | |
|---|---|
| **Mac** | Apple Silicon, ab macOS 15 |
| **Arbeitsspeicher** | FLUX.2 Klein 4B in 4 Bit ab 8 GB (entspannt ab 16 GB), in 8 Bit ab 24 GB |
| **Internet** | für den ersten Modell-Download: FLUX.2 Klein 4B, rund 10 GB, einmalig |
| **Platte** | rund 1 GB für die App, dazu etwa 10 GB für FLUX.2 Klein |

### Installieren

Die DMG ist signiert und von Apple notarisiert.

1. `NV-AI-<Version>.dmg` öffnen und „NV-AI“ in den Ordner „Programme“ ziehen. Wer PhotoCraft
   nutzt, zieht auch „NV-AI für PhotoCraft“ dorthin.
2. NV-AI öffnen. Unter **Modelle** FLUX.2 Klein laden (rund 9 bis 11 GB, einmalig). Ab 24 GB
   Arbeitsspeicher die 8-Bit-Fassung wählen, darunter die 4-Bit-Fassung.
3. Unter **Generieren** einen Prompt eingeben. Das erste Bild dauert länger, weil das Modell
   geladen wird.

NV-AI für Mac startet seinen Server gleich beim Programmstart, unabhängig vom Fenster. Er
lauscht nur auf `127.0.0.1:8100`; das PhotoCraft-Add-on und eigene Skripte erreichen NV-AI unter
`http://127.0.0.1:8100`.

### Was auf dem Mac läuft

| Engine | Modelle | Kann | Speicher |
|---|---|---|---|
| MLX (`flux-2-swift-mlx` 3.1.0, MIT) | FLUX.2 Klein 4B, 4 Bit oder 8 Bit (Apache-2.0) | Generieren, Bild-zu-Bild (`denoise`), Füllen mit Maske, bis 3 Referenzbilder | 4 Bit ab 8 GB, 8 Bit ab 24 GB |
| Core ML (`ml-stable-diffusion`) | Stable Diffusion 1.5/2.1/SDXL als fertige Core-ML-Pipelines, dazu Treffer aus der Suche | Generieren, Bild-zu-Bild (mit VAE-Encoder), negativer Prompt; festes Format | ab 8 GB |

Gemessen auf einem Mac mini (M1, 8 GB), FLUX.2 Klein 4B, 4 Bit, 4 Schritte:

- 512 × 512: 40,5 s, Speicherspitze 4,4 GB. Das Ergebnis ist bitgleich mit der CLI des Pakets.
- Aufträge des PhotoCraft-Add-ons bei 1184 × 880: Generieren 109 s (Spitze 7,9 GB),
  Überarbeiten (`denoise` 0,5) 65 s.

Auf 8 GB ist das die Grenze. Ab 16 GB läuft es entspannt.

Grenzen:

- Qwen-Image und FLUX 3 laufen auf dem Mac nicht, dafür gibt es noch keine nativen, freien
  Ports.
- Ein laufendes FLUX.2-Bild lässt sich nicht abbrechen: Das Paket prüft nirgends auf Abbruch,
  abgebrochen wird nach dem aktuellen Bild. Core ML bricht beim nächsten Schritt ab.
- Core-ML-Modelle haben ein festes Format. Andere Formate werden auf die gewünschte Größe
  gestreckt.

### Dateien und Rückmeldung

- Daten: `~/Library/Application Support/NV-AI` (`assets/` mit `index.json`).
- Protokoll: `~/Library/Logs/NV-AI/nvai.log` (Start, Serverstatus, Aufträge und Fehler).
- Problem melden (seit 0.4.1): Einstellungen → „Problem melden“. Beschreiben, was passiert ist,
  dann „Bericht speichern …“ oder „Auf GitHub melden“ (speichert den Bericht und öffnet ein
  vorausgefülltes Issue; die Datei dort hineinziehen). Der Bericht enthält Zeitstempel, Mac,
  macOS, die letzten Aufträge und das Ende von `nvai.log`, anonymisiert wie unter Windows: kein
  Benutzer- oder Rechnername, Benutzerordner als `~`, keine Prompts und keine Bilder.
- Der Messbericht unter Einstellungen → „Messbericht speichern …“ listet Dauer und
  Speicherbedarf je Bild, ebenfalls ohne Prompts.

---

## Aus dem Quelltext bauen

### Windows: Entwicklungsumgebung

| | |
|---|---|
| **NVIDIA-Grafikkarte** | ab 8 GB VRAM sinnvoll, 12–16 GB komfortabel. Aktueller Treiber (ab 580.88) |
| **Windows 10/11** | die Skripte sind PowerShell |
| **git** | https://git-scm.com/download/win |
| **uv** | `winget install astral-sh.uv` — legt die Python-Umgebungen an |
| **Node.js** | `npm` baut die Weboberfläche; das fertige `frontend/dist` liegt nicht im Repository |
| **Platte** | 30 GB für die Installation, dazu **pro Modell 5–30 GB** |

Python muss nicht vorinstalliert sein, `uv` holt sich die passende Fassung selbst.

```powershell
git clone https://github.com/Mantux775/NVAI-open.git
cd NVAI-open
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

Das Skript holt ComfyUI in der geprüften Fassung 0.42.1, legt zwei getrennte
Python-Umgebungen an (Orchestrator und GPU-Backend mit PyTorch für CUDA 13), baut die
Weboberfläche, wenn npm vorhanden ist, erkennt die Grafikkarte und nennt am Ende die Modelle,
die auf diese Karte passen. Rechne mit 10–20 Minuten, das meiste davon PyTorch.

#### Starten und beenden

```powershell
scripts\start.ps1     # danach http://127.0.0.1:8100 öffnen
scripts\stop.ps1      # beendet gezielt NV-AI und ComfyUI
```

ComfyUI startet beim ersten Auftrag automatisch (einmalig rund 30 s). Ist Port 8100 schon
belegt, nennt `start.ps1` den Prozess, der ihn hält, statt einen zweiten Server zu starten.

#### Zugriff von anderen Geräten

```powershell
scripts\start.ps1 -Lan
```

Der Server lauscht dann zusätzlich im Netz. Andere Geräte (etwa das PhotoCraft-Add-on auf einem
anderen Rechner) schicken einen Token im Header `X-NVAI-Token` mit; dieser Rechner selbst braucht
keinen. Der Token kommt aus `$env:NVAI_TOKEN`, sonst aus `data\api_token`. Fehlt beides, legt
`-Lan` die Datei mit 32 Zufallsbytes an. Im Heimnetz geht die Verbindung unverschlüsselt über
HTTP, der Token also auch; von unterwegs deshalb über ein VPN wie Tailscale. Beim ersten Start
fragt die Windows-Firewall — „Privates Netz“ zulassen.

#### Claude Code

```powershell
claude mcp add --scope user nvai -- "<Repository-Ordner>\server\.venv\Scripts\python.exe" -m nvai.mcp_server
```

Danach stehen dort `health`, `generate_image`, `generate_video`, `image_to_3d` und die
Modellverwaltung als Werkzeuge bereit. Einzelheiten und Prompt-Hinweise:
[CLAUDE_CODE.md](../CLAUDE_CODE.md) (englisch).

#### Optional: 3D-Worker

Die Mesh-Erzeugung läuft in eigenen Prozessen mit eigenen Abhängigkeiten:

```powershell
scripts\setup_triposg.ps1     # Geometrie, MIT-Lizenz
scripts\setup_trellis2.ps1    # Geometrie + PBR-Texturen, braucht einen C++-Compiler
```

Beide Skripte erwarten das jeweilige Original-Repository bereits unter `external\triposg` bzw.
`external\trellis2`. TRELLIS.2 kompiliert eine CUDA-Erweiterung und setzt die **Visual Studio
2022 Build Tools** mit C++-Werkzeugen voraus. Ohne 3D-Bedarf kann beides entfallen.

#### Was wo liegt

```
server/             Orchestrator (FastAPI), MCP-Server, 3D-Worker (server/workers)
frontend/           Weboberfläche (React/Vite), gebaut nach frontend/dist/
scripts/            Einrichtung, Start, Stop
packaging/windows/  Windows-Setup (Inno Setup)
packaging/tools/    Hilfsskripte für Veröffentlichungen
mac/NVAIMac/        NV-AI für Mac (SwiftUI)
photocraft-addon/   PhotoCraft-Add-on
docs/               Dokumentation
data/               entsteht beim ersten Start: Modelle, Assets, Datenbank
external/           entsteht bei der Installation: ComfyUI
```

### Das Windows-Setup bauen

```powershell
cd frontend; npm install; npm run build; cd ..
packaging\windows\build-setup.ps1 [-Addon <Ordner>]
```

Voraussetzungen:

- **Inno Setup 6:** `winget install JRSoftware.InnoSetup --scope user`. Das Skript sucht
  `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`.
- **uv** und **Python 3** im `PATH`: `uv.exe` kommt ins Setup, Python führt den Generator für
  die Hinweise zu Fremdkomponenten aus (`packaging\tools\third_party_notices.py`).
- Die gebaute Weboberfläche (`frontend\dist`).

Das Skript stellt unter `packaging\windows\build\stage` nur zusammen, was ins Setup gehört: den
Server-Code mit den 3D-Workern (ohne venv), `pyproject.toml`, `openapi.json`, die gebaute
Weboberfläche, ComfyUI im getesteten Tag `v0.42.1` und TripoSG in einem festen Commit, `uv.exe`
samt Lizenztexten, die festgeschriebenen Paketlisten aus `packaging\windows\locks`, die Lizenz
und die erzeugten Hinweise zu Fremdkomponenten. ComfyUI und TripoSG kommen per `git archive` aus
lokalen Klonen unter `external\`, falls vorhanden (keine Modelle, kein venv, keine Ausgaben),
sonst von GitHub. Dann ruft das Skript Inno Setup auf. Ergebnis:
`packaging\windows\build\NV-AI-Setup-<Version>.exe`; die Version kommt aus
`server\nvai\__init__.py`.

- Das PhotoCraft-Add-on wird zur optionalen Komponente, wenn ein gebauter Add-on-Ordner (mit
  `requirements.lock`) gefunden wird: `-Addon <Ordner>`, sonst `$env:NVAI_ADDON_DIR`, sonst
  `photocraft-addon\dist\addon` (gebaut mit `photocraft-addon\tools\build_addon.py`). Ohne ihn
  entsteht das Setup ohne PhotoCraft-Komponente.
- Auf dem Ziel-PC richtet das Setup Python 3.12.13 im Programmordner ein und genau die
  Paketstände aus `locks\`, geprüft per sha256-Hash (`uv pip sync --require-hashes`): dieselben
  Stände, die getestet sind.
- Die mitgelieferten `.ps1`-Skripte müssen reines ASCII sein, denn Windows PowerShell 5.1 liest
  Skripte ohne BOM als ANSI. Das Bauskript prüft das.

### Die Mac-App bauen

Voraussetzungen: ein Mac mit Apple Silicon, Xcode mit der Metal Toolchain (einmalig
`xcodebuild -downloadComponent MetalToolchain`) und XcodeGen.

- Gebaut wird mit **xcodebuild**, nicht mit `swift build`: Die Metal-Shader von MLX übersetzt nur
  Xcode.
- `project.yml` ist die XcodeGen-Spezifikation; das erzeugte `.xcodeproj` liegt nicht im
  Repository.
- Die Paketstände sind in `Package.resolved` gepinnt.

Die Skripte in `mac/NVAIMac/scripts` erwarten das Projekt unter `~/NVAIMac` auf dem Mac:

| Skript | Was es tut |
|---|---|
| `sync.sh` | Für die Entwicklung unter Windows, aus Git Bash: überträgt `project.yml`, `Sources`, `Resources`, `scripts` und `Package.resolved` per SSH nach `~/NVAIMac` auf einen Mac, der als `macmini` erreichbar ist, und führt dort `xcodegen generate` aus (XcodeGen unter `~/tools/xcodegen/bin/xcodegen` erwartet). `~/NVAIMac` ist nur ein Spiegel: `Sources` wird bei jedem Abgleich ersetzt |
| `build.sh` | baut `~/NVAIMac/dd/Build/Products/Release/NV-AI.app` (Release, arm64, ad hoc signiert); Protokoll in `~/NVAIMac/build.log` |
| `release.sh` | baut die DMG (siehe unten) |

Direkt auf dem Mac: `mac/NVAIMac` nach `~/NVAIMac` kopieren, dort `xcodegen generate` ausführen
und `Package.resolved` nach `NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`
kopieren. Das sind die Schritte, die `sync.sh` auf dem Mac ausführt. Danach:

```sh
zsh ~/NVAIMac/scripts/build.sh
```

Starten zum Testen, mit Einstellungen, die beim Start überschrieben werden (`-serverPort`,
`-modelsDirectory`, `-activeModelID`):

```sh
open -n ~/NVAIMac/dd/Build/Products/Release/NV-AI.app --args -serverPort 8110 -modelsDirectory <Modellordner>
curl -s http://127.0.0.1:8110/api/version
```

- Ist der Port belegt, versucht es der Server alle 2 s erneut.
- Ohne Bildschirm prüfen: `NV-AI --snapshot <png> [--tab generate|history|models|search|settings] [--report <md>] --quit`
  fotografiert das eigene Fenster und braucht keine Bildschirmfreigabe; `--report` schreibt
  dabei den Messbericht.

#### Die DMG bauen

```sh
zsh ~/NVAIMac/scripts/release.sh
```

Ergebnis: `~/NVAIMac/release/NV-AI-<Version>.dmg` mit NV-AI.app, der App des PhotoCraft-Add-ons
und „Erste Schritte“. Die App des Add-ons baut dessen eigenes `build-app.sh` aus dem Ordner, den
`ADDON_SRC` oben im Skript nennt; fehlt es dort, entsteht die DMG ohne Add-on.

- **Mit „Developer ID Application“-Zertifikat** im Schlüsselbund werden die Apps signiert
  (Hardened Runtime, Zeitstempel), bei Apple notarisiert und gestapelt, danach ebenso die DMG.
  Für die Notarisierung braucht `notarytool` einen App-Store-Connect-API-Schlüssel; siehe
  `notarize()` im Skript.
- **Ohne Zertifikat** ist die DMG nur ad hoc signiert und nicht notarisiert. Gatekeeper
  blockiert sie auf fremden Macs; sie taugt nur für interne Tests.
- **Schlüsselbund gesperrt** in einer SSH-Sitzung: das Kennwort per stdin übergeben und
  `--unlock-from-stdin` anhängen. Einmalig nach einem neuen Zertifikat zusätzlich
  `--allow-codesign`, damit codesign den Signierschlüssel ohne Rückfrage nutzen darf.

---

## Optional: PhotoCraft-Add-on

**NV-AI für PhotoCraft** verbindet PhotoCraft mit einem lokalen NV-AI. Es braucht PhotoCraft ab
Version 0.10.0: https://github.com/storytold/photocraft/releases/latest

- **Windows:** eine optionale Komponente des Setups, enthalten in der vollständigen Installation
  (wenn das Setup mit dem Add-on gebaut wurde). Ist PhotoCraft noch nicht installiert, bietet das Setup an, die Download-Seite zu
  öffnen; fehlt die Microsoft-WebView2-Laufzeit, installiert es sie. Gestartet wird das Add-on
  über den Startmenü-Eintrag „NV-AI für PhotoCraft“. Es findet NV-AI über
  `HKCU\Software\NV-AI` und startet es bei Bedarf.
- **macOS:** in der DMG als „NV-AI für PhotoCraft“ enthalten. Es startet NV-AI bei Bedarf
  selbst; beide laufen nur lokal.

Das Add-on spricht NV-AI über die REST-Schnittstelle unter `http://127.0.0.1:8100` an und
arbeitet deshalb gleich mit NV-AI unter Windows und mit NV-AI für Mac. Sein Quelltext liegt in
[`photocraft-addon/`](../../photocraft-addon/).
