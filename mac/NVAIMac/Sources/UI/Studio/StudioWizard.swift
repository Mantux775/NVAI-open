import AppKit
import SwiftUI

/// Assistent im Studio, Mac-Fassung von frontend/src/studio/Wizard.tsx (seit Mac 0.5.6; Nutzer 14.11.2026: „im studio
/// will ich eine art Wizzard … für mac version auch“). Sieben kurze Schritte wie unter Windows: Weg, Idee, Figur,
/// Szenen, Ton, Modelle und Zeit, Los. Er legt ein normales Studio-Projekt an, erzeugt erst je Szene zwei Startbilder
/// zur Auswahl (FLUX.2 Klein mit Referenz), dann die Szenen. Anders als unter Windows: keine Lippen zum Satz (der Satz
/// kommt auf die Spur „Stimme“), keine Schleife (die Mac-Videomodelle kennen kein Endbild), Zeiten aus dem
/// Hardware-Katalog bezogen auf den Mac mini M1.

enum WizardPathID: String, CaseIterable, Identifiable {
    case oneshot, story, narration, character, face, animation
    var id: String { rawValue }
}

enum WizardStyle: String, CaseIterable, Identifiable {
    case film, anim3d, cartoon, ink, anime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .film: return t("Realfilm", "Live action")
        case .anim3d: return t("3D-Animation", "3D animation")
        case .cartoon: return t("Zeichentrick", "Cartoon")
        case .ink: return t("Tusche", "Ink")
        case .anime: return "Anime"
        }
    }
    var image: String {
        switch self {
        case .film: return "Cinematic film still, photographed with natural light, realistic detail."
        case .anim3d: return "3D animated film still in the style of a modern animated feature film, soft warm lighting, rich colors."
        case .cartoon: return "Hand-drawn 2D cartoon frame with clean black ink lines and flat colors, simple and expressive. No glossy highlights, no lens flare."
        // Tusche: der Look des Kurzfilms, schwarz-weiß mit grauer Schraffur auf dunklem Grund
        case .ink: return "Hand-drawn 2D cartoon frame, mostly black and white, with imperfect, slightly wobbly black ink lines and a few loose grey hatching strokes, on a diffuse black background with a faint grey glow."
        case .anime: return "Anime illustration with clean line art and soft cel shading."
        }
    }
    var video: String {
        switch self {
        case .film: return "A cinematic live-action shot with natural light and realistic detail."
        case .anim3d: return "A 3D animated film scene in the style of a modern animated feature film, soft warm lighting."
        case .cartoon: return "A hand-drawn 2D cartoon animation with clean black ink lines and flat colors."
        case .ink: return "A hand-drawn 2D cartoon animation, mostly black and white, with imperfect, slightly wobbly black ink lines and flat grey shading on a diffuse black background."
        case .anime: return "An anime-style animation with clean line art and soft cel shading."
        }
    }
}

enum WizardMood: String, CaseIterable, Identifiable {
    case dramatic, happy, cool, calm, tense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dramatic: return t("Dramatisch", "Dramatic")
        case .happy: return t("Fröhlich", "Cheerful")
        case .cool: return t("Lässig", "Cool")
        case .calm: return t("Ruhig", "Calm")
        case .tense: return t("Spannend", "Suspenseful")
        }
    }
    var light: String {
        switch self {
        case .dramatic: return "Low-key light with deep shadows."
        case .happy: return "Bright, warm daylight."
        case .cool: return "A single hard spotlight from above, deep black shadows all around."
        case .calm: return "Soft, calm light."
        case .tense: return "Moody, high-contrast light."
        }
    }
    var music: String {
        switch self {
        case .dramatic: return "Slow dramatic cinematic score with deep cello drones, a lonely piano and soft timpani rolls, melancholic and heavy, slowly building and then fading into silence. BPM: 60."
        case .happy: return "Bright playful score with plucked strings, glockenspiel, ukulele and light percussion, cheerful and bouncy. BPM: 120."
        case .cool: return "Laid-back hip-hop beat with dusty vinyl crackle, a deep warm bass line, brushed drums and a muted jazz trumpet, cool and confident. BPM: 90."
        case .calm: return "Calm ambient score with soft piano, warm pads and gentle strings, peaceful and warm. BPM: 70."
        case .tense: return "Tense cinematic score with a pulsing synth bass, ticking percussion and rising strings, suspenseful. BPM: 100."
        }
    }
    var musicLabel: String {
        switch self {
        case .dramatic: return t("Langsame Filmmusik mit Cello, Klavier und Pauken", "Slow film score with cello, piano and timpani")
        case .happy: return t("Verspielt mit Zupfstreichern, Glockenspiel und Ukulele", "Playful with plucked strings, glockenspiel and ukulele")
        case .cool: return t("Lässiger Hip-Hop-Beat mit Plattenknistern, Bass und gedämpfter Trompete", "Laid-back hip-hop beat with vinyl crackle, bass and muted trumpet")
        case .calm: return t("Ruhiges Klavier mit warmen Flächen", "Calm piano with warm pads")
        case .tense: return t("Spannung mit pulsierendem Bass und steigenden Streichern", "Tension with pulsing bass and rising strings")
        }
    }
}

enum WizardFraming: String, CaseIterable, Identifiable {
    case wide, medium, close, detail, behind
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wide: return t("Totale", "Wide")
        case .medium: return t("Halbnah", "Medium")
        case .close: return t("Nah", "Close-up")
        case .detail: return t("Detail", "Detail")
        case .behind: return t("Von hinten", "From behind")
        }
    }
    var prompt: String {
        switch self {
        case .wide: return "Wide shot"
        case .medium: return "Medium shot from the waist up"
        case .close: return "Close-up of the face"
        case .detail: return "Detail shot"
        case .behind: return "Shot from behind"
        }
    }

    /// Ohne Figur ohne Körperteile: „from the waist up“ und „of the face“ verlangen eine Person im Bild
    func prompt(cast: Bool) -> String {
        guard !cast else { return prompt }
        switch self {
        case .medium: return "Medium shot"
        case .close: return "Close-up"
        default: return prompt
        }
    }
}

/// Musikvorschläge (wie MUSIC in Wizard.tsx; Nutzer 14.11.: „assistent soll bei der musik viel mehr vorschläge und
/// promt feld anbieten“). Ein Satz für Stable Audio 3: Gattung, Instrumente, Schlagwerk, Stimmung, dann das Tempo. Die
/// ersten fünf gehören zu den Stimmungen; die Stimmung wählt ihren Vorschlag vor.
struct WizardMusic: Identifiable {
    let id: String
    let label: String
    let prompt: String

    static var all: [WizardMusic] {
        WizardMood.allCases.map { WizardMusic(id: $0.rawValue, label: $0.label, prompt: $0.music) } + [
            WizardMusic(id: "epic", label: t("Episches Orchester", "Epic orchestra"), prompt: "Epic orchestral score with powerful brass, soaring strings, a choir and thundering taiko drums, heroic and uplifting. BPM: 110."),
            WizardMusic(id: "action", label: t("Action-Trailer", "Action trailer"), prompt: "Intense action trailer music with pulsing hybrid synths, staccato strings, booming percussion hits and rising brass, urgent and powerful. BPM: 120."),
            WizardMusic(id: "sad", label: t("Traurig", "Sad"), prompt: "Melancholic solo piano with a soft cello, slow and tender, sad and reflective. BPM: 65."),
            WizardMusic(id: "fantasy", label: t("Märchen", "Fairy tale"), prompt: "Magical fantasy score with harp, celesta, soft flutes and warm strings, enchanting and full of wonder. BPM: 80."),
            WizardMusic(id: "ambient", label: "Ambient", prompt: "Atmospheric ambient soundscape with slowly evolving synth pads, soft drones and distant chimes, spacious and peaceful. BPM: 60."),
            WizardMusic(id: "lofi", label: t("Lo-Fi", "Lo-fi"), prompt: "Lo-fi hip-hop beat with mellow Rhodes chords, soft vinyl crackle, a muffled kick and a lazy snare, relaxed and dreamy. BPM: 75."),
            WizardMusic(id: "jazz", label: t("Jazz-Trio", "Jazz trio"), prompt: "Smooth jazz trio with a walking upright bass, brushed drums and a mellow piano, warm and late-night. BPM: 95."),
            WizardMusic(id: "funk", label: "Funk", prompt: "Groovy funk with slap bass, wah-wah guitar, tight drums and a punchy brass section, upbeat and cheeky. BPM: 110."),
            WizardMusic(id: "synthwave", label: "Synthwave", prompt: "Retro synthwave with a pulsing analog bass, bright arpeggios, gated reverb drums and a warm lead synth, nostalgic and driving. BPM: 105."),
            WizardMusic(id: "techno", label: "Techno", prompt: "Driving techno with a deep four-on-the-floor kick, a rolling bass line and hypnotic synth stabs, dark and energetic. BPM: 126."),
            WizardMusic(id: "rock", label: "Rock", prompt: "Energetic indie rock with crunchy electric guitars, a punchy bass and driving live drums, bold and confident. BPM: 130."),
            WizardMusic(id: "folk", label: t("Akustik-Folk", "Acoustic folk"), prompt: "Warm acoustic folk with fingerpicked guitar, a soft mandolin and light hand percussion, gentle and hopeful. BPM: 90."),
            WizardMusic(id: "celtic", label: t("Keltisch", "Celtic"), prompt: "Lively Celtic folk with tin whistle, fiddle, bodhrán and acoustic guitar, adventurous and joyful. BPM: 115."),
            WizardMusic(id: "western", label: "Western", prompt: "Dusty western score with twangy electric guitar, a whistled melody, harmonica and a slow galloping rhythm, lonely and wide. BPM: 85."),
            WizardMusic(id: "comedy", label: t("Komödie", "Comedy"), prompt: "Quirky comedy score with pizzicato strings, bassoon, xylophone and playful woodwinds, bouncy and mischievous. BPM: 125."),
            WizardMusic(id: "horror", label: t("Grusel", "Horror"), prompt: "Dark horror score with eerie string clusters, low drones, distant metallic scrapes and sudden deep hits, unsettling. BPM: 70."),
            WizardMusic(id: "chiptune", label: t("8-Bit", "8-bit"), prompt: "Upbeat 8-bit chiptune with a square-wave melody, bubbly arpeggios and punchy retro drums, playful and fast. BPM: 140."),
        ]
    }

