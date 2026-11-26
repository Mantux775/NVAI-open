import Foundation

/// Studio im Fluss (seit Mac 1.0, Konzept „NVAI im Fluss“, Bildschirme D und E; wie flow/studio/logic.ts unter Windows):
/// Zustand je Szene, Weg einer Videoszene und der nächste Schritt des Projekts, abgeleitet aus dem Projekt (Szenen mit
/// Bahn und Art, Takes, Startbilder, Anschlüsse, Clips im Schnitt, Export). Reine Funktionen; die Oberfläche steht in
/// StudioFlowBar.swift und StudioSceneFocus.swift. Jeder Bildschirm beantwortet „Was passiert gerade? Was fehlt noch?
/// Was kommt als Nächstes?“. Was der Mac nicht rechnet (Schleife, Endbild, Layout-Video), erscheint nicht.
enum StudioFlow {
    /// „Startbild erzeugen“ einer Szene: zwei Varianten, die erste wird das Startbild. Gehört dem Studio, nicht den
    /// Eigenschaften: Der Auftrag läuft weiter, wenn man eine andere Szene wählt.
    struct StartRun: Equatable {
        let job: String
        var status: String  // running | done | error
        var variants: [String] = []
        var error: String?
    }

    struct Ctx {
        /// Projekt mit aufgelösten Anschluss-Markern
        let p: StudioProject
        let models: [FlowModel]
        let startRuns: [String: StartRun]
        let progress: (StudioScene) -> Double?
    }

    // MARK: Benennen

    static let laneOrder = ["video", "voice", "music", "sfx"]

    /// Bildszenen nach ihrem Start, danach Sprecher, Musik und Klang
    static func sceneOrder(_ p: StudioProject) -> [StudioScene] {
        p.scenes.sorted { a, b in
            let la = laneOrder.firstIndex(of: a.lane) ?? 9, lb = laneOrder.firstIndex(of: b.lane) ?? 9
            return la != lb ? la < lb : a.start < b.start
        }
    }

    /// Nummer einer Bildszene (1, 2, 3 …) bzw. Bahn und Nummer einer Tonszene („Sprecher 2“, bei nur einer „Musik“)
    static func sceneNum(_ p: StudioProject, _ id: String?) -> String {
        guard let s = p.scenes.first(where: { $0.id == id }) else { return "?" }
        let same = p.scenes.filter { $0.lane == s.lane }.sorted { $0.start < $1.start }
        let n = (same.firstIndex { $0.id == s.id } ?? 0) + 1
        if s.lane == "video" { return "\(n)" }
        let one = same.count == 1
        switch s.lane {
        case "voice": return one ? t("Sprecher", "Voice") : t("Sprecher \(n)", "Voice \(n)")
        case "music": return one ? t("Musik", "Music") : t("Musik \(n)", "Music \(n)")
        default: return one ? t("Klang", "Sound") : t("Klang \(n)", "Sound \(n)")
        }
    }

    /// „Szene 3“ bzw. „Sprecher 2“, für Sätze wie „wartet auf Szene 3“
    static func sceneRef(_ p: StudioProject, _ id: String?) -> String {
        guard let s = p.scenes.first(where: { $0.id == id }) else { return t("eine gelöschte Szene", "a deleted scene") }
        let num = sceneNum(p, id)
        return s.lane == "video" ? t("Szene \(num)", "Scene \(num)") : num
    }

    /// Titel einer Szene; ohne Titel der Anfang des Prompts
    static func sceneTitle(_ s: StudioScene) -> String {
        !s.title.isEmpty ? s.title : !s.prompt.isEmpty ? String(s.prompt.prefix(40)) : t("ohne Titel", "untitled")
    }

    /// Länge kurz: „22 s“, „1:05 min“
    static func fmtLength(_ ticks: Int) -> String {
        let s = Int(Studio.seconds(ticks).rounded())
        return s < 60 ? "\(s) s" : String(format: "%d:%02d min", s / 60, s % 60)
    }

    // MARK: Modelle

    /// image, video, speech oder audio
    static func modelKind(_ s: StudioScene) -> String {
        s.lane == "video" ? (s.kind == "image" ? "image" : "video") : s.lane == "voice" ? "speech" : "audio"
    }

