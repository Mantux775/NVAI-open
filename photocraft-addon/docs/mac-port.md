# Spezifikation: PhotoCraft-Add-on als Swift-Modul (PhotoCraftKit)

Referenz ist die Python-Brücke in diesem Repository (`bridge/`). Der Swift-Port bildet ihr
Verhalten nach und prüft sich gegen dieselben Golden-Daten (`golden/*.json`). Alle Angaben zum
Steuerkanal sind an **PhotoCraft 0.10.0** unter Windows 11 und macOS 26.6 (Mac mini M1) gemessen
(`tools/chain_probe.py`, 18.10.2026). Beide Plattformen verhalten sich in allen 46 Prüfschritten
gleich; exportierte PNGs sind bitgleich.

| Teil | Python (Windows) | Swift (macOS) |
|---|---|---|
| Steuerkanal | `bridge/photocraft.py`, Socket | `ControlClient`, Network.framework (`NWConnection`) |
| PhotoCraft starten | `bridge/launcher.py`, `subprocess` | `NSWorkspace.openApplication` bzw. `open -n` |
| NVAI-open | `bridge/nvai.py`, httpx | `NVAIClient`, URLSession |
| Bildaufbereitung | `bridge/imaging.py`, Pillow | `Imaging`, Core Image |
| Planung | `bridge/planning.py` | `Planning` (reine Funktionen) |
| Ablauf | `bridge/tasks.py` | `Workflow` |
| Oberfläche | `panel/` (HTML in pywebview) | natives schwebendes Fenster (nicht Teil von PhotoCraftKit) |

**Stand PhotoCraftKit (19.10.2026, Mac mini M1, macOS 26.6, Swift 6.4, Version 0.3.0):** 45 Tests grün:
- Golden-Daten: Geometrie und Planung exakt, Bildaufbereitung in Toleranz.
- Replay aller fünf Befehlsmitschnitte.
- Protokolltests gegen einen lokalen Fake-Server.
- Vertragstests gegen den NVAI-open-Vertrag (§7).
- PhotoCraft finden und Versionsvergleich, mit denselben Fällen wie die Brücke.

Dazu kommen zwei Live-Tests:
- gegen eine echte PhotoCraft-Testinstanz: Erfassen, zwei Varianten einfügen und tauschen, Maske,
  Auswahl, „Zuletzt geöffnet“;
- ein echter Auftrag „Füllen“ mit NVAI-open: Qwen-Image, 28 Schritte, 82 s; Ebene mit Maske, Uploads
  danach gelöscht.

Keine Warnungen; Bibliothek und Tests bauen auch im Swift-6-Sprachmodus.

```sh
cd PhotoCraftKit && swift test
PHOTOCRAFT_LIVE_PORT=47899 PHOTOCRAFT_LIVE_TOKEN=<token-datei> PHOTOCRAFT_LIVE_EXCHANGE=<austausch> \
  NVAI_LIVE_URL=http://127.0.0.1:8100 swift test --filter LivePhotoCraftTests
```

**Mac-App:** `MacApp/` ist das Panel als SwiftUI-App auf PhotoCraftKit. `build-app.sh` legt sie auf den
Schreibtisch, siehe README. Ein Auftrag über die Oberfläche selbst ist geprüft: Generieren mit
FLUX 3, eine Variante, 32 s, eingefügt und als Ergebnis angezeigt; dazu `--snapshot … --run`. Im
Normalbetrieb laufen NVAI-open und PhotoCraft beide auf dem Mac, NVAI-open also unter 127.0.0.1:8100.

---

## 1. PhotoCraft mit Steuerkanal starten

PhotoCraft lauscht nur, wenn es mit `--control <port>` startet. Die Einstellung
„Agentensteuerung erlauben“ (`integrations.allowAgentControl/controlPort`) ist in 0.10
wirkungslos (`crates/engine/src/prefs.rs`: „governed by the launch flags … not by these yet“).

```
PhotoCraft --control 47821
           --control-token-file <privat>/photocraft-control.token
           --automation-read-root  <austausch>
           --automation-write-root <austausch>
```

- **macOS:** `open -n -a /Applications/PhotoCraft.app --args …` oder
  `NSWorkspace.shared.openApplication(at:configuration:)` mit
  `configuration.arguments` und `configuration.createsNewApplicationInstance = true`.
  `--new-instance` gibt es auf dem Mac nicht. Für Tests zusätzlich
  `PHOTOCRAFT_CONFIG_DIR=<eigener Ordner>` (`open --env …` bzw. `configuration.environment`),
  sonst teilt sich die Testinstanz Einstellungen und Wiederherstellung mit der echten.
