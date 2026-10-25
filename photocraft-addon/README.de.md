# NVAI-open für PhotoCraft – lokale KI als Haupt-KI in PhotoCraft

*English: [README.md](README.md)*

Ein schlankes Panel-Fenster neben PhotoCraft, das die lokale Bildgenerierung von **NVAI-open**
(eigene GPU, keine Cloud) in den Bildbearbeitungs-Alltag holt – ähnlich wie Photoshops
„Generative Füllung“:

| Modus | Was passiert |
|---|---|
| **Füllen** | Die Auswahl wird passend zur Umgebung neu erzeugt (Inpainting). Ohne Prompt setzt sich die Umgebung fort – praktisch zum Wegretuschieren. Ohne Auswahl werden transparente Ränder gefüllt, etwa nach *Bild › Arbeitsfläche* mit transparenter Erweiterung (Outpainting) – dann hilft ein Prompt, der die Szene kurz beschreibt. Der Modus **Erweitern** macht das in einem Schritt. Ab NVAI-open 0.5.6 füllt auch FLUX 3 und wird genommen, wenn kein anderes Modell gewählt ist: NVAI-open färbt den Bereich grau, lässt FLUX 3 malen und setzt nur die Auswahl ausgerichtet zurück. Im Test entfernte es Kisten mit durchlaufendem Pflaster; um etwas Vorhandenes zu ändern, etwa die Schrift auf einem Schild, hielt **Überarbeiten** mit FLUX 3 Lage und Neigung besser. |
| **Erweitern** | Outpainting (seit 0.4.3 eigener Modus): links, oben, rechts, unten in Pixeln eingeben (oder „breiter“, „höher“, „nach unten“, „rundum“ wählen); das Add-on vergrößert die Arbeitsfläche und malt den neuen Rand passend dazu. Angeboten wird jedes Modell, das erweitern kann, FLUX 3 zuerst: im Test nahtlos, während Qwen an der alten Bildkante eine harte Naht ließ. Auf dem Mac ist es FLUX.2 Klein per Maske; dort bleibt der Übergang weicher und kann an der alten Bildkante als unscharfer Streifen sichtbar bleiben. Braucht NVAI-open ab 0.5.4 (Mac: 0.4.3). |
| **Generieren** | Ein neues Bild in der Auswahl – oder auf der ganzen Arbeitsfläche, wenn nichts ausgewählt ist. |
| **Überarbeiten** | Die Auswahl (oder das ganze Bild) wird neu gerechnet. Mit Qwen per Bild-zu-Bild – die *Stärke* bestimmt, wie viel sich ändert. Mit **FLUX 3** per Referenzbild: Der Prompt sagt, was sich ändert und was gleich bleibt („Replace the rope handles with iron handles; keep everything else unchanged.“). |
| **Restaurieren** | Für alte Fotos (seit 0.4.6, braucht NVAI-open 0.5.11): **Schäden entfernen** (Kratzer, Staub, Risse, Flecken), **einfärben** und mit SeedVR2 **schärfen und vergrößern**, jeder Schritt abwählbar, für die Auswahl oder das ganze Bild. *Automatisch* (Vorgabe) lässt das Bildmodell von NVAI-open das Foto auf Wasserflecken und Rissnetze prüfen und wählt *Gründlich* oder *Schonend* (bei 20 von 21 Testfotos wie erwartet). *Gründlich* rechnet das ganze Foto mit FLUX 3 neu: Risse, feine Kratzer, Wasserflecken und Ausbleichen verschwinden, Gesichter können je Variante leicht abweichen. *Schonend* ersetzt nur die beschädigten Stellen und behält Schärfe, Gesichter und Details genau wie im Foto (Kontrast und Verblassen kommen von FLUX 3). Gewählt wird nach der Art des Schadens: flächige Alterung (Wasserflecken, Craquelé, Korn, Ausbleichen) → *Gründlich*; einzelne Schäden auf einem sonst guten Foto (Staub, Kratzer, Risse, Lichteinfall) → *Schonend*. Beim Einfärben kommt nur die Farbe von FLUX 3; bekannte Farben im Prompt („her dress is dark red“) machen es genauer. Ein Graustufendokument, das eingefärbt wird, landet in einem neuen RGB-Dokument „<Name> – farbig“ mit dem Original als unterster Ebene (PhotoCraft lässt Add-ons den Farbmodus nicht ändern). Vergrößern skaliert das ganze Dokument und geht deshalb nur ohne Auswahl. Gemessen auf einer RTX 5060 Ti: zwei Varianten eines 1-MP-Fotos, schonend repariert, eingefärbt und 2× vergrößert, in rund 3 Minuten. |