    /// Das Videomodell einer Szene wie StudioGenerator.videoModel (das eigene, wenn geladen, sonst das aktive), aber aus
    /// dem Modellstand der App statt aus dem Dateisystem: Leiste und Karten fragen bei jedem Zeichnen
    static func videoModelID(_ s: StudioScene, _ models: [FlowModel]) -> String {
        let installed = Set(models.filter { $0.kind == "video" && $0.installed }.map(\.id))
        if let own = s.modelID, installed.contains(own) { return own }
        if let chosen = UserDefaults.standard.string(forKey: "video.model"), installed.contains(chosen) { return chosen }
        let rec = VideoCatalog.recommended.id
        if installed.contains(rec) { return rec }
        return VideoCatalog.models.filter { installed.contains($0.id) }.max { $0.minRAMGB < $1.minRAMGB }?.id ?? VideoModel.ltxv2B.id
    }

    /// Das Modell, mit dem die Szene rechnet (wie StudioGenerator.request): Standbild das eigene, sonst das aktive;
    /// Video das eigene, wenn geladen, sonst das aktive; Stimme Qwen3-TTS; Musik und Klang Stable Audio 3
    static func sceneModelID(_ s: StudioScene, _ models: [FlowModel]) -> String {
        switch modelKind(s) {
        case "image": return Models.find(s.modelID) != nil ? s.modelID! : (Models.find(Settings.activeModelID)?.id ?? Models.active.id)
        case "video": return videoModelID(s, models)
        case "speech": return SpeechCatalog.id
        default: return AudioCatalog.id
        }
    }

    static func sceneModel(_ s: StudioScene, _ models: [FlowModel]) -> FlowModel? {
        let id = sceneModelID(s, models)
        return models.first { $0.id == id }
    }

    private static func installed(_ id: String, _ models: [FlowModel]) -> Bool { models.first { $0.id == id }?.installed ?? false }

    /// Fehlt das Modell der Szene? Das fehlende Modell (zum Laden), sonst nil. Solange die Liste lädt: nil.
    static func missingModel(_ s: StudioScene, _ models: [FlowModel]) -> FlowModel? {
        guard !models.isEmpty else { return nil }
        switch modelKind(s) {
        case "video":
            return models.contains { $0.kind == "video" && $0.installed } ? nil : models.first { $0.id == VideoCatalog.recommended.id }
        case "speech":
            return installed(SpeechCatalog.id, models) ? nil : models.first { $0.id == SpeechCatalog.id }
        case "audio":
            return installed(AudioCatalog.id, models) ? nil : models.first { $0.id == AudioCatalog.id }
        default:
            let m = sceneModel(s, models)
            if let m, m.installed { return nil }
            // eigene Wahl, die fehlt; ohne Wahl und ohne geladenes Bildmodell das empfohlene
            if s.modelID != nil, let m { return m }
            if models.contains(where: { $0.kind == "image" && $0.installed }) { return nil }
            return models.first { $0.id == ModelCatalog.recommended.id }
        }
    }

    /// Ein geladenes Modell, das es auch tut (für „Lieber … (geladen)“)
    static func loadedAlternative(_ s: StudioScene, _ models: [FlowModel], _ missing: FlowModel) -> FlowModel? {
        let loaded = models.filter { $0.kind == missing.kind && $0.installed && $0.id != missing.id }
        return loaded.first { $0.recommended } ?? loaded.first
    }

    // MARK: Weg (Video)

    /// Wege einer Videoszene auf dem Mac, eine Wahl statt Klappen (Bildschirm E): Nur Text, Startbild, Anschluss.
    enum Way: String, CaseIterable { case text, start, chain }

    /// Der Weg aus den Angaben der Szene; ohne eigene Wahl ein Startbild (so arbeitet auch der Assistent)
    static func wayOf(_ s: StudioScene) -> Way {
        if s.chainFrom != nil { return .chain }
        if s.params["image_asset_id"]?.stringValue?.isEmpty == false { return .start }
        if s.params["way"]?.stringValue == "text" { return .text }
        return .start
    }

    /// Die Bildszene direkt davor (Ziel von „Anschluss an“)
    static func sceneBefore(_ p: StudioProject, _ s: StudioScene) -> StudioScene? {
        p.scenes.filter { $0.lane == "video" && $0.id != s.id && $0.start < s.start }.max { $0.start < $1.start }
    }

