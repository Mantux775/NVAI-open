import AppKit
import SwiftUI

struct GenerateView: View {
    @EnvironmentObject var state: AppState

    @State private var prompt = ""
    @State private var sizeIndex = 0
    @State private var steps = 4
    @State private var seedText = ""
    @State private var batch = 1
    /// Ausgangsbild, Maske, Referenzen und altes Foto sind Assets (erzeugt oder hochgeladen) wie in der
    /// Windows-Oberfläche; Hochladen legt die Datei dafür als Upload ab.
    @State private var startID: String?
    @State private var strength = 0.5
    @State private var maskID: String?
    @State private var referenceIDs: [String] = []
    /// Outpainting: Ränder links, oben, rechts, unten in Pixeln.
    @State private var outpaintOn = false
    @State private var edges = [0, 0, 0, 0]
    @State private var lastJobID: String?
    @State private var message: String?
    @State private var negative = ""
    @State private var guidance = 7.5
    /// Bild erzeugen oder altes Foto restaurieren (seit 0.4.6, dieselbe Route wie POST /api/image/restore).
    @State private var formMode = FormMode.generate
    @State private var photoID: String?
    @State private var repairOn = true
    /// auto (Vorgabe wie unter Windows), thorough oder gentle.
    @State private var repairMode = "auto"
    @State private var colorizeOn = false
    /// Schärfen und vergrößern mit SeedVR2 3B (seit 0.4.7), Maßstab 1, 2 oder 4.
    @State private var sharpenOn = false
    @State private var sharpenScale = 2
    @State private var notes = ""
    /// LoRAs für FLUX.2 Klein (seit 0.4.7): gewählte mit Stärke.
    @State private var loraChoices: [String: Double] = [:]
    /// Große Vorschau eines Ergebnisses (Klick auf ein Bild).
    @State private var preview: AssetRecord?

    enum FormMode: Hashable { case generate, restore, audio, video }

    /// Musik und Klänge (seit 0.4.7, Stable Audio 3 Medium).
    @State private var audioPrompt = ""
    @State private var audioSeconds = 10.0

    /// Video (seit 0.4.8, LTX-Video 2B), mit Startbild als erstem Bild des Videos.
    @State private var videoPrompt = ""
    @State private var videoSizeIndex = 0
    @State private var videoFrames = 97
    @State private var videoStartID: String?
    @AppStorage("video.model") private var videoModelID = VideoCatalog.id

    private var sizes: [(label: String, w: Int, h: Int)] {
        ModelCatalog.flux2Sizes.map { ($0["label"] as? String ?? "", $0["w"] as? Int ?? 1024, $0["h"] as? Int ?? 1024) }
    }

    private var activeModel: AnyModel? { Models.find(state.activeModelID) }
    private var isCoreML: Bool { activeModel?.engine == "coreml" }
    /// FLUX.2 Klein (LoRAs, Füllen, Erweitern); Z-Image Turbo nimmt keine Bilder an (features.img2img = false).
    private var isFlux: Bool { activeModel?.engine == "mlx" }
    private var takesImages: Bool { activeModel?.features["img2img"] as? Bool ?? true }
    /// Gemessen am Mac mini M1 mit 8 GB (26.10.2026): 512² 101 s, 832 × 1216 399 s (acht Schritte je ~48 s).
    private var zimageDuration: String {
        let size = sizes[min(sizeIndex, sizes.count - 1)]
        let measured = size.w * size.h <= 512 * 512 ? t("rund 100 s", "about 100 s") : t("rund 7 min", "about 7 min")
        return t("Dauer je Bild auf einem Mac mini M1 mit 8 GB (gemessen): \(measured).",
                 "Time per image on a Mac mini M1 with 8 GB (measured): \(measured).")
    }

    private var fixedSize: Int? {
        if case .coreml(let m) = activeModel { return m.resolution }
        return nil
    }
    private var hint: String { activeModel?.features["prompt_hint"] as? String ?? ModelCatalog.promptHint }
    private var placeholder: String { activeModel?.features["placeholder"] as? String ?? ModelCatalog.placeholder }
    private var maxReferences: Int { isCoreML ? 0 : activeModel?.features["references"] as? Int ?? 3 }

    /// Bilder zur Auswahl: die neuesten erzeugten und hochgeladenen, neueste zuerst; „Weitere laden“ nimmt je
    /// 50 dazu (wie der Verlauf der Windows-Oberfläche).
    @State private var sourceCount = 50
    private var allSources: [AssetRecord] { (state.images + state.uploads).sorted { $0.createdAt > $1.createdAt } }
    private var sources: [AssetRecord] { Array(allSources.prefix(sourceCount)) }

    /// Geladene Bildmodelle; das gewählte steht auch dabei, wenn es noch nicht geladen ist.
    private var modelChoices: [AnyModel] {
        let installed = state.models.filter(\.installed).map(\.model)
        if let active = activeModel, !installed.contains(where: { $0.id == active.id }) { return [active] + installed }
        return installed
    }

