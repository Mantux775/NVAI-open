import AppKit
import SwiftUI

struct GenerateView: View {
    @EnvironmentObject var state: AppState

    @State private var prompt = ""
    @State private var sizeIndex = 0
    @State private var steps = 4
    @State private var seedText = ""
    @State private var batch = 1
    @State private var startImage: URL?
    @State private var strength = 0.5
    @State private var mask: URL?
    @State private var references: [URL] = []
    /// Outpainting: Ränder links, oben, rechts, unten in Pixeln.
    @State private var outpaintOn = false
    @State private var edges = [0, 0, 0, 0]
    @State private var lastJobID: String?
    @State private var message: String?
    @State private var negative = ""
    @State private var guidance = 7.5
    /// „Prompt ausbauen“: läuft gerade, und der Text davor (für „Zurücknehmen“).
    @State private var expanding = false
    @State private var promptBeforeExpand: String?
    @State private var expandInfo: String?

    private var sizes: [(label: String, w: Int, h: Int)] {
        ModelCatalog.flux2Sizes.map { ($0["label"] as? String ?? "", $0["w"] as? Int ?? 1024, $0["h"] as? Int ?? 1024) }
    }

    private var activeModel: AnyModel? { Models.find(state.activeModelID) }
    private var isCoreML: Bool { activeModel?.engine == "coreml" }
    private var fixedSize: Int? {
        if case .coreml(let m) = activeModel { return m.resolution }
        return nil
    }
    private var hint: String { activeModel?.features["prompt_hint"] as? String ?? ModelCatalog.promptHint }
    private var placeholder: String { activeModel?.features["placeholder"] as? String ?? ModelCatalog.placeholder }

    /// Standardwerte des Modells übernehmen (FLUX.2: 4 Schritte; Core ML: 25–30 Schritte, cfg 7,5).
    private func applyDefaults() {
        let f = activeModel?.features ?? [:]
        steps = f["steps"] as? Int ?? 4
        guidance = f["cfg"] as? Double ?? 7.5
        if isCoreML { references = []; mask = nil; outpaintOn = false }
    }

    var body: some View {
        HSplitView {
            form.frame(minWidth: 380, idealWidth: 420, maxWidth: 520)
            results.frame(minWidth: 400)
        }
        .onAppear {
            // Auf 8-GB-Macs ist 512 × 512 die einzige flüssige Größe.
            if SystemInfo.memoryGB < 16, let small = sizes.firstIndex(where: { $0.w == 512 }) { sizeIndex = small }
            applyDefaults()
        }
        .onChange(of: state.activeModelID) { _, _ in applyDefaults() }
    }

    // MARK: Formular

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let model = activeModel {
                    HStack {
                        Text(model.name).font(.headline)
                        Spacer()
                        if !(state.models.first { $0.id == model.id }?.installed ?? false) {
                            Text(t("nicht geladen, siehe „Modelle“", "not downloaded, see \"Models\"")).foregroundStyle(.orange).font(.caption)
                        }
                    }
                }