Jedes Ergebnis landet als **eigene Ebene mit Ebenenmaske aus der Auswahl** im Dokument – nichts
wird zerstörend überschrieben. Bei mehreren Varianten tauscht ein Klick im Panel die Ebene aus,
**+** legt eine Variante zusätzlich an. Die Auswahl bleibt danach aktiv, sodass sofort der nächste
Versuch möglich ist.

## So funktioniert es

```
PhotoCraft (mit --control gestartet)          NVAI-open (:8100)  →  ComfyUI (:8188)
        ▲   JSON-Zeilen über 127.0.0.1:47821        ▲  REST
        │   (Token-geschützt)                       │
        └──────────── Brücke (:8120) ───────────────┘
                     + Panel-Fenster
```

1. **Erfassen** – Vom aktiven Dokument entsteht kurz eine reduzierte Arbeitskopie. Daraus
   werden Ausschnitt und Auswahlmaske in einen Austauschordner exportiert. Dein Dokument und
   sein Protokoll bleiben dabei unberührt.
2. **Rechnen** – Ausschnitt und Maske gehen in Arbeitsgröße (~1 Megapixel) an NVAI-open.
3. **Einfügen** – Das Ergebnis wird an exakt der richtigen Stelle als Ebene eingefügt und
   bekommt die Auswahl als Maske.

PhotoCraft selbst bringt (Stand 0.10) **keine** generative KI mit, und seine Plug-ins laufen in
einer Sandbox ohne Netzwerk. Der Steuerkanal ist deshalb der einzige saubere Weg.

## Einrichten

```powershell
scripts\setup.ps1              # venv (Python 3.12) + Abhängigkeiten + Tests
scripts\install_shortcut.ps1   # Verknüpfung „NVAI-open for PhotoCraft“ (Desktop + Startmenü)
```

Voraussetzungen:

- **PhotoCraft 0.10 oder neuer.** Die Brücke findet es über den Eintrag, den der PhotoCraft-Installer
  unter *App Paths* anlegt. Ein portables PhotoCraft trägt man in `settings.json` als
  `"photocraft_exe"` ein. Fehlt PhotoCraft oder ist es älter, zeigt das Panel einen Download-Knopf.
- **NVAI-open**, entweder als Entwicklungsordner (der Ordner über diesem bzw. ein Nachbarordner `NVAI-open`)
  oder per NVAI-open-Setup installiert (`HKCU\Software\NV-AI`).

Auf Tester-PCs kommt die Brücke als Add-on des NVAI-open-Setups, siehe
[`docs/windows-installer.md`](docs/windows-installer.md).
Für **Füllen** braucht NVAI-open Masken (`mask_asset_id`, ab NVAI-open 0.2.0). Generieren und Überarbeiten
laufen auch ohne sie.

**Sprache:** Englisch ist Standard, Deutsch wählbar – im Panel unten rechts („Automatisch“ folgt der
Systemsprache), in der Mac-App unter *Einstellungen*. NVAI-open bekommt die Sprache als
`Accept-Language` und liefert seine Modelltexte danach.

## Benutzen

1. Ein normal gestartetes PhotoCraft speichern und schließen – es lässt sich nachträglich nicht
   anbinden.
2. **„NVAI-open for PhotoCraft“** starten. Das startet bei Bedarf NVAI-open (minimiertes Konsolenfenster),
   PhotoCraft mit Steuerkanal und das Panel.
3. In PhotoCraft eine Auswahl treffen, im Panel Modus und Prompt wählen, **Strg + Enter**.

Tipps (Modellwahl nach `BILDMODELLE.md` von NVAI-open):