    /// Standardwerte des Modells übernehmen (FLUX.2: 4 Schritte; Core ML: 25–30 Schritte, cfg 7,5).
    private func applyDefaults() {
        let f = activeModel?.features ?? [:]
        steps = f["steps"] as? Int ?? 4
        guidance = f["cfg"] as? Double ?? 7.5
        if isCoreML { referenceIDs = []; maskID = nil; outpaintOn = false }
        if !takesImages { startID = nil; referenceIDs = []; maskID = nil; outpaintOn = false }
    }

    var body: some View {
        HSplitView {
            form.frame(minWidth: 400, idealWidth: 460, maxWidth: 600)
            results.frame(minWidth: 400)
        }
        .onAppear {
            // Auf 8-GB-Macs ist 512 × 512 die einzige flüssige Größe.
            if SystemInfo.memoryGB < 16, let small = sizes.firstIndex(where: { $0.w == 512 }) { sizeIndex = small }
            applyDefaults()
            if state.showRestore { formMode = .restore }
            if state.showAudio { formMode = .audio }
            if state.showVideo { formMode = .video }
        }
        .onChange(of: state.activeModelID) { _, _ in applyDefaults() }
        .onChange(of: state.showRestore) { _, show in if show { formMode = .restore } }
        .onChange(of: state.showAudio) { _, show in if show { formMode = .audio } }
        .onChange(of: state.showVideo) { _, show in if show { formMode = .video } }
        .sheet(item: $preview) { asset in
            let list = jobAssets.contains(asset) ? jobAssets : [asset]
            PreviewSheet(assets: list, index: list.firstIndex(of: asset) ?? 0,
                         useAsStart: { use in
                             formMode = .generate
                             startID = use.id
                         },
                         useAsReference: maxReferences > 0 ? { use in
                             formMode = .generate
                             if !referenceIDs.contains(use.id) && referenceIDs.count < maxReferences { referenceIDs.append(use.id) }
                         } : nil)
                .environmentObject(state)
        }
    }