    /// Anschluss, der nicht mehr an seine Vorlage grenzt (seit sich Szenen in der Kartenreihe umordnen lassen): die
    /// Vorlage, wenn sie nicht direkt (± 0,5 s) vor der Szene endet, sonst nil. Mit Take zählt, wessen Ende der Take
    /// wirklich fortsetzt, ohne Take der Anschluss, mit dem er entstünde.
    static func chainApart(_ p: StudioProject, _ s: StudioScene) -> StudioScene? {
        guard s.lane == "video", s.kind == "video" else { return nil }
        let id = s.take != nil ? StudioGenerator.carry(p, s) : s.chainFrom
        guard let id, let src = p.scenes.first(where: { $0.id == id }) else { return nil }
        let before = sceneBefore(p, s)
        return before?.id == src.id && abs(src.end - s.start) <= Studio.ticksPerSecond / 2 ? nil : src
    }

    /// Neue Startzeiten, wenn die Szenen einer Bahn in der Reihenfolge `ids` liegen sollen: lückenlos ab dem Start der
    /// bisher ersten, Längen bleiben, aufs Bildraster des Projekts. Nur die Szenen, deren Start sich ändert.
    static func reorderStarts(_ p: StudioProject, lane: String, ids: [String]) -> [(id: String, start: Int)] {
        let scenes = p.scenes.filter { $0.lane == lane }
        guard var at = scenes.map(\.start).min() else { return [] }
        let frame = max(1, p.frameTicks)
        var out: [(id: String, start: Int)] = []
        for id in ids {
            guard let s = scenes.first(where: { $0.id == id }) else { continue }
            let start = Int((Double(at) / Double(frame)).rounded()) * frame
            if start != s.start { out.append((id, start)) }
            at += s.duration
        }
        return out
    }

    /// Was ein Klick auf einen Weg an der Szene ändert (Felder für scene.update): „Nur Text“ nimmt das Startbild heraus,
    /// ⌘Z holt es zurück
    static func wayChange(_ s: StudioScene, _ way: Way, chainTo: String?) -> StudioParams {
        var out: StudioParams = [:]
        if s.chainFrom != nil && way != .chain { out["chain_from"] = .null }
        switch way {
        case .text: out["params"] = .object(["way": .string("text"), "image_asset_id": .null])
        case .start: out["params"] = .object(["way": .string("start")])
        case .chain:
            out["chain_from"] = chainTo.map(JSONValue.string) ?? .null
            out["params"] = .object(["way": .string("chain")])
        }
        return out
    }

    /// „4 s · 800 × 448“ unter dem Modell-Chip: Länge und das Format, das dieser Mac bei der Länge rechnet
    static func sceneFacts(_ p: StudioProject, _ s: StudioScene, _ models: [FlowModel]) -> String {
        let len = formatDecimal(Studio.seconds(s.duration), digits: 1) + " s"
        if s.lane == "voice" { return t("Länge folgt dem Satz", "length follows the line") }
        if s.lane != "video" { return len }
        if s.kind == "image" {
            let size = StudioGenerator.imageSize(p, s.params)
            return t("Standbild · \(len) · \(size.width) × \(size.height)", "still image · \(len) · \(size.width) × \(size.height)")
        }
        let video = VideoCatalog.model(videoModelID(s, models)) ?? .ltxv2B
        guard let size = StudioGenerator.videoSize(p, frames: StudioGenerator.videoFrames(s), maxVoxels: video.maxVoxels,
                                                   step: video.sizeStep) else {
            return t("\(len) · zu lang für diesen Mac", "\(len) · too long for this Mac")
        }
        return "\(len) · \(size.width) × \(size.height)"
    }

    // MARK: Zustand je Szene

    /// Der gewählte Take liegt als Clip im Schnitt
    static func inEdit(_ p: StudioProject, _ s: StudioScene) -> Bool {
        guard let take = s.take else { return false }
        return p.clips.contains { $0.sceneID == s.id && $0.assetID == take }
    }