- Englische Prompts in ganzen Sätzen treffen am genauesten. Unter dem Prompt steht die
  Kurzanleitung, die NVAI-open für das gewählte Modell mitliefert.
- Nur ein paar Worte? **✨ Prompt ausbauen** unter dem Prompt lässt NVAI-open daraus eine volle
  Bildbeschreibung schreiben. Windows: rund 15 s, braucht NVAI-open ab 0.4 mit geladenem FLUX 3.
  Mac: rund 25 s auf einem M1 mit 8 GB, braucht NVAI-open für Mac ab 0.4 mit geladenem FLUX.2 Klein
  (dessen Text-Encoder schreibt die Beschreibung, kein zusätzlicher Download). Vor dem Start lesen
  und streichen, was erfunden wurde; „Zurück zum eigenen Prompt“ nimmt es zurück.
- Lädt NVAI-open gerade ein Modell, zeigt das Panel den Download mit Fortschritt und einem ✕ zum
  Abbrechen (sofort ab NVAI-open 0.5.2 bzw. Mac 0.4.2; ältere Fassungen brechen alle Downloads ab).
- **Qwen-Image-2512** für Endergebnisse, Schrift und Konstruktion; **FLUX 3** fürs gezielte
  Ändern eines vorhandenen Bereichs (Teil ersetzen, Farbe, Material). FLUX 3 steht unter der
  FLUX Kommunity License (Umsatzgrenze, Prüfpflicht) – das Panel zeigt den Hinweis an.
- Für **neue Objekte** beim Füllen das volle Qwen-Modell nehmen. Lightning setzt dort fast nur
  die Umgebung fort – gut zum Wegretuschieren.
- Die Brücke rechnet Qwen voll standardmäßig mit 28 statt 50 Schritten (~55 s statt ~100 s je
  Megapixel). Unter *Erweitert › Schritte* lässt sich das überschreiben.
- *Erweitert › Native Auflösung* rechnet in der Trainingsauflösung des Modells (Qwen 1328²,
  FLUX 3 1440²): mehr Detail, etwa doppelte Zeit.
- Bei FLUX 3 zeigt das Panel unter dem Ergebnis die **Bildbeschreibung des Upsamplers**. Passt
  das Bild nicht, steht der Fehler oft schon dort – dann den Prompt ergänzen statt neu würfeln.
- FLUX 3 zeichnet beim Bearbeiten den ganzen Ausschnitt neu: Aufbau und Farben bleiben, die
  Feinstruktur weicht leicht ab (gemessen ~10 von 255). Die Ebenenmaske begrenzt das auf die
  Auswahl.
- Passt das in NVAI-open aktive Modell nicht zum Modus, nimmt die Brücke ein passendes und sagt es.
- **Esc** bricht einen laufenden Auftrag ab – nur den eigenen; NVAI-open kann parallel anderweitig
  benutzt werden.
- Das Pin-Symbol oben rechts hält das Panel im Vordergrund.

## Grenzen

- **Doppelklick im Explorer** öffnet, solange das angebundene PhotoCraft läuft, ein zweites
  PhotoCraft-Fenster ohne Anbindung (PhotoCraft schaltet die Einzelinstanz bei `--control` ab).
  Dateien deshalb über *Datei › Öffnen* oder per Drag & Drop ins Fenster holen.
- Die Modelle rechnen mit rund 1 Megapixel. Sehr große Auswahlen werden entsprechend
  hochskaliert und wirken weicher – dann in Teilen füllen.
- Während ein Auftrag erfasst oder eingefügt wird, blitzt in PhotoCraft kurz ein Hilfs-Tab auf.
- **Restaurieren:** Kleine Zeichen, die FLUX 3 weglässt, etwa ein Bindestrich in einer Beschriftung,
  verschwinden in beiden Arten – Schrift prüfen. An gleich hellen Kanten kann Farbe überlaufen.

## NVAI-open auf einem anderen Rechner

NVAI-open muss nicht auf demselben PC laufen, etwa über Tailscale. Adresse und Token stehen in
`%LOCALAPPDATA%\ArtCraft-LocalAI\settings.json` (oder in den Umgebungsvariablen `NVAI_URL` /
`NVAI_TOKEN`):

