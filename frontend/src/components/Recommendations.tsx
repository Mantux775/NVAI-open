import { t } from '../i18n'

export type RecommendationMode = 'image' | 'audio' | 'video' | '3d' | 'restore' | 'vhs'

// Empfohlene Einstellungen je Reiter (seit 0.5.11, Nutzerwunsch): nur Gemessenes, Zahlen von einer RTX 5060 Ti.
// Quelle und Belege: CLAUDE.md bzw. docs/CLAUDE_CODE.md ("Recommended settings at a glance") -- beide
// zusammen mit dieser Liste pflegen.
type Tip = { head: string; text: string }

const TIPS: Record<RecommendationMode, Tip[]> = {
  image: [
    {
      head: t('Modell nach Aufgabe', 'Model by task'),
      text: t(
        'Qwen-Image-2512 (volle Fassung) für Endassets, Schrift im Bild und Konstruktion, rund 100 s. '
          + 'FLUX 3 zum Bearbeiten und mit Referenzbildern, 13–30 s. Krea 2 für Fotos mit wenig KI-Look, rund 20 s. '
          + 'MOSS-Image für Plakate, Schilder und Grafiken mit Schrift, rund 51 s.',
        'Qwen-Image-2512 (full version) for final assets, text in the image and construction, about 100 s. '
          + 'FLUX 3 for editing and reference images, 13–30 s. Krea 2 for photos with little AI look, about 20 s. '
          + 'MOSS-Image for posters, signs and graphics with text, about 51 s.',
      ),
    },
    {
      head: t('MOSS-Image: das fertige Bild beschreiben', 'MOSS-Image: describe the finished picture'),
      text: t(
        'Schrift wörtlich in Anführungszeichen mit Ort und Schriftart. Bei 50 Schritten lassen: Die Kistenseile liefen '
          + 'dann in drei von drei Bildern durch Bohrungen, mit 25 Schritten (28 s) in zwei von drei.',
        'Text word for word in quotation marks with position and typeface. Leave it at 50 steps: the crate ropes then '
          + 'passed through drilled holes in three of three images, with 25 steps (28 s) in two of three.',
      ),
    },
    {
      head: t('Format nach Silhouette', 'Size by silhouette'),
      text: t(
        'Stehende Figur 832 × 1216, Fahrzeug 1216 × 832, Objekt 1024 × 1024. Im Quadrat verlieren Figuren eher die Füße.',
        'Standing figure 832 × 1216, vehicle 1216 × 832, object 1024 × 1024. In a square, figures tend to lose their feet.',
      ),
    },
    {
      head: t('Prompt in ganzen englischen Sätzen', 'Prompt in full English sentences'),
      text: t(
        'Erst Stil, dann Motiv mit Material und Zustand, dann Licht und Hintergrund. Schrift in Anführungszeichen, '
          + 'Konstruktion ausdrücklich („rope handles pass through drilled holes“). Keine (wort:1.3)-Klammern.',
        'Style first, then the subject with material and condition, then light and background. Text in quotation '
          + 'marks, construction spelled out (“rope handles pass through drilled holes”). No (word:1.3) brackets.',
      ),
    },
    {
      head: t('FLUX 3: genaue Bauweise ohne Ausbauer', 'FLUX 3: exact construction without the upsampler'),
      text: t(
        'Müssen Bauweise, Anzahl oder Blickrichtung genau stimmen, „Prompt ausbauen lassen“ abschalten und den Prompt in '
          + 'ganzen Sätzen schreiben: Mit Ausbauer bekam eine Angelrute in 4 von 6 Bildern eine zweite Schnur, ohne ihn '
          + 'in 0 von 2.',
        'If construction, counts or gaze must be exact, switch off “Expand the prompt” and write the prompt in whole '
          + 'sentences: with the upsampler a fishing rod got a second line in 4 of 6 images, without it in 0 of 2.',
      ),
    },
    {
      head: t('Krea 2: Bildausschnitt nennen', 'Krea 2: state the framing'),
      text: t(
        'Ohne „medium shot from the waist up, his whole head inside the frame“ fehlte der Kopf in drei von drei '
          + 'Bildern, mit dem Satz in keinem von zwei.',
        'Without “medium shot from the waist up, his whole head inside the frame” the head was cut off in three '
          + 'of three images, with it in none of two.',
      ),
    },
    {
      head: t('Mehrere Kandidaten', 'Several candidates'),
      text: t(
        'Zum Auswählen 4 Bilder in einem Auftrag statt vier einzeln (einmal Modell laden) und in voller Größe '
          + 'vergleichen, nicht an Vorschaubildern.',
        'To choose, make 4 images in one job instead of four separate ones (the model loads once) and compare '
          + 'them at full size, not as thumbnails.',
      ),
    },
    {
      head: t('Lizenz', 'License'),
      text: t(
        'Qwen-Image-2512 und MOSS-Image sind frei (Apache-2.0). FLUX 3 kommerziell nur unter 5 Mio. US-$ '
          + 'Jahresumsatz, Krea 2 unter 1 Mio. US-$, jedes Bild vor dem Veröffentlichen prüfen.',
        'Qwen-Image-2512 and MOSS-Image are free (Apache-2.0). FLUX 3 commercially only below US$5M annual revenue, '
          + 'Krea 2 below US$1M; review every image before publishing.',
      ),
    },
  ],
  audio: [
    {
      head: t('Soundeffekte: Stable Audio Open', 'Sound effects: Stable Audio Open'),
      text: t(
        'Den Klang beschreiben, nicht die Musik („heavy metal sword clash, single impact, dry studio recording“), '
          + '3–8 s, rund 12 s Rechenzeit.',
        'Describe the sound, not music (“heavy metal sword clash, single impact, dry studio recording”), 3–8 s, '
          + 'about 12 s to compute.',
      ),
    },
    {
      head: t('Instrumental bis 5 Minuten: Stable Audio 3', 'Instrumentals up to 5 minutes: Stable Audio 3'),
      text: t(
        'Ein Satz mit Gattung, Instrumenten und Stimmung, dann „BPM: 100.“; kein Gesang. 60 s in rund 10 s.',
        'One sentence with genre, instruments and mood, then “BPM: 100.”; no vocals. 60 s in about 10 s.',
      ),
    },
    {
      head: t('Lautheit', 'Loudness'),
      text: t(
        'Ergebnisse liegen bei −12 bis −17 LUFS mit Limiter. Für ein Video auf −14 LUFS normalisieren.',
        'Results come out at −12 to −17 LUFS with a limiter. Normalize to −14 LUFS for a video.',
      ),
    },
  ],
  video: [
    {
      head: t('LTX-2.5: Bild und Ton in einem Durchgang', 'LTX-2.5: picture and sound in one pass'),
      text: t(
        '5 s in 1280 × 704 dauern rund 93 s, in 1920 × 1088 rund 251 s.',
        '5 s at 1280 × 704 take about 93 s, at 1920 × 1088 about 251 s.',
      ),
    },
    {
      head: t('Prompt als ein Absatz im Präsens', 'Prompt as one paragraph in the present tense'),
      text: t(
        'Einstellung, Ort und Licht, Handlung, Kamera, dann der Ton; Gesprochenes in Anführungszeichen. Laute '
          + 'Geräuschquellen ausdrücklich nennen: leise beschriebene Umgebung kam fast unhörbar (−41 bis −52 LUFS).',
        'Shot, place and light, action, camera, then the sound; spoken lines in quotation marks. Name loud sound '
          + 'sources explicitly: surroundings described as soft came out almost inaudible (−41 to −52 LUFS).',
      ),
    },
    {
      head: t('Feste Einstellung', 'Fixed framing'),
      text: t(
        '„Static camera, a locked-off medium shot; the framing stays exactly as in the first frame.“ hielt den '
          + 'Ausschnitt; mit „stays still“ fuhr die Kamera bis zur Nahaufnahme heran.',
        '“Static camera, a locked-off medium shot; the framing stays exactly as in the first frame.” kept the '
          + 'framing; with “stays still” the camera pushed in to an extreme close-up.',
      ),
    },
    {
      head: t('Dieselbe Person in mehreren Szenen', 'The same person in several shots'),
      text: t(
        'LTX-2.5 erfindet ohne Startbild jedes Mal ein neues Gesicht. Startbilder mit FLUX 3 in Videogröße, weitere '
          + 'Einstellungen mit dem ersten als Referenzbild: 4 von 4 behielten Gesicht, Brille, Haar und Kleidung.',
        'Without a start image, LTX-2.5 invents a new face every time. Start images with FLUX 3 in the video size, '
          + 'further shots with the first one as a reference image: 4 of 4 kept face, glasses, hair and clothing.',
      ),
    },
    {
      head: t('Gesprochener Satz: rund 2 Wörter je Sekunde', 'Spoken line: about 2 words per second'),
      text: t(
        '15 Wörter liefen in einer 6-s-Szene bis ins letzte Bild und brachen mitten im Wort ab, 11 endeten 0,3 s '
          + 'vor Schluss. Nach dem Satz eine kleine Handlung vorgeben („Then she smiles and nods once.“).',
        '15 words ran into the last frame of a 6 s shot and were cut off mid-word, 11 ended 0.3 s before the end. '
          + 'Give the person a small action after the line (“Then she smiles and nods once.”).',
      ),
    },
    {
      head: t('Keine Gesten beim Sprechen', 'No gestures while speaking'),
      text: t(
        '„A single quick wave“ dauerte trotzdem 2,5 s, davon 1,4 s stumm. Mit „her hands stay resting on the desk“ '
          + 'sprach sie ab 0,6 s. Komma statt Ausrufezeichen: nach „Hi!“ 0,6 s Pause, nach „Hi there,“ 0,3 s.',
        '“A single quick wave” still lasted 2.5 s, 1.4 s of it silent. With “her hands stay resting on the desk” '
          + 'she spoke from 0.6 s. Commas, not exclamation marks: after “Hi!” a 0.6 s pause, after “Hi there,” 0.3 s.',
      ),
    },
    {
      head: t('Zeit im Prompt ausschreiben', 'Write the timing into the prompt'),
      text: t(
        '„For the first two seconds nothing happens: …, then …“ gab 1,3 s ruhigen Vorlauf; ohne kam der Knall nach '
          + '0,2 s, und die Pointe ging unter.',
        '“For the first two seconds nothing happens: …, then …” gave 1.3 s of calm build-up; without it the bang '
          + 'came after 0.2 s and the joke got lost.',
      ),
    },
    {
      head: t('Gesicht groß und sauber im Startbild', 'A large, clean face in the start image'),
      text: t(
        'LTX rechnet in Zellen von 32 px: Gesichter unter rund 200 px und rennende Nebenfiguren zerliefen. Halbnah '
          + 'oder näher; Startbild mit FLUX 3 und einer frontalen, geschärften Vorlage (mit Seitenblick kamen schiefe '
          + 'Augen).',
        'LTX works in cells of 32 px: faces under about 200 px and running extras melted. Medium shot or closer; '
          + 'start image from FLUX 3 with a frontal, sharpened reference (a sideways glance gave crooked eyes).',
      ),
    },
    {
      head: t('Kamera mit Endbild festhalten', 'Hold the camera with an end image'),
      text: t(
        '„Static camera“ im Prompt fuhr in einer halbnahen Einstellung trotzdem heran (3 von 3); in einer Halbtotalen '
          + 'von der Seite stand die Kamera ohne Endbild meist (14 von 18). Mit einem Endbild, das FLUX 3 aus dem '
          + 'Startbild bearbeitet (gleiches Gesicht, gleicher Ausschnitt), stand sie, und das Gesicht war am Ende '
          + 'wieder dasselbe.',
        '“Static camera” in the prompt still pushed in on a medium close shot (3 of 3); on a medium-wide side view '
          + 'the camera mostly stayed put without an end image (14 of 18). With an end image that FLUX 3 edits from the '
          + 'start image (same face, same framing), it stayed put and the face was the same again at the end.',
      ),
    },
    {
      head: t('Endbild und Schleife halten auch den Hintergrund fest',
        'End image and loop also freeze the background'),
      text: t(
        'Was in Start- und Endbild gleich ist, bleibt dazwischen stehen: In der Schleife änderten sich Wasser und '
          + 'Rauch so wenig wie das Ufer (0,3–2 von 255 je halbe Sekunde), auch mit einem Satz im Prompt, der sie '
          + 'bewegen sollte; mit Endbild vor und nach dem Ereignis meist ebenso. Dieselbe Szene nur mit Startbild: '
          + 'Wasser 1–9, Rauch 1–12. Es bewegt sich nur, was der Prompt als Ereignis verlangt. Für bewegten '
          + 'Hintergrund ohne Endbild und ohne Schleife.',
        'Whatever is the same in the start and end image stays put in between: in a loop, water and smoke changed '
          + 'as little as the shore (0.3–2 out of 255 per half second), even with a sentence in the prompt that asked '
          + 'them to move; with an end image mostly the same before and after the event. The same scene with only a '
          + 'start image: water 1–9, smoke 1–12. Only what the prompt asks for as an event moves. For a moving '
          + 'background, use neither an end image nor a loop.',
      ),
    },
    {
      head: t('Erkennbare Person: Startbild auch als Endbild', 'Recognizable person: start image as end image too'),
      text: t(
        'Nahaufnahme aus einem Porträt mit Blick ins Objektiv: Mit „Schleife“ blieb das Gesicht 5 s lang erkennbar '
          + '(Ähnlichkeit 0,80–1,0), nur mit Startbild fuhr die Kamera nach 1 s heran, und das Gesicht änderte sich '
          + '(0,3–0,4). Ein echtes Foto mit „Vorhandenes Bild erweitern“ aufs Videoformat bringen: Es bleibt pixelgleich.',
        'A close-up from a portrait looking into the lens: with “Loop” the face stayed recognizable for 5 s '
          + '(similarity 0.80–1.0); with the start image alone the camera pushed in after 1 s and the face changed '
          + '(0.3–0.4). Bring a real photo to the video format with “Extend an existing image”: it stays pixel for pixel.',
      ),
    },
    {
      head: t('Handlung über das Endbild festlegen', 'Pin down the action with the end image'),
      text: t(
        'Endbild = Startbild, in dem per Maske nur das Ergebnis ergänzt ist (Fisch im Eimer): Gesicht und Rest bleiben '
          + 'pixelgleich, LTX spielt die Handlung dazwischen nach dem Prompt (2 von 2: ein Fisch mit einer Schwanzflosse). '
          + 'Sagen, was die Hände nicht tun („does not touch the bucket“), und Requisiten einfach halten (Rute ohne Rolle).',
        'End image = the start image with only the result filled in by a mask (a fish in the bucket): the face and the '
          + 'rest stay pixel for pixel, LTX plays the action in between from the prompt (2 of 2: one fish with one tail). '
          + 'Say what the hands do not do (“does not touch the bucket”) and keep props simple (a rod without a reel).',
      ),
    },
    {
      head: t('Ruhige Figur: kurzer Prompt', 'A still person: a short prompt'),
      text: t(
        'Über viele Korrekturen war der Prompt auf 14 Sätze gewachsen, fast alle über die Figur, und sie bewegte sich '
          + 'zu viel. Mit 8 Sätzen in Lightricks’ Reihenfolge und der Stille in einem Satz („sits perfectly still like a '
          + 'statue … through everything that happens“) bewegte sie sich bei gleichem Seed 38–49 % weniger. Ohne Endbild '
          + 'wirkten Verbote nicht („does not reach into the bucket“): beschreiben, was sie tut. Korrekturen '
          + 'einarbeiten, nicht anhängen.',
        'Over many corrections the prompt had grown to 14 sentences, nearly all about the person, and the person moved '
          + 'too much. With 8 sentences in Lightricks’ order and the stillness in one sentence (“sits perfectly still '
          + 'like a statue … through everything that happens”) the person moved 38–49 % less with the same seed. '
          + 'Without an end image, bans did not work (“does not reach into the bucket”): describe what the person does. '
          + 'Work corrections in instead of appending them.',
      ),
    },
    {
      head: t('Gleiche Stimme in mehreren Clips', 'The same voice across clips'),
      text: t(
        'LTX erfindet die Stimme in jedem Clip neu. Sie passte, wenn das Gesicht im Bild war und die Beschreibung '
          + 'wortgleich blieb; aus dem Off und von hinten klang sie anders. Je Satz 2–3 Varianten machen und nach Gehör '
          + 'wählen.',
        'LTX makes up the voice anew in every clip. It matched when the face was in the picture and the description '
          + 'stayed word for word the same; off-screen and from behind it sounded different. Make 2–3 variants per line '
          + 'and pick by ear.',
      ),
    },
    {
      head: t('Gesichter: nicht verlängern, höchstens 6 s', 'Faces: no extending, 6 s at most'),
      text: t(
        'Verlängern kennt nur das letzte Bild; im angehängten Teil kam mehrfach ein anderer Mann. Längere Szenen aus '
          + 'Abschnitten mit Start- und Endbild. 8 s in 1920 × 832 mit DFR passen nicht in 16 GB (20–60 statt 6,5 min).',
        'Extending only sees the last frame; the appended part showed a different man several times. Build longer '
          + 'scenes from parts with start and end images. 8 s at 1920 × 832 with DFR does not fit in 16 GB (20–60 '
          + 'instead of 6.5 min).',
      ),
    },
    {
      head: t('Zwei Clips nahtlos: Verlängern oder Anschluss', 'Two clips without a seam: extend or chain'),
      text: t(
        'Mit dem letzten Bild als Startbild sprang das Bild an der Naht (der Bildschritt dort 1,9–2,5-fach so groß wie '
          + 'seine Nachbarn). „Video verlängern“ und der Anschluss im Studio übernehmen seit 0.5.17 die letzte Sekunde '
          + 'fest und blenden über diese Bilder: höchstens 1,4–1,6-fach, wie normale Bewegung. Ein Anschluss rechnet '
          + 'dafür eine Sekunde mehr.',
        'With the last frame as the start image, the picture jumped at the seam (the frame step there 1.9–2.5 times '
          + 'its neighbours). Since 0.5.17 “Extend a video” and the Studio chain pin the last second and crossfade over '
          + 'it: at most 1.4–1.6 times, like ordinary motion. A chained clip renders one second more for that.',
      ),
    },
    {
      head: t('Schleife nur mit ruhiger Kamera', 'Loop only with a still camera'),
      text: t(
        'Mit Heranfahren zerfiel die Schleife in den letzten Frames. Wasser und Rauch stehen mit Schleife still.',
        'With a push-in, the loop fell apart in the last frames. Water and smoke stand still in a loop.',
      ),
    },
    {
      head: t('Höchste Qualität (DFR)', 'Best quality (DFR)'),
      text: t(
        'Details bleiben über die ganze Länge, kostet rund das Dreifache (1080p, 5 s: 786 statt 241 s).',
        'Detail holds over the whole length, costs about three times as long (1080p, 5 s: 786 instead of 241 s).',
      ),
    },
    {
      head: t('Verlustfreie Kopie anlassen', 'Keep the lossless copy on'),
      text: t(
        'Der YouTube-Export im Studio hatte daraus 42,3 statt 37,7 dB PSNR (aus dem MP4), Anschluss-Startbilder '
          + 'sind pixelgenau. Kostet rund 32 MB je Sekunde bei 1080p.',
        'The Studio’s YouTube export reached 42.3 instead of 37.7 dB PSNR from it (from the MP4), chain start '
          + 'images are pixel-exact. Costs about 32 MB per second at 1080p.',
      ),
    },
    {
      head: t('Endbild', 'End image'),
      text: t(
        'Wenn das Gesicht am Schluss stimmen muss (Herauszoomen, Ende im Stand). Für Bewegung von Anfang an und für '
          + 'bewegten Hintergrund (Wasser, Rauch) ohne Endbild.',
        'When the face has to be right at the end (zoom out, ending at rest). For motion from the start and a moving '
          + 'background (water, smoke), leave it out.',
      ),
    },
    {
      head: t('MiniMax H3: Lizenz, Tempo, Zeitlupe', 'MiniMax H3: license, speed, slow motion'),
      text: t(
        'In EU, UK, Südkorea und USA ohne eigene Lizenz verboten, Ergebnisse nicht veröffentlichen. Vorgewählt ist der '
          + 'schnellste gemessene Weg: Turbo-LoRA 8 Schritte v1.1 + sol-attn + INT8-Attention, 9,4 s in 1344 × 576 in '
          + '6,6–6,9 statt 37 min. Es neigt zu Zeitlupe (24 fps, aber halb so viel Bewegung wie LTX-2.5): Tempo in den '
          + 'Prompt hob die Explosion um 30–55 %; FastH3 bewegt sich fast wie LTX.',
        'Prohibited in the EU, UK, South Korea and USA without a separate license; do not publish results. The fastest '
          + 'measured way is preselected: turbo LoRA 8 steps v1.1 + sol-attn + INT8 attention, 9.4 s at 1344 × 576 in '
          + '6.6–6.9 instead of 37 min. It tends to slow motion (24 fps, but half the motion of LTX-2.5): pace in the '
          + 'prompt raised the explosion by 30–55 %; FastH3 moves almost like LTX.',
      ),
    },
  ],
  '3d': [
    {
      head: t('Quellbild', 'Source image'),
      text: t(
        'Genau ein Objekt, ganz im Bild, einfarbiger Hintergrund, kein Boden und kein Schlagschatten. Boden und '
          + 'Schatten werden sonst zur Platte unter dem Mesh. Ein Sockel, der zum Objekt gehört, darf bleiben.',
        'Exactly one object, fully in the frame, plain background, no floor and no cast shadow. Otherwise floor '
          + 'and shadow turn into a plate under the mesh. A base that belongs to the object may stay.',
      ),
    },
    {
      head: t('Freistellen mit BiRefNet', 'Background removal with BiRefNet'),
      text: t(
        'Die Vorgabe, mit deutlich saubereren Kanten als die Randfarben-Füllung, die an weichen Verläufen scheitert.',
        'The default, with much cleaner edges than the edge color fill, which fails on soft gradients.',
      ),
    },
    {
      head: t('Flächen', 'Faces'),
      text: t(
        '10.000–40.000 für Spiele; −1 behält das volle Mesh mit rund 200.000.',
        '10,000–40,000 for games; −1 keeps the full mesh at about 200,000.',
      ),
    },
    {
      head: t('Schrift und Aufkleber', 'Lettering and decals'),
      text: t(
        '„Vorderseite aus dem Bild übernehmen“ einschalten. TripoSG baut gemalte Schrift sonst als verzerrtes Relief.',
        'Switch on “Take the front from the image”. Otherwise TripoSG builds painted lettering as a distorted relief.',
      ),
    },
    {
      head: t('Vor dem Spiel', 'Before the game'),
      text: t(
        'Meshes sind nicht garantiert wasserdicht; vor dem Einsatz Retopo.',
        'Meshes are not guaranteed to be watertight; retopologize before use.',
      ),
    },
  ],
  restore: [
    {
      head: t('Automatisch (Vorgabe)', 'Automatic (default)'),
      text: t(
        'Das Bildmodell sieht sich das Foto an und beantwortet, ob es Wasserflecken oder Rissnetze hat: ja → '
          + 'gründlich, nein → schonend. Bei 20 von 21 Testfotos traf das die bessere Wahl, rund 2,5 s. Was gewählt '
          + 'wurde, steht im Verlauf („gründlich restauriert“ bzw. „schonend restauriert“).',
        'The image model looks at the photo and answers whether it has water stains or crack networks: yes → '
          + 'thorough, no → gentle. That was the better choice on 20 of 21 test photos, about 2.5 s. The history '
          + 'shows what was chosen (“restored thoroughly” or “restored gently”).',
      ),
    },
    {
      head: t('Gründlich bei flächiger Alterung', 'Thorough for overall aging'),
      text: t(
        'Wasserflecken, Craquelé, Korn, Ausbleichen: Gründlich rechnet das ganze Foto neu. Ähnlichkeit zur '
          + 'unbeschädigten Vorlage an stark gealterten Testfotos: unbearbeitet 0,60, schonend 0,65, gründlich 0,69. '
          + 'Schonend ließ dort Risse und Wasserränder stehen, eingefärbt sah es nur bunt aus.',
        'Water stains, crack networks, grain, fading: Thorough redraws the whole photo. Similarity to the undamaged '
          + 'original on heavily aged test photos: untouched 0.60, gentle 0.65, thorough 0.69. Gentle left cracks '
          + 'and water stains there, and colorized it only looked tinted.',
      ),
    },
    {
      head: t('Schonend bei einzelnen Schäden', 'Gentle for separate damage'),
      text: t(
        'Staub, Kratzer, Streifen, Risse, Lichteinfall oder Schrift auf einem sonst guten Foto: Schonend ersetzt nur '
          + 'diese Stellen. Bei echten Glasplatten (1911, 1925) und Iwo Jima 1945 blieben so Schärfe und Gesichter, '
          + 'gründlich wurde weicher; an leicht beschädigten Testfotos 0,93 gegen 0,91.',
        'Dust, scratches, stripes, tears, light leaks or writing on an otherwise good photo: Gentle replaces just '
          + 'those spots. On real glass plates (1911, 1925) and Iwo Jima 1945 it kept the sharpness and the faces, '
          + 'thorough came out softer; on lightly damaged test photos 0.93 vs 0.91.',
      ),
    },
    {
      head: t('2 Varianten', '2 variants'),
      text: t(
        'Gesichter fallen je Variante etwas anders aus; ein Porträt von 1911 bekam in einer von zwei ein breiteres '
          + 'Gesicht. In voller Größe vergleichen und die ähnlichere nehmen.',
        'Faces come out a little different in each variant; a 1911 portrait got a wider face in one of two. '
          + 'Compare them at full size and keep the closer one.',
      ),
    },
    {
      head: t('Bekannte Farben als Hinweis', 'Known colors as hints'),
      text: t(
        'Auf Englisch, etwa „his suit is dark brown, her dress is dark red“: Die Farbabweichung sank damit um 40 %. '
          + 'Ohne Hinweis rät FLUX, ein brauner Anzug wurde blau.',
        'In English, for example “his suit is dark brown, her dress is dark red”: the color error fell by 40 %. '
          + 'Without hints FLUX guesses; a brown suit came out blue.',
      ),
    },
    {
      head: t('Schärfen', 'Sharpen'),
      text: t(
        'SeedVR2 mit 2× für Druck und große Bildschirme, 6–20 s. Schon mit 1× nahm es im Test grobes Korn heraus und '
          + 'zeichnete das Gesicht klarer, aber auch etwas anders; feines Rauschen in ruhigen Flächen blieb. Bei '
          + 'starker Vergrößerung erfindet es Feindetail.',
        'SeedVR2 at 2× for prints and large screens, 6–20 s. Even at 1× it removed coarse grain in the test and drew '
          + 'the face more clearly, but also a little differently; fine noise in calm areas stayed. At strong '
          + 'enlargement it invents fine detail.',
      ),
    },
    {
      head: t('Schrift prüfen', 'Check lettering'),
      text: t(
        'Kleine Zeichen, die FLUX weglässt (Bindestrich, Komma), fehlen danach in beiden Arten.',
        'Small marks that FLUX leaves out (a hyphen, a comma) are missing afterwards in both modes.',
      ),
    },
  ],
  vhs: [
    {
      head: t('Erst die Vorschau', 'Preview first'),
      text: t(
        '10 s an einer typischen Stelle aufwerten und vorher/nachher vergleichen, dann das ganze Video. Die Schätzung '
          + 'neben dem Knopf rechnet mit den Messwerten unten.',
        'Enhance 10 s at a typical spot and compare before/after, then the whole video. The estimate next to the '
          + 'button uses the measurements below.',
      ),
    },
    {
      head: t('Klassisch ist schnell, die KI ist langsam', 'Classic is fast, the AI is slow'),
      text: t(
        'Gemessen auf einer RTX 5060 Ti: Entflechten und leichtes Entrauschen rund 700 Bilder/s, mittleres '
          + 'Entrauschen rund 46, Stabilisieren rund 90. SeedVR2 7B rund 1,1 s je Bild in 720p und 1,9 s in 1080p: '
          + 'Eine Stunde Band mit 25 Bildern/s braucht in 720p rund 26 h. Die KI deshalb für die besten Stellen nehmen '
          + 'oder über Nacht laufen lassen; ein abgebrochener Lauf setzt mit denselben Einstellungen fort.',
        'Measured on an RTX 5060 Ti: deinterlacing and light denoising about 700 frames/s, medium denoising about 46, '
          + 'stabilizing about 90. SeedVR2 7B about 1.1 s per frame at 720p and 1.9 s at 1080p: an hour of tape at 25 '
          + 'frames/s takes about 26 h at 720p. Use the AI for the best parts or let it run overnight; a stopped run '
          + 'continues with the same settings.',
      ),
    },
    {
      head: t('Vor der KI entrauschen', 'Denoise before the AI'),
      text: t(
        'SeedVR2 holte im Test Krone, Gesicht und Stoff heraus, ließ aber buntes Farbrauschen stehen. „Leicht“ oder '
          + '„mittel“ entrauschen vorher; 720p reicht für VHS (rund 250 Zeilen echte Auflösung), 1080p kostet das '
          + 'Doppelte.',
        'In the test SeedVR2 brought out crown, face and fabric but left colored noise in place. Denoise “light” or '
          + '“medium” first; 720p is enough for VHS (about 250 lines of real resolution), 1080p costs twice the time.',
      ),
    },
    {
      head: t('Weiche Aufnahme: erst nachschärfen', 'Soft recording: sharpen first'),
      text: t(
        'Die KI malte am echten Band in eine unscharfe weite Einstellung kantige Splitter; besser gefiel klassisch mit Farbfilter und '
          + '50 Bilder/s. „Nachschärfen“ verstärkt nur vorhandene Kanten: Gesichtsschärfe 49 → 92 (leicht), 129 (mittel), '
          + '188 (stark), stark wird etwas körnig.',
        'On a real tape the AI painted angular shards into a blurry wide shot; classic with color filter and '
          + '50 fps looked better. “Sharpen” only strengthens existing edges: face sharpness 49 → 92 (light), 129 (medium), '
          + '188 (strong), strong gets a little grainy.',
      ),
    },
    {
      head: t('Farbflecken mindern', 'Reduce color blotches'),
      text: t(
        'Glättet nur die Farbe: über die Zeit nur dort, wo das Bild ruht, und an die Kanten der Helligkeit gelegt. Am echten '
          + 'Band Farbunruhe 1,27 → 0,18 ohne Nachziehen. Der frühere Filter mittelte auch bei Bewegung, die Farbe zog nach: '
          + 'das waren Schlieren. Dazu „Blockkanten glätten“ bei Aufnahmen mit sichtbaren Kompressionsblöcken.',
        'Smooths only the color: over time only where the picture is still, and aligned to the brightness edges. On a real '
          + 'tape color unrest 1.27 → 0.18 without trailing. The earlier filter also averaged during motion, the color trailed: '
          + 'those were smears. Add “Smooth block edges” for recordings with visible compression blocks.',
      ),
    },
    {
      head: t('Aufnahmen vom Wandler (720p, 30 Bilder/s)', 'Captures from a converter (720p, 30 fps)'),
      text: t(
        'Gemessen an zwei echten Bändern: Der Wandler hatte das 4:3-Bild auf 16:9 gezogen (runde Gegenstände 1,3- bis '
          + '1,5-mal breiter als hoch), dann „4:3 entzerren“ (960 × 720). Er nahm das 50-Hz-Band mit 30 Bildern/s auf, '
          + 'Schwenks ruckeln deshalb leicht. „Takt glätten“ rechnet mit RIFE die fehlenden Zwischenbilder (50 Bilder/s, gemessen: Schwenkschritte 1,29 / 1,40 / 0,48 → 0,48–0,62 px). Beim nächsten Band besser gleich am Wandler 4:3 und in der Aufnahme 50 oder 25 Bilder/s '
          + 'einstellen. Volle Helligkeitsskala wird jetzt richtig umgerechnet.',
        'Measured on two real tapes: the converter had stretched the 4:3 picture to 16:9 (round objects 1.3 to 1.5 times '
          + 'wider than high), so use “correct to 4:3” (960 × 720). It recorded the 50 Hz tape at 30 fps, so pans judder '
          + 'slightly. “Smooth cadence” computes the missing in-between frames with RIFE (50 fps, measured: pan steps 1.29 / 1.40 / 0.48 → '
          + '0.48–0.62 px). For the next tape better set the converter to 4:3 and record at 50 or 25 fps. Full-range brightness is '
          + 'converted correctly now.',
      ),
    },
  ],
}

