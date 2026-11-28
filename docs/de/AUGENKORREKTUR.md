# Augen bei kleinen Gesichtern

Ist eine Person klein im Bild (ganze Figur oder ab den Knien), malen Videomodelle die Augen oft als verschwommene,
unförmige Löcher: Die Pupillen fehlen und ändern sich von Bild zu Bild. Das Startbild kann tadellos sein; der Schaden
beginnt schon im ersten Bild des Videos.

## Warum das passiert

Videomodelle rechnen nicht jedes Pixel. Sie verdichten das Bild erst zu einem viel kleineren Raster und erzeugen dieses
Raster. MiniMax H3 fasst je 32 × 32 Pixel zu einer Einheit zusammen (laut Modellkarte 16-fache Verdichtung, dann 2 × 2
Zellen je Token); LTX-2.5 verdichtet ähnlich stark. In 1344 × 768 ist ein Gesicht ab den Knien rund 105 px hoch, also
nur etwa drei Einheiten; ein Auge ist kleiner als eine einzige. Für eine Pupille bleibt kein Platz, das Modell erfindet
sie, in jedem Bild etwas anders. Ein anderer Seed ändert daran nichts.

Gemessen an einem Mann, der auf die Kamera zugeht, Gesicht rund 105 px in 1344 × 768:

| Fassung | Augen |
|---|---|
| Startbild (1920 × 1088, Gesicht 147 px) | sauber |
| Dasselbe Startbild auf 1344 × 768 verkleinert | noch erkennbar |
| Erstes Bild des Videos in 1344 × 768 | grau, Pupillen fehlen |
| Erste Bilder des Videos in 1920 × 1088 (Gesicht rund 150 px) | Pupillen da |
| 1344 × 768 mit nachgerechnetem Gesicht (siehe unten) | in jedem Bild sauber |

## Was hilft

1. **Näher heran.** Ab der Hüfte oder näher hat das Gesicht 250 px und mehr; dann hat das Modell genug Einheiten für die
   Augen. Das ist der sicherste Weg, wenn die Einstellung es zulässt.
2. **Erst Entwurf, dann Final.** Einen Take schnell als Entwurf prüfen und den besten mit demselben Seed im
   Finalformat noch einmal rechnen. In NVAI-open: unter einem fertigen Video „⇧ Final rechnen“ (Generieren) oder
   „⇧ Final“ an der Szene (Studio). MiniMax H3: Entwurf 1344 × 768, Final 1920 × 1088 (auf einer Karte mit 16 GB für 3 s
   gemessen, rund 18 Minuten, 15,3 GB Grafikspeicher; Karten mit mehr Speicher tragen längere Clips, nicht gemessen).
   LTX-2.5: Entwurf 1280 × 704 im Standardweg (5 s in rund 93 s), Final 1920 × 1088 in höchster Qualität (DFR, 5 s in
   rund 13 Minuten). Der finale Take ähnelt dem Entwurf, ist aber nicht bildgleich: Das Rauschen ändert sich mit der
   Größe.
3. **Gesicht nachrechnen.** Unter einem fertigen Bild oder Video „☺ Gesicht nachrechnen“ (Generieren) oder unter den
   Takes einer Szene (Studio, Feld „Originalfoto der Person“). Ein Bild des Clips wird mit FLUX 3 und dem Originalfoto
   neu gemalt; die Gesichtszüge des Clips werden dabei vorher weichgezeichnet, damit das Gesicht aus dem Foto kommt
   und nicht vom Clip abdriftet. Kopfhaltung, Kopfbedeckung, Licht und Hintergrund bleiben. Im Video legt eine
   Verfolgung dieses Gesicht in jedem Bild auf den laufenden Kopf und gleicht das Licht Bild für Bild an. Die Augen sind
   in jedem Bild dieselben, sauberen. Das Ergebnis ist ein neuer Take, der alte bleibt. Das Foto findet NVAI-open
   meist selbst (aus „Person aus einem Foto“, über Startbild und Standbild zurück); sonst eines in das Feld ziehen.
   Rund 1 Minute für ein Bild, rund 75 Sekunden für 3 Sekunden Video.

   Grenze: Mund und Lider kommen aus dem einen nachgerechneten Bild und bewegen sich danach nicht. Für Clips ohne
   Sprechen (gehen, schauen, sich umdrehen); bei Sprache lieber näher heran oder „⇧ Final“.

