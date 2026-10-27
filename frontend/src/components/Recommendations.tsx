import { t } from '../i18n'

export type RecommendationMode = 'image' | 'audio' | 'video' | '3d' | 'restore'

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
        '„Static camera“ im Prompt fuhr trotzdem heran (3 von 3). Mit einem Endbild, das FLUX 3 aus dem Startbild '
          + 'bearbeitet (gleiches Gesicht, gleicher Ausschnitt), stand die Kamera, und das Gesicht war am Ende wieder '
          + 'dasselbe.',
        '“Static camera” in the prompt still pushed in (3 of 3). With an end image that FLUX 3 edits from the start '
          + 'image (same face, same framing), the camera stayed put and the face was the same again at the end.',
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
      head: t('Schleife nur mit ruhiger Kamera', 'Loop only with a still camera'),
      text: t(
        'Mit Heranfahren zerfiel die Schleife in den letzten Frames.',
        'With a push-in, the loop fell apart in the last frames.',
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
        'Wenn das Gesicht am Schluss stimmen muss (Herauszoomen, Ende im Stand). Für Bewegung von Anfang an ohne Endbild.',
        'When the face has to be right at the end (zoom out, ending at rest). For motion from the start, leave it out.',
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