- Fehlt die Token-Datei, legt PhotoCraft sie mit einem neuen 256-Bit-Token an (64 Hex-Zeichen).
  Ablage nutzerbezogen und nur für den Nutzer lesbar: Windows `%LOCALAPPDATA%\ArtCraft-LocalAI`,
  macOS sinnvollerweise `~/Library/Application Support/ArtCraft-LocalAI` mit Modus `0600`.
- Lese- und Schreibwurzel sind **ein** Austauschordner (`…/exchange`); alle Pfade in Befehlen
  sind relativ dazu und mit `/` getrennt. Absolute Pfade außerhalb, `..` und Laufwerksangaben
  lehnt PhotoCraft ab.
- `--control` schaltet die Einzelinstanz-Übergabe ab. Unter Windows öffnet ein Doppelklick im
  Explorer dann ein zweites Fenster ohne Anbindung. Läuft schon ein PhotoCraft **ohne**
  Steuerkanal, lässt es sich nicht nachträglich anbinden – nicht stillschweigend daneben
  starten, sondern zum Schließen auffordern (Python: `LaunchError`, Knopf „Zusätzlich starten“).
- Testinstanz auf dem Mac beenden nur gezielt: `kill $(pgrep -f "PhotoCraft --control <port>")`.
- **PhotoCraft finden:** `PhotoCraftLaunch.installedApp()` sucht über die Bundle-ID
  `ai.storyteller.photocraft` (Launch Services, egal in welchem Ordner) und fällt auf
  `/Applications/PhotoCraft.app` zurück. Die Version kommt aus `CFBundleShortVersionString`.
  Getestet ist 0.10.0 (`testedVersion`), ältere bekommen einen Hinweis. Fehlt PhotoCraft, zeigt
  die App „PhotoCraft ist nicht installiert“ mit Knopf zu `downloadURL`. Das ist die neueste
  GitHub-Veröffentlichung, Datei `…-macos-universal.dmg`; getartcraft.com verlinkte noch 0.7.0.
  Windows macht dasselbe über App Paths (`bridge/config.py`).

`instance.json` im Einstellungsordner gehört zur Einzelinstanz-Übergabe (Dateien in den
laufenden Prozess schicken), **nicht** zur Steuerung: Eine Anmeldung dort scheitert mit
„not taken“.

## 2. Transport

- TCP auf `127.0.0.1:<port>`, nur Loopback. Eine JSON-Zeile je Anfrage, eine je Antwort (UTF-8,
  `\n`). Anfrage `{"id", "method", "params"}`, Antwort `{"id", "ok", "result"}` oder
  `{"id", "ok": false, "error"}`.
- **Erste Zeile jeder Verbindung:** `{"id":"auth","method":"auth","params":{"token":"<64 hex>"}}`.
  Bei Fehlschlag schließt PhotoCraft die Verbindung. Ein zweites `auth` ergibt
  `"already authenticated"`, die Verbindung bleibt.
- Antworten mit fremder `id` (aus abgebrochenen Anfragen) überspringen.
- PhotoCraft antwortet spätestens nach 60 s: `timeout: not run` (nie gestartet, gefahrlos
  wiederholbar) bzw. `timeout: no reply in 60s` (läuft womöglich noch). Client-Timeout darunter
  (Python 65 s Lesezeit, MCP-Bridge 55 s).
- Leerlauf: PhotoCraft schließt nach 30 s. Vor einem Befehl nach > 20 s Leerlauf neu verbinden.
- Grenzen: Anfragezeile ≤ 1 MiB, Antwort ≤ 8 MiB, ≤ 16 Verbindungen.
- **Wiederholen:** Reine Lesebefehle (`ui.inspect`, `document.inspect`, `prefs.get`) nach einem
  Verbindungsfehler einmal neu senden. Bearbeitungen nie, sobald sie abgeschickt waren – nur wenn
  schon das Schreiben scheiterte. Fehlermeldung dann „wurde eventuell trotzdem ausgeführt“.
- Ein Swift-Client serialisiert alle Anfragen über **eine** Verbindung (Actor); mehrschrittige
  Abläufe (Erfassen, Einfügen) zusätzlich unter einer Sperre, damit die Statusabfrage nicht
  dazwischenfunkt.

## 3. Befehlsreferenz

Nur diese Befehle braucht die Brücke. „Gemessen“ heißt: Windows und macOS identisch.