    /// Mehrere Takes, keiner bestätigt (Klick auf einen Take oder „Take … behalten“ setzt params.take_ok), und noch nicht
    /// im Schnitt: Dann wählt der Nutzer, bevor es weitergeht (Bildschirm D: „Take wählen (2)“)
    static func needsChoice(_ p: StudioProject, _ s: StudioScene) -> Bool {
        s.takes.count > 1 && s.take != nil && s.params["take_ok"]?.stringValue != s.take && !inEdit(p, s)
    }

    struct SceneState: Equatable {
        let key: String
        let tone: FlowTone
        let label: String
    }

    private static func doneLabel(_ s: StudioScene) -> String {
        if s.lane == "voice" { return t("Satz fertig", "line done") }
        if s.lane != "video" { return t("Ton fertig", "sound done") }
        return s.kind == "image" ? t("Bild fertig", "image done") : t("Video fertig", "video done")
    }

    /// Zustand einer Szene als Chip: was gerade passiert, was fehlt, was als Nächstes kommt
    static func sceneState(_ c: Ctx, _ s: StudioScene) -> SceneState {
        let p = c.p
        if !s.jobs.isEmpty {
            let pr = c.progress(s)
            return SceneState(key: "running", tone: .info,
                              label: pr.map { t("rechnet \(Int(($0 * 100).rounded())) %", "computing \(Int(($0 * 100).rounded())) %") }
                                ?? t("rechnet", "computing"))
        }
        if let w = s.waitingFor {
            return SceneState(key: "waiting", tone: .plain, label: t("wartet auf \(sceneRef(p, w))", "waits for \(sceneRef(p, w))"))
        }
        if c.startRuns[s.id]?.status == "running" {
            return SceneState(key: "start_running", tone: .info, label: t("Startbild entsteht", "start image in progress"))
        }
        if s.error != nil { return SceneState(key: "error", tone: .err, label: t("Fehler", "error")) }
        if s.take != nil, StudioGenerator.stale(p, s) != nil {
            return SceneState(key: "stale", tone: .warn, label: t("veraltet", "outdated"))
        }
        let apart = SceneState(key: "chain_apart", tone: .warn, label: t("Anschluss getrennt", "chain apart"))
        if s.take != nil, chainApart(p, s) != nil { return apart }
        if s.take != nil {
            if needsChoice(p, s) {
                return SceneState(key: "choose", tone: .info, label: t("Take wählen (\(s.takes.count))", "choose a take (\(s.takes.count))"))
            }
            if inEdit(p, s) { return SceneState(key: "in_edit", tone: .ok, label: t("im Schnitt", "in the edit")) }
            return SceneState(key: "done", tone: .ok, label: doneLabel(s))
        }
        if missingModel(s, c.models) != nil { return SceneState(key: "model", tone: .warn, label: t("Modell fehlt", "model missing")) }
        if s.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SceneState(key: "prompt", tone: .warn, label: t("Prompt fehlt", "prompt missing"))
        }
        if s.lane == "video" && s.kind == "video" {
            switch wayOf(s) {
            case .chain:
                if chainApart(p, s) != nil { return apart }
                if let src = p.scenes.first(where: { $0.id == s.chainFrom }), src.take == nil {
                    return SceneState(key: "chain_wait", tone: .plain, label: t("wartet auf \(sceneRef(p, src.id))", "waits for \(sceneRef(p, src.id))"))
                }
                return SceneState(key: "ready", tone: .plain, label: t("Anschluss an \(sceneNum(p, s.chainFrom))", "chained to \(sceneNum(p, s.chainFrom))"))
            case .start:
                if s.params["image_asset_id"]?.stringValue?.isEmpty == false {
                    return SceneState(key: "start_set", tone: .plain, label: t("Startbild gewählt", "start image chosen"))
                }
                return SceneState(key: "start_missing", tone: .warn, label: t("Startbild fehlt", "start image missing"))
            case .text:
                return SceneState(key: "ready", tone: .plain, label: t("nur Text", "text only"))
            }
        }
        return SceneState(key: "ready", tone: .plain, label: t("bereit", "ready"))
    }

    /// Die Szene samt ihren Vorlagen ohne Take, die noch nicht laufen: Allein scheiterte ein Anschluss an „braucht die
    /// vorherige Szene erst ein Video“; zusammen wartet er auf sie (StudioGenerator.generate)
    static func withSources(_ p: StudioProject, _ ids: [String], _ env: StudioEnvironment) -> [String] {
        var out: [String] = []
        func add(_ id: String, _ depth: Int) {
            guard !out.contains(id), depth <= 20 else { return }
            out.append(id)
            guard let s = p.scenes.first(where: { $0.id == id }) else { return }
            for d in StudioCommands.dependencies(p, s, env) {
                if let src = p.scenes.first(where: { $0.id == d }), src.take == nil, src.jobs.isEmpty, src.waitingFor == nil {
                    add(d, depth + 1)
                }
            }
        }
        ids.forEach { add($0, 0) }
        return out
    }

    // MARK: Nächster Schritt (D)

    struct ExportInfo: Equatable {
        var status: String  // none | running | done | error
        var progress: Double
        var file: String?
        /// Der fertige Export zeigt den heutigen Schnitt (nach einer Änderung wird neu exportiert)
        var fresh: Bool
        /// „Shorts 1080 × 1920“
        var preset: String
    }

    enum NextKind: String {
        case wizard, model, prompt, start, choose, stale, generate, busy, error, conform, export, exporting, done, idle
    }

    struct Next {
        let kind: NextKind
        /// Schritt der Leiste, der dran ist (0 Idee … 5 Export, 6 alles erledigt)
        let step: Int
        let scenes: [StudioScene]
        let label: String
        /// zweite Zeile, wenn keine Zeit passt: „2 Varianten“, „4 Clips“, „ansehen“
        var note: String = ""
        var disabled = false
        /// Feld, das nach dem Klick in den Blick kommt
        var field: String?
    }

    /// „Szene 4“, „Szene 3 und 4“, bei mehr als drei „5 Szenen“
    private static func forScenes(_ p: StudioProject, _ list: [StudioScene]) -> (de: String, en: String) {
        let n = list.map { sceneNum(p, $0.id) }
        if list.count == 1 { return (sceneRef(p, list[0].id), sceneRef(p, list[0].id)) }
        if list.count <= 3 && list.allSatisfy({ $0.lane == "video" }) {
            let head = n.dropLast().joined(separator: ", ")
            return ("Szene \(head) und \(n.last!)", "scenes \(head) and \(n.last!)")
        }
        return ("\(list.count) Szenen", "\(list.count) scenes")
    }

    static func nextStep(_ c: Ctx, _ ex: ExportInfo) -> Next {
        let p = c.p
        let all = sceneOrder(p)
        if all.isEmpty {
            return Next(kind: .wizard, step: 0, scenes: [], label: t("Mit dem Assistenten beginnen", "Start with the assistant"),
                        note: t("ein ganzes Video, sieben kurze Schritte", "a whole video, seven short steps"))
        }
        let states = Dictionary(all.map { ($0.id, sceneState(c, $0).key) }, uniquingKeysWith: { a, _ in a })
        func of(_ keys: String...) -> [StudioScene] { all.filter { keys.contains(states[$0.id] ?? "") } }

        if let s = of("model").first {
            let m = missingModel(s, c.models)
            return Next(kind: .model, step: 3, scenes: [s],
                        label: t("\(m?.short ?? "Modell") für \(sceneRef(p, s.id)) laden", "Download \(m?.short ?? "the model") for \(sceneRef(p, s.id))"),
                        note: t("Größe und Lizenz ansehen", "see size and license"), field: "model")
        }
        if let s = of("prompt").first {
            return Next(kind: .prompt, step: 1, scenes: [s],
                        label: t("Prompt für \(sceneRef(p, s.id)) schreiben", "Write the prompt for \(sceneRef(p, s.id))"), field: "prompt")
        }
        // Startbilder, die gerade entstehen, erst ansehen (zwei Varianten), dann die Videos
        let making = of("start_running")
        if !making.isEmpty {
            let f = forScenes(p, making)
            return Next(kind: .busy, step: 2, scenes: making,
                        label: making.count == 1 ? t("Startbild für \(f.de) entsteht", "Start image for \(f.en) in progress")
                            : t("Startbilder für \(f.de) entstehen", "Start images for \(f.en) in progress"), field: "way")
        }
        let starts = of("start_missing")
        if !starts.isEmpty && !c.models.isEmpty && startImageModelID(p, starts[0]) == nil {
            // Ohne Bildmodell gibt es kein Startbild: erst das Modell, an Ort und Stelle in der Szene
            return Next(kind: .model, step: 2, scenes: [starts[0]],
                        label: t("Bildmodell für die Startbilder laden", "Download an image model for the start images"),
                        note: t("Größe und Lizenz ansehen", "see size and license"), field: "state")
        }
        if !starts.isEmpty {
            let f = forScenes(p, starts)
            return Next(kind: .start, step: 2, scenes: starts,
                        label: starts.count == 1 ? t("Startbild für \(f.de) erzeugen", "Generate the start image for \(f.en)")
                            : t("Startbilder für \(f.de) erzeugen", "Generate start images for \(f.en)"))
        }
        // Takes wählen: Vorlagen von Anschlüssen zuerst, ihr Take bestimmt den Anfang der nächsten Szene
        let isSource = { (s: StudioScene) in p.scenes.contains { $0.chainFrom == s.id } }
        if let s = of("choose").sorted(by: { isSource($0) && !isSource($1) }).first {
            return Next(kind: .choose, step: 3, scenes: [s],
                        label: t("Take für \(sceneRef(p, s.id)) wählen", "Choose a take for \(sceneRef(p, s.id))"),
                        note: t("\(s.takes.count) Varianten", "\(s.takes.count) variants"), field: "takes")
        }
        if let s = of("stale").first {
            return Next(kind: .stale, step: 3, scenes: [s], label: t("\(sceneRef(p, s.id)) ist veraltet", "\(sceneRef(p, s.id)) is outdated"),
                        note: t("ansehen", "review"), field: "state")
        }
        let gen = all.filter { ["ready", "start_set", "chain_wait"].contains(states[$0.id] ?? "")
            || (states[$0.id] == "chain_apart" && $0.take == nil) }
        if !gen.isEmpty {
            let f = forScenes(p, gen)
            let videos = gen.allSatisfy { $0.lane == "video" && $0.kind == "video" }
            let label = videos
                ? (gen.count == 1 ? t("Video für \(f.de) erzeugen", "Generate the video for \(f.en)") : t("Videos für \(f.de) erzeugen", "Generate videos for \(f.en)"))
                : (gen.count == 1 ? t("\(f.de) erzeugen", "Generate \(f.en)") : t("\(gen.count) Szenen erzeugen", "Generate \(gen.count) scenes"))
            return Next(kind: .generate, step: 3, scenes: gen, label: label)
        }
        let busy = of("running", "waiting")
        if !busy.isEmpty {
            let cur = busy.first { !$0.jobs.isEmpty } ?? busy[0]
            let more = busy.count > 1 ? t(" · \(busy.count - 1) weitere", " · \(busy.count - 1) more") : ""
            let pr = c.progress(cur).map { " · \(Int(($0 * 100).rounded())) %" } ?? ""
            return Next(kind: .busy, step: 3, scenes: [cur],
                        label: (!cur.jobs.isEmpty ? t("\(sceneRef(p, cur.id)) rechnet\(pr)", "\(sceneRef(p, cur.id)) computing\(pr)")
                                : t("\(sceneRef(p, cur.id)) wartet", "\(sceneRef(p, cur.id)) waiting")) + more, field: "state")
        }
        if let s = of("error").first {
            return Next(kind: .error, step: 3, scenes: [s], label: t("Fehler in \(sceneRef(p, s.id))", "Error in \(sceneRef(p, s.id))"),
                        note: t("ansehen", "review"), field: "state")
        }
        let withTake = all.filter { $0.take != nil }
        let pending = withTake.filter { !inEdit(p, $0) }
        if !pending.isEmpty {
            return Next(kind: .conform, step: 4, scenes: pending,
                        label: pending.count == withTake.count ? t("Alles in den Schnitt legen", "Put everything into the edit")
                            : t("In den Schnitt legen", "Put into the edit"),
                        note: pending.count == 1 ? t("1 Clip", "1 clip") : t("\(pending.count) Clips", "\(pending.count) clips"))
        }
        if p.clips.isEmpty {
            return Next(kind: .idle, step: 4, scenes: [], label: t("Der Schnitt ist leer", "The edit is empty"), disabled: true)
        }
        if ex.status == "running" {
            let pct = Int((ex.progress * 100).rounded())
            return Next(kind: .exporting, step: 5, scenes: [], label: t("Export läuft · \(pct) %", "Exporting · \(pct) %"), disabled: true)
        }
        if ex.status == "done" && ex.fresh {
            return Next(kind: .done, step: 6, scenes: [], label: t("Fertig: \(ex.file ?? "")", "Done: \(ex.file ?? "")"),
                        note: t("ansehen, liegt auch im Projektordner", "view, also in the project folder"))
        }
        return Next(kind: .export, step: 5, scenes: [], label: t("Exportieren · \(ex.preset)", "Export · \(ex.preset)"),
                    note: t("\(fmtLength(p.editDuration)) Film", "\(fmtLength(p.editDuration)) film"))
    }

    // MARK: Leiste (D)

    struct RailStep: Identifiable {
        let id: String  // idea | scenes | starts | videos | edit | export
        let label: String
        let small: String
        let done: Bool
        let title: String
    }

    /// `nextKind`: Art des nächsten Schritts; „n Clips bereit“ steht erst, wenn das Übernehmen dran ist (vorher „leer“)
    static func railSteps(_ c: Ctx, _ ex: ExportInfo, _ nextKind: NextKind) -> [RailStep] {
        let p = c.p
        let all = p.scenes
        let states = Dictionary(all.map { ($0.id, sceneState(c, $0).key) }, uniquingKeysWith: { a, _ in a })
        let clips = all.filter { $0.lane == "video" && $0.kind == "video" }
        let relevant = clips.filter { wayOf($0) != .text }
        let covered = relevant.filter { $0.take != nil || $0.chainFrom != nil || $0.params["image_asset_id"]?.stringValue?.isEmpty == false }.count
        let fine = all.filter { ["done", "in_edit"].contains(states[$0.id] ?? "") }.count
        let withTake = all.filter { $0.take != nil }
        let pending = withTake.filter { !inEdit(p, $0) }.count
        let sounds = all.filter { $0.lane != "video" }.count
        let edit = pending > 0 && nextKind == .conform
            ? (pending == 1 ? t("1 Clip bereit", "1 clip ready") : t("\(pending) Clips bereit", "\(pending) clips ready"))
            : !p.clips.isEmpty ? t("\(fmtLength(p.editDuration)) im Schnitt", "\(fmtLength(p.editDuration)) in the edit") : t("leer", "empty")
        let export = ex.status == "running" ? "\(Int((ex.progress * 100).rounded())) %"
            : ex.status == "done" && ex.fresh && ex.file != nil ? ex.file! : ex.preset
        return [
            RailStep(id: "idea", label: t("Idee", "Idea"), small: p.name, done: !all.isEmpty,
                     title: t("Der Name des Projekts; der Assistent nennt es nach der Idee.", "The project name; the assistant names it after the idea.")),
            RailStep(id: "scenes", label: t("Szenen", "Scenes"),
                     small: all.isEmpty ? t("noch keine", "none yet")
                        : t("\(all.count) Szenen · \(fmtLength(p.compositionDuration))", "\(all.count) scenes · \(fmtLength(p.compositionDuration))"),
                     done: !all.isEmpty && all.allSatisfy { $0.take != nil || !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty },
                     title: sounds > 0 ? t("Davon \(sounds) auf den Tonbahnen (Sprecher, Musik, Klang).", "\(sounds) of them on the sound lanes (voice, music, sound).")
                        : t("Szenen der Komposition.", "Scenes of the composition.")),
            RailStep(id: "starts", label: t("Startbilder", "Start images"),
                     small: relevant.isEmpty ? t("nicht nötig", "not needed") : t("\(covered) von \(relevant.count)", "\(covered) of \(relevant.count)"),
                     done: !all.isEmpty && covered == relevant.count,
                     title: t("Videoszenen mit Startbild, Anschluss oder fertigem Take; „Nur Text“ braucht keins.",
                              "Video scenes with a start image, a chain or a finished take; \"Text only\" needs none.")),
            RailStep(id: "videos", label: t("Videos", "Videos"), small: t("\(fine) von \(all.count)", "\(fine) of \(all.count)"),
                     done: !all.isEmpty && fine == all.count,
                     title: t("Szenen mit gewähltem Take (Video, Bild und Ton).", "Scenes with a chosen take (video, image and sound).")),
            RailStep(id: "edit", label: t("Schnitt", "Edit"), small: edit, done: !p.clips.isEmpty && pending == 0,
                     title: t("„Übernehmen“ legt die gewählten Takes in den Schnitt.", "\"Conform\" puts the chosen takes into the edit.")),
            RailStep(id: "export", label: "Export", small: export, done: ex.status == "done" && ex.fresh,
                     title: t("Die Vorlage folgt dem Projektformat (Hochformat: Shorts).", "The preset follows the project format (portrait: Shorts).")),
        ]
    }

    /// Kurzname einer Exportvorlage für Leiste und Knopf
    static func presetShort(_ id: String, _ p: StudioProject) -> String {
        switch id {
        case "shorts-1080x1920": return "Shorts 1080 × 1920"
        case "youtube-1080p": return "YouTube 1080p"
        case "youtube-2160p": return "YouTube 4K"
        case "prores": return "ProRes 4444"
        case "project": return "\(p.settings.width) × \(p.settings.height)"
        default:
            return StudioRender.presets.first { $0.id == id }.map { Lang.current == .de ? $0.label.de : $0.label.en } ?? id
        }
    }

    /// Exportvorlage nach dem Projektformat (Nutzertest 26.11.2026: ein Hochkant-Projekt ging sonst als 1920 × 1080
    /// hinaus): hochkant Shorts, 4K YouTube 4K, 1920 × 1080 YouTube 1080p, andere Größen im Projektformat
    static func presetForFormat(_ w: Int, _ h: Int) -> String {
        if h > w { return "shorts-1080x1920" }
        if w >= 3840 && h >= 2160 { return "youtube-2160p" }
        return w == 1920 && h == 1080 ? "youtube-1080p" : "project"
    }

    // MARK: Zeiten

    /// Bildmodell für „Startbild erzeugen“ (wie StudioGenerator.startImageModel); nil, wenn keins geladen ist
    static func startImageModelID(_ p: StudioProject, _ s: StudioScene) -> String? {
        StudioGenerator.startImageModel(p, s, StudioMediaProbe.environment)
    }

    /// Fehlt jedes Bildmodell für Startbilder: das, das man laden sollte (FLUX.2 Klein in der Fassung für diesen Mac)
    static func startImageNeed(_ p: StudioProject, _ s: StudioScene, _ models: [FlowModel]) -> FlowModel? {
        guard !models.isEmpty, startImageModelID(p, s) == nil else { return nil }
        return models.first { $0.id == ModelCatalog.recommended.id }
    }

    /// Eine Folge von Aufträgen: Rechenzeit je Auftrag, Laden einmal je Modell. unknown zählt die ohne Zahl.
    static func sumEstimates(_ list: [JobEstimate?]) -> (seconds: Double?, unknown: Int) {
        var total = 0.0, known = 0
        var loads: [String: Double] = [:]
        for e in list {
            guard let e, let s = e.seconds else { continue }
            known += 1
            total += s
            let key = e.modelID ?? ""
            if loads[key] == nil { loads[key] = e.load ?? 0 }
        }
        return (known > 0 ? total + loads.values.reduce(0, +) : nil, list.count - known)
    }

    /// Zeit je Szene: was geschätzt ist; Szenen ohne Zahl (ein Anschluss, dessen Vorlage erst im selben Lauf entsteht)
    /// aus der Rate einer Szene mit demselben Modell, hochgerechnet auf ihre Länge
    static func sceneEstimates(_ scenes: [StudioScene], _ got: [String: JobEstimate], _ models: [FlowModel]) -> [JobEstimate?] {
        let out: [JobEstimate?] = scenes.map { s in got[s.id].flatMap { $0.seconds != nil ? $0 : nil } }
        var rate: [String: (perSec: Double, e: JobEstimate)] = [:]
        for (s, e) in zip(scenes, out) {
            guard let e, let secs = e.seconds else { continue }
            let m = sceneModelID(s, models)
            if rate[m] == nil { rate[m] = (secs / max(0.5, Studio.seconds(s.duration)), e) }
        }
        return zip(scenes, out).map { s, e in
            if let e { return e }
            guard let r = rate[sceneModelID(s, models)] else { return nil }
            var copy = r.e
            copy.seconds = r.perSec * Studio.seconds(s.duration)
            copy.source = "rough"
            return copy
        }
    }
}