## Was nicht hilft

- **Ein anderer Seed:** Die Augen gehen in der Verdichtung verloren, jeder Seed verliert sie.
- **Das fertige Video hochskalieren** (RelayVSR, SeedVR2 und ähnliche): Sie schärfen, was da ist; aus einem
  verschwommenen Loch wird ein scharfes Loch. Bei kleinen Gesichtern kann RelayVSR zudem gemalt wirken.
- **Gesichtsrestaurierer, die jedes Bild einzeln bearbeiten** (GFPGAN, CodeFormer und andere): Sie malen die Augen neu,
  aber in jedem Bild anders, das Gesicht flackert. Einige davon dürfen nicht kommerziell genutzt werden.

## Leitfaden: eine Person in fünf Rollen

Eine Person geht auf die Kamera zu und wechselt etwa jede Sekunde die Rolle, etwa Feuerwehr, Notarzt, Polizei, Klempner,
Bauarbeiter. Die Überblendung wirkt wie ein Morph, weil Gesicht, Haltung, Straße und Licht bleiben und nur Kleidung und
Werkzeug wechseln. Alles geht in der Oberfläche von NVAI-open.

1. **Foto.** Ein frontales, scharfes Porträt: ein eigenes Foto (mit Einverständnis der Person) oder unter Generieren →
   Bild erzeugt.
2. **Startbild der ersten Rolle.** Generieren → Bild, „Person aus einem Foto“: das Foto auf Kopf und Schultern
   zuschneiden, FLUX 3, Format 1920 × 1088. Im Prompt Rolle, Kleidung und Werkzeug, „walks toward the camera down the
   middle of a dark street at night“, den Ausschnitt („framed from the knees up, his head near the top edge“) und Licht
   von vorn („a soft, bright light from the front keeps his face and eyes clearly lit“), Gegenlicht tief hinter den
   Beinen, nie auf Kopfhöhe. Vier Varianten rechnen und die Augen in voller Größe prüfen.
3. **Studio-Projekt.** 1920 × 1080, fünf Videoszenen nebeneinander, eine je Rolle. Modell MiniMax H3 (Lizenz beachten)
   oder LTX-2.5, Weg „Mit Startbild“; Szene 1 bekommt das Startbild.
4. **Prompt je Szene,** bis auf die Rolle gleich, zum Beispiel:

   > Realistic live-action cinematic look. The firefighter from the first frame, in full turnout gear and helmet,
   > strides toward the camera down the middle of a dark, hazy street at night, a red fire extinguisher hanging from
   > his right hand. He walks at a natural, confident pace, one step after another, and comes closer with every step.
   > His face stays exactly as in the first frame. He looks straight into the camera with a calm, serious but friendly
   > expression, his mouth closed. A soft, bright light from the front keeps his face and eyes clearly lit; behind him
   > a warm light glows low on the wet asphalt, thin haze drifts through the street and the lights shimmer and ripple
   > in the puddles. The camera at waist height slowly glides backward down the street ahead of him, a little slower
   > than he walks, so the wet street, the lights and the buildings move past on both sides while he still comes
   > closer. His boots splash softly on the wet asphalt.

   Was sich im Hintergrund bewegen soll, ausdrücklich nennen, sonst steht die Straße still. 3 Sekunden Länge reichen
   (MiniMax: 73 Bilder), genutzt wird je Rolle gut eine Sekunde.
5. **Szene 1 erzeugen** im Entwurfsformat (MiniMax 1344 × 768) und prüfen: Gang, Gesicht, Bewegung. Passt der Take,
   unter den Takes „☺ Gesicht nachrechnen“ mit dem Foto aus Schritt 1 (das Feld füllt sich meist selbst). Der neue Take
   hat saubere Augen und das Gesicht des Fotos. Den Take in den Schnitt legen. (Statt nachzurechnen geht auch
   „⇧ Final“ in 1920 × 1088 mit gleichem Seed, dauert aber rund 18 statt 1 bis 2 Minuten.)