| Befehl | Parameter | Antwort / Wirkung | Fallen |
|---|---|---|---|
| `ui.inspect` | – | `session.active`, `session.documents[{index,name,width,height,dirty,revision}]`, `document` (wie `document.inspect` des aktiven), `dialogs[]` | ~8 KB, als Statusabfrage alle 1–1,5 s tragbar |
| `engine.execute` `document.inspect` | – | `name,width,height,hasSelection,selectionBounds[x,y,w,h],activeLayer,layers[],channels.alpha[]` | `selectionBounds` umfasst weiche Kanten: Ellipse 400,250 300×220 mit `feather:4` → `[389,239,322,242]`. `layers` von oben nach unten; Gruppen haben `children` |
| `image.duplicate` | `{"name","mergedOnly":true}` | `{"document":i,"name"}`; neue reduzierte Kopie wird aktiv, **übernimmt die Auswahl**, nicht „dirty“ | – |
| `select.saveSelection` | `{"name":"NVAI-open Auswahl"}` | `{"channel","document","name"}`; Alphakanal im aktiven Dokument | macht das Dokument „dirty“ |
| `image.crop` | `{"x","y","width","height"}` | Dokument beschnitten, **Auswahl aufgehoben**, Kanäle mit beschnitten | Auswahl deshalb vorher als Kanal sichern |
| `app.save` | `{"path":"jobs/<id>/context.png"}` | `{"path","warnings"}`; flacher PNG-Export als **Kopie** (Dokumentpfad bleibt, kein Eintrag in „Zuletzt geöffnet“) | Elternordner muss existieren; nur unter der Schreibwurzel |
| `engine.execute` `channel.duplicate` | `{"channel":"NVAI-open Auswahl","document":"new"}` | `{"document":i}`; neues Graustufendokument wird aktiv; weiß = ausgewählt | – |
| `engine.execute` `file.close` | `{"document":i}` | schließt **ohne Rückfrage, auch ungespeichert** | Nur für eigene Hilfsdokumente! Danach wird der **Nachbar-Tab** aktiv (geschlossen i bei aktivem i → `min(i, n-1)`), nicht das vorige Dokument |
| `ui.menu.invoke` | `{"id":"window.document.<i>"}` | `{"document":i}`; holt Tab i nach vorn | Bei offenem modalem Dialog: „menu command is unavailable while a modal dialog is open“ |
| `app.open` | `{"path":"jobs/<id>/result-1.png"}` | `{"path","name","warnings"}`; neues Dokument wird aktiv | Trägt den Pfad unter „Zuletzt geöffnet“ ein. Große Dateien können als Hintergrundauftrag laden → `ui.inspect` abfragen, bis das aktive Dokument `name` heißt |
| `engine.execute` `layer.copyToDocument` | `{"document":ziel,"source":quelle,"layers":[id],"offset":[x,y],"name"}` | `{"document","layers":[neueId],"offset"}`; Ebene im Ziel über dessen aktiver Ebene, Ziel wird aktiv | Ersetzt das gesperrte `file.placeEmbedded`. Hintergrund der Quelle kommt als normale Ebene an |
| `layer.layerMask.revealSelection` | `{"layer":id}` | Ebenenmaske aus der Auswahl | **hebt die Auswahl auf** |
| `select.loadSelection` | `{"channel":"mask","layer":id}` | Auswahl aus der Ebenenmaske | so wird die Auswahl nach dem Einfügen wiederhergestellt |
| `layer.select` | `{"layer":id}` | aktive Ebene | – |
| `layer.delete` | `{"layer":id}` | löscht ohne Rückfrage (per `engine.execute`) | – |
| `prefs.get` / `prefs.set` | `{"path":"fileHandling.recentFiles"[,"value":[…]]}` | Liste der zuletzt geöffneten Dateien | Nach `app.open` alle Einträge entfernen, die mit `jobs/` beginnen. Die Oberfläche übernimmt die Liste jede Frame |
| `ui.focus` | – | Fenster nach vorn | – |
| `ui.screenshot` | `{"path"}` | PNG des Fensters unter der Schreibwurzel, `{width,height,path}` | Retina: Mac 1440×900, Windows 2160×1350 (je nach Bildschirm) |

**Gesperrt** über den Steuerkanal („uses ambient filesystem paths“): alle `file.*` mit Pfad
(`file.open`, `file.placeEmbedded`, `file.save*`, Exporte mit `dir`/`path`), `layer.exportAs`,
Plug-in-Installation, `prefs.set` auf `plugIns`, `scriptEvents`, `colorSettings`,
`historyLog`, `scratchDisks`. Datei-Ein/Ausgabe nur über `app.open`/`app.save`.

