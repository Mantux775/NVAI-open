import SwiftUI

/// Konzept „NVAI im Fluss“, Bildschirm E (seit Mac 1.0, wie flow/studio/SceneFocus.tsx unter Windows): Szene im Fokus.
/// Oben der Zustand mit dem passenden Knopf (fehlt, wartet, rechnet, wählen, veraltet), darunter Modell und Weg, dann
/// nur die Zusätze, die das Modell kann; die Aktionen stehen fest unten, statt mit langen Eigenschaften nach unten zu
/// wandern. Die Felder selbst (Startbild, Prompt, Stimme …) bleiben in StudioInspector.swift, Seltenes dort unter
/// „Feineinstellung“.
enum SceneFocus {
    static func wayLabel(_ w: StudioFlow.Way) -> String {
        switch w {
        case .text: return t("Nur Text", "Text only")
        case .start: return t("Startbild", "Start image")
        case .chain: return t("Anschluss", "Chain")
        }
    }

    static func wayHint(_ w: StudioFlow.Way) -> String {
        switch w {
        case .text: return t("Das Modell erfindet das erste Bild aus dem Prompt.", "The model invents the first frame from the prompt.")
        case .start: return t("Der Clip beginnt mit einem Bild; so sieht eine Figur in jeder Einstellung gleich aus.",
                              "The clip begins with an image, so a character looks the same in every shot.")
        case .chain: return t("Beginnt mit dem Ende der Szene davor: ihr letztes Bild ist das Startbild.",
                              "Begins with the end of the scene before: its last frame is the start image.")
        }
    }

    /// A, B, C … (ab dem 27. die Nummer)
    static func takeLetter(_ i: Int) -> String {
        i >= 0 && i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : "\(i + 1)"
    }
}

/// Fortschritt des laufenden Auftrags: Phase, Balken, Restzeit
struct SceneRunNote: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var flow = FlowJobs.shared
    let jobID: String?
    let expected: Double?
    var what: String?

    var body: some View {
        let job = jobID.flatMap { id in state.jobs.first { $0.id == id } }
        EverySecond(on: job.map(FlowJobs.isActive) ?? false) { now in
            let phase = job.flatMap { flow.currentPhase($0) }
            let label: String = {
                switch phase {
                case "queue": return t("Wartet auf die GPU", "Waiting for the GPU")
                case "prepare": return t("Bereitet vor", "Preparing")
                case "load": return t("Modell lädt", "Model loads")
                case "save": return t("Speichert", "Saving")
                default:
                    guard let job else { return t("Rechnet", "Computing") }
                    return job.stage.isEmpty ? t("Rechnet", "Computing") : t("Rechnet · \(job.stage)", "Computing · \(job.stage)")
                }
            }()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text((what.map { "\($0): " } ?? "") + label).lineLimit(2)
                    Spacer()
                    Text(job.map { FlowFormat.left(flow.remaining($0, expected: expected, now: now)) } ?? "").monospacedDigit()
                }
                ProgressView(value: phase == "run" ? max(0, min(1, job?.progress ?? 0)) : phase == "save" ? 1 : 0).tint(.green)
            }
            .font(.caption)
            .padding(8)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Hinweis mit Rand in der Farbe des Zustands und Knöpfen darunter
