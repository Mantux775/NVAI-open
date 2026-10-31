import AppKit
import SwiftUI

/// Eigenschaften wie studio/Inspector.tsx unter Windows: je nach Auswahl Projekt, Szene, Clip, Übergang, Marker,
/// mehrere Objekte oder ein Material. Felder übernehmen beim Bestätigen oder Verlassen; Zahlen mit Komma oder Punkt.
struct StudioInspector: View {
    @ObservedObject var model: StudioModel

    static func markerName(_ kind: String) -> String {
        switch kind {
        case "place": return t("Platzieren", "Place")
        case "transition": return t("Übergang", "Transition")
        case "chain": return t("Anschluss", "Chain")
        case "audio": return t("Ton ab hier", "Audio from here")
        case "ai": return t("KI-Auftrag", "AI task")
        default: return t("Notiz", "Note")
        }
    }

    static func markerHint(_ kind: String) -> String {
        switch kind {
        case "place": return t("Beim Übernehmen kommt die gewählte Szene an diese Stelle, auf die gewählte Spur.",
                               "On conform, the chosen scene goes here, on the chosen track.")
        case "transition": return t("Der Videoclip, der hier beginnt, bekommt diesen Übergang: sofort, wenn er schon im Schnitt liegt, sonst beim Übernehmen. Er wandert mit dem Marker.",
                                    "The video clip starting here gets this transition: at once if it is in the edit, otherwise on conform. It moves with the marker.")
        case "chain": return t("Die Videoszene, die hier beginnt, setzt die Szene davor fort (Mac: mit deren letztem Bild).",
                               "The video scene starting here continues the scene before it (Mac: with its last frame).")
        case "audio": return t("Beim Übernehmen beginnt die gewählte Ton-Szene hier.", "On conform, the chosen audio scene starts here.")
        case "ai": return t("Ein Auftrag für Claude: Es liest ihn per MCP, arbeitet ihn ab und hakt ihn ab.",
                            "A task for Claude: it reads it over MCP, does it and ticks it off.")
        default: return t("Nur eine Notiz.", "Just a note.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let p = model.project {
                    switch model.kind {
                    case .scene where model.selected.count > 1: ScenesInspector(model: model, project: p)
                    case .clip where model.selected.count > 1: ClipsInspector(model: model, project: p)
                    case .marker where model.selected.count > 1: MarkersInspector(model: model, project: p)
                    case .scene: if let s = model.scene { SceneInspector(model: model, project: p, scene: s).id(s.id) }
                    case .clip: if let c = model.clip { ClipInspector(model: model, project: p, clip: c).id(c.id) }
                    case .marker: if let m = model.marker { MarkerInspector(model: model, project: p, marker: m).id(m.id) }
                    case .transition: if let c = model.transitionClip { TransitionInspector(model: model, project: p, clip: c).id(c.id) }
                    case .media: if let id = model.mediaID { MediaInspector(model: model, project: p, assetID: id).id(id) }
                    case nil: ProjectInspector(model: model, project: p).id(p.id)
                    default: EmptyView()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Bausteine

/// Sekunden mit Komma oder Punkt.
func parseSeconds(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }

func formatSeconds(_ ticks: Int, digits: Int = 2) -> String { formatDecimal(Studio.seconds(ticks), digits: digits) }

/// Zahl mit Komma (deutsch) oder Punkt.
func formatDecimal(_ value: Double, digits: Int = 2) -> String {
    let text = String(format: "%.\(digits)f", value)
    return Lang.current == .de ? text.replacingOccurrences(of: ".", with: ",") : text
}

/// Textfeld, das beim Bestätigen oder Verlassen übernimmt.
struct CommitField: View {
    let label: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var token = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save() }
                .onChange(of: focused) { _, now in if !now { save() } }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in if !focused { text = v } }
        .pendingEdit(token: token, text: text, value: value, commit: commit)
    }

    private func save() {
        StudioModel.shared.registerEdit(token, nil)
        if text != value { commit(text) }
    }
}

extension View {
    /// Meldet eine Eingabe, die vom gespeicherten Wert abweicht, beim Studio an (Knöpfe übernehmen sie vor dem Handeln)
    /// und übernimmt sie, wenn das Feld verschwindet (andere Auswahl).
    func pendingEdit(token: UUID, text: String, value: String, commit: @escaping (String) -> Void) -> some View {
        onChange(of: text) { _, now in
            StudioModel.shared.registerEdit(token, now != value ? { commit(now) } : nil)
        }
        .onDisappear {
            StudioModel.shared.registerEdit(token, nil)
            if text != value { commit(text) }
        }
    }
}

/// Mehrzeiliges Textfeld (Prompt, KI-Auftrag), übernimmt beim Verlassen.
struct CommitEditor: View {
    let label: String
    let value: String
    var placeholder = ""
    var lines: CGFloat = 6
    let commit: (String) -> Void
    @State private var text = ""
    @State private var token = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(.callout).focused($focused)
                    .frame(height: lines * 17).scrollContentBackground(.hidden)
                if text.isEmpty {
                    Text(placeholder).font(.callout).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            .onChange(of: focused) { _, now in
                guard !now else { return }
                StudioModel.shared.registerEdit(token, nil)
                if text != value { commit(text) }
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in if !focused { text = v } }
        .pendingEdit(token: token, text: text, value: value, commit: commit)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

// MARK: - Projekt

private struct ProjectInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject

    private func update(_ params: StudioParams) { Task { await model.run("project.update", params) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Projekt", "Project")).font(.headline)
            CommitField(label: t("Name", "Name"), value: project.name) { v in
                if !v.trimmingCharacters(in: .whitespaces).isEmpty { update(["name": .string(v)]) }
            }
            Picker(t("Format", "Format"), selection: Binding(
                get: { "\(project.settings.width)x\(project.settings.height)" },
                set: { v in
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { update(["width": .int(parts[0]), "height": .int(parts[1])]) }
                })) {
                Text("1920 × 1080 (YouTube)").tag("1920x1080")
                Text("1080 × 1920 (Shorts)").tag("1080x1920")
                Text("1280 × 720").tag("1280x720")
                Text("3840 × 2160 (4K)").tag("3840x2160")
                let current = "\(project.settings.width)x\(project.settings.height)"
                if !["1920x1080", "1080x1920", "1280x720", "3840x2160"].contains(current) {
                    Text(verbatim: "\(project.settings.width) × \(project.settings.height)").tag(current)
                }
            }
            Picker(t("Bildrate", "Frame rate"), selection: Binding(
                get: { "\(project.settings.fps[0])/\(project.settings.fps[1])" },
                set: { v in
                    let parts = v.split(separator: "/").compactMap { Int($0) }
                    if parts.count == 2 { update(["fps": .array([.int(parts[0]), .int(parts[1])])]) }
                })) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag("\($0)/1") }
                let current = "\(project.settings.fps[0])/\(project.settings.fps[1])"
                if ![24, 25, 30, 50, 60].map({ "\($0)/1" }).contains(current) {
                    Text(String(format: "%.3f fps", Double(project.settings.fps[0]) / Double(project.settings.fps[1]))).tag(current)
                }
            }
            Text(t("Videoszenen rechnet die Mac-Fassung mit LTX-Video 2B (ohne Ton, 24 fps); Format und Länge passen sich dem Speicher dieses Macs an.",
                   "The Mac version renders video scenes with LTX-Video 2B (no sound, 24 fps); size and length follow this Mac's memory."))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("\(project.scenes.count) Szenen, \(project.clips.count) Clips, Schnitt \(formatSeconds(project.editDuration, digits: 1)) s.",
                   "\(project.scenes.count) scenes, \(project.clips.count) clips, edit \(formatSeconds(project.editDuration, digits: 1)) s."))
                .font(.caption)
            Text(t("So geht's: Oben komponierst du Szenen mit Prompt (Doppelklick auf eine Bahn), „Szenen erzeugen“ macht Clips, Bilder und Musik, „Übernehmen“ legt die Takes in den Schnitt. Unten schneidest du: V Auswahl, C Schneiden, Z Skalieren, S Magnet, M Marker, Leertaste spielt ab.",
                   "How it works: compose scenes with a prompt at the top (double-click a lane), \"Generate scenes\" makes clips, images and music, \"Conform\" puts the takes into the edit. Edit below: V selection, C razor, Z scale, S magnet, M marker, space plays."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Szene

private struct SceneInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let scene: StudioScene

    private func update(_ params: StudioParams) {
        Task { await model.run("scene.update", ["id": .string(scene.id)].merging(params) { $1 }) }
    }

    private var laneName: String {
        let n = StudioTimeline.laneNames[scene.lane] ?? (scene.lane, scene.lane)
        return t(n.0, n.1)
    }

    var body: some View {
        let status = StudioJSON.status(scene)
        let chainMarker = StudioCommands.resolvedChains(project)[scene.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Szene", "Scene") + " · " + laneName).font(.headline)
                Spacer()
                switch status {
                case "running": Badge(text: t("wird erzeugt", "generating"), color: .orange)
                case "waiting": Badge(text: t("wartet", "waiting"), color: .orange)
                case "done": Badge(text: t("fertig", "done"), color: .green)
                case "error": Badge(text: t("Fehler", "error"), color: .red)
                default: Badge(text: t("leer", "empty"), color: .secondary)
                }
            }
            if let error = scene.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let w = scene.waitingFor, let source = project.scenes.first(where: { $0.id == w }) {
                Text(t("Wartet auf „\(source.title.isEmpty ? t("Szene", "Scene") : source.title)“: dessen letztes Bild wird das Startbild.",
                       "Waiting for \"\(source.title.isEmpty ? t("Szene", "Scene") : source.title)\": its last frame becomes the start image."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            CommitField(label: t("Titel", "Title"), value: scene.title) { update(["title": .string($0)]) }
            CommitEditor(label: scene.lane == "video" ? t("Prompt: was zu sehen ist und wie es sich bewegt", "Prompt: what is seen and how it moves")
                         : t("Prompt: Klang, Stil, Tempo", "Prompt: sound, style, tempo"),
                         value: scene.prompt,
                         placeholder: scene.lane == "video" ? t("Einstellung, Ort und Licht, Handlung, Kamera …", "Shot, place and light, action, camera …")
                         : t("z. B. „Ruhiges Klavier mit weichen Flächen. BPM: 80.“", "e.g. \"Calm piano with soft pads. BPM: 80.\"")) {
                update(["prompt": .string($0)])
            }
            Picker(t("Bahn", "Lane"), selection: Binding(get: { scene.lane }, set: { lane in
                update(["lane": .string(lane), "kind": .string(lane == "video" ? "video" : "audio")])
            })) {
                ForEach(Studio.lanes, id: \.self) { lane in
                    let n = StudioTimeline.laneNames[lane] ?? (lane, lane)
                    Text(t(n.0, n.1)).tag(lane)
                }
            }
            if scene.lane == "video" {
                Picker(t("Art", "Kind"), selection: Binding(get: { scene.kind }, set: { update(["kind": .string($0)]) })) {
                    Text(t("Videoclip", "Video clip")).tag("video")
                    Text(t("Standbild", "Still image")).tag("image")
                }
            }
            HStack {
                CommitField(label: t("Start (s)", "Start (s)"), value: formatSeconds(scene.start)) { v in
                    if let s = parseSeconds(v) { update(["start_s": .double(max(0, s))]) }
                }
                CommitField(label: t("Dauer (s)", "Duration (s)"), value: formatSeconds(scene.duration)) { v in
                    if let s = parseSeconds(v) { update(["duration_s": .double(max(0.1, s))]) }
                }
            }
            modelPicker
            if scene.lane == "video" && scene.kind == "video" {
                let earlier = project.scenes.filter { $0.lane == "video" && $0.id != scene.id && $0.start < scene.start }
                Picker(t("Anschluss an", "Chain to"), selection: Binding(
                    get: { scene.chainFrom ?? chainMarker?.from ?? "" },
                    set: { update(["chain_from": $0.isEmpty ? .null : .string($0)]) })) {
                    Text(t("keinen", "none")).tag("")
                    ForEach(earlier) { s in Text(s.title.isEmpty ? String(s.prompt.prefix(30)) : s.title).tag(s.id) }
                }
                .disabled(chainMarker != nil)
                if chainMarker != nil {
                    Text(t("Den Anschluss setzt ein Anschluss-Marker.", "A chain marker sets the chain.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(scene.take == nil ? t("Erzeugen", "Generate") : t("Neu erzeugen", "Generate again")) {
                    Task { await model.generate([scene.id]) }
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(!scene.jobs.isEmpty || scene.waitingFor != nil)
                Spacer()
                Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
            }
            takes
        }
    }

    @ViewBuilder private var modelPicker: some View {
        if scene.kind == "image" {
            Picker(t("Modell", "Model"), selection: Binding(get: { scene.modelID ?? "" }, set: { update(["model_id": $0.isEmpty ? .null : .string($0)]) })) {
                Text(t("aktives Modell", "active model")).tag("")
                ForEach(Models.all.filter { $0.installed }, id: \.id) { m in Text(m.name).tag(m.id) }
            }
        } else {
            LabeledContent(t("Modell", "Model"), value: scene.lane == "video" ? "LTX-Video 2B" : "Stable Audio 3")
                .font(.callout)
        }
    }

    private var takes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Takes (\(scene.takes.count))", "Takes (\(scene.takes.count))")).font(.caption).foregroundStyle(.secondary)
            if scene.takes.isEmpty {
                Text(t("Noch keiner. Erzeugen oder ein Material auf die Szene ziehen.", "None yet. Generate, or drag an asset onto the scene."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(scene.takes.enumerated()), id: \.element) { i, take in
                        Button {
                            Task { await model.run("scene.take", ["id": .string(scene.id), "asset_id": .string(take)]) }
                        } label: {
                            ZStack(alignment: .topLeading) {
                                if scene.lane == "video" {
                                    StudioThumb(assetID: take, symbol: scene.kind == "image" ? "photo" : "film")
                                } else {
                                    ZStack { Color.gray.opacity(0.2); Text("♪").font(.title3) }
                                }
                                Text("\(i + 1)").font(.caption2.bold()).padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.white).padding(2)
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(take == scene.take ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(AssetSnapshot.shared.get(take).map { StudioMaterial.label($0) } ?? take)
                    }
                }
            }
        }
    }
}

// MARK: - Clip

private struct ClipInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let clip: StudioClip
    @State private var gain = 0.0
    @State private var scale = 100.0
    @State private var anchorX = 50.0
    @State private var anchorY = 50.0

    private var isVideo: Bool { clip.track.hasPrefix("V") }
    private var isImage: Bool { project.media[clip.assetID]?.kind == "image" }

    private func update(_ params: StudioParams) {
        Task { await model.run("clip.update", ["id": .string(clip.id)].merging(params) { $1 }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Clip", "Clip") + " · " + clip.track).font(.headline)
            if let r = AssetSnapshot.shared.get(clip.assetID) {
                Text(StudioMaterial.label(r)).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            if let s = project.scenes.first(where: { $0.id == clip.sceneID }) {
                Button(t("aus Szene: ", "from scene: ") + (s.title.isEmpty ? String(s.prompt.prefix(30)) : s.title)) {
                    model.select(.scene, s.id)
                }
                .buttonStyle(.link)
            }
            HStack {
                CommitField(label: t("Start (s)", "Start (s)"), value: formatSeconds(clip.start)) { v in
                    if let s = parseSeconds(v) { Task { await model.run("clip.move", ["id": .string(clip.id), "start_s": .double(max(0, s))]) } }
                }
                CommitField(label: t("Länge (s)", "Length (s)"), value: formatSeconds(clip.length)) { v in
                    if let s = parseSeconds(v) {
                        Task { await model.run("clip.trim", ["id": .string(clip.id), "edge": .string("end"), "to": .int(clip.start + Studio.ticks(s))]) }
                    }
                }
            }
            HStack {
                CommitField(label: t("In (s)", "In (s)"), value: formatSeconds(clip.inPoint)) { v in
                    if let s = parseSeconds(v) { Task { await model.run("clip.trim", ["id": .string(clip.id), "in_s": .double(s)]) } }
                }
                CommitField(label: t("Out (s)", "Out (s)"), value: formatSeconds(clip.outPoint)) { v in
                    if let s = parseSeconds(v) { Task { await model.run("clip.trim", ["id": .string(clip.id), "out_s": .double(s)]) } }
                }
            }
            if !isImage {
                CommitField(label: t("Geschwindigkeit (%)", "Speed (%)"), value: String(Int((clip.speed * 100).rounded()))) { v in
                    if let pct = parseSeconds(v) { Task { await model.setSpeed([clip.id], min(1000, max(10, pct)) / 100) } }
                }
                if clip.speed != 1 {
                    Text(t("In und Out sind Zeiten im Material. Der Ton behält seine Tonhöhe.", "In and Out are times in the material. The sound keeps its pitch."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Lautstärke: \(Int(gain)) dB", "Volume: \(Int(gain)) dB")).font(.caption).foregroundStyle(.secondary)
                    Slider(value: $gain, in: -30...12, step: 1) { editing in if !editing { update(["gain_db": .double(gain)]) } }
                }
                Toggle(t("Stumm", "Muted"), isOn: Binding(get: { clip.muted }, set: { update(["muted": .bool($0)]) }))
            }
            if isVideo {
                Toggle(t("Übergang vom vorigen Clip", "Transition from the previous clip"), isOn: Binding(
                    get: { clip.transition != nil },
                    set: { on in update(["transition": on ? .object(["kind": .string("dissolve"), "duration_s": .double(0.5)]) : .null]) }))
                if let tr = clip.transition {
                    HStack {
                        Picker(t("Art", "Kind"), selection: Binding(get: { tr.kind }, set: {
                            update(["transition": .object(["kind": .string($0), "duration": .int(tr.duration)])])
                        })) {
                            ForEach(Studio.transitionKinds, id: \.self) { Text(ClipBlock.transitionName($0)).tag($0) }
                        }
                        CommitField(label: "", value: formatSeconds(tr.duration)) { v in
                            if let s = parseSeconds(v) { update(["transition": .object(["kind": .string(tr.kind), "duration_s": .double(max(0.04, s))])]) }
                        }
                        .frame(width: 70)
                    }
                }
                Divider()
                scaleSection
            }
            Divider()
            HStack {
                Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
                Button(t("Löschen, Lücke schließen", "Delete, close gap"), role: .destructive) { Task { await model.deleteSelection(ripple: true) } }
            }
        }
        .onAppear(perform: load)
        .onChange(of: clip) { _, _ in load() }
        .onChange(of: model.playhead) { _, _ in scale = currentScale * 100 }
    }

    private func load() {
        gain = clip.gainDB
        scale = currentScale * 100
        anchorX = (clip.anchor?[0] ?? 0.5) * 100
        anchorY = (clip.anchor?[1] ?? 0.5) * 100
    }

    private var playheadInside: Bool { clip.start <= model.playhead && model.playhead <= clip.end }
    private var mediaAtPlayhead: Int { clip.mediaAt(model.playhead - clip.start) }
    private var currentScale: Double { clip.scaleAt(mediaAtPlayhead) }
    private var keys: [StudioScaleKey] { clip.scaleKeys ?? [] }

    private var scaleSection: some View {
        let near = Int((Double(project.frameTicks) * clip.speed / 2).rounded())
        let onKey = keys.contains { abs($0.at - mediaAtPlayhead) <= near }
        let note = !playheadInside ? t(" (Abspielkopf außerhalb)", " (playhead outside)")
            : onKey ? " ◆" : keys.count > 1 ? t(" (zwischen Keyframes)", " (between keyframes)") : ""
        return VStack(alignment: .leading, spacing: 6) {
            Text(t("Skalierung: \(Int(scale.rounded())) %", "Scale: \(Int(scale.rounded())) %") + note).font(.caption).foregroundStyle(.secondary)
            Slider(value: $scale, in: 10...400) { editing in
                guard !editing else { return }
                if !keys.isEmpty, playheadInside {
                    Task { await model.run("clip.key", ["id": .string(clip.id), "at": .int(model.playhead), "value": .double(scale / 100)]) }
                } else {
                    update(["scale": .double(scale / 100)])
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t("Fokuspunkt X: \(Int(anchorX)) %", "Focus point X: \(Int(anchorX)) %")).font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $anchorX, in: 0...100) { e in if !e { update(["anchor": .array([.double(anchorX / 100), .double(anchorY / 100)])]) } }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t("Fokuspunkt Y: \(Int(anchorY)) %", "Focus point Y: \(Int(anchorY)) %")).font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $anchorY, in: 0...100) { e in if !e { update(["anchor": .array([.double(anchorX / 100), .double(anchorY / 100)])]) } }
                }
            }
            HStack(spacing: 4) {
                Button(t("◆ Keyframe setzen", "◆ Set keyframe")) {
                    Task { await model.run("clip.key", ["id": .string(clip.id), "at": .int(model.playhead), "value": .double(scale / 100)]) }
                }
                .disabled(!playheadInside)
                Button(t("Keyframe löschen", "Delete keyframe")) {
                    Task { await model.run("clip.key", ["id": .string(clip.id), "at": .int(model.playhead), "delete": .bool(true)]) }
                }
                .disabled(!onKey || !playheadInside)
            }
            HStack(spacing: 4) {
                Button("◀ ◆") { jump(previous: true) }.disabled(!keys.contains { timeline($0) < model.playhead - near })
                Button("◆ ▶") { jump(previous: false) }.disabled(!keys.contains { timeline($0) > model.playhead + near })
                Button(t("Alle \(keys.count) Keyframes löschen", "Delete all \(keys.count) keyframes")) {
                    Task { await model.run("clip.key", ["id": .string(clip.id), "clear": .bool(true)]) }
                }
                .disabled(keys.isEmpty)
            }
            Text(t("Werkzeug Skalieren (Z): im Monitor ziehen setzt einen Keyframe am Abspielkopf, ein Klick den Fokuspunkt. Zwischen zwei Keyframes läuft die Skalierung gleichmäßig; unter 100 % scheint die Spur darunter durch. Keyframes hängen am Material und wandern beim Schneiden mit.",
                   "Scale tool (Z): drag in the monitor to set a keyframe at the playhead, click to set the focus point. Between two keyframes the scale changes evenly; below 100 % the track below shows through. Keyframes stick to the material and move along when you cut."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func timeline(_ k: StudioScaleKey) -> Int { clip.start + Int(Double(k.at - clip.inPoint) / clip.speed) }

    private func jump(previous: Bool) {
        let near = Int((Double(project.frameTicks) * clip.speed / 2).rounded())
        let times = keys.map(timeline)
        if previous, let t = times.filter({ $0 < model.playhead - near }).max() { model.seek(t) }
        if !previous, let t = times.filter({ $0 > model.playhead + near }).min() { model.seek(t) }
    }
}

// MARK: - Übergang

private struct TransitionInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let clip: StudioClip

    var body: some View {
        if let tr = clip.transition {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("Übergang", "Transition")).font(.headline)
                Text(t("Blendet am Anfang des Clips vom vorigen Clip derselben Spur über; der vorige läuft dafür über sein Ende hinaus weiter. Der Ton blendet ebenfalls über.",
                       "Blends at the start of the clip from the previous clip on the same track, which runs on past its end. The sound crossfades too."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(t("Art", "Kind"), selection: Binding(get: { tr.kind }, set: { k in
                    Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .object(["kind": .string(k), "duration": .int(tr.duration)])]) }
                })) {
                    ForEach(Studio.transitionKinds, id: \.self) { Text(ClipBlock.transitionName($0)).tag($0) }
                }
                CommitField(label: t("Dauer (s)", "Duration (s)"), value: formatSeconds(tr.duration)) { v in
                    if let s = parseSeconds(v) {
                        Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .object(["kind": .string(tr.kind), "duration_s": .double(max(0.04, s))])]) }
                    }
                }
                if let mid = tr.marker, let m = project.markers.first(where: { $0.id == mid }) {
                    Button(t("Kommt vom Übergang-Marker „\(m.name.isEmpty ? StudioInspector.markerName(m.kind) : m.name)“",
                             "Comes from the transition marker \"\(m.name.isEmpty ? StudioInspector.markerName(m.kind) : m.name)\"")) {
                        model.select(.marker, m.id)
                    }
                    .buttonStyle(.link)
                }
                HStack {
                    Button(t("Zum Clip", "To the clip")) { model.select(.clip, clip.id) }
                    Spacer()
                    Button(t("Entfernen", "Remove"), role: .destructive) {
                        Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .null]); model.select(.clip, clip.id) }
                    }
                }
            }
        }
    }
}

// MARK: - Marker

private struct MarkerInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let marker: StudioMarker

    private func update(_ params: StudioParams) {
        Task { await model.run("marker.update", ["id": .string(marker.id)].merging(params) { $1 }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Marker", "Marker")).font(.headline)
            Picker(t("Art", "Kind"), selection: Binding(get: { marker.kind }, set: { update(["kind": .string($0), "color": .string("")]) })) {
                ForEach(Studio.markerKinds, id: \.self) { Text(StudioInspector.markerName($0)).tag($0) }
            }
            Text(StudioInspector.markerHint(marker.kind)).font(.caption).foregroundStyle(.secondary)
            CommitField(label: t("Name", "Name"), value: marker.name) { update(["name": .string($0)]) }
            if marker.kind == "ai" {
                CommitEditor(label: t("Auftrag an die KI", "Task for the AI"), value: marker.comment,
                             placeholder: t("z. B. „Mach aus Szene 3 eine Nahaufnahme und erzeuge sie neu“", "e.g. \"Turn scene 3 into a close-up and generate it again\""),
                             lines: 5) { update(["comment": .string($0)]) }
            } else {
                CommitField(label: t("Kommentar", "Comment"), value: marker.comment) { update(["comment": .string($0)]) }
            }
            HStack {
                CommitField(label: t("Position (s)", "Position (s)"), value: formatSeconds(marker.at)) { v in
                    if let s = parseSeconds(v) { update(["at_s": .double(max(0, s))]) }
                }
                CommitField(label: t("Dauer (s)", "Duration (s)"), value: formatSeconds(marker.duration)) { v in
                    if let s = parseSeconds(v) { update(["duration_s": .double(max(0, s))]) }
                }
            }
            if marker.kind == "place" {
                scenePicker(project.scenes.filter { $0.lane == "video" })
                let video = project.tracks(of: "video")
                Picker(t("Spur", "Track"), selection: Binding(
                    get: { marker.params["track"]?.stringValue ?? project.trackOrHighest("V2", kind: "video") },
                    set: { update(["params": .object(["track": .string($0)])]) })) {
                    ForEach(Array(video.enumerated()), id: \.element.id) { i, tr in
                        Text(i == 0 ? "\(tr.id) " + t("(oben)", "(top)") : tr.id).tag(tr.id)
                    }
                }
            }
            if marker.kind == "audio" { scenePicker(project.scenes.filter { $0.lane != "video" }) }
            if marker.kind == "transition" {
                Picker(t("Übergang", "Transition"), selection: Binding(
                    get: { marker.params["transition"]?.stringValue ?? "dissolve" },
                    set: { update(["params": .object(["transition": .string($0)])]) })) {
                    ForEach(Studio.transitionKinds, id: \.self) { Text(ClipBlock.transitionName($0)).tag($0) }
                }
                if marker.duration == 0 {
                    CommitField(label: t("Dauer des Übergangs (s)", "Transition length (s)"),
                                value: formatDecimal(marker.params["seconds"]?.doubleValue ?? 0.5)) { v in
                        if let s = parseSeconds(v) { update(["params": .object(["seconds": .double(max(0.04, s))])]) }
                    }
                }
            }
            Toggle(t("Erledigt", "Done"), isOn: Binding(get: { marker.done }, set: { update(["done": .bool($0)]) }))
            Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
        }
    }

    private func scenePicker(_ scenes: [StudioScene]) -> some View {
        Picker(t("Szene", "Scene"), selection: Binding(
            get: { marker.params["scene_id"]?.stringValue ?? "" },
            set: { update(["params": .object(["scene_id": .string($0)])]) })) {
            Text(t("keine", "none")).tag("")
            ForEach(scenes) { s in Text(s.title.isEmpty ? String(s.prompt.prefix(30)) : s.title).tag(s.id) }
        }
    }
}

// MARK: - Mehrere

private struct ClipsInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject

    var body: some View {
        let clips = project.clips.filter { model.selected.contains($0.id) }
        let from = clips.map(\.start).min() ?? 0, to = clips.map(\.end).max() ?? 0
        let allMuted = clips.allSatisfy(\.muted)
        VStack(alignment: .leading, spacing: 10) {
            Text(t("\(clips.count) Clips", "\(clips.count) clips")).font(.headline)
            Text("\(formatSeconds(from)) – \(formatSeconds(to)) s").font(.caption.monospacedDigit())
            Button(allMuted ? t("Alle Ton an", "Unmute all") : t("Alle stumm", "Mute all")) {
                Task { await model.batch(clips.map { ("clip.update", ["id": .string($0.id), "muted": .bool(!allMuted)]) }) }
            }
            Button(t("Überblendung 0,5 s an jedem", "Dissolve 0.5 s on each")) {
                Task { await model.batch(clips.filter { $0.track.hasPrefix("V") }.map {
                    ("clip.update", ["id": .string($0.id), "transition": .object(["kind": .string("dissolve"), "duration_s": .double(0.5)])])
                }) }
            }
            HStack {
                Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
                Button(t("Löschen, Lücken schließen", "Delete, close gaps"), role: .destructive) { Task { await model.deleteSelection(ripple: true) } }
            }
        }
    }
}

private struct ScenesInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject

    var body: some View {
        let scenes = project.scenes.filter { model.selected.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            Text(t("\(scenes.count) Szenen", "\(scenes.count) scenes")).font(.headline)
            Button(t("Alle erzeugen", "Generate all")) {
                Task { await model.generate(scenes.filter { $0.jobs.isEmpty && $0.waitingFor == nil }.map(\.id)) }
            }
            .buttonStyle(.borderedProminent).tint(.green)
            Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
        }
    }
}

private struct MarkersInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject

    var body: some View {
        let markers = project.markers.filter { model.selected.contains($0.id) }
        let allDone = markers.allSatisfy(\.done)
        VStack(alignment: .leading, spacing: 10) {
            Text(t("\(markers.count) Marker", "\(markers.count) markers")).font(.headline)
            Button(allDone ? t("Alle wieder öffnen", "Reopen all") : t("Alle erledigt", "All done")) {
                Task { await model.batch(markers.map { ("marker.update", ["id": .string($0.id), "done": .bool(!allDone)]) }) }
            }
            Button(t("Löschen", "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
        }
    }
}

// MARK: - Material

private struct MediaInspector: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let assetID: String
    @State private var confirm = false

    /// Anzeigename des Modells wie im Verlauf (LTX-Video und Stable Audio 3 stehen nicht im Bildkatalog).
    static func modelName(_ r: AssetRecord) -> String {
        if r.modelID == VideoCatalog.id { return VideoCatalog.name }
        if r.modelID == AudioCatalog.id { return AudioCatalog.name }
        return Models.find(r.modelID)?.name ?? r.meta["model_name"]?.stringValue ?? r.modelID
    }

    var body: some View {
        if let r = AssetSnapshot.shared.get(assetID) {
            let media = project.media[r.id] ?? StudioMediaCache.shared.get(r.id)
            let inEdit = project.clips.contains { $0.assetID == r.id }
            let kind = media?.kind ?? (StudioMaterial.symbol(r) == "waveform" ? "audio" : StudioMaterial.symbol(r) == "film" ? "video" : "image")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(t("Material", "Media") + " · " + (kind == "video" ? t("Video", "Video") : kind == "audio" ? t("Ton", "Audio") : t("Bild", "Image")))
                        .font(.headline)
                    if inEdit { Badge(text: t("im Schnitt", "in edit"), color: .green) }
                }
                Text(StudioMaterial.label(r)).font(.caption).lineLimit(6).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    if !r.modelID.isEmpty { row(t("Modell", "Model"), Self.modelName(r)) }
                    if let d = media?.duration { row(t("Länge", "Length"), formatSeconds(d, digits: 1) + " s") }
                    if let w = media?.width ?? r.meta["width"]?.intValue, let h = media?.height ?? r.meta["height"]?.intValue {
                        row(t("Größe", "Size"), "\(w) × \(h)")
                    }
                    if let fps = media?.fps { row(t("Bildrate", "Frame rate"), String(format: "%g fps", fps)) }
                    if let seed = r.meta["seed"]?.intValue { row("Seed", String(seed)) }
                    row(t("Erstellt", "Created"), Date(timeIntervalSince1970: r.createdAt).formatted(date: .abbreviated, time: .shortened))
                    row(t("Ordner", "Folder"), r.meta["studio_project"]?.stringValue == project.id ? project.name : t("Verlauf", "History"))
                }
                .font(.caption)
                Button(kind == "audio" ? t("Am Abspielkopf einfügen (A2)", "Insert at the playhead (A2)") : t("Am Abspielkopf einfügen (V1)", "Insert at the playhead (V1)")) {
                    Task {
                        let track = kind == "audio" ? project.trackOrHighest("A2", kind: "audio") : "V1"
                        if let res = await model.run("clip.add", ["track": .string(track), "asset_id": .string(r.id), "start": .int(model.playhead)]),
                           let id = res["id"]?.stringValue {
                            model.leaveSource()
                            model.select(.clip, id)
                        }
                    }
                }
                Button(t("Datei öffnen", "Open file")) { NSWorkspace.shared.open(AssetStore.shared.fileURL(r.filename)) }
                Button(confirm ? t("Wirklich löschen? Die Datei ist dann weg.", "Really delete? The file will be gone.") : t("Löschen", "Delete"),
                       role: .destructive) {
                    if confirm {
                        Task {
                            await AssetStore.shared.delete(r.id)
                            model.leaveSource()
                            await AppState.shared.refresh()
                        }
                    } else {
                        confirm = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirm = false }
                    }
                }
                .disabled(inEdit)
                .help(inEdit ? t("Liegt im Schnitt: erst den Clip löschen.", "It is in the edit: delete the clip first.") : "")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