## 4. Ablauf

### 4.1 Erfassen

1. `ui.inspect` → Zieldokument (`session.active`, `name`, Größe), Auswahl (`hasSelection`,
   `selectionBounds`). Kein Dokument → Fehler.
2. Ausschnitt `region` nach §5.2 bestimmen (Modus, Auswahl, Arbeitsfläche).
3. Nur wenn Kontext (Füllen, Überarbeiten) oder Maske (Auswahl vorhanden) gebraucht wird:
   1. `image.duplicate {"name":"NVAI-open Arbeitskopie","mergedOnly":true}` → `dup`
   2. mit Auswahl: `select.saveSelection {"name":"NVAI-open Auswahl"}`
   3. `region ≠ Arbeitsfläche`: `image.crop` auf `region`
   4. mit Kontext: `app.save {"path":"jobs/<id>/context.png"}`
   5. mit Auswahl: `channel.duplicate {…,"document":"new"}` → `app.save mask.png` →
      `file.close` (Maskendokument)
   6. immer: `file.close {"document":dup}`, danach das Zieldokument wieder aktivieren
      (`ui.inspect`, ggf. `ui.menu.invoke window.document.<i>`)
4. Füllen **ohne** Auswahl: transparente Pixel des Kontexts (Alpha < 250) sind die Maske
   („Arbeitsfläche erweitert“). Keine → Fehler „bitte Auswahl treffen …“. Sonst `region` auf
   §5.2 `outpaint_region` verkleinern, Kontext und Maske zuschneiden, `alpha_mask = true`.

Das Dokument des Nutzers und sein Protokoll bleiben beim Erfassen unverändert.

### 4.2 Rechnen

1. `GET /api/version` (30 s merken): `api` muss **1** sein und `authorized` wahr – sonst Fehler im
   Klartext (§7). Masken gibt es, wenn `features` `mask` enthält. Bei 404 (NVAI-open vor 0.2.0) stattdessen
   `GET /openapi.json`: Kennt `GenerateImageRequest` `mask_asset_id`? (60 s merken.) Füllen ohne
   Masken → Fehler.
2. `GET /api/health` (aktives Bildmodell), `GET /api/models?kind=image` → `Planning.chooseModel`.
3. `Planning.plan` → Technik, Arbeitsgröße, Request (§6).
4. Kontext auf Arbeitsgröße **strecken** (nicht beschneiden), Transparenz mit Mittelfarbe füllen
   (§5.3), als PNG `POST /api/upload` (Feldname `file`, Dateiname `photocraft-<id>-context.png`).
   Technik `reference` → `reference_asset_ids:[id]`, sonst `image_asset_id`.
5. Maske (nur `send_mask`): auf Arbeitsgröße, um `mask_grow` px wachsen, `mask_blur` weich
   (§5.4), als RGB-PNG hochladen → `mask_asset_id`.
6. `POST /api/generate/image` → Job; `GET /api/jobs/{id}` alle 0,5 s (`queued`, `running` mit
   `progress` 0–1 und `stage`, `done` mit `asset_ids`, `error`, `cancelled`). Nicht erreichbar
   → bis 45 s weiter fragen (NVAI-open-Neustart). `cancelled` ohne eigenen Abbruch → Fehler
   „NVAI-open hat den Auftrag abgebrochen (<stage>)“.
7. Je Asset `GET /api/assets/{id}` → `url` (`/files/<name>`), `meta.seed`, `meta.model_name`,
   `meta.caption` (FLUX 3); Bild laden, auf `region`-Größe bringen (Generieren: füllen und mittig
   beschneiden; sonst exakt strecken), als `jobs/<id>/result-<k>.png` speichern.
8. Hochgeladene Ausschnitte/Masken wieder löschen (`DELETE /api/assets/{id}`), auch im
   Fehlerfall. Liegengebliebene (`meta.original_name` beginnt mit `photocraft-`, älter als 1 h)
   beim Start aufräumen.
9. Abbrechen: wartender Job → `DELETE /api/jobs/{id}`; laufender → `POST /api/jobs/current/cancel`
   **nur**, wenn `health.current_job` der eigene ist (NVAI-open wird parallel benutzt).

### 4.3 Einfügen (Variante k)

1. `ui.inspect` → Zieldokument wiederfinden: gespeicherter Index mit gleichem Namen und gleicher
   Größe, sonst erster Treffer nach Name+Größe, sonst eindeutige Größe (nach „Speichern unter“),
   sonst Fehler. Aktivieren (siehe 4.1).