    // MARK: Formular

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker(t("Aufgabe", "Task"), selection: $formMode) {
                    Text(t("Bild erzeugen", "Create image")).tag(FormMode.generate)
                    Text(t("Foto restaurieren", "Restore photo")).tag(FormMode.restore)
                    Text(t("Musik und Klänge", "Music and sounds")).tag(FormMode.audio)
                    Text(t("Video", "Video")).tag(FormMode.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch formMode {
                case .restore: restoreForm
                case .audio: audioForm
                case .video: videoForm
                case .generate: generateForm
                }
            }
            .padding(14)
        }
    }

    /// Ein Bild als Auswahl mit null oder einem Eintrag (für ImageStrip).
    private func single(_ value: Binding<String?>) -> Binding<[String]> {
        Binding(get: { value.wrappedValue.map { [$0] } ?? [] }, set: { value.wrappedValue = $0.last })
    }

    private func strip(_ selection: Binding<[String]>, limit: Int = 1, allowNone: Bool = true) -> ImageStrip {
        ImageStrip(sources: sources, selection: selection, limit: limit, allowNone: allowNone,
                   upload: { await uploadFiles($0) }, remove: { removeAsset($0) },
                   loadMore: allSources.count > sourceCount ? { sourceCount += 50 } : nil)
    }

    private func pixelSize(_ id: String?) -> (width: Int, height: Int)? {
        guard let id, let asset = allSources.first(where: { $0.id == id }) else { return nil }
        return ImageFiles.pixelSize(AssetStore.shared.fileURL(asset.filename))
    }

    // MARK: Modell

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(t("Modell", "Model"), selection: Binding(get: { state.activeModelID }, set: { state.setActiveModel($0) })) {
                ForEach(modelChoices) { m in
                    Text(m.installed ? m.name : t("\(m.name) (nicht geladen)", "\(m.name) (not downloaded)")).tag(m.id)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let best = activeModel?.info["best_for"] as? String, !best.isEmpty {
                    Text(best).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Weitere Modelle …", "More models …")) { state.selectedTab = "models" }
                    .buttonStyle(.link).font(.caption)
            }
            if let model = activeModel, !model.installed {
                Text(t("Noch nicht geladen: unter „Modelle“ herunterladen.", "Not downloaded yet: download it under \"Models\"."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: LoRAs

    /// Geladene LoRAs zum Anhaken, mit Stärke und Auslösewort (das gehört in den Prompt, wie unter Windows).
    @ViewBuilder
    private var loraSection: some View {
        let installed = state.loras.filter(\.installed).map(\.model)
        DisclosureGroup(loraChoices.isEmpty ? "LoRAs" : t("LoRAs (\(loraChoices.count) gewählt)", "LoRAs (\(loraChoices.count) selected)")) {
            VStack(alignment: .leading, spacing: 8) {
                if installed.isEmpty {
                    Button(t("LoRAs unter „Modelle“ laden …", "Download LoRAs under \"Models\" …")) { state.selectedTab = "models" }
                        .buttonStyle(.link).font(.caption)
                }
                ForEach(installed) { lora in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(lora.name, isOn: Binding(get: { loraChoices[lora.id] != nil },
                                                        set: { loraChoices[lora.id] = $0 ? lora.strength : nil }))
                        if let strength = loraChoices[lora.id] {
                            HStack {
                                Text(t("Stärke", "Strength") + String(format: " %.2f", strength)).font(.caption.monospacedDigit())
                                Slider(value: Binding(get: { loraChoices[lora.id] ?? lora.strength },
                                                      set: { loraChoices[lora.id] = ($0 * 20).rounded() / 20 }), in: 0...1.5)
                            }
                            .padding(.leading, 20)
                            if !lora.trigger.isEmpty {
                                HStack {
                                    Text(t("Auslöser: ", "Trigger: ") + lora.trigger).font(.caption).foregroundStyle(.secondary)
                                    if !prompt.localizedCaseInsensitiveContains(lora.trigger) {
                                        Button(t("In den Prompt", "Add to prompt")) {
                                            prompt = prompt.isEmpty ? lora.trigger : "\(lora.trigger), \(prompt)"
                                        }
                                        .buttonStyle(.link).font(.caption)
                                    }
                                }
                                .padding(.leading, 20)
                            }
                            if lora.use == "edit" {
                                Text(t("Bearbeitet ein Bild: das Bild als Referenz wählen.", "Edits an image: pick the image as a reference."))
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                            }
                        }
                    }
                }
                Text(t("Eine andere Auswahl lädt FLUX.2 Klein neu, die LoRAs werden dabei eingerechnet.",
                       "A different selection reloads FLUX.2 Klein with the LoRAs merged in."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Musik und Klänge

    @ViewBuilder
    private var audioForm: some View {
        if !state.audioInstalled {
            Text(t("Braucht Stable Audio 3 Medium (3,8 GB).", "Needs Stable Audio 3 Medium (3.8 GB)."))
                .font(.callout).foregroundStyle(.orange)
            Button(t("Unter „Modelle“ laden …", "Download under \"Models\" …")) { state.selectedTab = "models" }
                .buttonStyle(.link)
        }
        Text(t("Beschreibung (auf Englisch)", "Description")).font(.subheadline.bold())
        TextEditor(text: $audioPrompt)
            .font(.body)
            .frame(minHeight: 90)
            .overlay(alignment: .topLeading) {
                if audioPrompt.isEmpty {
                    Text(verbatim: "Cinematic orchestral score with strings, brass and timpani, slow and solemn. BPM: 80.")
                        .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
            .border(.quaternary)
        Text(t("Ein Satz: Gattung mit Hauptinstrumenten, Stimmung, dann „BPM: 100.“. Für Geräusche den Klang beschreiben "
               + "(„heavy wooden door creaks open, then slams shut“). Ohne Gesang; die Länge hängt NVAI-open selbst an.",
               "One sentence: genre with lead instruments, mood, then \"BPM: 100.\". For sound effects describe the sound "
               + "(\"heavy wooden door creaks open, then slams shut\"). No vocals; NVAI-open appends the length itself."))
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Text(t("Länge: \(Int(audioSeconds)) s", "Length: \(Int(audioSeconds)) s")).monospacedDigit().frame(width: 110, alignment: .leading)
            Slider(value: $audioSeconds, in: 1...AudioCatalog.maxSeconds, step: 1)
        }
        HStack {
            Text("Seed")
            TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
        }
        HStack {
            Button {
                Task { await submitAudio() }
            } label: {
                Text(t("Erzeugen", "Generate")).frame(minWidth: 120)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!state.audioInstalled || audioPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let job = currentJob, !job.isFinished {
                Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
            }
        }
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
        if !state.audios.isEmpty {
            Text(t("Zuletzt erzeugt", "Recently generated")).font(.subheadline.bold()).padding(.top, 6)
            ForEach(state.audios.prefix(20)) { asset in AudioRow(asset: asset) }
        }
    }

    private func submitAudio() async {
        message = nil
        var body: [String: JSONValue] = [
            "prompt": .string(audioPrompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "seconds": .double(audioSeconds), "model_id": .string(AudioCatalog.id),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        do {
            let request = try AudioJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submitAudio(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Video

    private var videoSizes: [(label: String, w: Int, h: Int)] {
        VideoCatalog.sizes.map { ($0["label"] as? String ?? "", $0["w"] as? Int ?? 768, $0["h"] as? Int ?? 512) }
    }

    private var videoSize: (label: String, w: Int, h: Int) { videoSizes[min(videoSizeIndex, videoSizes.count - 1)] }

    private var videoModel: VideoCatalog.Choice {
        VideoCatalog.choices.first { $0.id == videoModelID } ?? VideoCatalog.choices[0]
    }

    /// Startbild wählbar: nicht, wenn das Modell keines kann (ausgegraut); ungeprüft (nil) bleibt es wählbar mit
    /// Hinweis; LTX-Video 2B braucht dafür seinen Bild-Encoder.
    private var startImageUsable: Bool {
        switch videoModel.startImage {
        case false?: return false
        case true?: return state.videoEncoderInstalled
        case nil: return true
        }
    }

    private var videoDownload: JobRecord? {
        state.jobs.first { $0.downloadModelID == VideoCatalog.id && !$0.isFinished }
    }

    @ViewBuilder
    private var videoStartBox: some View {
        GroupBox(t("Startbild (optional)", "Start image (optional)")) {
            VStack(alignment: .leading, spacing: 6) {
                if videoModel.startImage == true && state.videoInstalled && !state.videoEncoderInstalled {
                    Text(t("Das Startbild braucht den Bild-Encoder von LTX-Video: 1,4 GB Download, danach 0,46 GB auf der Platte.",
                           "A start image needs LTX-Video's image encoder: 1.4 GB download, then 0.46 GB on disk."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let videoDownload {
                        ProgressView(value: videoDownload.progress)
                        Text(videoDownload.stage).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(t("Startbild nachrüsten", "Add start image")) {
                            Task {
                                _ = await JobQueue.shared.submitVideoDownload()
                                await state.refresh()
                            }
                        }
                    }
                }
                strip(single($videoStartID))
                    .disabled(!startImageUsable)
                    .opacity(startImageUsable ? 1 : 0.4)
                if videoModel.startImage == false {
                    Text(t("Das gewählte Videomodell kann kein Startbild.", "The selected video model cannot take a start image."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if videoModel.startImage == nil {
                    Text(t("Ob das gewählte Videomodell ein Startbild nutzt, ist ungeprüft.",
                           "It has not been checked whether the selected video model uses a start image."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if videoStartID != nil && startImageUsable {
                    Text(t("Das Bild wird mittig auf \(videoSize.w) × \(videoSize.h) zugeschnitten und ist das erste Bild des Videos. "
                           + "Im Prompt das Bild kurz beschreiben, dann Bewegung und Kamera.",
                           "The image is center-cropped to \(videoSize.w) × \(videoSize.h) and becomes the first frame. "
                           + "In the prompt, describe the image briefly, then the motion and the camera."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: videoStartID) { _, id in
            // Hoch- oder Querformat wie das Bild; innerhalb davon schneidet das Startbild mittig zu.
            guard let size = pixelSize(id), size.width != size.height else { return }
            let portrait = size.height > size.width
            if (videoSize.h > videoSize.w) != portrait,
               let index = videoSizes.firstIndex(where: { ($0.h > $0.w) == portrait }) {
                videoSizeIndex = index
            }
        }
    }

    /// Längen, die bei diesem Format auf diesen Mac passen (`VideoJobRequest.maxVoxels`).
    private var videoFrameChoices: [Int] {
        VideoCatalog.frameChoices.filter { videoSize.w * videoSize.h * $0 <= VideoJobRequest.maxVoxels }
    }

    /// Gemessen am Mac mini M1 mit 8 GB (26.10.2026): 512 × 320 × 49 Bilder 40 s, 768 × 512 × 97 Bilder 174 s;
    /// dazwischen und darüber linear nach der Zahl der Bildpunkte geschätzt.
    private var videoDuration: String {
        let voxels = Double(videoSize.w * videoSize.h * videoFrames)
        let seconds = 4 + voxels * 4.45e-6
        let measured = (videoSize.w == 512 && videoSize.h == 320 && videoFrames == 49)
            || (videoSize.w == 768 && videoSize.h == 512 && videoFrames == 97)
        let amount = seconds < 90 ? t("rund \(Int((seconds / 5).rounded() * 5)) s", "about \(Int((seconds / 5).rounded() * 5)) s")
            : t("rund \(Int((seconds / 60).rounded())) min", "about \(Int((seconds / 60).rounded())) min")
        return measured
            ? t("Dauer auf einem Mac mini M1 mit 8 GB (gemessen): \(amount).", "Time on a Mac mini M1 with 8 GB (measured): \(amount).")
            : t("Dauer auf einem Mac mini M1 mit 8 GB (geschätzt aus zwei Messungen): \(amount).",
                "Time on a Mac mini M1 with 8 GB (estimated from two measurements): \(amount).")
    }

    @ViewBuilder
    private var videoForm: some View {
        if !state.videoInstalled {
            Text(t("Braucht LTX-Video 2B (7,6 GB).", "Needs LTX-Video 2B (7.6 GB)."))
                .font(.callout).foregroundStyle(.orange)
            Button(t("Unter „Modelle“ laden …", "Download under \"Models\" …")) { state.selectedTab = "models" }
                .buttonStyle(.link)
        }
        if VideoCatalog.choices.count > 1 {
            Picker(t("Modell", "Model"), selection: $videoModelID) {
                ForEach(VideoCatalog.choices) { Text($0.name).tag($0.id) }
            }
        } else {
            LabeledContent(t("Modell", "Model"), value: videoModel.name)
        }
        Text(t("Beschreibung (auf Englisch)", "Description")).font(.subheadline.bold())
        TextEditor(text: $videoPrompt)
            .font(.body)
            .frame(minHeight: 110)
            .overlay(alignment: .topLeading) {
                if videoPrompt.isEmpty {
                    Text(verbatim: "A close-up shot of a burning torch mounted on a dark stone wall in a medieval castle "
                         + "at night. The flame flickers and sways, casting warm orange light across the rough stone "
                         + "blocks. Small sparks rise and fade into the darkness. The camera slowly pushes in.")
                        .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
            .border(.quaternary)
        ExpandPromptRow(text: $videoPrompt, target: .video, message: $message)
        Text(t("Ein Absatz im Präsens: Einstellung, Ort und Licht, die Handlung mit Verben, dann die Kamera. Bewegung "
               + "ausdrücklich beschreiben. Schrift im Bild gelingt LTX-Video 2B nicht. Ohne Ton, 24 Bilder je Sekunde.",
               "One paragraph in the present tense: shot, setting and light, the action with verbs, then the camera. "
               + "Describe motion explicitly. LTX-Video 2B cannot render lettering. No sound, 24 frames per second."))
            .font(.caption).foregroundStyle(.secondary)
        videoStartBox
        Picker(t("Format", "Size"), selection: $videoSizeIndex) {
            ForEach(videoSizes.indices, id: \.self) { i in Text(videoSizes[i].label).tag(i) }
        }
        Picker(t("Länge", "Length"), selection: $videoFrames) {
            ForEach(videoFrameChoices, id: \.self) { f in
                Text(String(format: t("%.0f s (%d Bilder)", "%.0f s (%d frames)"), Double(f - 1) / Double(VideoCatalog.fps), f)).tag(f)
            }
        }
        .onChange(of: videoSizeIndex) { _, _ in
            if !videoFrameChoices.contains(videoFrames) { videoFrames = videoFrameChoices.last ?? 49 }
        }
        Text(videoDuration).font(.caption).foregroundStyle(.secondary)
        HStack {
            Text("Seed")
            TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
        }
        HStack {
            Button {
                Task { await submitVideo() }
            } label: {
                Text(t("Erzeugen", "Generate")).frame(minWidth: 120)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!state.videoInstalled || videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let job = currentJob, !job.isFinished {
                Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
            }
        }
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
        if !state.videos.isEmpty {
            Text(t("Zuletzt erzeugt", "Recently generated")).font(.subheadline.bold()).padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(state.videos.prefix(12)) { asset in VideoRow(asset: asset) }
            }
        }
    }

    private func submitVideo() async {
        message = nil
        var body: [String: JSONValue] = [
            "prompt": .string(videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "width": .int(videoSize.w), "height": .int(videoSize.h), "frames": .int(videoFrames),
            "fps": .int(VideoCatalog.fps), "model_id": .string(videoModel.id),
        ]
        if let start = videoStartID, startImageUsable { body["image_asset_id"] = .string(start) }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        do {
            let request = try VideoJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submitVideo(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Foto restaurieren

    /// Schäden entfernen (automatisch, gründlich oder schonend) und einfärben mit FLUX.2 Klein. Gemessen auf einem
    /// Mac mini M1 mit 8 GB: Entfernen ~120 s, Einfärben ~105 s je Variante, beim ersten Mal ~50 s Laden dazu
    /// (Livetest 25.10.2026); schonend setzt danach in rund 1 s ein.
    @ViewBuilder
    private var restoreForm: some View {
        Text(t("Altes Foto", "Old photo")).font(.subheadline.bold())
        strip(single($photoID), allowNone: false)
        if let size = pixelSize(photoID) {
            Text(t("\(size.width) × \(size.height) px; das Ergebnis wird am Foto ausgerichtet und behält dessen Format.",
                   "\(size.width) × \(size.height) px; the result is aligned with the photo and keeps its size."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if Models.expansionModel == nil {
            Text(t("Restaurieren braucht FLUX.2 Klein (unter „Modelle“).", "Restoring needs FLUX.2 Klein (under \"Models\")."))
                .font(.caption).foregroundStyle(.orange)
        }
        Toggle(t("Schäden entfernen (Kratzer, Staub, Risse, Flecken)", "Remove damage (scratches, dust, tears, stains)"), isOn: $repairOn)
        if repairOn {
            VStack(alignment: .leading, spacing: 4) {
                Picker(t("Art", "Kind"), selection: $repairMode) {
                    Text(t("Automatisch", "Automatic")).tag("auto")
                    Text(t("Gründlich", "Thorough")).tag("thorough")
                    Text(t("Schonend", "Gentle")).tag("gentle")
                }
                .pickerStyle(.segmented)
                Text(repairModeNote).font(.caption).foregroundStyle(.secondary)
                if repairMode == "auto" && !(state.helpers.first { $0.model == .vision }?.installed ?? false) {
                    Button(t("Qwen3.5 4B unter „Modelle“ laden …", "Download Qwen3.5 4B under \"Models\" …")) {
                        state.selectedTab = "models"
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.leading, 20)
        }
        Toggle(t("Einfärben", "Colorize"), isOn: $colorizeOn)
        if colorizeOn {
            Text(t("Übernommen wird nur die Farbe; Helligkeit und Detail bleiben die des Fotos.",
                   "Only the color is taken over; brightness and detail stay the photo's."))
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
        }
        let seedvr2 = state.helpers.first { $0.model == .sharpen }?.installed ?? false
        Toggle(t("Schärfen und vergrößern (SeedVR2)", "Sharpen and enlarge (SeedVR2)"), isOn: $sharpenOn)
            .disabled(!seedvr2)
        if !seedvr2 {
            Button(t("Braucht SeedVR2 3B (4,7 GB): unter „Modelle“ laden …", "Needs SeedVR2 3B (4.7 GB): download under \"Models\" …")) {
                state.selectedTab = "models"
            }
            .buttonStyle(.link).font(.caption).padding(.leading, 20)
        } else if sharpenOn {
            VStack(alignment: .leading, spacing: 4) {
                Picker(t("Maßstab", "Scale"), selection: $sharpenScale) {
                    Text(t("1× (nur schärfen)", "1× (sharpen only)")).tag(1)
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                }
                .pickerStyle(.segmented)
                if let size = pixelSize(photoID) {
                    let out = sharpenSize(size)
                    Text(t("Ergebnis \(out.width) × \(out.height) px. Nimmt Rauschen, Korn und Unschärfe heraus, repariert aber "
                           + "keine Kratzer.",
                           "Result \(out.width) × \(out.height) px. Removes noise, grain and blur, but does not repair scratches."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 20)
        }
        Text(t("Hinweise (optional, auf Englisch)", "Hints (optional)")).font(.subheadline.bold())
        TextEditor(text: $notes)
            .font(.body)
            .frame(minHeight: 60)
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    Text(verbatim: "his cap is white with dark navy stripes").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
            .border(.quaternary)
        Text(t("Bekannte Farben nennen: gemessen 40 % weniger Farbabweichung beim Einfärben.",
               "Name known colors: measured 40% less color error when colorizing."))
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Text("Seed")
            TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
            Spacer()
            Stepper(t("Varianten: \(batch)", "Variants: \(batch)"), value: $batch, in: 1...4)
        }
        if repairOn || colorizeOn || sharpenOn {
            let minutes = max(1, Int((Double(restoreSeconds) / 60).rounded()))
            Text(t("Dauer rund \(minutes) min, beim ersten Mal knapp 1 min länger (gemessen auf einem Mac mini M1 mit 8 GB).",
                   "About \(minutes) min, close to 1 min longer the first time (measured on a Mac mini M1 with 8 GB)."))
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button {
                Task { await submitRestore() }
            } label: {
                Text(t("Restaurieren", "Restore")).frame(minWidth: 120)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(photoID == nil || !(repairOn || colorizeOn || sharpenOn))
            if let job = currentJob, !job.isFinished {
                Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
            }
        }
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
    }

    /// Geschätzte Dauer auf einem Mac mini M1 mit 8 GB (gemessen 25.10.2026): Schäden ~120 s, Farbe ~105 s je Variante,
    /// „Automatisch“ ~20 s, Schärfen ~20 s je Kachel von 384 px (3200 × 2432: 80 Kacheln, knapp 30 min).
    private var restoreSeconds: Int {
        let variants = repairOn || colorizeOn ? batch : 1
        var seconds = ((repairOn ? 120 : 0) + (colorizeOn ? 105 : 0)) * batch
        if repairOn && repairMode == "auto" && (state.helpers.first { $0.model == .vision }?.installed ?? false) { seconds += 20 }
        if sharpenOn, let size = pixelSize(photoID) {
            let out = sharpenSize(size)
            func tiles(_ side: Int) -> Int { side <= 384 ? 1 : Int((Double(side - 64) / 320).rounded(.up)) }
            seconds += tiles(out.width) * tiles(out.height) * 20 * variants
        }
        return seconds
    }

    /// Zielgröße beim Schärfen: Foto × Maßstab, höchstens `HelperModel.sharpenMaxPixels` (wie der Auftrag).
    private func sharpenSize(_ size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        var w = size.width * sharpenScale, h = size.height * sharpenScale
        let limit = Double(HelperModel.sharpenMaxPixels)
        if Double(w * h) > limit {
            let k = (limit / Double(w * h)).squareRoot()
            w = Int(Double(w) * k)
            h = Int(Double(h) * k)
        }
        return (w, h)
    }

    /// Wann welche Art (gemessen unter Windows an 21 Testfotos): nach der Art des Schadens, nicht nach der Menge.
    private var repairModeNote: String {
        switch repairMode {
        case "thorough":
            return t("Rechnet das ganze Foto neu: am besten bei flächiger Alterung (Wasserflecken, Craquelé, Korn, Ausbleichen). "
                     + "Gesichter können sich je Variante leicht ändern.",
                     "Redraws the whole photo: best for overall aging (water stains, craquelure, grain, fading). Faces may "
                     + "change slightly from variant to variant.")
        case "gentle":
            return t("Behält das Foto in voller Auflösung und setzt nur die Schäden ein: am besten bei einzelnen Kratzern, Staub, "
                     + "Rissen oder Schrift auf sonst gutem Foto. Wasserränder und Craquelé bleiben stehen.",
                     "Keeps the photo at full resolution and only replaces the damage: best for single scratches, dust, tears "
                     + "or writing on an otherwise good photo. Water rings and craquelure stay.")
        default:
            if state.helpers.first(where: { $0.model == .vision })?.installed ?? false {
                return t("Qwen3.5 4B sieht sich das Foto vorher an: Schäden über das ganze Bild → gründlich, sonst schonend "
                         + "(bei 20 von 21 Testfotos die bessere Wahl, rund 20 s).",
                         "Qwen3.5 4B looks at the photo first: damage across the whole picture → thorough, otherwise gentle "
                         + "(the better choice on 20 of 21 test photos, about 20 s).")
            }
            return t("Braucht das Zusatzmodell Qwen3.5 4B (3 GB); ohne rechnet „Automatisch“ gründlich.",
                     "Needs the add-on Qwen3.5 4B (3 GB); without it, \"Automatic\" restores thoroughly.")
        }
    }

    private func submitRestore() async {
        message = nil
        guard let photoID else { return }
        var body: [String: JSONValue] = [
            "image_asset_id": .string(photoID),
            "repair": .bool(repairOn), "repair_mode": .string(repairMode), "colorize": .bool(colorizeOn),
            "sharpen": .bool(sharpenOn), "scale": .int(sharpenScale),
            "notes": .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)), "batch_size": .int(batch),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        do {
            let request = try RestoreJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submitRestore(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: Bild erzeugen

    @ViewBuilder
    private var generateForm: some View {
        modelPicker

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
        ExpandPromptRow(text: $prompt, target: .image, message: $message)
        if isFlux { loraSection }

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
            if activeModel?.engine == "zimage" {
                Text(zimageDuration).font(.caption).foregroundStyle(.secondary)
            }
        }
        Stepper(t("Schritte: \(steps)", "Steps: \(steps)"), value: $steps, in: 1...60)
        HStack {
            Text("Seed")
            TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
            Spacer()
            Stepper(t("Bilder: \(batch)", "Images: \(batch)"), value: $batch, in: 1...4)
        }

        if takesImages {
        GroupBox(t("Ausgangsbild (optional)", "Start image (optional)")) {
            VStack(alignment: .leading, spacing: 8) {
                strip(single($startID))
                if let size = pixelSize(startID) {
                    Text("\(size.width) × \(size.height) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if startID != nil && !isCoreML {
                    Toggle(t("Über den Rand hinaus erweitern (Outpainting)", "Extend beyond the edges (outpainting)"),
                           isOn: $outpaintOn)
                }
                if startID != nil && outpaintOn && !isCoreML {
                    outpaintFields
                } else if startID != nil {
                    HStack {
                        Text(t("Stärke", "Strength") + String(format: " %.2f", strength))
                        Slider(value: $strength, in: 0.1...1.0)
                    }
                    .disabled(maskID != nil)
                    Text(maskID != nil
                         ? t("Mit Maske: weiß wird neu gerechnet, schwarz bleibt unverändert.",
                             "With a mask: white is regenerated, black stays unchanged.")
                         : t("0,3 behutsam, 0,5 deutlich, 1,0 nur noch als Vorlage.",
                             "0.3 subtle, 0.5 clear, 1.0 uses it only as a reference."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !isCoreML {
                        Text(t("Maske (optional, weiß = neu)", "Mask (optional, white = new)")).font(.caption.bold())
                        strip(single($maskID))
                    }
                }
            }
            .padding(4)
        }
        }

        if maxReferences > 0 {
            GroupBox(t("Referenzbilder (bis \(maxReferences)) – \(referenceIDs.count) gewählt",
                       "Reference images (up to \(maxReferences)) – \(referenceIDs.count) chosen")) {
                VStack(alignment: .leading, spacing: 6) {
                    strip($referenceIDs, limit: maxReferences, allowNone: false)
                    Text(t("Im Prompt als „the first image“, „the second image“ ansprechen, in der Reihenfolge der Nummern. "
                           + "Mit einem Bild wird bearbeitet: sagen, was sich ändert und was gleich bleibt.",
                           "Refer to them in the prompt as \"the first image\", \"the second image\", in the order of the "
                           + "numbers. With one image you edit it: say what changes and what stays the same."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }

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
        if let source = pixelSize(startID) {
            let e = Outpaint.Edges(left: edges[0], top: edges[1], right: edges[2], bottom: edges[3])
            let size = Outpaint.size(width: source.width, height: source.height, e)
            Text("\(source.width) × \(source.height) → \(size.width) × \(size.height)").font(.callout.monospacedDigit())
        }
        Text(t("Das Bild bleibt, nur der neue Rand wird gemalt; das Format ergibt sich aus Bild und Rand. "
               + "Der Prompt beschreibt das ganze erweiterte Bild.",
               "The image stays; only the new border is painted, the size follows from image and border. "
               + "The prompt describes the whole extended picture."))
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Bilder hochladen und löschen

    /// Dateien als Uploads ablegen (wie POST /api/upload); gibt die neuen Asset-IDs zurück.
    private func uploadFiles(_ urls: [URL]) async -> [String] {
        message = nil
        var ids: [String] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                _ = try ImageFiles.load(data)
                ids.append(try await AssetStore.shared.addUpload(data: data, originalName: url.lastPathComponent).id)
            } catch {
                message = t("„\(url.lastPathComponent)“ ist kein lesbares Bild.", "\"\(url.lastPathComponent)\" is not a readable image.")
            }
        }
        await state.refresh()
        return ids
    }

    /// Ein Bild aus der Auswahl löschen (auch aus dem Verlauf, wie „Dieses Quellbild löschen“ unter Windows).
    private func removeAsset(_ asset: AssetRecord) {
        let id = asset.id
        if startID == id { startID = nil }
        if maskID == id { maskID = nil }
        if photoID == id { photoID = nil }
        referenceIDs.removeAll { $0 == id }
        Task {
            await AssetStore.shared.delete(id)
            await state.refresh()
        }
    }

    // MARK: Ergebnisse

    private var currentJob: JobRecord? {
        guard let lastJobID else { return nil }
        return state.jobs.first { $0.id == lastJobID }
    }

    private var jobAssets: [AssetRecord] {
        guard let job = currentJob else { return [] }
        return (state.images + state.audios + state.videos).filter { $0.jobID == job.id }
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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                        ForEach(jobAssets.filter { $0.kind == "audio" }) { asset in AudioRow(asset: asset) }
                        ForEach(jobAssets.filter { $0.kind == "video" }) { asset in VideoRow(asset: asset) }
                        ForEach(jobAssets.filter { $0.kind == "image" || $0.kind == "upload" }) { asset in
                            VStack(alignment: .leading) {
                                AssetThumbnail(asset: asset, maxSide: 720)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
                                    .onTapGesture { preview = asset }
                                    .help(AssetActions.help(click: t("Klick: große Vorschau", "Click: large preview")))
                                Text(details(asset)).font(.caption).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button(t("Große Vorschau", "Large preview")) { preview = asset }
                                Button(t("Als Ausgangsbild verwenden", "Use as start image")) {
                                    formMode = .generate
                                    startID = asset.id
                                }
                                AssetMenuItems(asset: asset)
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
        let extending = outpaintOn && !isCoreML && edges.contains { $0 > 0 }
        if let startID, extending {
            body["image_asset_id"] = .string(startID)
            body["outpaint"] = .array(edges.map { .int(max(0, min(Outpaint.maxEdge, $0))) })
        } else if let startID {
            body["image_asset_id"] = .string(startID)
            body["denoise"] = .double(maskID != nil ? 1.0 : strength)
            if let maskID, !isCoreML { body["mask_asset_id"] = .string(maskID) }
        }
        if !referenceIDs.isEmpty && !extending && maxReferences > 0 {
            body["reference_asset_ids"] = .array(referenceIDs.prefix(maxReferences).map { .string($0) })
        }
        let installedLoRAs = Set(state.loras.filter(\.installed).map(\.id))
        let chosen = loraChoices.filter { installedLoRAs.contains($0.key) }.sorted { $0.key < $1.key }
        if isFlux && !chosen.isEmpty {
            body["loras"] = .array(chosen.map { .object(["model_id": .string($0.key), "strength": .double($0.value)]) })
        }
        do {
            let request = try ImageJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submit(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