6. **Schnittpunkt.** Den Clip im Schnitt auf seine Länge kürzen, etwa 1,0 s. Geht die Person schnell auf die Kamera zu,
   eher kürzer, sonst ist sie bei der letzten Rolle zu nah. Rechtsklick auf das letzte Bild des Clips → „Standbild
   hier ins Material“.
7. **Nächste Rolle anziehen.** Unter Generieren das Standbild öffnen → „✎ Überarbeiten“ (FLUX 3, Format 1920 × 1088).
   Im Prompt in zwei Sätzen, was wegfällt und was neu ist:

   > Edit the image: change only his clothes and what he carries. He no longer wears the firefighter turnout gear and
   > the black firefighter helmet. He now wears a red emergency doctor jacket with yellow and silver reflective stripes,
   > dark trousers and a plain white rescue helmet. He now has a plain red emergency medical case hanging from his right
   > hand; it is the only thing in his hands, and his shoulders are free. Keep everything else exactly unchanged: his
   > face, his body position and stride, his position and size in the frame (framed from the knees up, his head near
   > the top edge, exactly as large as in the image), the camera framing, the light, the street and the background.

   Nicht „Replace A with B“ schreiben: Enthält die Beschreibung von A selbst ein „with“, kann die alte Kleidung bleiben.
   Das alte Werkzeug gar nicht nennen, auch nicht verneint („is gone“): Ein über der Schulter getragener Pümpel blieb
   sonst in allen Bildern; mit „it is the only thing in his hands, and his shoulders are free“ war er weg. Nichts
   nennen, was außerhalb des Bildes liegt (Schuhe), sonst zoomt das Bild heraus. Von vier Varianten die nehmen, bei der
   Größe und Lage dem Standbild entsprechen und die Augen sauber sind.
8. **Startbild der nächsten Szene.** Das gewählte Bild aus dem Material auf „Startbild“ von Szene 2 ziehen und Szene 2
   erzeugen, prüfen und wie in Schritt 5 das Gesicht nachrechnen. So bleibt das Gesicht über alle Rollen das des
   Fotos und driftet nicht von Clip zu Clip weiter ab.
9. **Überblendung.** Clip 2 direkt hinter Clip 1 legen, Übergang am Anfang: Überblendung 0,4 s. Der auslaufende Clip
   spielt dabei über sein Ende hinaus weiter. MiniMax steht am Anfang eines Clips rund sechs Bilder fast still, während
   der vorige weitergeht: Clip 2 vorn um einige Bilder kürzen, bis die Köpfe in der Überblendung übereinanderliegen.
   Bild für Bild prüfen; liegen sie nebeneinander, sieht man doppelte Augen.
10. **Wiederholen** für die weiteren Rollen. Ab der vierten ist die Person so nah, dass ein tief getragenes Werkzeug beim
    Näherkommen unten aus dem Bild rutscht: dann gehoben tragen lassen („carried over his right shoulder“).
11. **Musik.** Mit Stable Audio 3 ein paar Sekunden länger erzeugen als das Video, im Schnitt nur den Anfangspunkt
    verschieben, bis der volle Einsatz auf den ersten Rollenwechsel fällt und das Ausklingen auf das Videoende.
12. **Export**, etwa YouTube 1080p.

Zeiten auf einer Karte mit 16 GB: Startbilder mit FLUX 3 rund 45 s je Bild, ein MiniMax-Entwurf von 3 s rund 7 Minuten,
das Gesicht nachrechnen rund 75 s (ein Final in 1080p bräuchte rund 18 Minuten).

## Hinweise

- Andere lösen dasselbe Problem mit einem Gesichtsdurchgang des Videomodells selbst: Das Gesicht wird verfolgt, groß
  ausgeschnitten, mit geringer Stärke neu gerechnet und zurückgeblendet (für MiniMax H3 die ComfyUI-Erweiterung
  „H3-FaceRefine“). Der Ausschnitt muss auf der bewegten Person ruhig sitzen, sonst „kocht“ das Gesicht.
- Ergebnisse von MiniMax H3 unterliegen seiner Lizenz: Ohne eigene Genehmigung von MiniMax dürfen sie in der EU, in
  Großbritannien, Südkorea und den USA nicht genutzt werden, auch privat nicht.
- Gemessen auf einer RTX 5060 Ti mit 16 GB.
