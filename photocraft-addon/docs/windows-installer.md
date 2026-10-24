# PhotoCraft-Add-on im Windows-Setup

Das Add-on (Brücke und Panel) ist eine optionale Komponente des NVAI-open-Setups („NVAI-open-Setup.exe“,
Inno Setup, pro Nutzer). Gedacht ist es für einen frisch installierten PC ohne Python, Git oder
Node. Den Rahmen (Inno Setup, uv, Python 3.12, Registry-Schlüssel, Verknüpfungen) baut die
NVAI-open-Seite. Hier steht, was das Add-on mitbringt, braucht und selbst erledigt.

## Ordner `addon\` bauen

```bat
python tools\build_addon.py [Ziel] [--check]
```

Standardziel ist `dist\addon`. Ein vorhandener Zielordner wird nur ersetzt, wenn er von diesem
Skript stammt (`addon.ini` darin). `--check` installiert danach wie das Setup ein venv aus dem
Lock (braucht `uv`), lädt die Brücke aus dem Ordner und entfernt das venv wieder. Das dauert etwa
7 s.

| Pfad | Zweck |
|---|---|
| `bridge\` | Brücke (Python-Paket, wird aus dem Ordner gestartet, nicht installiert) |
| `panel\` | Oberfläche (HTML/CSS/JS), dazu `icon.ico` für Fenster, Taskleiste und Verknüpfung |
| `requirements.lock` | 25 Laufzeitpakete, festgeschrieben auf den getesteten Stand, mit sha256 |
| `addon.ini` | Version und Startbefehl für das Setup-Skript, außerdem Kennzeichen „installiertes Add-on“ |

Tests, Golden-Daten, `PhotoCraftKit\` und `MacApp\` gehören nicht dazu. Das Symbol erzeugt
`python tools\make_icon.py` (Pillow). Es enthält 16 bis 128 px als BMP und 256 px als PNG. Liegen
alle Größen als PNG vor, scheitert .NET bzw. pywebview am 256er.

`addon.ini` enthält nur ASCII in den Werten, damit Inno Setup sie mit `ReadIni` lesen kann:

```ini
[addon]
version=0.3.0
python=3.12
requirements=requirements.lock
run=.venv\Scripts\pythonw.exe
parameters=-m bridge --launch
workdir=.
icon=panel\icon.ico
appusermodelid=NVAI.PhotoCraft
```

Beispiel: `#define AddonVersion ReadIni(SourcePath + "\addon\addon.ini", "addon", "version", "0")`.

## Installationsschritt

```bat
uv venv --python 3.12 "<addon>\.venv"
uv pip sync --python "<addon>\.venv\Scripts\python.exe" --require-hashes "<addon>\requirements.lock"
```

- Das venv ist etwa 32 MB groß, dazu kommt das gemeinsame Python 3.12. Heruntergeladen werden
  etwa 15 MB Wheels, mit gefülltem uv-Cache dauert es etwa 1 s.
- Geprüft: Ein frisches venv aus dem Lock besteht alle Tests, die Brücke startet, `/api/state`
  antwortet, das Panel wird ausgeliefert.

## Verknüpfung

| Feld | Wert |
|---|---|
| Name | NVAI-open for PhotoCraft (deutsches Setup: NVAI-open für PhotoCraft) |
| Ziel | `"<addon>\.venv\Scripts\pythonw.exe"` |
| Argumente | `-m bridge --launch` |
| Arbeitsordner | `<addon>` (die Brücke wird von dort geladen) |
| Symbol | `<addon>\panel\icon.ico` |
| AppUserModelID | `NVAI.PhotoCraft`, in Inno `AppUserModelID: "NVAI.PhotoCraft"` im Abschnitt `[Icons]` |

Die Brücke setzt dieselbe AppUserModelID für ihren Prozess. Die Taskleiste zeigt dann das Symbol
der Verknüpfung, und Anheften heftet die Verknüpfung an statt `pythonw.exe`. Es erscheint kein
Konsolenfenster. `--launch` startet bei lokaler NVAI-open auch NVAI-open, außerdem PhotoCraft mit
Steuerkanal, und öffnet dann das Panel. Ein zweiter Start holt das vorhandene Fenster nach vorn.

Vor Deinstallation und Update die Brücke beenden. Das ist `pythonw.exe` aus `<addon>\.venv`;
Port 8120 gehört ihr. Schließt man ihr Fenster, beendet sie sich. Läuft das Panel ohne WebView2
im Browser, gibt es kein Fenster, dann muss der Prozess beendet werden.

## Wie das Add-on NVAI-open findet

Unter `HKCU\Software\NV-AI` liest es folgende Werte:

- `InstallDir` (REG_SZ)
- `Version` (REG_SZ)
- `DataDir` (REG_SZ)
- `Port` (REG_DWORD, Standard 8100)