2. `document.inspect`; frühere Ebene dieser Aufgabe (`placed_layer`) suchen, wenn ersetzt wird.
3. Maske wählen: Hat die Aufgabe eine Auswahlmaske und sind die aktuellen `selectionBounds`
   gleich denen beim Erfassen → echte Auswahl verwenden. Sonst, wenn die alte Ebene eine Maske
   hat: `select.loadSelection {"channel":"mask","layer":alt}` und dann die Auswahl verwenden.
   Sonst (oder bei `alpha_mask`) die Maske ins Ergebnis einbacken (§5.5) und
   `result-<k>-alpha.png` öffnen.
4. Beim Ersetzen `layer.select {"layer":alt}` (die Kopie landet über der aktiven Ebene).
5. `app.open` → auf das Temp-Dokument warten → `document.inspect` (erste Ebene) →
   `layer.copyToDocument {document:ziel, source:temp, layers:[id], offset:[region.x,region.y],
   name}` → `file.close {temp}` → „Zuletzt geöffnet“ bereinigen → Ziel aktivieren.
6. Mit Auswahl: `layer.layerMask.revealSelection {neu}`, dann
   `select.loadSelection {"channel":"mask","layer":neu}` (Auswahl bleibt für den nächsten Versuch).
7. Beim Ersetzen `layer.delete {alt}`.

Ebenenname: `Planning.layerName` (§6.5). Mitschnitte der kompletten Folgen: `golden/sequences.json`.

## 5. Geometrie und Bildaufbereitung (`bridge/imaging.py`)

### 5.1 Arbeitsgröße

`workingSize(w, h, target = 1024²)`: `s = √(target/(w·h))`; `gw, gh = w·s, h·s`. Ist die lange
Seite > 2048, beide mit `2048/max` skalieren; ist die kurze danach < 256, beide mit `256/min`.
Dann jede Seite auf das nächste Vielfache von 16 runden und auf 256…2048 begrenzen. Gerundet
wird wie Pythons `round`: bei exakt .5 zur geraden Zahl (Swift `.rounded(.toNearestOrEven)`;
gilt auch für den Rand in `contextRegion`). „Native Auflösung“: `target = 1328²` (Qwen) bzw.
`1440²` (FLUX 3).

**Festes Format** (`features.fixed_size = N`, Core-ML-Modelle in NVAI-open für Mac): Arbeitsgröße ist
immer N×N (`Planning.fixedSize`). Solche Modelle rechnen nur N×N und strecken ihr Ergebnis sonst
selbst auf die angefragte Größe, also verzerrt. Generieren beschneidet das Quadrat danach mittig
auf das Format der Auswahl. Füllen und Überarbeiten stauchen den Ausschnitt auf N×N und skalieren
exakt zurück, er bleibt deckungsgleich. Weicht der Ausschnitt um mehr als den Faktor 1,1 vom
Quadrat ab, gibt es die Warnung `fixed_size`.

### 5.2 Ausschnitt

- `growRect(r, m, W, H)`: um `m` nach allen Seiten, auf die Arbeitsfläche begrenzt, Breite/Höhe
  mindestens 1.
- `contextRegion(sel, W, H, frac = 0.35, minMargin = 32)`: `m = max(minMargin,
  round(max(sel.w, sel.h)·frac))`, dann `growRect`.
- Je Modus (`Planning.regionFor`): ohne Auswahl die ganze Arbeitsfläche; Füllen
  `contextRegion(sel, frac = margin)`; Überarbeiten `growRect(sel, 16)`; Generieren `sel`.
- Erweitern (`Planning.outpaintRegion`): `contextRegion(transparent, frac = max(margin, 1.0))`.
  Gemessen: Macht die leere Fläche 52 % des Ausschnitts aus, komponiert Qwen ein fremdes Motiv;
  mit Faktor 1,0 (≈ 28 %) setzt es die Szene fort.

### 5.3 Kontext fürs Modell

RGB; transparente Stellen mit der **Mittelfarbe der deckenden Pixel** (Alpha > 127) füllen, dann
mit Alpha darüberlegen. Keine deckenden Pixel → Grau 128. Core Image: `CIAreaAverage` über eine
mit der Deckungsmaske multiplizierte Fassung, geteilt durch den Mittelwert der Maske.

### 5.4 Maske fürs Modell