```json
{"nvai_url": "http://pc-name:8100", "nvai_token": "…"}
```

Der Token geht als Header `X-NVAI-Token` mit. Ab NVAI-open 0.2.0 gilt: Vom eigenen Rechner braucht es
keinen Token, von anderen Rechnern für alles außer `/api/health` und `/api/version`. Damit andere
Rechner überhaupt zugelassen werden, muss NVAI-open dort mit `scripts\start.ps1 -Lan` laufen. Den Token
findet man dann in `data\api_token` von NVAI-open. Fehlt der Token oder passt er nicht, sagt das
Panel das. Nach dem Eintragen genügt **Erneut prüfen**, ein Neustart der Brücke ist nicht nötig.

Selbst gestartet wird NVAI-open nur, wenn die Adresse lokal ist; sonst zeigt das Panel, unter welcher
Adresse es NVAI-open erwartet.

Die Brücke spricht Version 1 des NVAI-open-Vertrags. Er liegt als Kopie unter
`contract/nvai-openapi.json`, und `tests/test_contract.py` prüft beide Clients dagegen. Meldet
NVAI-open über `/api/version` eine andere Version, verweigert das Panel die Arbeit mit einem Hinweis.

## Mac-App „NVAI-open für PhotoCraft“

`MacApp/` ist das Panel als native Mac-App (SwiftUI auf `PhotoCraftKit`). Sie kann dasselbe wie das
Windows-Panel: Füllen, Generieren, Überarbeiten, Varianten tauschen und PhotoCraft mit Steuerkanal
starten. Das Fenster bleibt auf Wunsch über PhotoCraft (Stecknadel oben rechts).

- **Bauen und installieren** (auf dem Mac, mit `PhotoCraftKit/` daneben): `MacApp/build-app.sh` baut
  die App im Release-Modus mit Hardened Runtime und legt `NVAI-open for PhotoCraft.app` auf den
  Schreibtisch. Ein anderer Zielordner geht als Argument. Ohne weitere Angabe wird ad hoc signiert;
  für die Weitergabe signiert `--sign "Developer ID Application: …"` mit Zeitstempel, danach lässt
  sich die App notarisieren.
- **PhotoCraft** findet die App über seine Bundle-ID, egal in welchem Ordner. Fehlt es oder ist es
  älter als 0.10.0, zeigt sie einen Hinweis mit Download-Knopf.
- **NVAI-open:** Im Normalbetrieb läuft „NVAI-open für Mac“ auf demselben Mac unter
  `http://127.0.0.1:8100`, ohne Token. Läuft es nicht, startet der Knopf **NVAI-open starten** es im
  Hintergrund. Eine NVAI-open auf einem anderen Rechner geht auch: Adresse und Token unter
  *Einstellungen …* (⌘,) oder im Hinweis „NVAI-open verbinden“ eintragen, dann **Verbindung prüfen**.
- **Daten:** `~/Library/Application Support/ArtCraft-LocalAI/` enthält `settings.json` (nur für den
  Nutzer lesbar), das Steuer-Token für PhotoCraft, den Austauschordner und `logs/mac-app.log`.
- **Fehlersuche ohne Bildschirm** (etwa per ssh):
  - `…/Contents/MacOS/NVAIPhotoCraft --selftest` prüft Einstellungen, PhotoCraft und NVAI-open.
  - `open -n "NVAI-open for PhotoCraft.app" --args --snapshot /tmp/panel.png --quit` speichert ein
    Bild des Fensters; mit `--run "<prompt>"` vorher einen Auftrag „Generieren“ mit einer Variante.

## Mac-Fassung

Die Mac-App bekommt das Add-on als natives Swift-Modul. Grundlage hier im Repository:

- [`docs/mac-port.md`](docs/mac-port.md) – Spezifikation: jeder Steuerbefehl mit Parametern,
  Antwort und Fallen, der komplette Ablauf, Geometrie, Planung, NVAI-open-Nutzung.
- `golden/*.json` – Golden-Testdaten aus der Python-Referenz (`python tools/export_golden.py`).
- `contract/nvai-openapi.json` – API-Vertrag von NVAI-open (Kopie; erneuern mit
  `python tools/export_golden.py --refresh-contract`).