struct SceneNote<Actions: View>: View {
    let text: String
    var tone: FlowTone = .warn
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { Rectangle().fill(tone.color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Zustand oben mit dem passenden Knopf
struct SceneStateNote: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: StudioModel
    let p: StudioProject
    let s: StudioScene
    let st: StudioFlow.SceneState
    /// „≈ 1:50“ für Erzeugen bzw. Neu rechnen; „≈ 40 s“ für Startbild erzeugen
    let eta: String
    let startEta: String
    let expected: Double?
    let onGenerate: () -> Void
    let update: (StudioParams) -> Void
    let onWay: (StudioFlow.Way, String?) -> Void

    private func withEta(_ label: String, _ e: String) -> String { e.isEmpty ? label : "\(label) · \(e)" }

    var body: some View {
        switch st.key {
        case "running":
            SceneRunNote(jobID: s.jobs.last, expected: expected)
        case "start_running":
            SceneRunNote(jobID: model.startRuns[s.id]?.job, expected: nil, what: t("Startbild", "Start image"))
        case "waiting":
            let ref = StudioFlow.sceneRef(p, s.waitingFor)
            let src = p.scenes.first { $0.id == s.waitingFor }
            SceneNote(text: s.lane == "voice" ? t("Wartet auf den Take von \(ref): Er gibt die Stimme vor.", "Waiting for the take of \(ref): it sets the voice.")
                      : src?.lane == "voice" ? t("Wartet auf den Satz von \(ref): Diese Szene spricht ihn.", "Waiting for the line of \(ref): this scene speaks it.")
                      : t("Wartet auf \(ref): Diese Szene beginnt mit deren Ende.", "Waiting for \(ref): this scene begins with its ending."),
                      tone: .plain) { EmptyView() }
        case "chain_wait":
            SceneNote(text: t("Schließt an \(StudioFlow.sceneRef(p, s.chainFrom)) an, die noch kein Video hat. „Erzeugen“ rechnet erst sie, dann diese.",
                              "Continues \(StudioFlow.sceneRef(p, s.chainFrom)), which has no video yet. \"Generate\" renders it first, then this one."),
                      tone: .plain) { EmptyView() }
        case "error":
            SceneNote(text: t("Fehler: ", "Error: ") + (s.error ?? ""), tone: .err) {
                Button(withEta(t("Erneut versuchen", "Try again"), eta), action: onGenerate).controlSize(.small)
            }
        case "stale":
            let stale = StudioGenerator.stale(p, s)
            SceneNote(text: stale?.why == "take"
                      ? t("\(StudioFlow.sceneRef(p, stale?.source)) hat einen neuen Take. Diese Szene schließt daran an und beginnt noch mit dem alten Ende.",
                          "\(StudioFlow.sceneRef(p, stale?.source)) has a new take. This scene continues from it and still begins with the old ending.")
                      : stale?.reason ?? "") {
                HStack {
                    Button(withEta(t("Neu rechnen", "Render again"), eta), action: onGenerate)
                        .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                    Button(t("So lassen", "Keep as is")) {
                        if let stale, let take = s.take {
                            update(["params": .object(["chain_keep": .object(["take": .string(take), "source": .string(stale.take)])])])
                        }
                    }
                    .controlSize(.small)
                    .help(t("Den Hinweis für genau diesen Take nicht mehr zeigen (⌘Z holt ihn zurück)",
                            "Stop showing this notice for exactly this take (⌘Z brings it back)"))
                }
            }
        case "choose":
            let i = s.takes.firstIndex(of: s.take ?? "") ?? 0
            SceneNote(text: t("\(s.takes.count) Takes: unten den besten wählen; der gewählte kommt in den Schnitt.",
                              "\(s.takes.count) takes: choose the best one below; the chosen one goes into the edit."), tone: .info) {
                Button(t("Take \(SceneFocus.takeLetter(i)) behalten", "Keep take \(SceneFocus.takeLetter(i))")) {
                    update(["params": .object(["take_ok": s.take.map(JSONValue.string) ?? .null])])
                }
                .controlSize(.small)
            }
        case "start_missing":
            let busy = model.startRuns[s.id]?.status == "running"
            if let need = StudioFlow.startImageNeed(p, s, state.flowModels) {
                VStack(alignment: .leading, spacing: 6) {
                    SceneNote(text: t("Startbild fehlt, und für Startbilder ist noch kein Bildmodell geladen.",
                                      "The start image is missing, and no image model for start images is downloaded yet.")) { EmptyView() }
                    ModelNeedView(model: need, why: t("für die Startbilder", "for the start images"), compact: true)
                    Button(t("Ohne Startbild: Nur Text", "Without a start image: text only")) { onWay(.text, nil) }.controlSize(.small)
                }
            } else {
                SceneNote(text: t("Startbild fehlt. Erzeugen oder ein Bild aus dem Material auf „Startbild“ ziehen.",
                                  "The start image is missing. Generate one or drag a picture from the media onto \"Start image\".")) {
                    HStack {
                        Button(withEta(t("Startbild erzeugen", "Generate start image"), startEta)) { model.startImages([s.id]) }
                            .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                            .disabled(busy || s.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(t("Nur Text", "Text only")) { onWay(.text, nil) }.controlSize(.small)
                    }
                }
            }
        case "chain_apart":
            let src = StudioFlow.chainApart(p, s)
            let before = StudioFlow.sceneBefore(p, s)
            let ref = StudioFlow.sceneRef(p, src?.id)
            let marker = StudioCommands.resolvedChains(p)[s.id] != nil && model.project?.scenes.first(where: { $0.id == s.id })?.chainFrom == nil
            SceneNote(text: s.take != nil
                      ? t("\(ref) liegt nicht mehr direkt vor dieser Szene. Der Take beginnt mit deren Ende; im Schnitt passt die Naht so nicht.",
                          "\(ref) is no longer directly before this scene. The take begins with its ending; in the edit the seam does not fit like this.")
                      : t("\(ref) liegt nicht mehr direkt vor dieser Szene; ein neuer Take begänne trotzdem mit deren Ende.",
                          "\(ref) is no longer directly before this scene; a new take would still begin with its ending.")) {
                HStack {
                    if let before, before.id != src?.id, before.kind == "video" {
                        Button(t("Anschluss an \(StudioFlow.sceneNum(p, before.id))", "Chain to \(StudioFlow.sceneNum(p, before.id))")) {
                            onWay(.chain, before.id)
                        }
                        .controlSize(.small)
                    }
                    if s.chainFrom != nil && !marker {
                        Button(t("Startbild statt Anschluss", "Start image instead")) { onWay(.start, nil) }.controlSize(.small)
                    }
                }
            }
        case "done", "in_edit":
            SceneDoneNote(model: model, s: s)
        default:
            EmptyView()
        }
    }
}

/// Vorschläge an einer fertigen Szene (seit 1.1.0, wie unter Windows): ein Video-Take im Entwurfsformat seines Modells
/// bekommt „⇧ Final“ (dasselbe groß, gleicher Seed); eine Szene mit einem Foto der Person „☺ Gesicht nachrechnen“
/// (neuer Take, das Gesicht aus dem Foto; nicht bei Sprache, der Mund stünde still).
struct SceneDoneNote: View {
    @ObservedObject var model: StudioModel
    let s: StudioScene

    var body: some View {
        let take = s.take.flatMap { AssetSnapshot.shared.get($0) }
        let df = s.kind == "video" ? s.modelID.flatMap { VideoCatalog.draftFinal($0) } : nil
        let width = take?.meta["width"]?.intValue ?? s.params["width"]?.intValue ?? 0
        let draft = df != nil && width > 0 && width < df!.final.w
        let photo = s.params["face_ref_asset_id"]?.stringValue
            ?? s.params["reference_asset_ids"]?.arrayValue?.compactMap(\.stringValue).last
        let speaks = s.kind == "video" && (s.params["audio_from"]?.stringValue != nil
            || s.prompt.contains("\"") || s.prompt.contains("„") || s.prompt.contains("“"))
        let face = photo != nil && take?.meta["face_fix"] == nil && !speaks
        if draft || face {
            VStack(alignment: .leading, spacing: 6) {
                if draft, let df {
                    SceneNote(text: t("Entwurf. Passt der Take, „⇧ Final“ rechnen: \(df.final.w) × \(df.final.h), gleicher Seed.",
                                      "Draft. If the take fits, render \"⇧ Final\": \(df.final.w) × \(df.final.h), same seed."),
                              tone: .info) {
                        Button("⇧ " + t("Final", "Final")) {
                            Task {
                                var params: [String: JSONValue] = ["width": .int(df.final.w), "height": .int(df.final.h)]
                                if let seed = take?.meta["seed"] { params["seed"] = seed }
                                _ = await model.run("scene.update", ["id": .string(s.id), "params": .object(params)])
                                await model.generate([s.id])
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if face {
                    SceneNote(text: t("Weicht das Gesicht vom Foto ab oder fehlen Pupillen: das Gesicht aus dem Originalfoto nachrechnen (neuer Take). Nur für Clips ohne Sprechen: Mund und Lider bewegen sich danach nicht.",
                                      "If the face drifts from the photo or pupils are missing: recompute the face from the original photo (a new take). Only for clips without speech: the mouth and eyelids no longer move afterwards."),
                              tone: .plain) {
                        Button("☺ " + t("Gesicht nachrechnen", "Recompute face")) { Task { await model.faceFix(s.id) } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Modell der Szene: Chip „LTX-Video 2B · bereit“ mit Länge und Format, oder das fehlende Modell zum Laden
struct SceneModelLine: View {
    @EnvironmentObject var state: AppState
    let p: StudioProject
    let s: StudioScene
    let onPick: (String) -> Void
    /// Modell wechseln (öffnet „Feineinstellung“ mit der Auswahl)
    let onModelClick: () -> Void

    var body: some View {
        if let missing = StudioFlow.missingModel(s, state.flowModels) {
            let alt = StudioFlow.loadedAlternative(s, state.flowModels, missing)
            ModelNeedView(model: missing, why: t("für diese Szene", "for this scene"), alternative: alt,
                          onUseAlternative: alt.map { a in { onPick(a.id) } }, compact: true)
        } else if let m = StudioFlow.sceneModel(s, state.flowModels) {
            let dl = state.jobs.first { $0.downloadModelID == m.id && !$0.isFinished }
            HStack(spacing: 8) {
                Button(action: onModelClick) {
                    FlowChip(text: "\(m.short) · " + (dl.map { t("lädt \(Int(($0.progress * 100).rounded())) %", "downloading \(Int(($0.progress * 100).rounded())) %") }
                                                   ?? t("bereit", "ready")), tone: .ok)
                }
                .buttonStyle(.plain)
                .help(t("Modell wechseln (unter „Feineinstellung“)", "Change the model (under \"Fine tuning\")"))
                Text(StudioFlow.sceneFacts(p, s, state.flowModels)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Schalter für das, was das Modell der Szene kann: auf dem Mac LoRAs für FLUX.2 Klein (Standbilder) und „Seed
/// festhalten“. Genaue Werte (Stärke, Seed als Zahl) stehen unter „Feineinstellung“.
struct SceneToggles: View {
    @EnvironmentObject var state: AppState
    let s: StudioScene
    let update: (StudioParams) -> Void

    private struct Item: Identifiable {
        let id: String
        let label: String
        let on: Bool
        let help: String
        let action: () -> Void
    }

    var body: some View {
        let model = StudioFlow.sceneModel(s, state.flowModels)
        let params = s.params
        let loras = params["loras"]?.arrayValue ?? []
        var items: [Item] = []
        // LoRAs nimmt auf dem Mac nur FLUX.2 Klein (Standbilder): die der Szene und weitere geladene, bis fünf
        if s.lane == "video", s.kind == "image", case .flux? = Models.find(StudioFlow.sceneModelID(s, state.flowModels)) {
            let chosen = loras.compactMap { $0["model_id"]?.stringValue }
            let fitting = LoRACatalog.all.filter { $0.installed && $0.base == LoRAModel.family }.map(\.id)
            for id in Array((chosen + fitting.filter { !chosen.contains($0) }).prefix(5)) {
                let lora = LoRACatalog.find(id)
                let on = chosen.contains(id)
                let name = (lora?.name ?? id).replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                items.append(Item(id: id, label: "LoRA: \(name)", on: on,
                                  help: [lora?.trigger.isEmpty == false ? t("Trigger: \(lora!.trigger)", "Trigger: \(lora!.trigger)") : ""]
                                    .filter { !$0.isEmpty }.joined(),
                                  action: {
                                      let list: [JSONValue] = on ? loras.filter { $0["model_id"]?.stringValue != id }
                                          : loras + [.object(["model_id": .string(id), "strength": .double(lora?.strength ?? 0.8)])]
                                      update(["params": .object(["loras": .array(list)])])
                                  }))
            }
        }
        let seed = params["seed"].flatMap { $0.isNull ? nil : $0.intValue }
        items.append(Item(id: "seed", label: t("Seed festhalten", "Keep the seed"), on: seed != nil,
                          help: seed.map { t("Seed \($0): „Neu erzeugen“ rechnet mit demselben Zufall", "Seed \($0): \"Generate again\" uses the same randomness") }
                            ?? t("Den Seed des gewählten Takes behalten, um nur den Prompt zu ändern", "Keep the seed of the chosen take to change only the prompt"),
                          action: {
                              if seed != nil {
                                  update(["params": .object(["seed": .null])])
                              } else {
                                  let fromTake = s.take.flatMap { AssetSnapshot.shared.get($0)?.meta["seed"]?.intValue }
                                  update(["params": .object(["seed": .int(fromTake ?? Int.random(in: 0..<2_147_483_648))])])
                              }
                          }))
        return VStack(alignment: .leading, spacing: 5) {
            FlowLabel(text: t("Was \(model?.short ?? t("das Modell", "the model")) dazu kann", "What \(model?.short ?? "the model") adds"))
            FlowWrap(spacing: 6) {
                ForEach(items) { it in
                    Button(action: it.action) {
                        Text(it.label).font(.caption).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(it.on ? Color.green.opacity(0.12) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(it.on ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4)))
                            .foregroundStyle(it.on ? Color.green : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(it.help)
                    .accessibilityAddTraits(it.on ? .isSelected : [])
                }
            }
        }
    }
}

/// Zeilen, die umbrechen, wenn der Platz nicht reicht (Schalter, Chips)
struct FlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Takes A, B, …: Klick wählt den Take und bestätigt die Wahl (params.take_ok)
struct SceneTakes: View {
    @ObservedObject var model: StudioModel
    let s: StudioScene
    let attention: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLabel(text: t("Takes (\(s.takes.count))", "Takes (\(s.takes.count))"))
            if s.takes.isEmpty {
                Text(t("Noch keiner. Erzeugen oder ein Material auf die Szene ziehen.", "None yet. Generate, or drag an asset onto the scene."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], spacing: 6) {
                    ForEach(Array(s.takes.enumerated()), id: \.element) { i, take in
                        Button {
                            Task {
                                await model.batch([("scene.take", ["id": .string(s.id), "asset_id": .string(take)]),
                                                   ("scene.update", ["id": .string(s.id), "params": .object(["take_ok": .string(take)])])])
                            }
                        } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    if s.lane == "video" {
                                        StudioThumb(assetID: take, symbol: s.kind == "image" ? "photo" : "film")
                                    } else {
                                        ZStack { Color.gray.opacity(0.2); Text("♪").font(.title3) }
                                    }
                                }
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(take == s.take ? Color.green : .clear, lineWidth: 2))
                                Text(SceneFocus.takeLetter(i) + (take == s.take ? " · " + t("gewählt", "chosen") : ""))
                                    .font(.caption2).foregroundStyle(take == s.take ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(take == s.take ? t("Gewählt. Klick bestätigt die Wahl.", "Chosen. Click to confirm the choice.")
                              : AssetSnapshot.shared.get(take).map { StudioMaterial.label($0) } ?? take)
                    }
                }
            }
        }
        .padding(attention ? 6 : 0)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(attention ? Color.blue.opacity(0.7) : .clear, lineWidth: 1.5))
    }
}