Auf Arbeitsgröße (bilinear), `grow` Mal 3×3-Maximum (= quadratische Dilatation um `grow` px,
Core Image `CIMorphologyRectangleMaximum` mit `2·grow+1`), dann Gauß-Weichzeichner
(`CIGaussianBlur`, `inputRadius = blur`). Werte: Füllen 12/10, Überarbeiten 4/8, Erweitern
24/20 (Arbeitspixel). NVAI-open: weiß = neu erzeugen; Graustufen gehen über Differential Diffusion
stufenlos über.

### 5.5 Ergebnis

- Füllen/Überarbeiten: exakt auf `region` strecken (Lanczos) – der Upload war genauso
  gestaucht, das hebt sich auf; Ergebnis und Umgebung bleiben deckungsgleich.
- Generieren: auf `region` füllen und mittig beschneiden.
- Einbacken: Maske als Alphakanal (bilinear auf Bildgröße). Erweitern: Transparenzmaske des
  vollen `context.png`, auf `region` zugeschnitten, `grow 12`, `blur 8` (Dokumentpixel).
- Vorschaubild: mit Maske als PNG mit Alpha (zeigt nur, was sichtbar wird), sonst JPEG.

Bildoperationen müssen nicht bitgleich zu Pillow sein; die Golden-Daten geben Toleranzen an.

## 6. Planung (`bridge/planning.py`)

### 6.1 Fähigkeiten

`capable(model, need, masksSupported)` mit `f = model.features ?? {}`:
- `img2img` = `f.img2img ?? true`
- `refine` = `img2img || (f.references ?? 0) > 0`
- `mask` = `f.mask ?? (img2img && masksSupported)`

| Modus | braucht |
|---|---|
| Generieren | – |
| Füllen | `mask` |
| Überarbeiten | `refine` |

### 6.2 Modellwahl

`chooseModel(mode, wanted, active, models, masks)` über `runnable`-Modelle:
1. `wanted ?? active` vorhanden und fähig → nehmen, keine Warnung.
2. `wanted` vorhanden, aber unfähig → Fehler `model_incapable`.
3. Fähige Kandidaten in NVAI-open-Reihenfolge, schwache Workflows (`qwen_image_lightning`, `flux`)
   stabil nach hinten; keiner → Fehler `no_capable_model`.
4. Warnung `model_unavailable` (gewünschtes fehlt), `active_model_incapable` oder
   `no_active_model`.

### 6.3 Technik

Generieren → `txt2img`; Füllen → `inpaint`; Überarbeiten → `reference`, wenn das Modell kein
Bild-zu-Bild, aber Referenzen kann (FLUX 3); sonst `inpaint`, wenn eine Auswahl da ist und das
Modell Masken kann; sonst `img2img`.

### 6.4 Request

| Feld | Regel |
|---|---|
| `prompt` | getrimmt. Füllen ohne Prompt: `DEFAULT_FILL_PROMPT` |
| `negative_prompt` | getrimmt. Füllen ohne Prompt und ohne eigenen: `features.default_negative + " " + DEFAULT_FILL_NEGATIVE` (Qwens Modellkarten-Standard bleibt erhalten) |
| `batch_size` | `variants` auf 1…4 begrenzt |
| `width`, `height` | Arbeitsgröße |
| `model_id` | gewähltes Modell |
| `steps`, `cfg`, `seed` | nur wenn gesetzt; ohne `steps` bei `qwen_image` 28 (`INTERACTIVE_STEPS`) |
| `hires` | nur wenn gewünscht **und** `features.hires ?? true` |
| `denoise` | Füllen 1,0; Überarbeiten `strength` (Standard 0,5); nicht bei `reference` |
| `image_asset_id` / `reference_asset_ids` / `mask_asset_id` | beim Ausführen ergänzt (§4.2) |

Fehler `prompt_required`: Generieren ohne Prompt, `reference` ohne Prompt. Warnung
`weak_prompt_fill`: Füllen mit Prompt und schwachem Workflow. `send_mask` = Auswahl/Transparenz
vorhanden **und** Technik `inpaint`; Maskenwerte nach §5.4.

### 6.5 Ebenenname

`"NVAI-open " + Modus` (Füllen/Generieren/Überarbeiten), bei Prompt `": " +` Prompt mit
zusammengefassten Leerzeichen, über 48 Zeichen auf 47 + „…“ gekürzt; bei mehreren Varianten
`" (k+1)"`.

## 7. NVAI-open