    /// Sieht ein eigener Text nicht englisch aus? (wie NON_EN in Wizard.tsx) Dann wird er vor dem Erzeugen übertragen.
    static func looksGerman(_ s: String) -> Bool {
        s.range(of: "[äöüßÄÖÜ]|\\b(der|das|und|ein|eine|einen|mit|auf|bei|vom|zum|zur|dem|des|ist|sind|nicht|sich|unter|hinter|nach|aus|wird|langsam|leise|ruhige|ruhiges|ruhig|traurig|fröhlich|schnell|laut)\\b",
                options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Wofür der Assistent ein Modell braucht (Mac)
enum WizardRole: String, CaseIterable, Identifiable {
    case image, video, speech, music
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return t("Bilder", "Images")
        case .video: return t("Videos", "Videos")
        case .speech: return t("Stimme", "Voice")
        case .music: return t("Musik", "Music")
        }
    }
}

/// Ein Modell zur Wahl (Nutzer 14.11.: „der assistent soll auch model auswählen lassen, aber der beste ist vorgewählt,
/// und wenn kein noch da anfragen zum herunterladen“)
struct WizardModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let installed: Bool
    let downloadGB: Double
    /// Video: Ton aus dem Bild
    let sound: Bool
}

enum WizardVoice: String, CaseIterable, Identifiable {
    case warmFemale, calmMale, oldRough, youngBright
    var id: String { rawValue }
    var label: String {
        switch self {
        case .warmFemale: return t("Warme Frauenstimme", "Warm female voice")
        case .calmMale: return t("Ruhige Männerstimme", "Calm male voice")
        case .oldRough: return t("Alt und rau", "Old and rough")
        case .youngBright: return t("Jung und fröhlich", "Young and cheerful")
        }
    }
    var prompt: String {
        switch self {
        case .warmFemale: return "A warm, clear female voice, about thirty-five, calm and friendly."
        case .calmMale: return "A calm, deep male voice, about forty-five, warm and steady."
        case .oldRough: return "An old man with a rough, gravelly, deep voice, speaking slowly and wearily."
        case .youngBright: return "A bright, cheerful young voice, lively and friendly."
        }
    }
}

enum WizardStep: Int, CaseIterable {
    case path, idea, character, scenes, sound, models, create
    var label: String {
        switch self {
        case .path: return t("Weg", "Path")
        case .idea: return t("Idee", "Idea")
        case .character: return t("Figur", "Character")
        case .scenes: return t("Szenen", "Scenes")
        case .sound: return t("Ton", "Sound")
        case .models: return t("Modelle", "Models")
        case .create: return t("Los", "Go")
        }
    }
    var help: String {
        switch self {
        case .path: return t("Wähle, was für ein Video es werden soll. Du kannst alles später im Studio ändern.",
                             "Choose what kind of video you want. You can change everything in the Studio later.")
        case .idea: return t("Stil und Stimmung gelten für alle Szenen, so passt am Ende alles zusammen.",
                             "Style and mood apply to every scene, so everything fits together in the end.")
        case .character: return t("Zuerst die Figur: Aus dem gewählten Entwurf entstehen alle Startbilder, so sieht sie in jeder Szene gleich aus.",
                                  "The character first: every start image is made from the chosen draft, so it looks the same in every scene.")
        case .scenes: return t("Wie viele Szenen? Nimm einen Vorschlag oder bestimme die Anzahl selbst. Eine Szene ist eine Einstellung von 3 bis 4 Sekunden; eine klare Handlung je Szene klappt am besten.",
                               "How many scenes? Take a suggestion or choose the number yourself. A scene is one shot of 3 to 4 seconds; one clear action per scene works best.")
        case .sound: return t("Stimme und Musik entstehen auf deinem Mac. Gesprochene Sätze liegen auf der Spur „Stimme“; Lippen zum Satz gibt es nur unter Windows.",
                              "Voice and music are made on your Mac. Spoken lines go on the \"Voice\" track; lips that follow the line are Windows only.")
        case .models: return t("Vorgewählt sind die besten Modelle für deinen Mac; je Aufgabe kannst du ein anderes wählen. Die besten brauchen länger, sehen aber am besten aus.",
                               "The best models for your Mac are preselected; you can pick another one for each task. The best ones take longer but look best.")
        case .create: return t("Zuerst die Startbilder: Sie legen fest, wie jede Szene aussieht. Gefällt eins nicht, nimm das andere.",
                               "Start images first: they decide how each scene looks. If you don't like one, take the other.")
        }
    }
}

struct WizardSceneDraft: Identifiable {
    let id = UUID()
    var framing: WizardFraming
    var seconds: Int
    var hint: String
    var action = ""
    var line = ""
}

/// Szenen für eine Anzahl (wie arc in Wizard.tsx; Nutzer 14.11.: „der user soll auch szenen anzahl auswählen, du
/// schlägst ein paar auswahl möglichkeiten vor und der user kann aber auch selbst bestimmen“): Anfang und Ende stehen
/// fest, dazwischen die Mitte in dieser Reihenfolge, danach `more` (bekommt die Nummer der Szene in der Mitte, ab 1);
/// eine einzelne Szene bekommt einen eigenen Hinweis. Jede Szene entsteht neu (eigene id für ForEach).
struct WizardArc {
    typealias Hint = (framing: WizardFraming, seconds: Int, de: String, en: String)
    let single: Hint
    let first: Hint
    let middle: [Hint]
    let more: (Int) -> Hint
    let last: Hint

    func scenes(_ n: Int) -> [WizardSceneDraft] {
        func make(_ h: Hint) -> WizardSceneDraft { WizardSceneDraft(framing: h.framing, seconds: h.seconds, hint: t(h.de, h.en)) }
        if n <= 1 { return [make(single)] }
        return [make(first)] + (0..<(n - 2)).map { k in make(k < middle.count ? middle[k] : more(k + 1)) } + [make(last)]
    }
}

/// Figur: nötig (spricht in die Kamera, Gesicht aus dem Foto), üblich (vorgewählt, ohne geht auch) oder freiwillig
/// (ohne vorgewählt), wie `character` in Wizard.tsx (Nutzer 14.11.: „assistent soll in betracht ziehen, dass es keine
/// figur gibt“)
enum WizardCast { case required, usual, optional }

/// Die sechs Vorlagen (wie PATHS in Wizard.tsx)
struct WizardPath {
    let id: WizardPathID
    let icon: String
    let title: String
    let text: String
    let cast: WizardCast
    /// "none", "lines" (Figur spricht; auf dem Mac auf der Spur „Stimme“) oder "narration"
    let lines: String
    let chain: Bool
    let photo: Bool
    let style: WizardStyle
    /// Vorschläge für die Anzahl der Szenen: kurz, empfohlen (Vorgabe), länger
    let counts: [Int]
    let arc: WizardArc
    /// Hinweise ohne Figur (nil: dieselben)
    var arcNone: WizardArc? = nil
    /// Beispiel im Schritt „Idee“, wenn es nicht um eine Figur geht
    var idea: String? = nil

    /// Höchstens so viele Szenen im Assistenten (im Studio gehen mehr)
    static let maxScenes = 20

    var needsCharacter: Bool { cast == .required }
    /// Mit Figur vorgewählt
    var castByDefault: Bool { cast != .optional }

    /// Szenen für eine Anzahl, ohne Angabe die empfohlene; `cast` false: Hinweise ohne Figur
    func scenes(_ n: Int? = nil, cast on: Bool = true) -> [WizardSceneDraft] {
        ((on ? nil : arcNone) ?? arc).scenes(n ?? counts[1])
    }