/** Aufklappbarer Kasten „Empfohlene Einstellungen“ für den gewählten Reiter, zugeklappt wie die übrigen Hinweise. */
export function Recommendations({ mode }: { mode: RecommendationMode }) {
  const tips = TIPS[mode]
  if (!tips.length) return null
  return (
    <details className="recommend" key={mode}>
      <summary>{t('Empfohlene Einstellungen', 'Recommended settings')}</summary>
      <ul>
        {tips.map((tip) => (
          <li key={tip.head}>
            <strong>{tip.head}:</strong> {tip.text}
          </li>
        ))}
      </ul>
    </details>
  )
}

// Kurzer Tipp unter der Modellwahl, immer sichtbar (Nutzer 31.10.2026: „im generieren berreich soll es immer "Hints"
// geben, was am besten funktioniert. kurz und klar.“ / „bei fotos auch.“). Ein bis zwei Sätze, nur Gemessenes (RTX 5060 Ti);
// je Modell, sonst je Modellfamilie, sonst je Reiter. Ausführlich steht es im Kasten „Empfohlene Einstellungen“.
const TIP_BY_ID: Record<string, string> = {
  'qwen-image-2512-lightning': t(
    'Nur für Entwürfe (8 Schritte, rund 17 s). Endassets mit der vollen Fassung und 50 Schritten.',
    'For drafts only (8 steps, about 17 s). Final assets with the full version and 50 steps.'),
}
const TIP_BY_FAMILY: Record<string, string> = {
  qwenimage: t(
    'Vorgewählt: natives 1328² mit 50 Schritten (rund 200 statt 100 s, feinere Details). Stehende Figuren 1056 × 1584, '
      + 'Schrift in Anführungszeichen.',
    'Preselected: native 1328² with 50 steps (about 200 instead of 100 s, finer detail). Standing figures 1056 × 1584, '
      + 'text in quotation marks.'),
  qwenimage21: t(
    'Nur nicht kommerziell. Bis zehn Referenzen, im Prompt als <image1>, <image2> … ansprechen.',
    'Non-commercial only. Up to ten references, addressed in the prompt as <image1>, <image2> …'),
  flux3: t(
    'Vorgewählt: 2 MP (1440², Bild rund 26 statt 12 s). Bearbeiten und Figuren halten mit Referenzbild; Stil zuerst '
      + 'nennen, müssen Anzahl oder Bauweise stimmen, „Prompt ausbauen“ abschalten.',
    'Preselected: 2 MP (1440², image about 26 instead of 12 s). Editing and keeping characters with a reference image; '
      + 'name the style first, if counts or construction must be exact, switch off “Expand the prompt”.'),
  krea2: t(
    'Vorgewählt: 2 MP (1408², rund 37 statt 20 s). Fotografisch mit wenig KI-Look; Bildausschnitt nennen („medium shot '
      + 'from the waist up“), sonst fehlt oft der Kopf.',
    'Preselected: 2 MP (1408², about 37 instead of 20 s). Photographic with little AI look; state the framing (“medium '
      + 'shot from the waist up”), otherwise the head is often cut off.'),
  moss_image: t(
    'Vorgewählt: 2 MP (1408², laut OpenMOSS das obere Ende). Plakate und Schilder: das fertige Bild beschreiben, Schrift '
      + 'wörtlich in Anführungszeichen mit Ort und Schriftart.',
    'Preselected: 2 MP (1408², the top end according to OpenMOSS). Posters and signs: describe the finished picture, text '
      + 'word for word in quotation marks with position and typeface.'),
  ltx25: t(
    'Vorgewählt: 1080p mit DFR, 5 s (rund 13 min). Ein Absatz mit 4–8 Sätzen, laute Geräusche ausdrücklich nennen; ein '
      + 'Endbild hält Gesicht und Kamera. Auf 16 GB in 1920 × 832 höchstens 6 s.',
    'Preselected: 1080p with DFR, 5 s (about 13 min). One paragraph of 4–8 sentences, name loud sounds explicitly; an end '
      + 'image holds face and camera. On 16 GB at 1920 × 832 at most 6 s.'),
  minimax_h3: t(
    'Vorgewählt: Turbo 8 + sol-attn + INT8 (9,4 s in 6,9 statt 37 min gemessen). Neigt zu Zeitlupe: jede Bewegung mit '
      + 'Tempo beschreiben.',
    'Preselected: turbo 8 + sol-attn + INT8 (9.4 s measured in 6.9 instead of 37 min). Tends to slow motion: describe '
      + 'the pace of every movement.'),
  minimax_h3_ref2va: t(
    'Vorgewählt: Turbo 8 + sol-attn + INT8 (9,4 s in 6,6 statt 37 min gemessen). Referenzen als <Picture 1> … ansprechen, '
      + 'Bewegung mit Tempo beschreiben.',
    'Preselected: turbo 8 + sol-attn + INT8 (9.4 s measured in 6.6 instead of 37 min). Address references as '
      + '<Picture 1> …, describe the pace of every movement.'),
  minimax_h3_fast: t(
    'Fest 8 Schritte (7,9 min) und kaum Zeitlupe: bewegt sich fast wie LTX-2.5. Nur Text und Startbild.',
    'Fixed 8 steps (7.9 min) and hardly any slow motion: moves almost like LTX-2.5. Text and start image only.'),
  wan: t(
    'Bewegung ausdrücklich beschreiben. Auf 16 GB langsam; LTX-2.5 ist der schnellere Weg mit Ton.',
    'Describe the motion explicitly. Slow on 16 GB; LTX-2.5 is the faster way, with sound.'),
  wan22: t(
    'Bewegung ausdrücklich beschreiben. Auf 16 GB sehr langsam (I2V: 5 s rund 55 min ohne LoRA); LTX-2.5 ist schneller.',
    'Describe the motion explicitly. Very slow on 16 GB (I2V: 5 s about 55 min without a LoRA); LTX-2.5 is faster.'),
  stable_audio: t(
    'Vorgewählt: 6 s (kurze Effekte 3–8 s). Den Klang beschreiben („heavy metal sword clash, single impact, dry“).',
    'Preselected: 6 s (short effects 3–8 s). Describe the sound (“heavy metal sword clash, single impact, dry”).'),
  stable_audio3: t(
    'Vorgewählt: 60 s (rund 10 s Rechenzeit). Musik ohne Gesang: ein Satz mit Gattung, Instrumenten und Stimmung, dann '
      + '„BPM: 100.“',
    'Preselected: 60 s (about 10 s to render). Music without vocals: one sentence with genre, instruments and mood, then '
      + '“BPM: 100.”'),
  triposg: t(
    'Freigestelltes Objekt ohne Boden und Schatten. Nur Geometrie (rund 60 s); vor dem Einsatz im Spiel retopologisieren.',
    'Cut-out object without floor and shadow. Geometry only (about 60 s); retopologize before using it in a game.'),
  trellis2: t(
    'Freigestelltes Objekt ohne Boden und Schatten. Mit PBR-Texturen (rund 75 s); gemalte Schrift wird nicht lesbar.',
    'Cut-out object without floor and shadow. With PBR textures (about 75 s); painted text does not become readable.'),
}
const TIP_BY_MODE: Partial<Record<RecommendationMode, string>> = {
  image: t(
    'Endassets mit Qwen-Image-2512, Bearbeiten mit FLUX 3, Fotos mit Krea 2, Schrift und Plakate mit MOSS-Image.',
    'Final assets with Qwen-Image-2512, editing with FLUX 3, photos with Krea 2, text and posters with MOSS-Image.'),
  video: t(
    'Erste Wahl LTX-2.5: Bild und Ton in einem Durchgang, 5 s in rund 1,5 min.',
    'First choice LTX-2.5: picture and sound in one pass, 5 s in about 1.5 min.'),
  audio: t('Effekte mit Stable Audio Open, Musik mit Stable Audio 3.', 'Effects with Stable Audio Open, music with Stable Audio 3.'),
  '3d': t(
    'Erst ein freigestelltes Bild ohne Boden und Schatten, dann das Mesh.',
    'First a cut-out image without floor and shadow, then the mesh.'),
  restore: t(
    '„Automatisch“ erkennt Wasserflecken und Risse (20 von 21 Fotos richtig) und wählt gründlich oder schonend. Zwei '
      + 'Varianten in voller Größe vergleichen; Farbhinweise senken Farbfehler um rund 40 %.',
    '“Automatic” detects water stains and cracks (20 of 21 photos right) and picks thorough or gentle. Compare two '
      + 'variants at full size; color hints cut color errors by about 40 %.'),
}

/** Kurzer Tipp, was am besten funktioniert, immer sichtbar unter der Modellwahl (beim Restaurieren immer der Fotos-Tipp). */
export function ModelTip({ mode, model }: { mode: RecommendationMode; model?: { id: string; family: string } | null }) {
  const text = mode === 'restore' ? TIP_BY_MODE.restore
    : (model && (TIP_BY_ID[model.id] ?? TIP_BY_FAMILY[model.family])) || TIP_BY_MODE[mode]
  if (!text) return null
  return (
    <p className="model-tip">
      <strong>{t('Tipp', 'Tip')}:</strong> {text}
    </p>
  )
}