| Aufruf | Verwendung |
|---|---|
| `GET /api/version` | Schema `VersionInfo`: `api` (Vertragsversion, muss 1 sein), `version`, `features` (`mask`, `references`, `upsampler` …), `auth` (`local`/`token`), `authorized` |
| `GET /api/health` | bewusst untypisiert (Diagnose), tolerant lesen: `active_models.image`, `current_job`, `queue_depth`, `vram_loaded`, `gpu`, `comfy_running` |
| `GET /api/models?kind=image` | `id,name,workflow,runnable,commercial_ok,warning,best_for,features` |
| `GET /openapi.json` | nur bei 404 auf `/api/version`: `GenerateImageRequest.properties.mask_asset_id` vorhanden? |
| `POST /api/upload` | multipart `file`; Antwort-Asset `id` |
| `POST /api/generate/image` | Request nach §6.4 → Job `id` |
| `GET /api/jobs/{id}` · `DELETE /api/jobs/{id}` | Status · wartenden Job verwerfen |
| `POST /api/jobs/current/cancel` | nur eigener laufender Job |
| `GET /api/assets/{id}` · `DELETE /api/assets/{id}` | Ergebnis-Metadaten · Upload löschen |
| `GET /api/assets?kind=upload` | Aufräumen beim Start |
| `GET /files/{name}` | Bilddatei |

- **Vertrag:** `contract/nvai-openapi.json` ist eine Kopie von `NV-AI/server/openapi.json`
  (`info.x-api-version` = 1; NVAI-open pflegt das Original). `tests/test_contract.py` und
  `NVAIContractTests` prüfen ohne laufendes NVAI-open: Jeder Aufruf der Clients steht im Vertrag
  (Methode, Pfad, Query-Parameter, multipart-Felder). Jeder Request der Planung passt zum Schema
  `GenerateImageRequest` (Typen, Grenzen, Vielfache) und enthält **keine unbekannten Felder**, denn
  die würde NVAI-open still ignorieren. Die gelesenen Felder von `VersionInfo`, `Job`, `Asset` und
  `ModelInfo` existieren. Auch die Antworten der Test-Attrappe müssen zum Vertrag passen (Schema
  bzw. Medientyp, `/files/…` etwa `image/*`), sonst prüfen die Tests ins Leere.
  Die Python-Tests prüfen zusätzlich gegen das Original, wenn NVAI-open daneben liegt. Erneuern:
  `python tools/export_golden.py --refresh-contract` (kopiert auch nach `Golden/`).
- **Zugriff (ab NVAI-open 0.2.0):** Vom eigenen Rechner nie ein Token. Andere Rechner brauchen
  **`X-NVAI-Token`** für alles außer `/api/health` und `/api/version`, auch für `/files/…`.
  Die Clients schicken ihn deshalb bei jeder Anfrage mit. Ohne eingerichteten Token (`auth: local`)
  lehnt NVAI-open fremde Rechner ab (403); geöffnet wird es dort mit `scripts\start.ps1 -Lan`, der
  Token liegt dann in `data\api_token`. `authorized` sagt vorab, ob die Anfragen durchkämen.
  Für beide Fälle gibt es eine eigene Meldung. Im Panel steht dazu der Knopf „Erneut prüfen“:
  `POST /api/nvai/check` liest den Token neu aus `settings.json`, ein Neustart ist nicht nötig.
- Basis-URL und Token sind konfigurierbar (Python: Umgebung `NVAI_URL`/`NVAI_TOKEN` oder
  `settings.json` im Datenordner). NVAI-open selbst starten nur bei lokaler URL (`127.0.0.1`,
  `localhost`, `::1`).
- `features` der Modelle (BILDMODELLE.md, Abschnitt 7) steuert auch die Oberfläche: `prompt_hint`,
  `placeholder`, `negative_prompt` (Feld sperren), `hires` (Schalter sperren), `warning`
  (Lizenzhinweis, etwa FLUX 3).

## 8. Golden-Daten

`python tools/export_golden.py` erzeugt sie, `tests/test_golden.py` hält sie aktuell.

- Rechtecke sind halboffen `[x0, y0, x1, y1)`; Masken-Rechtecke `[x0,y0,x1,y1,wert]`,
  RGBA-Rechtecke `[x0,y0,x1,y1,r,g,b,a]` auf einer Grundfarbe.
- `imaging.json`: `working_size`, `context_region`, `grow_rect`, `mask_bbox`,
  `mask_from_alpha` exakt; `prepare_model_mask`, `flatten_for_model`, `bake_alpha` mit
  `tolerance` (Begrenzungsrahmen in px, Werte 0–255).