    /// Anzahl ändern, ohne Geschriebenes zu verlieren (wie resizeScenes in Wizard.tsx): Ist noch nichts geschrieben,
    /// passen die Hinweise neu zur Anzahl; sonst kommen neue Szenen vor die letzte (das Ende bleibt das Ende), und
    /// entfernt werden nur leere, zuerst aus der Mitte von hinten. Sind zu viele beschrieben, bleibt die Liste länger.
    func resized(_ list: [WizardSceneDraft], to n: Int, cast on: Bool) -> [WizardSceneDraft] {
        func filled(_ s: WizardSceneDraft) -> Bool {
            !s.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let tpl = scenes(n, cast: on)
        if !list.contains(where: filled) { return tpl }
        if list.count == 1 && n > 1 { return [list[0]] + tpl.dropFirst() }
        var out = list
        while out.count < n { out.insert(tpl[out.count - 1], at: out.count - 1) }
        while out.count > n {
            let order = Array(stride(from: out.count - 2, through: 1, by: -1)) + [out.count - 1, 0]
            guard let i = order.first(where: { $0 >= 0 && $0 < out.count && !filled(out[$0]) }) else { break }
            out.remove(at: i)
        }
        return out
    }

    static func make(_ id: WizardPathID) -> WizardPath {
        switch id {
        case .oneshot:
            return WizardPath(id: id, icon: "🌅", title: t("Eine durchgehende Einstellung", "One continuous shot"),
                              text: t("Ein Moment ohne Schnitt, aus verbundenen Clips. Gut für Orte, Stimmungen, ein Produkt.",
                                      "One moment without a cut, made of joined clips. Good for places, moods, a product."),
                              cast: .optional, lines: "none", chain: true, photo: false, style: .film, counts: [2, 3, 4],
                              arc: WizardArc(single: (.wide, 4, "Was sieht man, was passiert?", "What do we see, what happens?"),
                                             first: (.wide, 4, "Anfang: Was sieht man zuerst?", "Start: what do we see first?"),
                                             middle: [(.wide, 4, "Weiter: Was passiert dann?", "Next: what happens then?")],
                                             more: { _ in (.wide, 4, "Weiter: Was passiert dann?", "Next: what happens then?") },
                                             last: (.wide, 4, "Ende: Wie hört der Moment auf?", "End: how does the moment end?")),
                              idea: t("z. B. Ein Morgen an einem stillen See: Nebel, dann bricht die Sonne durch.",
                                      "e.g. A morning at a quiet lake: mist, then the sun breaks through."))
        case .story:
            return WizardPath(id: id, icon: "🎬", title: t("Kurzgeschichte in Szenen", "A short story in scenes"),
                              text: t("Mehrere Einstellungen wie in einem Kurzfilm: Einführung, Handlung, Ende.",
                                      "Several shots like a short film: introduction, action, ending."),
                              cast: .usual, lines: "lines", chain: false, photo: false, style: .film, counts: [3, 4, 6],
                              arc: WizardArc(single: (.medium, 4, "Die ganze Geschichte in einer Einstellung: Wer tut was?", "The whole story in one shot: who does what?"),
                                             first: (.wide, 4, "Einführung: Wo sind wir, wer ist da?", "Introduction: where are we, who is there?"),
                                             middle: [(.medium, 4, "Handlung: Was tut die Figur?", "Action: what does the character do?"),
                                                      (.close, 4, "Reaktion: Was fühlt sie? Hier passt ein Satz.", "Reaction: what does it feel? A line fits here."),
                                                      (.detail, 4, "Detail: ein wichtiger Gegenstand oder eine Hand.", "Detail: an important object or a hand."),
                                                      (.medium, 4, "Wendung: Etwas Unerwartetes passiert.", "Twist: something unexpected happens."),
                                                      (.close, 4, "Höhepunkt: der entscheidende Moment.", "Climax: the decisive moment."),
                                                      (.medium, 4, "Auflösung: Wie geht es aus?", "Resolution: how does it turn out?")],
                                             more: { _ in (.medium, 4, "Was passiert dann?", "What happens then?") },
                                             last: (.wide, 4, "Ende: ein ruhiges Schlussbild.", "Ending: a quiet final image.")),
                              arcNone: WizardArc(single: (.medium, 4, "Die ganze Geschichte in einer Einstellung: Was passiert?", "The whole story in one shot: what happens?"),
                                                 first: (.wide, 4, "Einführung: Wo sind wir, was sieht man?", "Introduction: where are we, what do we see?"),
                                                 middle: [(.medium, 4, "Handlung: Was passiert?", "Action: what happens?"),
                                                          (.close, 4, "Nah dran: Was sieht man aus der Nähe?", "Close up: what do we see up close?"),
                                                          (.detail, 4, "Detail: ein wichtiger Gegenstand.", "Detail: an important object."),
                                                          (.medium, 4, "Wendung: Etwas Unerwartetes passiert.", "Twist: something unexpected happens."),
                                                          (.close, 4, "Höhepunkt: der entscheidende Moment.", "Climax: the decisive moment."),
                                                          (.medium, 4, "Auflösung: Wie geht es aus?", "Resolution: how does it turn out?")],
                                                 more: { _ in (.medium, 4, "Was passiert dann?", "What happens then?") },
                                                 last: (.wide, 4, "Ende: ein ruhiges Schlussbild.", "Ending: a quiet final image.")))
        case .narration:
            return WizardPath(id: id, icon: "🎙", title: t("Mit Sprecher", "With a narrator"),
                              text: t("Eine Stimme erzählt, dazu passende Bilder in Bewegung. Gut für Erklärvideos.",
                                      "A voice tells the story over matching moving pictures. Good for explainers."),
                              cast: .optional, lines: "narration", chain: false, photo: false, style: .film, counts: [3, 4, 6],
                              arc: WizardArc(single: (.wide, 4, "Das Bild zum Text: was man sieht, während der Sprecher erzählt.", "The picture for the text: what we see while the narrator talks."),
                                             first: (.wide, 4, "Einstieg: ein Bild, das neugierig macht.", "Opening: a picture that makes you curious."),
                                             middle: [(.medium, 4, "Punkt 1: was gezeigt wird, während der Sprecher erzählt.", "Point 1: what we see while the narrator talks.")],
                                             more: { k in (.medium, 4, "Punkt \(k).", "Point \(k).") },
                                             last: (.wide, 4, "Schluss: ein Bild zum Nachklingen.", "Ending: a picture that lingers.")),
                              idea: t("z. B. Wie aus einer Kaffeebohne ein Espresso wird.", "e.g. How a coffee bean becomes an espresso."))
        case .character:
            return WizardPath(id: id, icon: "🗣", title: t("Figur spricht", "A character speaks"),
                              text: t("Eine Figur spricht in die Kamera. Auf dem Mac liegt der Satz auf der Spur „Stimme“.",
                                      "A character talks into the camera. On the Mac the line goes on the \"Voice\" track."),
                              cast: .required, lines: "lines", chain: false, photo: false, style: .anim3d, counts: [1, 3, 5],
                              arc: WizardArc(single: (.medium, 4, "Begrüßung und Botschaft in einem: Was sagt sie?", "Greeting and message in one: what does it say?"),
                                             first: (.medium, 4, "Begrüßung: Wie fängt sie an?", "Greeting: how does it start?"),
                                             middle: [(.medium, 4, "Die Botschaft.", "The message.")],
                                             more: { _ in (.medium, 4, "Noch ein Gedanke.", "One more thought.") },
                                             last: (.close, 4, "Abschluss: ein letzter Satz.", "Ending: a last line.")))
        case .face:
            return WizardPath(id: id, icon: "📷", title: t("Gesicht aus einem Foto", "A face from a photo"),
                              text: t("Ein Porträtfoto wird zur Hauptfigur: in einer Rolle, an einem Ort, mit Bewegung und Stimme.",
                                      "A portrait photo becomes the main character: in a role, at a place, with movement and voice."),
                              cast: .required, lines: "lines", chain: false, photo: true, style: .film, counts: [1, 3, 5],
                              arc: WizardArc(single: (.medium, 4, "Wo ist die Person, was tut sie? Gern mit einem Satz.", "Where is the person, what does it do? A line works well here."),
                                             first: (.medium, 4, "Erste Einstellung: Wo ist die Person, was tut sie?", "First shot: where is the person, what does it do?"),
                                             middle: [],
                                             more: { _ in (.medium, 4, "Was passiert dann?", "What happens next?") },
                                             last: (.close, 4, "Nah aufs Gesicht, gern mit einem Satz.", "Close on the face, a line works well here.")))
        case .animation:
            return WizardPath(id: id, icon: "🎨", title: t("Animation", "Animation"),
                              text: t("Gezeichnet oder als 3D-Animation, mit eigener Figur oder ohne. Ein kleiner Gag oder eine Geschichte.",
                                      "Drawn or as 3D animation, with a character of your own or without. A small gag or a story."),
                              cast: .usual, lines: "lines", chain: false, photo: false, style: .cartoon, counts: [3, 4, 6],
                              arc: WizardArc(single: (.medium, 4, "Der ganze Gag in einer Einstellung.", "The whole gag in one shot."),
                                             first: (.wide, 4, "Einführung: die Figur in ihrer Welt.", "Introduction: the character in its world."),
                                             middle: [(.medium, 4, "Handlung: Was passiert?", "Action: what happens?"),
                                                      (.close, 4, "Reaktion, gern mit einem Satz.", "Reaction, a line works well here."),
                                                      (.medium, 4, "Es geht schief: Was passiert Unerwartetes?", "It goes wrong: what unexpected thing happens?"),
                                                      (.close, 4, "Noch eine Reaktion.", "Another reaction.")],
                                             more: { _ in (.medium, 4, "Was passiert dann?", "What happens then?") },
                                             last: (.wide, 4, "Ende: die Pointe oder ein stilles Schlussbild.", "Ending: the punchline or a quiet final image.")),
                              arcNone: WizardArc(single: (.medium, 4, "Der ganze Gag in einer Einstellung.", "The whole gag in one shot."),
                                                 first: (.wide, 4, "Einführung: Wo sind wir, was sieht man?", "Introduction: where are we, what do we see?"),
                                                 middle: [(.medium, 4, "Handlung: Was passiert?", "Action: what happens?"),
                                                          (.close, 4, "Nah dran: Was sieht man aus der Nähe?", "Close up: what do we see up close?"),
                                                          (.medium, 4, "Es geht schief: Was passiert Unerwartetes?", "It goes wrong: what unexpected thing happens?"),
                                                          (.close, 4, "Noch ein Blick aus der Nähe.", "Another look up close.")],
                                                 more: { _ in (.medium, 4, "Was passiert dann?", "What happens then?") },
                                                 last: (.wide, 4, "Ende: die Pointe oder ein stilles Schlussbild.", "Ending: the punchline or a quiet final image.")))
        }
    }
}

struct WizardError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Ein Download aus dem Assistenten: Fortschritt 0 bis 1, Fehler, fertig
struct WizardFetch {
    var progress: Double = 0
    var error: String?
    var done = false
}

/// Ein fehlendes Modell im Kasten „Soll ich es laden?“
struct WizardMissing: Identifiable {
    let role: WizardRole
    let model: WizardModelOption
    var id: String { model.id }
}

/// Ein Startbild-Platz: zwei Varianten zur Auswahl
struct WizardBoardItem: Identifiable {
    let id: String  // Szene
    var job: String?
    var variants: [AssetRecord] = []
    var chosen: String?
    var error: String?
}

struct StudioWizard: View {
    @ObservedObject var model: StudioModel
    let onClose: () -> Void
    let onDone: () -> Void

    @State private var step: WizardStep = .path
    @State private var pathID: WizardPathID = .story
    @State private var idea = ""
    @State private var place = ""
    @State private var style: WizardStyle = .film
    @State private var mood: WizardMood = .dramatic
    @State private var portrait = false
    @State private var useCharacter = true
    @State private var charName = ""
    @State private var look = ""
    @State private var reference: AssetRecord?
    @State private var drafts: [AssetRecord] = []
    @State private var chosenDraft: String?
    @State private var scenes: [WizardSceneDraft] = WizardPath.make(.story).scenes()
    @State private var countNote: String?
    @State private var voice: WizardVoice = .warmFemale
    @State private var language = Lang.current == .de ? "de" : "en"
    @State private var music = true
    /// Musik: ohne eigene Wahl der Vorschlag der Stimmung; musicText = eigener oder geänderter Prompt
    @State private var musicPick: String?
    @State private var musicText: String?
    /// Modelle: eigene Wahl je Aufgabe (sonst das beste), Downloads aus dem Assistenten
    @State private var choice: [WizardRole: String] = [:]
    @State private var fetches: [String: WizardFetch] = [:]
    @State private var busy: String?
    @State private var stage: String?
    @State private var error: String?
    @State private var board: [WizardBoardItem] = []
    @State private var projectID: String?