- `PhotoCraftKit/` – Swift-Paket ohne Oberfläche (Steuerclient über Network.framework,
  NVAI-open-Client, Core-Image-Aufbereitung, Planung, Ablauf). Tests mit `swift test`; die
  Golden-Daten liegen als Kopie unter `PhotoCraftKit/Tests/PhotoCraftKitTests/Golden`.
- `tools/chain_probe.py` – prüft die komplette Steuerkette gegen eine PhotoCraft-Testinstanz
  (nur Standardbibliothek; unter Windows und macOS identische Ergebnisse).

## Dateien und Daten

| Pfad | Inhalt |
|---|---|
| `bridge/` | Brücke: PhotoCraft-Client, NVAI-open-Client, Bildaufbereitung, Planung, Aufträge, HTTP-Server, Fenster |
| `panel/` | Oberfläche (HTML/CSS/JS, ohne Build-Schritt) |
| `%LOCALAPPDATA%\ArtCraft-LocalAI\` | Laufzeitdaten: Token, Austauschordner, Logs, Fensterposition |
| `…\exchange\jobs\<id>\` | Ausschnitt, Maske, Ergebnisse je Auftrag (nach 3 Tagen gelöscht) |
| `…\logs\bridge.log` | Protokoll der Brücke |

Das Steuer-Token (`photocraft-control.token`) erlaubt die volle Fernsteuerung von PhotoCraft –
es liegt deshalb nur nutzerbezogen unter `%LOCALAPPDATA%`. PhotoCraft darf per Fernsteuerung
ausschließlich im Austauschordner lesen und schreiben.

## Fehlersuche

| Meldung | Ursache |
|---|---|
| „PhotoCraft ist nicht installiert“ | PhotoCraft über den Knopf im Panel laden (Datei `…-windows-x64.msi`). Ein portables PhotoCraft in `settings.json` als `photocraft_exe` eintragen |
| „PhotoCraft … ist älter als 0.10.0“ | Mit älteren Versionen ist der Steuerkanal nicht getestet, also aktualisieren |
| „NVAI-open ist auf diesem PC nicht installiert“ | Weder das NVAI-open-Setup (`HKCU\Software\NV-AI`) noch der Entwicklungsordner wurde gefunden |
| „In NVAI-open ist noch kein Bildmodell installiert“ | Frische Installation: In NVAI-open (Knopf **NVAI-open öffnen**) ein Bildmodell laden. Das Panel merkt es von selbst |
| „PhotoCraft läuft bereits ohne NVAI-open-Anbindung“ | Normal gestartetes PhotoCraft schließen, dann im Panel neu starten |
| „kennt noch keine Masken“ | NVAI-open ohne Masken-Erweiterung oder noch nicht neu gestartet |
| „Token fehlt oder ist falsch“ | Entferntes NVAI-open: Token in `settings.json` eintragen, dann **Erneut prüfen** |
| „nimmt nur Anfragen vom eigenen Rechner an“ | Entferntes NVAI-open läuft ohne `-Lan` – dort mit `scripts\start.ps1 -Lan` starten |
| „spricht API-Version …“ | Brücke und NVAI-open passen nicht zusammen – die ältere Seite aktualisieren |
| „Das Zieldokument … ist nicht mehr geöffnet“ | Dokument während des Auftrags geschlossen oder in der Größe geändert |
| „NVAI-open hat den Auftrag abgebrochen (… Serverneustart …)“ | NVAI-open wurde währenddessen neu gestartet – einfach erneut auslösen |

Entwicklung: `python -m bridge --server` startet nur die Brücke (Panel dann unter
http://127.0.0.1:8120), `python -m pytest` die Tests (darunter der Abgleich der Golden-Daten).

Für das Windows-Setup auf einem frischen PC hält `requirements.lock` die getesteten Paketstände fest,
mit Hashes. `python tools/build_addon.py --check` stellt daraus den Ordner `dist\addon` für das
NVAI-open-Setup zusammen und prüft ihn. Wie das Add-on in das NVAI-open-Setup kommt, steht in
[`docs/windows-installer.md`](docs/windows-installer.md).