- `planning.json`: `capable`, `choose_model` (Ergebnis `{model, warning}` oder `{error}`),
  `technique_for`, `region_for`, `outpaint_region`, `plan` (komplette Payload), `layer_name` –
  alles exakt. Modelle stehen unter `models`.
- `sequences.json`: je Szenario Ausgangslage (`setup`), Aufgabe, Mitschnitt aus Anfrage und
  Antwort. Replay-Test: Der Swift-Ablauf muss Methode und Parameter in derselben Reihenfolge
  senden; die Antworten werden zurückgespielt. Pfade `jobs/<task-id>/…`.

## 9. Messwerte (RTX 5060 Ti, NVAI-open)

| Fall | Ergebnis |
|---|---|
| Füllen, Qwen voll, 28 Schritte, 2 Varianten, Ausschnitt 632×548 → 1104×960 | 118 s, Pferd mit Zaun davor korrekt |
| Erweitern um 320 px, Kontextfaktor 1,0 | 67 s, Szene setzt sich fort, weiche Naht, leichter Farbsprung |
| Qwen Lightning beim Füllen mit Prompt | Maske greift, aber fast nur Umgebung (cfg 1) |
| FLUX 3 Referenz-Bearbeitung 432×332 | 48 s; Unverändertes weicht ~9–15/255 ab (wird neu gezeichnet) |
| Einfügen/Variantentausch in PhotoCraft | 0,25 s |

## 10. Offene Punkte für den Mac

- Finder-Doppelklick bei laufender Testinstanz (zwei PhotoCraft-Prozesse): welche Instanz
  bekommt die Datei? Noch nicht geprüft.
- Panel schwebt per `NSWindow.Level.floating` über PhotoCraft (MacApp). Offen: Fokus ohne PhotoCraft
  zu deaktivieren (`NSPanel` mit `.nonactivatingPanel`).
- Lokale Mac-NVAI-open: „NVAI-open für Mac“ (Bundle-ID `com.noerr.nvai.mac`) ist ein eigenes Projekt der
  NVAI-open-Seite. Es rechnet mit FLUX.2 Klein 4B über MLX (Workflow `flux2_klein`) und bietet
  denselben Vertrag auf 127.0.0.1:8100. Qwen und FLUX 3 gibt es dort vorerst nicht. Die
  `features`:
  - `mask = true`
  - `references` bis 3
  - `img2img = true` (mit Stärke)
  - `negative_prompt = false` (destilliert)
  - `hires = false`

  Die App richtet sich nur nach `features`. Einzige Namensregel: Die Workflows `flux` und
  `qwen_image_lightning` gelten beim Füllen als prompt-schwach (`WEAK_PROMPT_WORKFLOWS`).
- NVAI-open starten: Ist NVAI-open lokal eingestellt und nicht erreichbar, und ist NVAI-open für Mac
  installiert, zeigt die App „NVAI-open starten“. Der Knopf öffnet sie per NSWorkspace, ohne sie nach
  vorn zu holen. Danach steht bis zu 120 s „NVAI-open startet …“. Gemessen am 19.10.2026: nach 1,6 s
  verbunden (Diagnose `--snapshot … --start-nvai`).
- Ohne installiertes Bildmodell (frisch installiertes NVAI-open) zeigen App und Windows-Panel „In NVAI-open
  ist noch kein Bildmodell installiert“ mit Knopf „NVAI-open öffnen“. Die Liste wird nachgeladen, bis
  ein Modell da ist.
- Echter Auftrag Füllen auf dem Mac ohne PC (19.10.2026): PhotoCraft 0.10.0 und NVAI-open für Mac mit
  FLUX.2 Klein 4B, 1024×1024, 4 Schritte, NVAI-open 117,7 s, Speicherspitze 7,9 GB, alle Prüfungen
  grün (`testFillWithRealNVAI`).
- Weitergabe: eine DMG mit beiden Apps, Developer ID und notarisiert. Die NVAI-open-Seite signiert
  und notarisiert. Die App hat die Bundle-ID `com.noerr.nvai.photocraft`. `build-app.sh --sign
  "<Identität>"` signiert mit Hardened Runtime und Zeitstempel, ohne Identität ad hoc. Ad hoc ist
  gemessen (`flags=0x10002(adhoc,runtime)`, Selbsttest und Fenster laufen). Der Weg mit Developer ID
  ist mangels Zertifikat noch ungeprüft. Entitlements sind nicht nötig.
- Token-Datei mit `0600` anlegen, falls PhotoCraft sie nicht selbst anlegt.