    private var path: WizardPath { WizardPath.make(pathID) }
    private var characterOn: Bool { path.needsCharacter || useCharacter }
    /// Wie die Sätze klingen: ohne Figur spricht niemand im Bild, dann liest sie ein Sprecher aus dem Off
    private var lineMode: String { path.lines == "lines" && !characterOn ? "narration" : path.lines }
    private var musicPreset: WizardMusic {
        let all = WizardMusic.all
        return all.first { $0.id == (musicPick ?? mood.rawValue) } ?? all[0]
    }
    private var lines: [String] {
        path.lines == "none" ? [] : scenes.map { $0.line.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var totalSeconds: Int { scenes.reduce(0) { $0 + $1.seconds } }
    private var startScenes: Int { path.chain ? 1 : scenes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(step != .character ? step.help : path.photo ? faceHelp : path.needsCharacter ? step.help : castHelp)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
        .task {
            if let s = WizardDemo.script, !WizardDemo.started {
                WizardDemo.started = true
                await runDemo(s)
            }
        }
    }

    /// Hilfe im Schritt „Figur“, wenn es auch ohne geht
    private var castHelp: String {
        t("Gibt es eine Hauptfigur? Dann zuerst sie: Aus dem gewählten Entwurf entstehen alle Startbilder, so sieht sie in jeder Szene gleich aus. Ohne Figur geht es gleich weiter zu den Szenen.",
          "Is there a main character? Then it comes first: every start image is made from the chosen draft, so it looks the same in every scene. Without a character you go straight on to the scenes.")
    }

    private var faceHelp: String {
        t("Ein Foto von Kopf und Schultern, frontal und gut beleuchtet, trifft das Gesicht am besten. Das Foto bleibt auf deinem Mac. Auf dem Mac endet ein Clip nicht wieder im Startbild (das kann nur LTX-2.5 unter Windows), das Gesicht kann deshalb im Clip etwas wandern.",
          "A head-and-shoulders photo, frontal and well lit, gets the face best. The photo stays on your Mac. On the Mac a clip does not end in its start image again (only LTX-2.5 on Windows can do that), so the face may drift a little within the clip.")
    }

    // MARK: Kopf und Fuß

    private var header: some View {
        HStack(spacing: 10) {
            Text("✨ " + t("Assistent", "Assistant")).font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 4) {
                ForEach(WizardStep.allCases, id: \.rawValue) { s in
                    Text(s.label).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(s == step ? Color.green : Color.clear))
                        .overlay(Capsule().stroke(s.rawValue < step.rawValue ? Color.green.opacity(0.6) : Color.secondary.opacity(0.4)))
                        .foregroundStyle(s == step ? Color.black : (s.rawValue < step.rawValue ? Color.primary : Color.secondary))
                }
            }
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(t("Schließen; alles Angelegte bleibt im Studio", "Close; everything created stays in the Studio"))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Button("← " + t("Zurück", "Back")) {
                if let prev = WizardStep(rawValue: step.rawValue - 1) { step = prev }
            }
            .disabled(step == .path || busy != nil || (step == .create && !board.isEmpty))
            Spacer()
            Text(t("Schritt \(step.rawValue + 1) von 7", "Step \(step.rawValue + 1) of 7")).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if step != .create {
                Button(t("Weiter", "Next") + " →") {
                    if let next = WizardStep(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(!canNext || busy != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var canNext: Bool {
        switch step {
        case .idea: return !idea.trimmingCharacters(in: .whitespaces).isEmpty
        case .character: return path.photo ? (reference != nil && !look.trimmingCharacters(in: .whitespaces).isEmpty)
                                           : (!characterOn || chosenDraft != nil)
        case .scenes: return scenes.allSatisfy { !$0.action.trimmingCharacters(in: .whitespaces).isEmpty }
        default: return true
        }
    }

    // MARK: Schritte

    @ViewBuilder private var content: some View {
        switch step {
        case .path: pathStep
        case .idea: ideaStep
        case .character: characterStep
        case .scenes: scenesStep
        case .sound: soundStep
        case .models: modelsStep
        case .create: createStep
        }
    }

    private var pathStep: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
            ForEach(WizardPathID.allCases) { id in
                let p = WizardPath.make(id)
                let d = p.scenes()
                Button { choose(id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.icon).font(.title2)
                        Text(p.title).font(.headline)
                        Text(p.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(t("\(d.count) Szenen · ≈ \(d.reduce(0) { $0 + $1.seconds }) s",
                               "\(d.count) scenes · ≈ \(d.reduce(0) { $0 + $1.seconds }) s"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(id == pathID ? Color.green : Color.secondary.opacity(0.3),
                                                                        lineWidth: id == pathID ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choose(_ id: WizardPathID) {
        let p = WizardPath.make(id)
        pathID = id
        style = p.style
        scenes = p.scenes(cast: p.castByDefault)
        countNote = nil
        useCharacter = p.castByDefault
    }

    /// Mit oder ohne Figur: Die Hinweise der Szenen passen sich an, Geschriebenes bleibt
    private func setCast(_ on: Bool) {
        useCharacter = on
        let tpl = path.scenes(scenes.count, cast: on)
        for i in scenes.indices where i < tpl.count { scenes[i].hint = tpl[i].hint }
    }

    // MARK: Anzahl der Szenen

    private func setCount(_ n: Int) {
        let want = min(max(n, 1), WizardPath.maxScenes)
        let next = path.resized(scenes, to: want, cast: characterOn)
        scenes = next
        countNote = next.count <= want ? nil : path.chain
            ? t("Teile mit Text bleiben stehen; entferne sie einzeln mit ✕.", "Parts with text stay; remove them one by one with ✕.")
            : t("Szenen mit Text bleiben stehen; entferne sie einzeln mit ✕.", "Scenes with text stay; remove them one by one with ✕.")
    }

    private func countLabel(_ n: Int) -> String {
        path.chain ? t("\(n) \(n == 1 ? "Teil" : "Teile")", "\(n) \(n == 1 ? "part" : "parts")")
                   : t("\(n) \(n == 1 ? "Szene" : "Szenen")", "\(n) \(n == 1 ? "scene" : "scenes")")
    }

    private func countTag(_ k: Int) -> String {
        [t("kurz", "short"), t("empfohlen", "recommended"), t("länger", "longer")][min(k, 2)]
    }

    /// Ein Vorschlag: Anzahl, Filmlänge und Rechenzeit für die Liste, die daraus würde
    private func countChip(_ n: Int, _ k: Int) -> some View {
        let list = path.resized(scenes, to: n, cast: characterOn)
        let secs = list.reduce(0) { $0 + $1.seconds }
        let est = estimateTotal(list).map { " · " + HardwareCatalog.duration($0) } ?? ""
        let sel = scenes.count == n
        return Button { setCount(n) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(countLabel(n) + " · " + countTag(k)).font(.callout.weight(.semibold))
                Text(t("\(secs) s Film", "\(secs) s of film") + est).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Color.green : Color.secondary.opacity(0.3), lineWidth: sel ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var countPicker: some View {
        let own = Binding<Int>(get: { scenes.count }, set: { setCount($0) })
        let ownSel = !path.counts.contains(scenes.count)
        return VStack(alignment: .leading, spacing: 6) {
            Text(path.chain ? t("Wie viele Teile?", "How many parts?") : t("Wie viele Szenen?", "How many scenes?"))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(path.counts.enumerated()), id: \.offset) { k, n in countChip(n, k) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Eigene Anzahl", "Custom number")).font(.callout.weight(.semibold))
                    HStack(spacing: 4) {
                        TextField("", value: own, format: .number).textFieldStyle(.roundedBorder).frame(width: 44)
                        Stepper("", value: own, in: 1...WizardPath.maxScenes).labelsHidden()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ownSel ? Color.green : Color.secondary.opacity(0.3), lineWidth: ownSel ? 2 : 1))
                .help(t("1 bis \(WizardPath.maxScenes)", "1 to \(WizardPath.maxScenes)"))
            }
            if let countNote { Text(countNote).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            field(t("Worum geht es? Ein, zwei Sätze reichen.", "What is it about? One or two sentences are enough.")) {
                TextField(path.idea ?? t("z. B. Ein müder Hase zieht eine alte, fast leere Batterie durch die Dunkelheit.",
                                         "e.g. A tired rabbit drags an old, almost empty battery through the dark."), text: $idea, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            field(t("Wo spielt es? (gilt für alle Szenen)", "Where does it take place? (for all scenes)")) {
                TextField(t("z. B. ein diffuser schwarzer Raum mit einer dünnen weißen Linie am Boden",
                            "e.g. a diffuse black void with a thin white line on the floor"), text: $place)
                    .textFieldStyle(.roundedBorder)
            }
            field(t("Stil", "Style")) {
                Picker("", selection: $style) { ForEach(WizardStyle.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            field(t("Stimmung (Licht und Musik)", "Mood (light and music)")) {
                Picker("", selection: $mood) { ForEach(WizardMood.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            field(t("Format", "Format")) {
                Picker("", selection: $portrait) {
                    Text(t("Quer 16:9 (YouTube)", "Landscape 16:9 (YouTube)")).tag(false)
                    Text(t("Hochkant 9:16 (Shorts)", "Portrait 9:16 (Shorts)")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    /// Wahl „Mit Figur“ / „Ohne Figur“
    private func castCard(_ on: Bool) -> some View {
        let sel = characterOn == on
        return Button { setCast(on) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? t("Mit Figur", "With a character") : t("Ohne Figur", "Without a character")).font(.callout.weight(.semibold))
                Text(on ? t("Eine Hauptfigur, die in jeder Szene gleich aussieht", "A main character who looks the same in every scene")
                        : t("Orte, Dinge, Natur: Die Szenen zeigen, was du beschreibst", "Places, things, nature: the scenes show what you describe"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 240, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Color.green : Color.secondary.opacity(0.3), lineWidth: sel ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var characterStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !path.needsCharacter {
                HStack(spacing: 8) { castCard(true); castCard(false) }
            }
            if !characterOn {
                Text(t("Ohne Figur gibt es keine Entwürfe: Die Startbilder entstehen direkt aus deinen Szenen. Kommen Menschen oder Tiere vor, nenn sie in der Szene; sie sehen dann von Szene zu Szene etwas anders aus.",
                       "Without a character there are no drafts: the start images are made straight from your scenes. If people or animals appear, name them in the scene; they will then look a little different from scene to scene.")
                     + (path.lines == "lines" ? " " + t("Sätze spricht ein Sprecher aus dem Off.", "Lines are spoken by a narrator off screen.") : ""))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if path.photo {
                HStack(alignment: .top, spacing: 12) {
                    field(t("Name (freiwillig)", "Name (optional)")) {
                        TextField(t("z. B. Kapitän Lena", "e.g. Captain Lena"), text: $charName).textFieldStyle(.roundedBorder)
                    }
                    field(t("Porträtfoto", "Portrait photo")) {
                        Button(reference == nil ? t("Foto wählen …", "Choose a photo …") : t("✓ Foto geladen, anderes wählen", "✓ Photo loaded, choose another")) {
                            pickReference()
                        }
                        .disabled(busy != nil)
                    }
                }
                if let reference { AssetThumbnail(asset: reference, maxSide: 300).frame(maxHeight: 140) }
                field(t("Wer soll die Person sein? Rolle und Kleidung", "Who should the person be? Role and clothes")) {
                    TextField(t("z. B. eine Kapitänin in dunkelblauer Uniform mit weißer Mütze", "e.g. a ship captain in a dark blue uniform with a white cap"),
                              text: $look, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                }
            } else if characterOn {
                HStack(alignment: .top, spacing: 12) {
                    field(t("Name", "Name")) {
                        TextField(t("z. B. Somi", "e.g. Somi"), text: $charName).textFieldStyle(.roundedBorder)
                    }
                    field(t("Eigene Vorlage (freiwillig)", "Your own template (optional)")) {
                        HStack {
                            Button(reference == nil ? t("Skizze oder Foto …", "Sketch or photo …") : t("✓ Vorlage geladen", "✓ Template loaded")) {
                                pickReference()
                            }
                            if reference != nil { Button(t("ohne Vorlage", "no template")) { reference = nil } }
                        }
                        .disabled(busy != nil)
                    }
                }
                field(t("Wie sieht sie oder er aus?", "What does the character look like?")) {
                    TextField(t("z. B. ein kleiner weißer Hase mit langen Ohren, müden Augen und hängenden Schultern",
                                "e.g. a small white rabbit with long ears, tired eyes and slumped shoulders"), text: $look, axis: .vertical)
                        .lineLimit(2...3).textFieldStyle(.roundedBorder)
                }
                Text(t("Tipp: Gib der Figur ein, zwei Erkennungszeichen (eine Farbe, ein Kleidungsstück). Dann erkennt man sie in jeder Szene.",
                       "Tip: give the character one or two distinctive marks (a colour, a piece of clothing). Then it is recognizable in every scene."))
                    .font(.callout).foregroundStyle(.secondary)
                fetchBox([.image], t("Für die Entwürfe fehlt noch das Bildmodell. Soll ich es laden?",
                                     "The image model for the drafts is not downloaded yet. Shall I download it?"))
                HStack(spacing: 10) {
                    Button(busy == "drafts" ? t("Entwürfe entstehen …", "Making drafts …")
                           : (drafts.isEmpty ? t("4 Entwürfe erzeugen", "Make 4 drafts") : t("Neue Entwürfe", "New drafts"))) {
                        Task { await makeDrafts() }
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(busy != nil || (look.trimmingCharacters(in: .whitespaces).isEmpty && reference == nil) || !missing([.image]).isEmpty)
                    if drafts.isEmpty, let s = estimate(images: 4, megapixels: 0.79, reference: reference != nil) {
                        Text(HardwareCatalog.duration(s)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !drafts.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(drafts, id: \.id) { a in
                            Button { chosenDraft = a.id } label: {
                                AssetThumbnail(asset: a, maxSide: 300)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(a.id == chosenDraft ? Color.green : Color.clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    private var scenesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            countPicker
            ForEach($scenes) { $s in
                let i = scenes.firstIndex(where: { $0.id == s.id }) ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(path.chain ? t("Teil \(i + 1)", "Part \(i + 1)") : t("Szene \(i + 1)", "Scene \(i + 1)")).font(.headline)
                        Spacer()
                        if !(path.chain && i > 0) {
                            Picker("", selection: $s.framing) { ForEach(WizardFraming.allCases) { Text($0.label).tag($0) } }
                                .labelsHidden().frame(width: 130)
                        }
                        Picker("", selection: $s.seconds) { ForEach([3, 4], id: \.self) { Text("\($0) s").tag($0) } }
                            .labelsHidden().frame(width: 70)
                        if scenes.count > 1 {
                            Button { scenes.removeAll { $0.id == s.id }; countNote = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help(path.chain ? t("Teil entfernen", "Remove part") : t("Szene entfernen", "Remove scene"))
                        }
                    }
                    TextField(s.hint, text: $s.action, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                    if path.lines != "none" {
                        TextField(path.lines == "narration" ? t("Sprecher sagt …", "The narrator says …")
                                  : lineMode == "narration" ? t("Sprecher aus dem Off sagt (freiwillig) …", "Narrator off screen says (optional) …")
                                  : t("Sagt (freiwillig) …", "Says (optional) …"),
                                  text: $s.line).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
            if scenes.count < WizardPath.maxScenes {
                Button("+ " + (path.chain ? t("Teil", "Part") : t("Szene", "Scene"))) {
                    scenes.append(path.chain ? WizardSceneDraft(framing: .wide, seconds: 4, hint: t("Weiter: Was passiert dann?", "Next: what happens then?"))
                                             : WizardSceneDraft(framing: .medium, seconds: 4, hint: t("Was passiert dann?", "What happens then?")))
                    countNote = nil
                }
            }
            let est = estimateTotal(scenes).map { t(", Rechenzeit ", ", computing time ") + HardwareCatalog.duration($0) } ?? ""
            Text(t("Zusammen \(totalSeconds) s Film", "\(totalSeconds) s of film in total") + est + ". "
                 + t("Auf dem Mac sind Clips bis 4 s üblich (Arbeitsspeicher).", "On the Mac clips of up to 4 s are usual (memory).")
                 + (path.lines == "lines" && lineMode == "narration" ? " " + t("Ohne Figur spricht ein Sprecher aus dem Off.", "Without a character a narrator speaks off screen.") : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var soundStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if lines.isEmpty {
                Text(t("Keine gesprochenen Sätze: Das Video bekommt Musik, wenn du willst.", "No spoken lines: the video gets music if you like."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                field(t("Stimme", "Voice")) {
                    Picker("", selection: $voice) { ForEach(WizardVoice.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                field(t("Sprache der Sätze", "Language of the lines")) {
                    Picker("", selection: $language) {
                        ForEach(SpeechCatalog.languages.filter { $0 != "auto" }, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                }
                Text(t("Der erste Satz gibt die Stimme vor, alle weiteren klingen genauso.", "The first line sets the voice, all others sound the same."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle(t("Musik", "Music"), isOn: $music)
            if music {
                field(t("Vorschläge (die Stimmung hat einen vorgewählt)", "Suggestions (the mood picked one)")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(WizardMusic.all) { m in
                            let sel = musicText == nil && musicPreset.id == m.id
                            Button { musicPick = m.id; musicText = nil } label: {
                                Text(m.label).font(.callout).lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
                                    .overlay(Capsule().stroke(sel ? Color.green : Color.secondary.opacity(0.3), lineWidth: sel ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(m.prompt)
                        }
                    }
                }
                field(t("Musik-Prompt: ändern oder selbst schreiben", "Music prompt: change it or write your own")) {
                    TextField("", text: Binding(get: { musicText ?? musicPreset.prompt }, set: { musicText = $0 }), axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                }
                Text(t("Am besten ein Satz: Gattung, Instrumente, Schlagwerk und Stimmung, am Ende das Tempo („BPM: 90.“). Nur Instrumentalmusik, ohne Gesang. Deutscher Text wird vor dem Erzeugen ins Englische übertragen.",
                       "Best as one sentence: genre, instruments, percussion and mood, the tempo at the end (\"BPM: 90.\"). Instrumental music only, no singing."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deviceLine).font(.callout)
            fetchBox(usedRoles, t("Noch nicht geladen. Soll ich die Modelle jetzt laden?", "Not downloaded yet. Shall I download the models now?"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text(t("Aufgabe", "Task")).foregroundStyle(.secondary)
                    Text(t("Modell", "Model")).foregroundStyle(.secondary)
                    Text(t("Zeit", "Time")).foregroundStyle(.secondary)
                }
                Divider()
                if characterOn && !path.photo && drafts.isEmpty {
                    row(t("Figur (4 Entwürfe)", "Character (4 drafts)"), .image, picker: true,
                        estimate(images: 4, megapixels: 0.79, reference: reference != nil))
                }
                row(t("Startbilder (\(startScenes) × 2)", "Start images (\(startScenes) × 2)"), .image,
                    picker: !(characterOn && !path.photo && drafts.isEmpty),
                    estimate(images: startScenes * 2, megapixels: 0.59, reference: path.photo || characterOn))
                if !lines.isEmpty {
                    row(t("Stimme (\(lines.count) \(lines.count == 1 ? "Satz" : "Sätze"))", "Voice (\(lines.count) \(lines.count == 1 ? "line" : "lines"))"),
                        .speech, picker: true, voiceEstimate)
                }
                if music {
                    row(t("Musik", "Music"), .music, picker: true, musicEstimate)
                }
                row(t("Videos (\(totalSeconds) s)", "Videos (\(totalSeconds) s)"), .video, picker: true, videoEstimate)
                Divider()
                GridRow {
                    Text(t("Zusammen", "Total")).fontWeight(.semibold)
                    Text("")
                    Text(estimateTotal(scenes).map { HardwareCatalog.duration($0) } ?? "–").fontWeight(.semibold)
                }
            }
            .font(.callout)
            Text(t("Die Zeiten sind Schätzungen aus dem Hardware-Katalog, gemessen auf einem Mac mini M1. Ohne Messung für ein gewähltes Modell steht „–“.",
                   "The times are estimates from the hardware catalog, measured on a Mac mini M1. Without a measurement for a chosen model it shows \"–\"."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Zeile unter „Modelle“: Aufgabe, Modell (zur Wahl, wenn es mehrere gibt; das beste ist vorgewählt), Zeit
    private func row(_ task: String, _ role: WizardRole, picker: Bool, _ seconds: Double?) -> some View {
        let list = options(role)
        let current = chosen(role)
        let sel = Binding<String>(get: { chosen(role)?.id ?? "" }, set: { choice[role] = $0 })
        return GridRow(alignment: .top) {
            Text(task)
            VStack(alignment: .leading, spacing: 2) {
                if picker && list.count > 1 {
                    Picker("", selection: sel) {
                        ForEach(list) { o in
                            Text(o.name + (o.id == best(role) ? t(" (empfohlen)", " (recommended)") : "")
                                 + (o.installed ? "" : t(" – nicht geladen, \(gbText(o.downloadGB))", " – not downloaded, \(gbText(o.downloadGB))")))
                                .tag(o.id)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 380, alignment: .leading)
                } else {
                    Text(current?.name ?? t("kein Modell", "no model"))
                }
                if let m = current, !m.installed {
                    Text(fetchState(m)).font(.caption).foregroundStyle(.orange)
                }
                // Ton nur erwähnen, wenn ein anderes Modell ihn hätte (auf kleinen Macs hat keins Ton)
                if picker, role == .video, let m = current, !m.sound, list.contains(where: \.sound) {
                    Text(t("Ohne Ton: Geräusche fehlen, Stimme und Musik bleiben.", "No sound: no sound effects, voice and music stay."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(seconds.map { HardwareCatalog.duration($0) } ?? "–")
        }
    }

    // MARK: Modelle zur Wahl

    /// Aufgaben, die dieses Video braucht
    private var usedRoles: [WizardRole] {
        [.image, .video] + (lines.isEmpty ? [] : [.speech]) + (music ? [.music] : [])
    }

    /// Was der Assistent zur Wahl stellt: was auf diesem Mac läuft (Arbeitsspeicher, macOS); Bild mit Figur nur FLUX.2
    /// Klein (nimmt Referenzbilder), ohne Figur auch Z-Image Turbo
    private func options(_ role: WizardRole) -> [WizardModelOption] {
        let ram = SystemInfo.memoryGB
        switch role {
        case .image:
            var list = ModelCatalog.all.filter { ram >= $0.minRAMGB }.map {
                WizardModelOption(id: $0.id, name: $0.name, installed: ModelCatalog.status($0).installed, downloadGB: $0.downloadGB, sound: false)
            }
            if !characterOn {
                list += ZImageCatalog.all.filter { ram >= $0.minRAMGB }.map {
                    WizardModelOption(id: $0.id, name: $0.name, installed: $0.installed, downloadGB: $0.downloadGB, sound: false)
                }
            }
            return list
        case .video:
            return VideoCatalog.models.filter { ram >= $0.minRAMGB && (!$0.isLTX2 || LTX2Engine.osSupported) }.map {
                WizardModelOption(id: $0.id, name: $0.name, installed: $0.installed, downloadGB: $0.downloadGB, sound: $0.hasAudio)
            }
        case .speech:
            return [WizardModelOption(id: SpeechCatalog.id, name: SpeechCatalog.name, installed: SpeechCatalog.installed,
                                      downloadGB: SpeechCatalog.downloadGB, sound: false)]
        case .music:
            return [WizardModelOption(id: AudioCatalog.id, name: AudioCatalog.name, installed: AudioCatalog.installed,
                                      downloadGB: AudioCatalog.downloadGB, sound: false)]
        }
    }

    /// Vorgewählt: das beste für diesen Mac (die Empfehlung nach Arbeitsspeicher)
    private func best(_ role: WizardRole) -> String {
        switch role {
        case .image: return ModelCatalog.recommended.id
        case .video: return VideoCatalog.recommended.id
        case .speech: return SpeechCatalog.id
        case .music: return AudioCatalog.id
        }
    }

    /// Gewählt: die eigene Wahl, solange sie zur Wahl steht, sonst das beste
    private func chosen(_ role: WizardRole) -> WizardModelOption? {
        let list = options(role)
        return list.first { $0.id == choice[role] } ?? list.first { $0.id == best(role) } ?? list.first
    }

    private func missing(_ roles: [WizardRole]) -> [WizardMissing] {
        roles.compactMap { r in chosen(r).flatMap { $0.installed ? nil : WizardMissing(role: r, model: $0) } }
    }

    private func gbText(_ gb: Double) -> String {
        String(format: "%.1f", gb).replacingOccurrences(of: ".", with: Lang.current == .de ? "," : ".") + " GB"
    }

    private func fetchState(_ m: WizardModelOption) -> String {
        guard let f = fetches[m.id] else { return t("noch nicht geladen (\(gbText(m.downloadGB)))", "not downloaded yet (\(gbText(m.downloadGB)))") }
        if let e = f.error { return e }
        return f.done ? "✓" : t("lädt … \(Int(f.progress * 100)) %", "downloading … \(Int(f.progress * 100)) %")
    }

    /// Fehlen gewählte Modelle, fragt der Assistent, ob er sie laden soll; danach zeigt er den Fortschritt
    @ViewBuilder private func fetchBox(_ roles: [WizardRole], _ why: String) -> some View {
        let list = missing(roles)
        if !list.isEmpty {
            let open = list.filter { fetches[$0.id] == nil || fetches[$0.id]?.error != nil }
            let gb = open.reduce(0.0) { $0 + $1.model.downloadGB }
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.callout.weight(.semibold))
                ForEach(list) { x in
                    Text("• \(x.role.label): \(x.model.name) (\(gbText(x.model.downloadGB)))"
                         + (fetches[x.id] == nil ? "" : " · " + fetchState(x.model)))
                        .font(.callout)
                }
                if !open.isEmpty {
                    Button(t("Ja, jetzt laden (\(gbText(gb)))", "Yes, download now (\(gbText(gb)))")) {
                        fetch(open.map(\.id))
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.8)))
        }
    }

    /// Fehlende Modelle laden, wenn der Nutzer Ja sagt: der normale Download-Auftrag der App, Fortschritt hier
    private func fetch(_ ids: [String]) {
        for id in ids where fetches[id] == nil || fetches[id]?.error != nil {
            fetches[id] = WizardFetch()
            Task {
                let job: JobRecord
                if id == AudioCatalog.id {
                    job = await JobQueue.shared.submitAudioDownload()
                } else if SpeechCatalog.matches(id) {
                    job = await JobQueue.shared.submitSpeechDownload()
                } else if VideoCatalog.model(id) != nil {
                    job = await JobQueue.shared.submitVideoDownload(id)
                } else if let m = Models.find(id) {
                    job = await JobQueue.shared.submitDownload(m)
                } else {
                    fetches[id]?.error = t("Unbekanntes Modell", "Unknown model")
                    return
                }
                while true {
                    try? await Task.sleep(for: .seconds(1))
                    guard let j = await JobQueue.shared.job(job.id) else {
                        fetches[id]?.error = t("Auftrag verschwunden.", "Job disappeared.")
                        return
                    }
                    if j.status == "done" { fetches[id] = WizardFetch(progress: 1, error: nil, done: true); return }
                    if j.status == "error" || j.status == "cancelled" { fetches[id]?.error = j.error ?? j.status; return }
                    fetches[id]?.progress = j.progress
                }
            }
        }
    }

    private var deviceLine: String {
        let cores = HardwareCatalog.gpuCores.map { t(", \($0) GPU-Kerne", ", \($0) GPU cores") } ?? ""
        var s = t("Dein Mac: \(SystemInfo.chip)\(cores), \(SystemInfo.memoryGB) GB.", "Your Mac: \(SystemInfo.chip)\(cores), \(SystemInfo.memoryGB) GB.")
        if let sp = HardwareCatalog.speed, HardwareCatalog.device?.id != HardwareCatalog.referenceID {
            s += " " + t("Etwa \(String(format: "%.1f", sp))-mal so schnell wie der gemessene Mac mini M1.",
                         "About \(String(format: "%.1f", sp))× the speed of the measured Mac mini M1.")
        }
        return s
    }

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if board.isEmpty {
                Text(summary).font(.callout)
                fetchBox(usedRoles, t("Noch nicht geladen. Soll ich die Modelle jetzt laden?", "Not downloaded yet. Shall I download the models now?"))
                HStack(spacing: 10) {
                    Button(busy == "build" ? t("Wird angelegt …", "Setting up …")
                           : t("Projekt anlegen und Startbilder erzeugen", "Set up the project and make the start images")) {
                        Task { await build() }
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(busy != nil || !missing([.image]).isEmpty)
                    if let stage { Text(stage).font(.callout).foregroundStyle(.secondary) }
                }
            } else {
                ForEach(Array(board.enumerated()), id: \.element.id) { i, item in
                    HStack(alignment: .center, spacing: 10) {
                        Text("\(i + 1)").font(.callout.monospacedDigit()).frame(width: 22)
                        if item.job == nil && item.variants.isEmpty && item.error == nil {
                            Text(t("setzt die Szene davor fort", "continues the scene before")).font(.callout).foregroundStyle(.secondary)
                        } else if let e = item.error {
                            Text(e).font(.callout).foregroundStyle(.red)
                        } else if item.variants.isEmpty {
                            Text(t("Startbild entsteht …", "Making the start image …")).font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(item.variants, id: \.id) { a in
                                Button { Task { await pick(i, a.id) } } label: {
                                    AssetThumbnail(asset: a, maxSide: 400)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(a.id == item.chosen ? Color.green : Color.clear, lineWidth: 3))
                                }
                                .buttonStyle(.plain).frame(maxHeight: 140)
                            }
                        }
                    }
                }
                fetchBox(usedRoles, t("Für die Szenen fehlt noch etwas. Soll ich es jetzt laden?", "Something is still missing for the scenes. Shall I download it now?"))
                Button(boardReady ? t("Szenen erzeugen", "Generate the scenes") : t("Warte auf die Startbilder …", "Waiting for the start images …")) {
                    Task { await generateScenes() }
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(!boardReady || busy != nil || !missing(usedRoles).isEmpty)
            }
        }
    }

    private var summary: String {
        var parts = [path.title, t("\(scenes.count) Szenen", "\(scenes.count) scenes"), "\(totalSeconds) s",
                     portrait ? t("hochkant", "portrait") : t("quer", "landscape"), style.label]
        if !characterOn { parts.append(t("ohne Figur", "without a character")) } else if chosenDraft != nil { parts.append(t("mit Figur", "with a character")) }
        if music { parts.append(t("mit Musik", "with music")) }
        return parts.joined(separator: ", ") + "."
    }

    private var boardReady: Bool { !board.isEmpty && board.allSatisfy { $0.job == nil || !$0.variants.isEmpty || $0.error != nil } }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            c()
        }
    }

    // MARK: Modelle und Zeiten

    /// Das gewählte Bildmodell (vorgewählt das beste; fehlt es, sperrt der Assistent Entwürfe und Startbilder)
    private var imageModelID: String? { chosen(.image)?.id }

    /// Bilder mit FLUX.2 Klein: Messwert 512² (0,26 MP) auf dem M1, linear nach Bildpunkten; mit Referenzbild rund
    /// 1,8-mal so lang (gemessen 14.11.2026: zwei Entwürfe 768 × 1024 mit Vorlage 409 s auf dem M1, ohne geschätzt 224 s)
    private func estimate(images: Int, megapixels: Double, reference: Bool = false) -> Double? {
        guard let id = imageModelID, let e = HardwareCatalog.estimate(id) else { return nil }
        return e.seconds * megapixels / 0.26 * Double(images) * (reference ? 1.8 : 1)
    }

    private var videoEstimate: Double? { videoEstimate(seconds: Double(totalSeconds)) }

    private func videoEstimate(seconds: Double) -> Double? {
        guard let id = chosen(.video)?.id, let e = HardwareCatalog.estimate(id) else { return nil }
        let per = e.task == "video_5s_512" ? 5.0 : 4.0
        return e.seconds / per * seconds
    }

    private var musicEstimate: Double? { musicEstimate(seconds: Double(totalSeconds)) }

    /// Messwert 12 s Musik; länger wächst die Zeit etwa mit der Länge
    private func musicEstimate(seconds: Double) -> Double? {
        HardwareCatalog.estimate(AudioCatalog.id).map { $0.seconds * max(1, seconds / 12) }
    }

    private var voiceEstimate: Double? { HardwareCatalog.estimate("qwen3-tts").map { $0.seconds * Double(lines.count) + 20 } }

    /// Rechenzeit aller Schritte, die noch kommen, für eine Szenenliste (wie die Zeilen unter „Modelle“; für die
    /// Vorschläge der Anzahl auch für eine andere Liste als die aktuelle)
    private func estimateTotal(_ list: [WizardSceneDraft]) -> Double? {
        let secs = Double(list.reduce(0) { $0 + $1.seconds })
        let starts = path.chain ? 1 : list.count
        guard let img = estimate(images: starts * 2, megapixels: 0.59, reference: path.photo || characterOn),
              let vid = videoEstimate(seconds: secs) else { return nil }
        var total = img + vid
        if characterOn && !path.photo && drafts.isEmpty {
            total += estimate(images: 4, megapixels: 0.79, reference: reference != nil) ?? 0
        }
        if !lines.isEmpty { total += voiceEstimate ?? 0 }
        if music { total += musicEstimate(seconds: secs) ?? 0 }
        return total
    }

    // MARK: Arbeit

    private func pickReference() {
        guard let url = Panels.chooseImage(path.photo ? t("Porträtfoto wählen", "Choose a portrait photo") : t("Vorlage wählen", "Choose a template")),
              let data = try? Data(contentsOf: url) else { return }
        Task {
            do {
                let pid = try await ensureProject()
                let record = try await AssetStore.shared.addUpload(data: data, originalName: url.lastPathComponent)
                await AssetStore.shared.tag([record.id], project: pid)
                reference = record
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Name aus dem ersten Satzteil der Idee (bis . ! ? : ;), lange Namen an einer Wortgrenze gekürzt
    private func projectName() -> String {
        let first = idea.split(whereSeparator: { ".!?:;\n".contains($0) }).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var name = first.isEmpty ? (charName.isEmpty ? t("Mein Video", "My video") : charName) : first
        if name.count > 48 {
            name = String(name.prefix(48))
            if let space = name.lastIndex(where: { $0 == " " || $0 == "," }) { name = String(name[..<space]) }
        }
        return name
    }

    /// Projekt erst beim ersten Rechenschritt: das offene, wenn es leer ist, sonst ein neues
    private func ensureProject() async throws -> String {
        if let projectID { return projectID }
        if let p = model.project, p.scenes.isEmpty, p.clips.isEmpty {
            projectID = p.id
        } else {
            await model.newProject()
            guard let p = model.project else { throw WizardError(message: t("Das Projekt ließ sich nicht anlegen.", "The project could not be created.")) }
            projectID = p.id
        }
        let (w, h) = portrait ? (1080, 1920) : (1920, 1080)
        _ = await model.run("project.update", ["name": .string(projectName()), "width": .int(w), "height": .int(h)])
        return projectID!
    }

    private func images(prompt: String, width: Int, height: Int, count: Int, references: [String], project: String) async throws -> [AssetRecord] {
        var body: [String: JSONValue] = ["prompt": .string(prompt), "width": .int(width), "height": .int(height), "batch_size": .int(count)]
        if let id = imageModelID { body["model_id"] = .string(id) }
        if !references.isEmpty { body["reference_asset_ids"] = .array(references.map { .string($0) }) }
        let request = try ImageJobRequest.parse(.object(body))
        let job = await JobQueue.shared.submit(request)
        while true {
            try await Task.sleep(for: .milliseconds(600))
            guard let j = await JobQueue.shared.job(job.id) else { throw WizardError(message: t("Auftrag verschwunden.", "Job disappeared.")) }
            if j.status == "done" {
                await AssetStore.shared.tag(j.assetIDs, project: project)
                var out: [AssetRecord] = []
                for id in j.assetIDs { if let r = await AssetStore.shared.get(id) { out.append(r) } }
                return out
            }
            if j.status == "error" || j.status == "cancelled" { throw WizardError(message: j.error ?? j.status) }
        }
    }

    private func makeDrafts() async {
        busy = "drafts"
        error = nil
        defer { busy = nil }
        do {
            let pid = try await ensureProject()
            let who = charName.isEmpty ? "the main character" : charName
            let en = await toEnglish([look])
            let prompt = reference != nil
                ? "\(style.image) Character design of \(who), based on the first image: \(dot(en[0].isEmpty ? "the same character" : en[0])). Full body, standing upright, facing the viewer, plain neutral background, nothing else in the picture."
                : "\(style.image) Character design of \(who): \(dot(en[0])). Full body, standing upright, facing the viewer, plain neutral background, nothing else in the picture."
            var out: [AssetRecord] = []
            for _ in 0..<2 {
                out += try await images(prompt: prompt, width: 768, height: 1024, count: 2, references: reference.map { [$0.id] } ?? [], project: pid)
            }
            drafts = out
            chosenDraft = out.first?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func dot(_ s: String) -> String {
        var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while x.hasSuffix(".") || x.hasSuffix(" ") { x.removeLast() }
        return x
    }

    /// Freie Texte treu ins Englische (Ziel „translate“, ein Aufruf, nummeriert); gesprochene Sätze bleiben.
    private func toEnglish(_ texts: [String]) async -> [String] {
        let need = texts.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty && (Lang.current == .de || $0.range(of: "[äöüßÄÖÜ]", options: .regularExpression) != nil) }
        guard need.contains(true) else { return texts }
        var out = texts
        let numbered = texts.enumerated().compactMap { i, x in need[i] ? "[\(i + 1)] \(x.split(whereSeparator: \.isNewline).joined(separator: " "))" : nil }
            .joined(separator: "\n")
        guard let result = try? await JobQueue.expandAndWait(numbered, target: .translate) else { return texts }
        for line in result.expanded.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]"), let n = Int(s[s.index(after: s.startIndex)..<close]),
                  n >= 1, n <= texts.count, need[n - 1] else { continue }
            out[n - 1] = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if texts.count == 1, need[0], out[0] == texts[0] { out[0] = result.expanded.trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }

    private func startPrompt(_ s: WizardSceneDraft, action: String, place: String, look: String) -> String {
        let setting = place.isEmpty ? "" : " Setting: \(place)."
        if path.photo {
            return "\(style.image) The person from the first image, with exactly the same face, eyes, nose, mouth and hair color: \(look). \(s.framing.prompt): \(action), the face clearly visible.\(setting) \(mood.light)"
        }
        let who = charName.isEmpty ? "the character" : charName
        let char = characterOn && chosenDraft != nil
            ? "The character is \(who) from the first image: the same face, the same body and the same clothes, in the same style. " : ""
        return "\(style.image) \(char)\(s.framing.prompt(cast: characterOn)): \(action).\(setting) \(mood.light)"
    }

    private func videoPrompt(_ s: WizardSceneDraft, action: String, place: String) -> String {
        // Ein Satz auf der Spur „Stimme“ (Mac: immer; ohne Figur vom Sprecher aus dem Off): Das Video bleibt leise, sonst
        // spräche ein Videomodell mit Ton womöglich selbst etwas dazu
        let spoken = path.lines != "none" && !s.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sound = path.lines == "narration" || spoken ? "Quiet ambient sound, no speech." : "Natural sounds of the scene."
        // eigene Sätze groß beginnen („Wide shot. A dark empty stage …“)
        func cap(_ x: String) -> String { x.prefix(1).uppercased() + x.dropFirst() }
        return [style.video + " " + s.framing.prompt(cast: characterOn) + ".", place.isEmpty ? "" : cap(place) + ".", mood.light,
                cap(action) + ".", "The camera holds steady.", sound].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func build() async {
        busy = "build"
        error = nil
        defer { busy = nil; stage = nil }
        do {
            let pid = try await ensureProject()
            stage = t("Texte werden ins Englische übertragen …", "Translating the texts into English …")
            // Der Musik-Prompt nur, wenn er nicht englisch aussieht (die Vorschläge sind englisch und bleiben wörtlich)
            let ownMusic = (musicText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let musicIn = !ownMusic.isEmpty && WizardMusic.looksGerman(ownMusic) ? ownMusic : ""
            let en = await toEnglish([idea, place, look, musicIn] + scenes.map(\.action))
            let txPlace = dot(en[1]), txLook = dot(en[2])
            let musicPrompt = !musicIn.isEmpty ? en[3] : (ownMusic.isEmpty ? musicPreset.prompt : ownMusic)
            let actions = scenes.indices.map { dot(en[4 + $0].isEmpty ? en[0] : en[4 + $0]) }
            stage = t("Szenen werden angelegt …", "Setting up the scenes …")
            var cid: String?
            if (characterOn && (chosenDraft != nil || (path.photo && reference != nil))) || !lines.isEmpty {
                let name = charName.isEmpty ? (lineMode == "narration" ? t("Sprecher", "Narrator") : t("Figur", "Character")) : charName
                cid = await model.run("character.add", ["name": .string(name), "voice": .string(voice.prompt), "language": .string(language)])?["id"]?.stringValue
            }
            let inPicture: [JSONValue] = (cid != nil && characterOn && (chosenDraft != nil || path.photo)) ? [.string(cid!)] : []
            let refs: [String] = path.photo ? (reference.map { [$0.id] } ?? []) : (characterOn ? (chosenDraft.map { [$0] } ?? []) : [])
            var ids: [String] = []
            var start = 0.0
            var firstVoice: String?
            for (i, s) in scenes.enumerated() {
                var params: [String: JSONValue] = ["lane": .string("video"), "kind": .string("video"),
                                                   "title": .string("\(i + 1) \(s.framing.label)"),
                                                   "prompt": .string(videoPrompt(s, action: actions[i], place: txPlace)),
                                                   "start_s": .double(start), "duration_s": .double(Double(s.seconds)),
                                                   "params": .object(["characters": .array(inPicture)])]
                if let v = chosen(.video)?.id { params["model_id"] = .string(v) }
                if path.chain && i > 0 { params["chain_from"] = .string(ids[i - 1]) }
                guard let id = await model.run("scene.add", params)?["id"]?.stringValue else { throw WizardError(message: model.notice ?? "scene.add") }
                ids.append(id)
                let line = s.line.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.lines != "none", !line.isEmpty {
                    let words = Double(line.split(whereSeparator: \.isWhitespace).count)
                    var vp: [String: JSONValue] = ["lane": .string("voice"), "title": .string(t("Satz \(i + 1)", "Line \(i + 1)")),
                                                   "prompt": .string(line), "start_s": .double(start + 0.2),
                                                   "duration_s": .double(min(Double(s.seconds), 0.6 + words / 2.4))]
                    if let cid { vp["params"] = .object(["character": .string(cid)]) }
                    if let v = await model.run("scene.add", vp)?["id"]?.stringValue {
                        if lineMode == "lines" {
                            // bleibt im Projekt; unter Windows spricht das Video den Satz mit den Lippen
                            _ = await model.run("scene.update", ["id": .string(id), "params": .object(["audio_from": .string(v)])])
                        }
                        firstVoice = firstVoice ?? v
                    }
                }
                start += Double(s.seconds)
            }
            if let cid, let firstVoice, lines.count > 1 {
                _ = await model.run("character.update", ["id": .string(cid), "voice_from": .string(firstVoice)])
            }
            if music {
                _ = await model.run("scene.add", ["lane": .string("music"), "title": .string(t("Musik", "Music")),
                                                  "prompt": .string(musicPrompt), "start_s": .double(0),
                                                  "duration_s": .double(Double(totalSeconds) + 0.5)])
            }
            stage = t("Startbilder entstehen …", "Making the start images …")
            let (w, h) = portrait ? (576, 1024) : (1024, 576)
            board = ids.enumerated().map { i, id in WizardBoardItem(id: id, job: (path.chain && i > 0) ? nil : "pending") }
            for (i, s) in scenes.enumerated() where !(path.chain && i > 0) {
                do {
                    let variants = try await images(prompt: startPrompt(s, action: actions[i], place: txPlace, look: txLook),
                                                    width: w, height: h, count: 2, references: refs, project: pid)
                    board[i].variants = variants
                    board[i].chosen = variants.first?.id
                    if let first = variants.first {
                        _ = await model.run("scene.update", ["id": .string(ids[i]), "params": .object(["image_asset_id": .string(first.id)])])
                    }
                } catch {
                    board[i].error = error.localizedDescription
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pick(_ i: Int, _ assetID: String) async {
        board[i].chosen = assetID
        _ = await model.run("scene.update", ["id": .string(board[i].id), "params": .object(["image_asset_id": .string(assetID)])])
    }

    private func generateScenes() async {
        busy = "videos"
        defer { busy = nil }
        await model.generate()
        onDone()
    }

    /// Prüfstand (`--studio-wizard`, siehe WizardDemo): Vorgabe eintragen, jeden Schritt fotografieren, Entwürfe und
    /// Startbilder erzeugen, die Wahl aus der Vorgabe treffen und auf Wunsch die Szenen starten.
    private func runDemo(_ s: WizardDemo.Script) async {
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1200))
            WizardDemo.snap(name)
        }
        try? await Task.sleep(for: .milliseconds(1500))
        if let id = WizardPathID(rawValue: s.path) { choose(id) }
        await snap("wz-1-path")
        idea = s.idea
        place = s.place ?? ""
        if let v = s.style.flatMap(WizardStyle.init(rawValue:)) { style = v }
        if let v = s.mood.flatMap(WizardMood.init(rawValue:)) { mood = v }
        step = .idea
        await snap("wz-2-idea")
        charName = s.name ?? ""
        look = s.look ?? ""
        if let ref = s.reference {
            let file = (ref as NSString).expandingTildeInPath
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                let pid = try await ensureProject()
                let record = try await AssetStore.shared.addUpload(data: data, originalName: (file as NSString).lastPathComponent)
                await AssetStore.shared.tag([record.id], project: pid)
                reference = record
            } catch {
                self.error = error.localizedDescription
            }
        }
        step = .character
        if let c = s.character { setCast(c) }
        await snap("wz-3-character")
        if s.drafts ?? true, characterOn, !path.photo {
            await makeDrafts()
            if let d = s.draft, d < drafts.count { chosenDraft = drafts[d].id }
            await snap("wz-3-character-drafts")
        }
        // Mit `count` wählt der Prüfstand die Anzahl wie ein Nutzer und füllt nur die ersten Szenen; `recount` ändert sie
        // danach noch einmal (Geschriebenes muss bleiben)
        if let n = s.count { setCount(n) }
        for (i, sc) in s.scenes.enumerated() {
            if i >= scenes.count {
                if s.count != nil { break }
                scenes.append(WizardSceneDraft(framing: .medium, seconds: 4, hint: ""))
            }
            scenes[i].action = sc.action
            scenes[i].line = sc.line ?? ""
            if let v = sc.seconds { scenes[i].seconds = v }
            if let v = sc.framing.flatMap(WizardFraming.init(rawValue:)) { scenes[i].framing = v }
        }
        if s.count == nil, scenes.count > s.scenes.count { scenes.removeLast(scenes.count - s.scenes.count) }
        step = .scenes
        await snap("wz-4-scenes")
        if let n = s.recount {
            setCount(n)
            AppLog.info("Wizard demo: recount \(n) -> \(scenes.count) scenes: \(scenes.map { $0.action.isEmpty ? "-" : $0.action }.joined(separator: " | "))")
            await snap("wz-4-recount")
        }
        if let v = s.voice.flatMap(WizardVoice.init(rawValue:)) { voice = v }
        if let v = s.language { language = v }
        if let v = s.music { music = v }
        if let v = s.musicPick { musicPick = v }
        if let v = s.musicPrompt { musicText = v }
        for (k, v) in s.models ?? [:] { if let r = WizardRole(rawValue: k) { choice[r] = v } }
        step = .sound
        await snap("wz-5-sound")
        step = .models
        await snap("wz-6-models")
        step = .create
        await snap("wz-7-create")
        if s.build ?? true {
            await build()
            for (i, k) in (s.picks ?? []).enumerated() where i < board.count && k < board[i].variants.count {
                await pick(i, board[i].variants[k].id)
            }
            await snap("wz-7-board")
        }
        AppLog.info("Wizard demo: cast \(characterOn), lines \(lineMode), image \(chosen(.image)?.id ?? "-"), video \(chosen(.video)?.id ?? "-"), missing \(missing(usedRoles).map(\.id)), music \((musicText ?? musicPreset.prompt).prefix(40))")
        AppLog.info("Wizard demo: project \(projectID ?? "-"), \(drafts.count) drafts, \(board.count) scenes, error \(error ?? "-")")
        if s.generate == true { await generateScenes() } else { onClose() }
        WizardDemo.finished = true
    }
}

/// Prüfstand für den Assistenten (Mac 0.5.6): `--snapshot <png> --tab studio --studio-wizard <json> --quit` spielt ihn
/// ohne Maus nach einer Vorgabe durch (Weg, Idee, Figur mit Vorlage, Anzahl und Szenen, Ton, Wahl der Entwürfe und Startbilder),
/// fotografiert jeden Schritt in den Ordner `out` und erzeugt mit `generate` die Szenen; LaunchOptions wartet darauf,
/// übernimmt mit `conform` in den Schnitt und fotografiert dann das Studio. Ohne die Option passiert nichts.
@MainActor
enum WizardDemo {
    struct Scene: Decodable {
        let action: String
        let line: String?
        let seconds: Int?
        let framing: String?
    }

    struct Script: Decodable {
        let path: String
        let style: String?
        let mood: String?
        let idea: String
        let place: String?
        let name: String?
        let look: String?
        let reference: String?
        let scenes: [Scene]
        /// Anzahl der Szenen wie im Schritt „Szenen“ gewählt, danach `recount` zum Prüfen des Änderns
        let count: Int?
        /// Mit oder ohne Figur (ohne Angabe die Vorgabe des Wegs)
        let character: Bool?
        /// Musikvorschlag (id aus WizardMusic) oder eigener Prompt
        let musicPick: String?
        let musicPrompt: String?
        /// Modellwahl je Aufgabe (image, video, speech, music)
        let models: [String: String]?
        let recount: Int?
        let voice: String?
        let language: String?
        let music: Bool?
        let drafts: Bool?
        let draft: Int?
        let build: Bool?
        let picks: [Int]?
        let generate: Bool?
        let conform: Bool?
        let out: String
    }

    static let loaded = Notification.Name("NVAIWizardDemoLoaded")
    /// Prüfstand angefordert: Dann fragt das Studio beim Start nicht (die Vorgabe wird erst nach dem Start geladen; lief
    /// die App gleich im Studio an, stand die Frage vor dem Blatt des Assistenten, 14.11.2026)
    static var requested: Bool { CommandLine.arguments.contains("--studio-wizard") }
    static var script: Script?
    static var started = false
    static var finished = false

    static func load(_ file: String) {
        do {
            script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            NotificationCenter.default.post(name: loaded, object: nil)
        } catch {
            AppLog.error("Wizard demo: \(error.localizedDescription)")
        }
    }

    private static var outDir: String { ((script?.out ?? "~/pruefstand/wizard") as NSString).expandingTildeInPath }

    /// Foto des Assistenten (Blatt) bzw. mit `sheet: false` des ganzen Fensters
    static func snap(_ name: String, sheet: Bool = true) {
        LaunchOptions.write((outDir as NSString).appendingPathComponent(name + ".png"), sheet: sheet)
    }
}

/// Frage beim Start des Studios und bei einem neuen Projekt (Kästchen „Nicht mehr anzeigen“)
struct StudioWizardAsk: View {
    let onAnswer: (_ start: Bool, _ never: Bool) -> Void
    @State private var never = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("✨ " + t("Soll ich dich durch dein Video führen?", "Shall I guide you through your video?")).font(.title3.weight(.semibold))
            Text(t("In sieben kurzen Schritten: Idee, Szenen und, wenn du willst, eine Figur wählst du; Modelle und Prompts schlägt der Assistent vor.",
                   "In seven short steps: you choose the idea, the scenes and, if you like, a character; the assistant suggests the models and prompts."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle(t("Nicht mehr anzeigen", "Don't show again"), isOn: $never)
            HStack {
                Spacer()
                Button(t("Nein, danke", "No, thanks")) { onAnswer(false, never) }
                Button(t("Ja, führ mich", "Yes, guide me")) { onAnswer(true, never) }
                    .buttonStyle(.borderedProminent).tint(.green).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    static let neverKey = "studio.wizard.never"
    static var wanted: Bool { !UserDefaults.standard.bool(forKey: neverKey) }
}

/// Kurze Hinweise nach dem Assistenten: was jetzt passiert und wie es weitergeht
struct StudioWizardCoach: View {
    let running: Int
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("✨ " + t("So geht es weiter", "What happens next")).font(.headline)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(running > 0
                 ? t("1. Die Szenen entstehen (\(running) offen). Den Fortschritt siehst du oben neben „Übernehmen“.",
                     "1. The scenes are being made (\(running) left). You see the progress at the top next to \"Conform\".")
                 : t("1. Die Szenen sind fertig.", "1. The scenes are done."))
                .foregroundStyle(running > 0 ? Color.green : Color.secondary)
            Text(t("2. Takes prüfen: eine Szene anklicken, rechts unter „Takes“.", "2. Check the takes: click a scene, see \"Takes\" on the right."))
            Text(t("3. „Übernehmen ↓“ legt alles in den Schnitt.", "3. \"Conform ↓\" puts everything into the edit."))
            Text(t("4. Format wählen und „Exportieren“.", "4. Pick a format and \"Export\"."))
        }
        .font(.callout)
        .padding(12)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.6)))
        .shadow(radius: 10)
    }
}