                Text(t("Prompt", "Prompt")).font(.subheadline.bold())
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                        }
                    }
                    .border(.quaternary)
                Text(hint).font(.caption).foregroundStyle(.secondary)
                expandRow

                if isCoreML {
                    Text(t("Negativer Prompt", "Negative prompt")).font(.subheadline.bold())
                    TextField("blurry, low quality, watermark, text", text: $negative)
                    HStack {
                        Text("CFG \(guidance, specifier: "%.1f")")
                        Slider(value: $guidance, in: 1...12)
                    }
                }
                if let fixedSize {
                    Text(t("Format: \(fixedSize) × \(fixedSize) (fest bei diesem Modell)", "Size: \(fixedSize) × \(fixedSize) (fixed for this model)")).font(.callout)
                } else {
                    Picker(t("Format", "Size"), selection: $sizeIndex) {
                        ForEach(sizes.indices, id: \.self) { i in Text(sizes[i].label).tag(i) }
                    }
                }
                Stepper(t("Schritte: \(steps)", "Steps: \(steps)"), value: $steps, in: 1...60)
                HStack {
                    Text("Seed")
                    TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
                    Spacer()
                    Stepper(t("Bilder: \(batch)", "Images: \(batch)"), value: $batch, in: 1...4)
                }

                GroupBox(t("Ausgangsbild (optional)", "Start image (optional)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        imageRow(startImage, choose: { startImage = Panels.chooseImage(t("Ausgangsbild wählen", "Choose start image")) },
                                 clear: { startImage = nil; mask = nil })
                        if startImage != nil && !isCoreML {
                            Toggle(t("Über den Rand hinaus erweitern (Outpainting)", "Extend beyond the edges (outpainting)"),
                                   isOn: $outpaintOn)
                        }
                        if startImage != nil && outpaintOn && !isCoreML {
                            outpaintFields
                        } else if startImage != nil {
                            HStack {
                                Text(t("Stärke", "Strength") + String(format: " %.2f", strength))
                                Slider(value: $strength, in: 0.1...1.0)
                            }
                            .disabled(mask != nil)
                            Text(mask != nil
                                 ? t("Mit Maske: weiß wird neu gerechnet, schwarz bleibt unverändert.",
                                     "With a mask: white is regenerated, black stays unchanged.")
                                 : t("0,3 behutsam, 0,5 deutlich, 1,0 nur noch als Vorlage.",
                                     "0.3 subtle, 0.5 clear, 1.0 uses it only as a reference."))
                                .font(.caption).foregroundStyle(.secondary)
                            if !isCoreML {
                                imageRow(mask, label: t("Maske", "Mask"), choose: { mask = Panels.chooseImage(t("Maske wählen (weiß = neu)", "Choose mask (white = new)")) },
                                         clear: { mask = nil })
                            }
                        }
                    }
                    .padding(4)
                }

                if !isCoreML { GroupBox(t("Referenzbilder (bis 3)", "Reference images (up to 3)")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(references, id: \.self) { url in
                            imageRow(url, choose: {}, clear: { references.removeAll { $0 == url } })
                        }
                        if references.count < 3 {
                            Button(t("Referenz hinzufügen …", "Add reference …")) {
                                if let url = Panels.chooseImage(t("Referenzbild wählen", "Choose reference image")) { references.append(url) }
                            }
                        }
                        Text(t("Im Prompt als „the first image“, „the second image“ ansprechen.",
                               "Refer to them in the prompt as \"the first image\", \"the second image\"."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                } }

                HStack {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(t("Generieren", "Generate")).frame(minWidth: 120)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let job = currentJob, !job.isFinished {
                        Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
                    }
                }
                if let message { Text(message).foregroundStyle(.red).font(.callout) }
            }
            .padding(14)
        }
    }

    /// Ränder fürs Erweitern, mit Schnellwahl und Zielformat.
    @ViewBuilder
    private var outpaintFields: some View {
        let labels = [t("Links", "Left"), t("Oben", "Top"), t("Rechts", "Right"), t("Unten", "Bottom")]
        HStack {
            ForEach(0..<4, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(labels[i]).font(.caption)
                    TextField("0", value: $edges[i], format: .number).frame(width: 64)
                }
            }
        }
        HStack {
            Button(t("↔ breiter", "↔ wider")) { edges = [256, 0, 256, 0] }
            Button(t("↕ höher", "↕ taller")) { edges = [0, 256, 0, 256] }
            Button(t("↓ nach unten", "↓ downwards")) { edges = [0, 0, 0, 384] }
            Button(t("rundum", "all around")) { edges = [128, 128, 128, 128] }
        }
        .controlSize(.small)
        if let url = startImage, let source = try? ImageFiles.load(url) {
            let e = Outpaint.Edges(left: edges[0], top: edges[1], right: edges[2], bottom: edges[3])
            let size = Outpaint.size(of: source, e)
            Text("\(source.width) × \(source.height) → \(size.width) × \(size.height)").font(.callout.monospacedDigit())
        }
        Text(t("Das Bild bleibt, nur der neue Rand wird gemalt; das Format ergibt sich aus Bild und Rand. "
               + "Der Prompt beschreibt das ganze erweiterte Bild.",
               "The image stays; only the new border is painted, the size follows from image and border. "
               + "The prompt describes the whole extended picture."))
            .font(.caption).foregroundStyle(.secondary)
    }

    /// „✨ Prompt ausbauen“: aus ein paar Worten eine volle Bildbeschreibung, mit Zurücknehmen.
    @ViewBuilder
    private var expandRow: some View {
        let canExpand = Models.expansionModel != nil
        HStack {
            Button {
                Task { await expand() }
            } label: {
                Text(expanding ? t("Baut aus …", "Expanding …") : t("✨ Prompt ausbauen", "✨ Expand prompt"))
            }
            .disabled(!canExpand || expanding || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(t("Schreibt aus ein paar Worten eine volle Bildbeschreibung (Qwen3 aus FLUX.2 Klein). "
                    + "Danach lesen und Erfundenes streichen.",
                    "Turns a few words into a full image description (Qwen3 from FLUX.2 Klein). "
                    + "Read it afterwards and delete what was invented."))
            if expanding { ProgressView().controlSize(.small) }
            if let before = promptBeforeExpand, !expanding {
                Button(t("Zurück zum eigenen Prompt", "Back to my prompt")) {
                    prompt = before
                    promptBeforeExpand = nil
                    expandInfo = nil
                }
            }
            Spacer()
        }
        if !canExpand {
            Text(t("Prompt ausbauen braucht FLUX.2 Klein (unter „Modelle“).",
                   "Expand prompt needs FLUX.2 Klein (under \"Models\")."))
                .font(.caption).foregroundStyle(.secondary)
        } else if let expandInfo {
            Text(expandInfo).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func expand() async {
        message = nil
        let original = prompt
        expanding = true
        defer { expanding = false }
        do {
            let result = try await JobQueue.expandAndWait(original.trimmingCharacters(in: .whitespacesAndNewlines))
            promptBeforeExpand = original
            prompt = result.expanded
            let words = result.expanded.split(whereSeparator: \.isWhitespace).count
            expandInfo = t("\(words) Wörter in \(Int(result.seconds.rounded())) s. Lesen und Erfundenes streichen.",
                           "\(words) words in \(Int(result.seconds.rounded())) s. Read it and delete what was invented.")
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    @ViewBuilder
    private func imageRow(_ url: URL?, label: String? = nil, choose: @escaping () -> Void,
                          clear: @escaping () -> Void) -> some View {
        HStack {
            if let url {
                if let thumb = Thumbnails.image(at: url, maxSide: 96) {
                    Image(nsImage: thumb).resizable().scaledToFit().frame(width: 48, height: 48)
                }
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(t("Entfernen", "Remove"), action: clear)
            } else {
                Button(t("\(label ?? "Bild") wählen …", "Choose \((label ?? "image").lowercased()) …"), action: choose)
                Spacer()
            }
        }
    }

    // MARK: Ergebnisse

    private var currentJob: JobRecord? {
        guard let lastJobID else { return nil }
        return state.jobs.first { $0.id == lastJobID }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = currentJob {
                HStack {
                    Text(statusText(job)).font(.headline)
                    Spacer()
                    if !job.isFinished { ProgressView(value: job.progress).frame(width: 160) }
                }
                Text(job.stage).font(.caption).foregroundStyle(.secondary)
                if let error = job.error { Text(error).foregroundStyle(.red) }
                let assets = state.images.filter { $0.jobID == job.id }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                        ForEach(assets) { asset in
                            VStack(alignment: .leading) {
                                AssetThumbnail(asset: asset, maxSide: 720)
                                Text(details(asset)).font(.caption).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button(t("Im Finder zeigen", "Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(asset.filename)])
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text(t("Noch nichts erzeugt.", "Nothing generated yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
    }

    private func statusText(_ job: JobRecord) -> String {
        switch job.status {
        case "queued": return t("Wartet", "Queued")
        case "running": return t("Rechnet …", "Generating …")
        case "done": return t("Fertig", "Done")
        case "cancelled": return t("Abgebrochen", "Cancelled")
        default: return t("Fehler", "Error")
        }
    }

    private func details(_ asset: AssetRecord) -> String {
        var parts: [String] = []
        if let seed = asset.meta["seed"]?.intValue { parts.append("Seed \(seed)") }
        if let s = asset.meta["duration_s"]?.doubleValue { parts.append(String(format: "%.1f s", s)) }
        if let mb = asset.meta["peak_memory_mb"]?.intValue { parts.append(t("\(mb) MB Spitze", "\(mb) MB peak")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Auftrag

    private func upload(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        _ = try ImageFiles.load(data)
        return try await AssetStore.shared.addUpload(data: data, originalName: url.lastPathComponent).id
    }

    private func submit() async {
        message = nil
        let size = fixedSize.map { (label: "", w: $0, h: $0) } ?? sizes[min(sizeIndex, sizes.count - 1)]
        var body: [String: JSONValue] = [
            "prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "width": .int(size.w), "height": .int(size.h),
            "steps": .int(steps), "batch_size": .int(batch),
            "model_id": .string(state.activeModelID),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        if isCoreML {
            body["negative_prompt"] = .string(negative)
            body["cfg"] = .double(guidance)
        }
        do {
            let extending = outpaintOn && !isCoreML && edges.contains { $0 > 0 }
            if let startImage, extending {
                body["image_asset_id"] = .string(try await upload(startImage))
                body["outpaint"] = .array(edges.map { .int(max(0, min(Outpaint.maxEdge, $0))) })
            } else if let startImage {
                body["image_asset_id"] = .string(try await upload(startImage))
                body["denoise"] = .double(mask != nil ? 1.0 : strength)
                if let mask { body["mask_asset_id"] = .string(try await upload(mask)) }
            }
            if !references.isEmpty && !extending {
                var ids: [JSONValue] = []
                for url in references { ids.append(.string(try await upload(url))) }
                body["reference_asset_ids"] = .array(ids)
            }
            let request = try ImageJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submit(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