Die Adresse ist `http://127.0.0.1:<Port>`. Vorrang haben `NVAI_URL` und `nvai_url` in
`settings.json`, etwa für eine NVAI-open auf einem anderen Rechner.

- **Start:** über `<InstallDir>\nvai-start.cmd`, ohne Konsolenfenster. Das Skript startet NVAI-open,
  falls es nicht läuft, und kehrt sofort zurück. Endet es mit einem Fehlercode, zeigt das Panel
  diesen an. Danach steht dort bis zu 120 s „NVAI-open startet …“, bis NVAI-open antwortet. Bereit ist
  NVAI-open erst, wenn `/api/version` antwortet; die Brücke prüft das vor jedem Auftrag.
- **Ohne Eintrag** und ohne Entwicklungsordner meldet das Panel „NVAI-open ist auf diesem PC nicht
  installiert“.
- **Entwicklungsrechner:** Das installierte Add-on (mit `addon.ini`) gehört immer zum Setup. Aus
  dem Repository gestartet bleibt die Brücke beim Entwicklungsordner von NVAI-open (der Ordner darüber
  oder ein Nachbarordner `NVAI-open`, Port 8100), solange es den gibt. Eine Testinstallation des Setups
  auf demselben PC lenkt sie so nicht um.
  `NVAI_ROOT` bzw. `nvai_root` erzwingt den Entwicklungsordner.

## Wie das Add-on PhotoCraft findet

PhotoCraft installieren die Tester selbst. Weder das Setup noch die Brücke installieren es mit.
Die Brücke sucht bei jedem Statusabgleich neu, in dieser Reihenfolge:

1. `PHOTOCRAFT_EXE` bzw. `photocraft_exe` in `settings.json`, etwa für die portable Fassung.
2. `App Paths\photocraft.exe`, zuerst unter HKCU, dann unter HKLM. Dort trägt sich der
   PhotoCraft-MSI ein, auch wenn der ArtCraft Launcher ihn installiert hat.
3. `%ProgramFiles%\PhotoCraft\photocraft.exe`.

Die Version kommt aus der Versionsressource der exe. Ist sie älter als 0.10.0 (damit ist der
Steuerkanal vermessen), erscheint ein Hinweis mit Download-Knopf. Starten lässt sich PhotoCraft
trotzdem. Fehlt PhotoCraft ganz, zeigt das Panel „PhotoCraft ist nicht installiert“ mit Knopf
„PhotoCraft herunterladen“. Nach der Installation geht es ohne Neustart weiter.

Der Download-Link ist <https://github.com/storytold/photocraft/releases/latest>. Dort steht die Datei
`…-windows-x64.msi`. Die Seite getartcraft.com/apps/photocraft verlinkte im Oktober 2026 noch
0.7.0, während 0.10.0 aktuell war.

## Voraussetzungen

- **Keine Adminrechte.** Die Brücke lauscht nur auf 127.0.0.1:8120, der PhotoCraft-Steuerkanal auf
  127.0.0.1:47821. Dafür fragt die Firewall nicht nach.
- **Daten:** `%LOCALAPPDATA%\ArtCraft-LocalAI\` mit Steuer-Token, Austauschordner, Logs und
  `settings.json`. Mit `ARTCRAFT_LOCALAI_DATA` lässt sich der Ordner umlegen. Das Log
  `logs\bridge.log` nennt beim Start, welches NVAI-open und welches PhotoCraft gefunden wurde.
- **Microsoft Edge WebView2 Runtime** für das Panel-Fenster (pywebview 6.2.1, dazu .NET Framework ab
  4.6.2). Unter Windows 11 ist sie vorinstalliert, unter Windows 10 nicht immer. Das Setup sollte
  sie bei Bedarf pro Nutzer installieren, das geht ohne Adminrechte. Fehlt sie trotzdem, öffnet die
  Brücke das Panel im Standardbrowser. Es läuft dann vollständig, nur nicht als eigenes Fenster.
  Erkennung: Wert `pv` unter `HKCU|HKLM\SOFTWARE\[WOW6432Node\]Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`.

## Lock erneuern

Nach einem Paket-Update im Entwicklungs-venv und grünen Tests:

```bat
uv pip freeze --python .venv\Scripts\python.exe > %TEMP%\tested.txt
uv pip compile pyproject.toml -c %TEMP%\tested.txt --python-version 3.12 ^
  --python-platform x86_64-pc-windows-msvc --generate-hashes --no-header --no-annotate -o requirements.lock
```

Die drei Kommentarzeilen am Anfang von `requirements.lock` danach wieder einsetzen.
`tools\build_addon.py` prüft, dass jedes Paket aus `pyproject.toml` im Lock steht und eine
Prüfsumme hat.
