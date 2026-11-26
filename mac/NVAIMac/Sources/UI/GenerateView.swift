import AppKit
import SwiftUI

/// „Generieren“: Bild, Foto restaurieren, Musik und Klänge, Sprache, Video. Seit Mac 1.0 nach dem Konzept „NVAI im
/// Fluss“ (Bildschirme B und C, wie panels/Generate.tsx unter Windows): Beim Video bestimmt ein Weg die Felder statt
/// einzelner Klappen, über dem großen Knopf stehen Modell-Chip, Format und Länge, ein fehlendes Modell lädt an Ort und
/// Stelle, der Knopf nennt Aktion und Zeit. Rechts der Fortschritt in Phasen mit Restzeit, danach das Ergebnis mit
/// „Fertig nach m:ss“, Seed zum Kopieren und den nächsten Schritten. Schritte, Seed und CFG stehen unter
/// „Feineinstellung“, nichts davon fällt weg.
struct GenerateView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var flow = FlowJobs.shared

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
    /// Zugeklappt, bis etwas gewählt ist, wie unter Windows (Nutzer 22.11.2026: „reference images sollte als klapp menü
    /// standart mässig zugeklappt sein“, „also alles kompakter und atraktiver für den user“)
    @State private var startOpen = false
    @State private var refsOpen = false
    @State private var infoOpen = false
    /// Schritte, Seed, CFG (Konzept: „bleiben unter ‚Feineinstellung‘, nur nicht mehr im Weg“)
    @State private var fineOpen = false
    /// Ein Absenden zur Zeit (seit 0.5.9): Zwei schnelle Klicks oder zweimal ⌘↩ gaben zwei gleiche Aufträge.
    @State private var submitting = false
    /// Vorgaben (Format auf 8-GB-Macs, Schritte, CFG) nur beim ersten Erscheinen setzen (seit 0.5.9): Vorher setzte
    /// jeder Reiterwechsel zurück, was man eingestellt hatte.
    @State private var didAppear = false
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
    /// Eigene LoRA-Datei direkt in der Auswahl hinzufügen (seit 0.5.5); passt sie, gleich anhaken
    @State private var loraFile: LoRAFileChoice?
    @State private var loraNote: String?
    /// Große Vorschau eines Ergebnisses (Klick auf ein Bild).
    @State private var preview: AssetRecord?

    enum FormMode: Hashable { case generate, restore, audio, speech, video }

    /// Musik und Klänge (seit 0.4.7, Stable Audio 3 Medium).
    @State private var audioPrompt = ""
    @State private var audioSeconds = 10.0

    /// Video (seit 0.4.8, LTX-Video 2B), mit Startbild als erstem Bild des Videos.
    @State private var videoPrompt = ""
    @State private var videoSizeIndex = 0
    @State private var videoFrames = 97
    @State private var videoStartID: String?
    /// Weg des Videos (seit Mac 1.0, Bildschirm B): text (nur Text) oder start (mit Startbild)
    @State private var videoWay = "text"
    @AppStorage("video.model") private var videoModelID = VideoCatalog.recommended.id

    /// Sprecherstimme: dieselben Felder wie SpeechForm (SceneStorage teilt sie im Fenster), damit der große Knopf hier
    /// unten den Satz abschicken und „Als Stimmvorlage“ sie setzen kann
    @SceneStorage("speech.text") private var speechText = ""
    @SceneStorage("speech.fromRecording") private var speechFromRecording = false
    @SceneStorage("speech.voice") private var speechVoice = ""
    @SceneStorage("speech.recording") private var speechRecordingID: String?
    @SceneStorage("speech.voiceText") private var speechVoiceText = ""
    @SceneStorage("speech.language") private var speechLanguage = "auto"
    @SceneStorage("speech.seed") private var speechSeed = ""

    // Fluss (seit Mac 1.0): Schätzung am Knopf, Lauf rechts, nächste Schritte
    @State private var mainEstimate: JobEstimate?
    @State private var run: RunInfo?
    @State private var pickedID: String?
    @State private var nextEstimates: [String: JobEstimate] = [:]
    @State private var nextNeed: NextNeed?
    @State private var studioNote: String?
    @FocusState private var promptFocused: Bool

    /// Was der rechte Teil über den laufenden Auftrag weiß (Titel, Modell für „Modell lädt“, Schätzung)
    struct RunInfo {
        let job: String
        let title: String
        let model: String?
        let expected: Double?
        let next: String
    }

    /// Ein nächster Schritt braucht ein Modell, das fehlt: darunter laden, statt etwas zu starten
    struct NextNeed {
        let why: String
        let model: FlowModel
        let alternative: FlowModel?
        let useAlternative: (() -> Void)?
    }

    private var sizes: [(label: String, w: Int, h: Int)] {
        ModelCatalog.flux2Sizes.map { ($0["label"] as? String ?? "", $0["w"] as? Int ?? 1024, $0["h"] as? Int ?? 1024) }
    }

    private var activeModel: AnyModel? { Models.find(state.activeModelID) }
    private var isCoreML: Bool { activeModel?.engine == "coreml" }
    /// FLUX.2 Klein (LoRAs, Füllen, Erweitern); Z-Image Turbo nimmt keine Bilder an (features.img2img = false).
    private var isFlux: Bool { activeModel?.engine == "mlx" }
    private var takesImages: Bool { activeModel?.features["img2img"] as? Bool ?? true }

    private var fixedSize: Int? {
        if case .coreml(let m) = activeModel { return m.resolution }
        return nil
    }
    private var hint: String { activeModel?.features["prompt_hint"] as? String ?? ModelCatalog.promptHint }
    private var placeholder: String { activeModel?.features["placeholder"] as? String ?? ModelCatalog.placeholder }
    private var maxReferences: Int { isCoreML ? 0 : activeModel?.features["references"] as? Int ?? 3 }
    /// Nur erweitern (Ausgangsbild, Schalter, Ränder): Der Knopf heißt dann „Bild erweitern“, der Prompt ist optional
    /// (Nutzer 22.11.2026: „wenn ich nur extend will dann lieber neuen button einblenden, mit extend image“)
    private var extending: Bool { takesImages && startID != nil && outpaintOn && !isCoreML && edges.contains { $0 > 0 } }
    /// Ohne eigenen Text beim Erweitern, wie EXTEND_PROMPT in der Windows-Oberfläche
    private static let extendPrompt = "The same scene continues seamlessly beyond the edges, in the same style, "
        + "with the same lighting and the same perspective."

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

    private func flowModel(_ id: String?) -> FlowModel? { id.flatMap { id in state.flowModels.first { $0.id == id } } }

    var body: some View {
        // Einstellungen links, mit dem Teiler nach rechts bis 1100 px breiter zu ziehen (Nutzer 18.11. auf einem MacBook
        // M4 mit 1710 px: „inhalte von den einstellungen links und rechts gecropt, der bereich soll sich mit dem schiebe
        // regler nach rechts vergrößern lassen“; vorher höchstens 600 px)
        HSplitView {
            VStack(spacing: 0) {
                form
                Divider()
                submitBar
            }
            .frame(minWidth: 420, idealWidth: 560, maxWidth: 1100)
            // Feste Idealbreite: sonst rückt die Teilung, sobald ein Ergebnis kommt (Ergebnisspalte schrumpfte auf 380)
            results.frame(minWidth: 380, idealWidth: 640, maxWidth: .infinity)
        }
        .onAppear {
            if !didAppear {
                didAppear = true
                // Auf 8-GB-Macs ist 512 × 512 die einzige flüssige Größe.
                if SystemInfo.memoryGB < 16, let small = sizes.firstIndex(where: { $0.w == 512 }) { sizeIndex = small }
                applyDefaults()
            }
            if state.showRestore { formMode = .restore }
            if state.showAudio { formMode = .audio }
            if state.showVideo { formMode = .video }
            if state.showSpeech { formMode = .speech }
            if let focus = state.generateFocus { applyFocus(focus.mode) }
            if let text = state.flowPrefill { prefill(text) }
            if let start = state.generateStartPreset { startID = start }
            if startID != nil { startOpen = true }
            if !referenceIDs.isEmpty { refsOpen = true }
        }
        .onChange(of: state.activeModelID) { _, _ in applyDefaults() }
        .onChange(of: state.images.count + state.uploads.count) { _, _ in pruneSelection() }
        .onChange(of: state.showRestore) { _, show in if show { formMode = .restore } }
        .onChange(of: state.showAudio) { _, show in if show { formMode = .audio } }
        .onChange(of: state.showVideo) { _, show in if show { formMode = .video } }
        .onChange(of: state.showSpeech) { _, show in if show { formMode = .speech } }
        .onChange(of: state.generateFocus) { _, focus in if let focus { applyFocus(focus.mode) } }
        // Prüfstand: Prompt vorgeben und den großen Knopf drücken (LaunchOptions, `--flow-prompt`, `--flow-submit`)
        .onChange(of: state.flowPrefill) { _, text in if let text { prefill(text) } }
        .onChange(of: state.flowSubmit) { _, _ in Task { await submitCurrent() } }
        .onChange(of: state.generateJobID) { _, _ in
            pickedID = nil
            nextNeed = nil
            studioNote = nil
        }
        // Ein gewähltes Bild klappt seinen Bereich auf (Vorschau „Als Ausgangsbild“, „Als Referenz“)
        .onChange(of: startID) { _, id in if id != nil { startOpen = true } }
        .onChange(of: referenceIDs.count) { old, new in if new > old { refsOpen = true } }
        .onChange(of: videoStartID) { _, id in if id != nil { videoWay = "start" } }
        // Zeit am Knopf, kurz entprellt; Texte ändern sie nicht (außer bei der Stimme die Länge)
        .task(id: estimateKey) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let p = plan() else {
                if plan() == nil { mainEstimate = nil }
                return
            }
            mainEstimate = await Estimate.one(kind: p.kind, params: .object(p.body))
        }
        .task(id: nextKey) { await loadNextEstimates() }
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

    private func prefill(_ text: String) {
        switch formMode {
        case .video: videoPrompt = text
        case .audio: audioPrompt = text
        case .speech: speechText = text
        case .restore: notes = text
        case .generate: prompt = text
        }
    }

    private func applyFocus(_ mode: String) {
        switch mode {
        case "restore": formMode = .restore
        case "audio": formMode = .audio
        case "speech": formMode = .speech
        case "video": formMode = .video
        default: formMode = .generate
        }
    }

    // MARK: Formular

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Fünf Aufgaben als Leiste; ist die Spalte dafür zu schmal, als Menü statt links und rechts abgeschnitten
                ViewThatFits(in: .horizontal) {
                    taskPicker.pickerStyle(.segmented).fixedSize()
                    taskPicker.pickerStyle(.menu).frame(maxWidth: 260, alignment: .leading)
                }
                switch formMode {
                case .restore: restoreForm
                case .audio: audioForm
                case .speech: SpeechForm()
                case .video: videoForm
                case .generate: generateForm
                }
                fineSettings
                if let message { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            }
            .padding(14)
        }
    }

    private var taskPicker: some View {
        Picker(t("Aufgabe", "Task"), selection: $formMode) {
            Text(t("Bild erzeugen", "Create image")).tag(FormMode.generate)
            Text(t("Foto restaurieren", "Restore photo")).tag(FormMode.restore)
            Text(t("Musik und Klänge", "Music and sounds")).tag(FormMode.audio)
            Text(t("Sprache", "Speech")).tag(FormMode.speech)
            Text(t("Video", "Video")).tag(FormMode.video)
        }
        .labelsHidden()
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
        guard let id, let asset = AssetSnapshot.shared.get(id) ?? allSources.first(where: { $0.id == id }) else { return nil }
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
                // Noch nicht geladene Bildmodelle: gewählt, erscheint unten „Laden“ mit Größe und Lizenz
                let missing = state.models.filter { !$0.installed && $0.model.engine != "coreml" && $0.model.fits != "nein" }.map(\.model)
                    .filter { m in !modelChoices.contains { $0.id == m.id } }
                if !missing.isEmpty {
                    Divider()
                    ForEach(missing) { m in Text(t("\(m.name) (noch nicht geladen)", "\(m.name) (not downloaded yet)")).tag(m.id) }
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
            // Modell-Infos zugeklappt unter dem Tipp (Nutzer 22.11.2026: „sollte als aufklappmenü unter tip sein (auch
            // kompakter) mit icon model infos“)
            if let model = activeModel {
                DisclosureGroup(isExpanded: $infoOpen) {
                    modelInfo(model)
                } label: {
                    Label(t("Modell-Infos", "Model info"), systemImage: "info.circle").font(.caption)
                }
            }
        }
    }

    /// Beschreibung, Lizenz, Download, Für und Wider des Modells
    @ViewBuilder
    private func modelInfo(_ model: AnyModel) -> some View {
        let info = model.info
        let license = info["license"] as? String ?? ""
        let commercial = info["commercial_ok"] as? Bool ?? false
        VStack(alignment: .leading, spacing: 4) {
            if let text = info["description"] as? String, !text.isEmpty {
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            if !license.isEmpty {
                Text(t("Lizenz: \(license)", "License: \(license)")
                     + (commercial ? t(" · kommerziell erlaubt", " · commercial use allowed") : ""))
            }
            if let gb = info["size_gb"] as? Double, gb > 0 {
                Text("Download: \(gb.formatted(.number.precision(.fractionLength(1)))) GB")
            }
            ForEach(info["pros"] as? [String] ?? [], id: \.self) { Text("+ " + $0) }
            ForEach(info["cons"] as? [String] ?? [], id: \.self) { Text("– " + $0) }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        .padding(.top, 2)
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
                Button(t("+ Eigene LoRA-Datei hinzufügen", "+ Add your own LoRA file")) {
                    loraNote = nil
                    if let url = Panels.chooseLoRAFile() { loraFile = LoRAFileChoice(url: url) }
                }
                .buttonStyle(.link).font(.caption)
                if let loraNote { Text(loraNote).font(.caption).foregroundStyle(.green).textSelection(.enabled) }
            }
            .padding(.top, 4)
        }
        .sheet(item: $loraFile) { choice in
            LoRAAddSheet(url: choice.url, preferBase: LoRAModel.family) { loraAdded($0) }.environmentObject(state)
        }
    }

    /// Nach dem Hinzufügen: passt die LoRA zum gewählten Modell (FLUX.2 Klein), ist sie gleich angehakt.
    private func loraAdded(_ r: LoRAUploads.Result) {
        let m = r.model
        let fits = isFlux && m.base == LoRAModel.family
        if fits && loraChoices[m.id] == nil { loraChoices[m.id] = m.strength }
        let trigger = m.trigger.isEmpty ? "" : t(" Trigger-Wörter: \(m.trigger)", " Trigger words: \(m.trigger)")
        loraNote = (r.existing ? t("Diese Datei war schon da („\(m.name)“), ihre Angaben sind aktualisiert. ",
                                   "This file was already there (“\(m.name)”); its details were updated. ") : "")
            + (fits ? (r.existing ? t("„\(m.name)“ ist angehakt.", "“\(m.name)” is ticked.")
                                  : t("„\(m.name)“ ist hinzugefügt und angehakt.", "“\(m.name)” was added and ticked.")) + trigger
                    : (r.existing ? "" : t("„\(m.name)“ ist hinzugefügt. ", "“\(m.name)” was added. "))
                        + t("Sie gehört zu \(m.baseLabel) und erscheint bei den Modellen dafür.",
                            "It belongs to \(m.baseLabel) and shows up with the models for it."))
            + (r.warning.isEmpty ? "" : " " + r.warning)
    }

    // MARK: Musik und Klänge

    @ViewBuilder
    private var audioForm: some View {
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
        // nur Musik und Klänge (seit 0.5.9): Die Sätze der Sprecherstimme stehen unter „Sprache“ und standen hier mit dazwischen
        let sounds = state.audios.filter { $0.meta["speech"]?.boolValue != true }
        if !sounds.isEmpty {
            Text(t("Zuletzt erzeugt", "Recently generated")).font(.subheadline.bold()).padding(.top, 6)
            ForEach(sounds.prefix(20)) { asset in AudioRow(asset: asset) }
        }
    }

    // MARK: Video

    private var videoSizes: [(label: String, w: Int, h: Int)] {
        videoSpec.sizes.map { ($0["label"] as? String ?? "", $0["w"] as? Int ?? 768, $0["h"] as? Int ?? 512) }
    }

    private var videoSize: (label: String, w: Int, h: Int) { videoSizes[min(videoSizeIndex, videoSizes.count - 1)] }

    private var videoModel: VideoCatalog.Choice {
        VideoCatalog.choices.first { $0.id == videoModelID } ?? VideoCatalog.choices[0]
    }

    /// Das gewählte Videomodell (2B oder 13B) mit seinen Dateien und Grenzen.
    private var videoSpec: VideoModel { VideoCatalog.model(videoModel.id) ?? .ltxv2B }

    /// Bild-Encoder des gewählten Modells geladen (fürs Startbild).
    private var videoEncoderReady: Bool { state.videoInstalledIDs.contains(videoSpec.id) && videoSpec.encoderInstalled }

    /// Startbild wählbar: nicht, wenn das Modell keines kann; ungeprüft (nil) bleibt es wählbar mit Hinweis; LTX-Video
    /// 2B braucht dafür seinen Bild-Encoder.
    private var startImageUsable: Bool {
        switch videoModel.startImage {
        case false?: return false
        case true?: return videoEncoderReady
        case nil: return true
        }
    }

    /// Die Wege, die das gewählte Modell kann (Bildschirm B: nur Passendes ist sichtbar). LTX-Video auf dem Mac macht Text
    /// oder Startbild zu Video; Endbild, Schleife, Layout-Video und Verlängern gibt es nur unter Windows mit LTX-2.5.
    private var videoWays: [String] { videoModel.startImage == false ? ["text"] : ["text", "start"] }

    private var videoDownload: JobRecord? {
        state.jobs.first { $0.downloadModelID == videoSpec.id && !$0.isFinished }
    }

    @ViewBuilder
    private var videoStartBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if videoModel.startImage == true && state.videoInstalled && !videoEncoderReady {
                SceneNote(text: t("Das Startbild braucht den Bild-Encoder von LTX-Video: 1,4 GB Download, danach 0,46 GB auf der Platte.",
                                  "A start image needs LTX-Video's image encoder: 1.4 GB download, then 0.46 GB on disk.")) {
                    if let videoDownload {
                        ProgressView(value: videoDownload.progress).tint(.green)
                        Text(videoDownload.stage).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(t("Startbild nachrüsten", "Add start image")) {
                            Task {
                                _ = await JobQueue.shared.submitVideoDownload(videoSpec.id)
                                await state.refresh()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            strip(single($videoStartID))
                .disabled(!startImageUsable)
                .opacity(startImageUsable ? 1 : 0.4)
            if videoModel.startImage == nil {
                Text(t("Ob das gewählte Videomodell ein Startbild nutzt, ist ungeprüft.",
                       "It has not been checked whether the selected video model uses a start image."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if videoStartID != nil && startImageUsable {
                Text(t("Das Bild wird mittig auf \(videoSize.w) × \(videoSize.h) zugeschnitten und ist das erste Bild des Videos.",
                       "The image is center-cropped to \(videoSize.w) × \(videoSize.h) and becomes the first frame."))
                    .font(.caption).foregroundStyle(.secondary)
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

    /// Längen, die bei diesem Format und Modell auf diesen Mac passen (`VideoModel.maxVoxels`).
    private var videoFrameChoices: [Int] {
        VideoCatalog.frameChoices.filter { videoSize.w * videoSize.h * $0 <= videoSpec.maxVoxels }
    }

    @ViewBuilder
    private var videoForm: some View {
        if VideoCatalog.choices.count > 1 {
            Picker(t("Modell", "Model"), selection: $videoModelID) {
                ForEach(VideoCatalog.choices) { Text($0.name).tag($0.id) }
            }
        }
        // Weg statt Klappen (Bildschirm B): die Felder folgen dem Weg
        VStack(alignment: .leading, spacing: 6) {
            FlowLabel(text: t("Weg", "Path"))
            Picker(t("Weg", "Path"), selection: Binding(get: { videoWays.contains(videoWay) ? videoWay : "text" }, set: { videoWay = $0 })) {
                ForEach(videoWays, id: \.self) { w in
                    Text(w == "start" ? t("Mit Startbild", "With start image") : t("Nur Text", "Text only")).tag(w)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if videoWay == "start" && videoWays.contains("start") {
                videoStartBox
            } else {
                Text(t("Kein Bild nötig.", "No image needed.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(videoWay == "start"
                 ? t("Im Prompt nur die Bewegung beschreiben; das Format folgt dem Startbild.",
                     "Describe only the motion in the prompt; the format follows the start image.")
                 : t("Reines Text-zu-Video.", "Pure text to video."))
                .font(.caption)
                .padding(.leading, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Color.green.opacity(0.6)).frame(width: 3) }
                .help(videoWay == "start"
                      ? t("Mit Startbild wird daraus Bild-zu-Video. Das Format wird beim Wählen des Startbilds auf das nächste passende Seitenverhältnis gestellt; danach gilt, was du einstellst.",
                          "With a start image this becomes image-to-video. Choosing a start image sets the format to the closest matching aspect ratio; after that, what you set applies.")
                      : "")
        }
        Text(t("Beschreibung (auf Englisch)", "Description")).font(.subheadline.bold())
        TextEditor(text: $videoPrompt)
            .font(.body)
            .frame(minHeight: 110)
            .focused($promptFocused)
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
               + "ausdrücklich beschreiben. Schrift im Bild gelingt LTX-Video nicht. 24 Bilder je Sekunde; Ton nur mit "
               + "LTX-2.3 und LTX-2.5.",
               "One paragraph in the present tense: shot, setting and light, the action with verbs, then the camera. "
               + "Describe motion explicitly. LTX-Video cannot render lettering. 24 frames per second; sound only with "
               + "LTX-2.3 and LTX-2.5."))
            .font(.caption).foregroundStyle(.secondary)
            .onChange(of: videoSizeIndex) { _, _ in
                if !videoFrameChoices.contains(videoFrames) { videoFrames = videoFrameChoices.last ?? 49 }
            }
            .onChange(of: videoModelID) { old, _ in
                // Anderes Modell, andere Formate und Grenzen (seit 0.5.9): dasselbe Format, sonst das mit dem nächsten
                // Seitenverhältnis, dann die Länge in die neuen Grenzen. Vorher meinte derselbe Index ein anderes Format
                // (2B 512 × 320, LTX-2 576 × 1024), und eine zu große Länge ließ die Auswahl leer.
                let before = (VideoCatalog.model(old) ?? .ltxv2B).sizes.map { ($0["w"] as? Int ?? 0, $0["h"] as? Int ?? 0) }
                if before.indices.contains(videoSizeIndex) {
                    let was = before[videoSizeIndex]
                    if let same = videoSizes.firstIndex(where: { $0.w == was.0 && $0.h == was.1 }) {
                        videoSizeIndex = same
                    } else {
                        let ratio = Double(was.0) / Double(max(1, was.1))
                        func distance(_ i: Int) -> Double { abs(log(Double(videoSizes[i].w) / Double(max(1, videoSizes[i].h)) / ratio)) }
                        videoSizeIndex = videoSizes.indices.min { distance($0) < distance($1) } ?? 0
                    }
                } else {
                    videoSizeIndex = 0
                }
                if !videoFrameChoices.contains(videoFrames) { videoFrames = videoFrameChoices.last ?? 49 }
            }
        if !state.videos.isEmpty {
            Text(t("Zuletzt erzeugt", "Recently generated")).font(.subheadline.bold()).padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(state.videos.prefix(12)) { asset in VideoRow(asset: asset) }
            }
        }
    }

    // MARK: Foto restaurieren

    /// Schäden entfernen (automatisch, gründlich oder schonend) und einfärben mit FLUX.2 Klein. Gemessen auf einem
    /// Mac mini M1 mit 8 GB: Entfernen ~120 s, Einfärben ~105 s je Variante, beim ersten Mal ~50 s Laden dazu
    /// (Livetest 25.10.2026); schonend setzt danach in rund 1 s ein. Die Zeit steht seit Mac 1.0 am Knopf.
    @ViewBuilder
    private var restoreForm: some View {
        Text(t("Altes Foto", "Old photo")).font(.subheadline.bold())
        strip(single($photoID), allowNone: false)
        if let size = pixelSize(photoID) {
            Text(t("\(size.width) × \(size.height) px; das Ergebnis wird am Foto ausgerichtet und behält dessen Format.",
                   "\(size.width) × \(size.height) px; the result is aligned with the photo and keeps its size."))
                .font(.caption).foregroundStyle(.secondary)
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
                if repairMode == "auto" && !HelperModel.vision.installed, let vision = flowModel(HelperModel.vision.id) {
                    ModelNeedView(model: vision, why: t("für „Automatisch“", "for \"Automatic\""), compact: true)
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
        if sharpenOn && !seedvr2, let model = flowModel(HelperModel.sharpen.id) {
            ModelNeedView(model: model, why: t("zum Schärfen", "for sharpening"), compact: true).padding(.leading, 20)
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

    // MARK: Bild erzeugen

    @ViewBuilder
    private var generateForm: some View {
        modelPicker

        Text(t("Prompt", "Prompt")).font(.subheadline.bold())
        TextEditor(text: $prompt)
            .font(.body)
            .frame(minHeight: 110)
            .focused($promptFocused)
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
            .border(.quaternary)
        Text(hint).font(.caption).foregroundStyle(.secondary)
        ExpandPromptRow(text: $prompt, target: .image, message: $message)
        if isFlux { loraSection }

        if takesImages {
        DisclosureGroup(isExpanded: $startOpen) {
            VStack(alignment: .leading, spacing: 8) {
                strip(single($startID))
                if let size = pixelSize(startID) {
                    let target = fixedSize.map { (label: "", w: $0, h: $0) } ?? sizes[min(sizeIndex, sizes.count - 1)]
                    let off = abs((Double(size.width) / Double(size.height)) / (Double(target.w) / Double(target.h)) - 1) > 0.02
                    // seit 0.5.8 mittig zugeschnitten statt gestreckt (ImageFiles.filled), wie unter Windows
                    Text("\(size.width) × \(size.height) px" + (off && !outpaintOn && maskID == nil && isFlux
                        ? " · " + t("wird mittig auf \(target.w) × \(target.h) zugeschnitten", "cropped to \(target.w) × \(target.h) around the center")
                        : ""))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                    if maskID == nil, maxReferences > 0 {
                        // Gesichtstausch (Nutzer 18.11.): Als Ausgangsbild bleibt die Bildaufteilung des Fotos; eine Person in
                        // einer neuen Szene geht nur über die Referenz (gemessen am Mac mini, notizen/mac.md)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(t("Gesicht in eine neue Szene setzen? Das geht über „Referenzbilder“; als Ausgangsbild bleibt die Bildaufteilung des Fotos.",
                                   "Put a face into a new scene? That works through \"Reference images\"; as a start image the photo keeps its layout."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(t("Als Referenz für Gesichtstausch", "Use as reference for a face swap")) {
                                if let id = startID {
                                    referenceIDs.removeAll { $0 == id }
                                    referenceIDs.insert(id, at: 0)
                                    if referenceIDs.count > maxReferences { referenceIDs.removeLast(referenceIDs.count - maxReferences) }
                                }
                                startID = nil
                            }
                            .controlSize(.small)
                        }
                    }
                    if !isCoreML {
                        Text(t("Maske (optional, weiß = neu)", "Mask (optional, white = new)")).font(.caption.bold())
                        strip(single($maskID))
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text(startID == nil ? t("Vorhandenes Bild überarbeiten oder erweitern", "Edit or extend an existing image")
                 : outpaintOn ? t("Bild erweitern", "Extend image") : t("Vorhandenes Bild überarbeiten", "Edit an existing image"))
                .font(.subheadline.bold())
        }
        }

        if maxReferences > 0 {
            DisclosureGroup(isExpanded: $refsOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    strip($referenceIDs, limit: maxReferences, allowNone: false)
                    Text(t("Im Prompt als „the first image“, „the second image“ ansprechen, in der Reihenfolge der Nummern. "
                           + "Mit einem Bild wird bearbeitet: sagen, was sich ändert und was gleich bleibt.",
                           "Refer to them in the prompt as \"the first image\", \"the second image\", in the order of the "
                           + "numbers. With one image you edit it: say what changes and what stays the same."))
                        .font(.caption).foregroundStyle(.secondary)
                    // Gesichtstausch (gemessen 18.11., notizen/mac.md): Ohne Geschlecht wurde aus einer Frau ein Mann; „keep …
                    // exactly as in the first image“ übernahm Pulli und Selfie-Ausschnitt des Fotos
                    Text(t("Gesichtstausch: sagen, wer es ist (Frau oder Mann, Alter, Haare), und die neue Szene beschreiben, z. B. "
                           + "„The woman from the first image, in her forties with curly red hair, now a pirate on the deck of a ship“. "
                           + "Mit „keep … exactly as in the first image“ bleiben Kleidung und Ausschnitt des Fotos.",
                           "Face swap: say who it is (woman or man, age, hair) and describe the new scene, e.g. "
                           + "\"The woman from the first image, in her forties with curly red hair, now a pirate on the deck of a ship\". "
                           + "With \"keep … exactly as in the first image\" the photo's clothes and framing stay."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(referenceIDs.isEmpty
                     ? t("Referenzbilder (bis \(maxReferences))", "Reference images (up to \(maxReferences))")
                     : t("Referenzbilder – \(referenceIDs.count) gewählt", "Reference images – \(referenceIDs.count) chosen"))
                    .font(.subheadline.bold())
            }
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
        if let source = pixelSize(startID) {
            let e = Outpaint.Edges(left: edges[0], top: edges[1], right: edges[2], bottom: edges[3])
            let size = Outpaint.size(width: source.width, height: source.height, e)
            Text(verbatim: "\(source.width) × \(source.height) → \(size.width) × \(size.height)").font(.callout.monospacedDigit())
        }
        Text(t("Das Bild bleibt, nur der neue Rand wird gemalt; das Format ergibt sich aus Bild und Rand. "
               + "Der Prompt beschreibt das ganze erweiterte Bild.",
               "The image stays; only the new border is painted, the size follows from image and border. "
               + "The prompt describes the whole extended picture."))
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Feineinstellung

    /// Schritte, Seed, CFG und Negativprompt unter einer Klappe; die Zeile sagt, was davon gesetzt ist
    @ViewBuilder
    private var fineSettings: some View {
        let seed = formMode == .speech ? speechSeed : seedText
        let defaultSteps = activeModel?.features["steps"] as? Int ?? 4
        let set = [formMode == .generate && steps != defaultSteps ? t("\(steps) Schritte", "\(steps) steps") : "",
                   seed.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "Seed \(seed)",
                   formMode == .generate && isCoreML && !negative.isEmpty ? t("Negativprompt", "negative prompt") : ""]
            .filter { !$0.isEmpty }
        DisclosureGroup(isExpanded: $fineOpen) {
            VStack(alignment: .leading, spacing: 8) {
                if formMode == .generate {
                    Stepper(t("Schritte: \(steps)", "Steps: \(steps)"), value: $steps, in: 1...60)
                    if isCoreML {
                        Text(t("Negativer Prompt", "Negative prompt")).font(.caption.bold())
                        TextField("blurry, low quality, watermark, text", text: $negative)
                        HStack {
                            Text("CFG \(guidance, specifier: "%.1f")")
                            Slider(value: $guidance, in: 1...12)
                        }
                    }
                }
                HStack {
                    Text("Seed")
                    if formMode == .speech {
                        TextField(t("zufällig", "random"), text: $speechSeed).frame(width: 160)
                    } else {
                        TextField(t("zufällig", "random"), text: $seedText).frame(width: 160)
                    }
                }
                if formMode == .video {
                    Text(t("LTX-Video rechnet fest mit 8 Schritten und 24 Bildern je Sekunde.", "LTX-Video always uses 8 steps and 24 frames per second."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            (Text(t("Feineinstellung", "Advanced settings")).font(.subheadline.bold())
             + Text(set.isEmpty ? "" : " · " + set.joined(separator: ", ")).font(.caption).foregroundColor(.secondary))
        }
    }

    // MARK: Knopf unten (Bildschirm B)

    private var modeKey: String {
        switch formMode {
        case .generate: return "image"
        case .restore: return "restore"
        case .audio: return "audio"
        case .speech: return "speech"
        case .video: return "video"
        }
    }

    /// Was der große Knopf tut, in Worten (Konzept: „Ein Knopf nennt Aktion und Zeit“)
    private var actionLabel: String {
        switch formMode {
        case .generate:
            if extending { return t("Bild erweitern", "Extend image") }
            if takesImages && startID != nil && !outpaintOn { return t("Bild überarbeiten", "Rework image") }
            return batch > 1 ? t("\(batch) Bilder erzeugen", "Create \(batch) images") : t("Bild erzeugen", "Create image")
        case .video: return t("Video erzeugen", "Create video")
        case .audio: return t("Ton erzeugen", "Create sound")
        case .speech: return t("Text sprechen", "Speak the text")
        case .restore: return t("Foto restaurieren", "Restore photo")
        }
    }

    /// „das nächste Bild“ für den Hinweis unter den Phasen
    private var nextWord: String {
        switch formMode {
        case .generate: return t("das nächste Bild", "the next image")
        case .video: return t("das nächste Video", "the next video")
        case .audio: return t("der nächste Ton", "the next sound")
        case .speech: return t("der nächste Satz", "the next line")
        case .restore: return t("das nächste Foto", "the next photo")
        }
    }

    /// Das Modell, mit dem der Knopf rechnet (für Chip, „Modell lädt“ und „fehlt“)
    private var mainModelID: String? {
        switch formMode {
        case .generate: return state.activeModelID
        case .video: return state.videoInstalled ? videoSpec.id : VideoCatalog.recommended.id
        case .audio: return AudioCatalog.id
        case .speech: return SpeechCatalog.id
        case .restore: return repairOn || colorizeOn ? (Models.expansionModel?.id ?? ModelCatalog.recommended.id) : HelperModel.sharpen.id
        }
    }

    /// Fehlt das Modell des Knopfs? Dann steht es mit Größe und Lizenz über dem Knopf (geladen wird erst nach dem Klick)
    private var need: FlowModel? {
        switch formMode {
        case .generate:
            guard let m = activeModel, !m.installed else { return nil }
            return flowModel(m.id)
        case .video: return state.videoInstalled ? nil : flowModel(VideoCatalog.recommended.id)
        case .audio: return state.audioInstalled ? nil : flowModel(AudioCatalog.id)
        case .speech: return state.speechInstalled ? nil : flowModel(SpeechCatalog.id)
        case .restore:
            if (repairOn || colorizeOn) && Models.expansionModel == nil { return flowModel(ModelCatalog.recommended.id) }
            return nil
        }
    }

    /// Warum der Knopf (noch) nicht geht; leer = er geht
    private var blocked: String {
        switch formMode {
        case .generate:
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !extending
                ? t("Erst einen Prompt schreiben", "Write a prompt first") : ""
        case .video:
            if videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t("Erst einen Prompt schreiben", "Write a prompt first") }
            if videoWay == "start" && (videoStartID == nil || !startImageUsable) { return t("Erst ein Startbild wählen", "Choose a start image first") }
            return ""
        case .audio:
            return audioPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t("Erst den Klang beschreiben", "Describe the sound first") : ""
        case .speech:
            if speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t("Erst den Text schreiben", "Write the text first") }
            return speechFromRecording && speechRecordingID == nil ? t("Erst eine Aufnahme wählen", "Choose a recording first") : ""
        case .restore:
            if photoID == nil { return t("Erst ein Foto wählen", "Choose a photo first") }
            if !(repairOn || colorizeOn || sharpenOn) { return t("Mindestens einen Schritt wählen", "Choose at least one step") }
            if sharpenOn && !HelperModel.sharpen.installed { return t("Erst SeedVR2 laden (oben)", "Download SeedVR2 first (above)") }
            return ""
        }
    }

    private var currentJob: JobRecord? { state.generateJobID.flatMap { id in state.jobs.first { $0.id == id } } }

    /// Der eigene Auftrag läuft noch (dann zeigt der Knopf die Restzeit)
    private var busyJob: JobRecord? { currentJob.flatMap { FlowJobs.isActive($0) ? $0 : nil } }

    /// Chip mit Zustand: „FLUX.2 Klein 4B · bereit“, „· lädt 42 %“, „· fehlt“
    private func modelChip(_ id: String?) -> some View {
        let m = flowModel(id)
        let dl = id.flatMap { mid in state.jobs.first { $0.downloadModelID == mid && !$0.isFinished } }
        let text: String
        let tone: FlowTone
        if let dl {
            text = (m?.short ?? "") + " · " + (dl.status == "queued" ? t("wartet auf den Download", "waiting to download")
                                               : t("lädt \(Int((dl.progress * 100).rounded())) %", "downloading \(Int((dl.progress * 100).rounded())) %"))
            tone = .info
        } else if let m, !m.installed {
            text = m.short + " · " + t("fehlt", "missing")
            tone = .warn
        } else {
            text = (m?.short ?? "") + " · " + t("bereit", "ready")
            tone = .ok
        }
        return FlowChip(text: text, tone: tone).help(m?.name ?? "")
    }

    /// Chip mit Auswahl („768 × 512 ▾“): sichtbar der kurze Text, die Liste zeigt die vollen Namen
    private func chipMenu<Content: View>(_ text: String, help: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        // Das Menü zeichnet seine Beschriftung selbst (nur Text): den Rand des Chips deshalb außen herum
        Menu { content() } label: { Text(text + " ▾") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.45)))
            .help(help)
    }

    @ViewBuilder
    private var chipRow: some View {
        FlowWrap(spacing: 6) {
            switch formMode {
            case .restore:
                if repairOn || colorizeOn { modelChip(Models.expansionModel?.id ?? ModelCatalog.recommended.id) }
                if sharpenOn { modelChip(HelperModel.sharpen.id) }
                if repairOn || colorizeOn {
                    chipMenu(batch == 1 ? t("1 Variante", "1 variant") : t("\(min(4, batch)) Varianten", "\(min(4, batch)) variants")) {
                        ForEach(1...4, id: \.self) { n in Button(n == 1 ? t("1 Variante", "1 variant") : t("\(n) Varianten", "\(n) variants")) { batch = n } }
                    }
                }
            case .generate:
                modelChip(state.activeModelID)
                if extending, let source = pixelSize(startID) {
                    let size = Outpaint.size(width: source.width, height: source.height,
                                             Outpaint.Edges(left: edges[0], top: edges[1], right: edges[2], bottom: edges[3]))
                    FlowChip(text: "\(size.width) × \(size.height)").help(t("Beim Erweitern ergibt sich das Format aus Bild und Rand",
                                                                           "When extending, the size follows from image and border"))
                } else if let fixed = fixedSize {
                    FlowChip(text: "\(fixed) × \(fixed)").help(t("fest bei diesem Modell", "fixed for this model"))
                } else {
                    let s = sizes[min(sizeIndex, sizes.count - 1)]
                    chipMenu("\(s.w) × \(s.h)", help: t("Stehende Figuren im Hochformat — im Quadrat fehlen ihnen oft die Beine.",
                                                       "Standing figures in portrait format — in a square they often lose their legs.")) {
                        ForEach(sizes.indices, id: \.self) { i in Button(sizes[i].label) { sizeIndex = i } }
                    }
                }
                chipMenu(batch == 1 ? t("1 Bild", "1 image") : t("\(batch) Bilder", "\(batch) images")) {
                    ForEach(1...4, id: \.self) { n in Button(n == 1 ? t("1 Bild", "1 image") : t("\(n) Bilder", "\(n) images")) { batch = n } }
                }
            case .audio:
                modelChip(AudioCatalog.id)
                FlowChip(text: "\(Int(audioSeconds)) s")
            case .speech:
                modelChip(SpeechCatalog.id)
            case .video:
                modelChip(mainModelID)
                chipMenu("\(videoSize.w) × \(videoSize.h)") {
                    ForEach(videoSizes.indices, id: \.self) { i in Button(videoSizes[i].label) { videoSizeIndex = i } }
                }
                chipMenu(String(format: t("%.0f s", "%.0f s"), Double(videoFrames - 1) / Double(VideoCatalog.fps))) {
                    ForEach(videoFrameChoices, id: \.self) { f in
                        Button(String(format: t("%.0f s (%d Bilder)", "%.0f s (%d frames)"), Double(f - 1) / Double(VideoCatalog.fps), f)) { videoFrames = f }
                    }
                }
            }
        }
    }

    /// Klebt unten an der linken Spalte: Chips, fehlendes Modell, großer Knopf mit Aktion und Zeit
    private var submitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow
            if let need {
                let alt: FlowModel? = formMode == .generate
                    ? state.flowModels.first { $0.kind == "image" && $0.installed && $0.recommended } ?? state.flowModels.first { $0.kind == "image" && $0.installed }
                    : nil
                ModelNeedView(model: need, why: needWhy, alternative: alt, onUseAlternative: alt.map { a in { state.setActiveModel(a.id) } })
            }
            EverySecond(on: busyJob != nil) { now in
                let left = busyJob.map { FlowFormat.left(flow.remaining($0, expected: run?.job == $0.id ? run?.expected : nil, now: now)) }
                FlowBigButton(label: busyJob != nil ? t("Läuft …", "Running …") : actionLabel,
                              eta: left ?? FlowFormat.eta(mainEstimate?.total),
                              disabled: busyJob != nil || need != nil || !blocked.isEmpty || submitting,
                              help: [blocked, FlowFormat.source(mainEstimate), "⌘↩"].filter { !$0.isEmpty }.joined(separator: " · ")) {
                    Task { await submitCurrent() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            if !blocked.isEmpty && need == nil && busyJob == nil {
                Text(blocked).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
    }

    private var needWhy: String {
        switch formMode {
        case .generate: return t("für Bilder", "for images")
        case .video: return t("für Video", "for video")
        case .audio: return t("für Musik und Geräusche", "for music and sound effects")
        case .speech: return t("für die Sprecherstimme", "for the narrator voice")
        case .restore: return t("zum Restaurieren", "for restoring")
        }
    }

    // MARK: Aufträge

    /// Der Auftrag, den der große Knopf abschickt: Art und genau seine Angaben (dieselben gehen in die Schätzung)
    private func plan() -> (kind: String, body: [String: JSONValue])? {
        switch formMode {
        case .generate: return imageBody().map { ("txt2img", $0) }
        case .video: return ("txt2video", videoBody())
        case .audio: return ("txt2audio", audioBody())
        case .speech: return speechBody().map { ("tts", $0) }
        case .restore: return restoreBody().map { ("restore", $0) }
        }
    }

    /// Neu schätzen, wenn sich Art, Modell, Format, Länge, Weg oder Schalter ändern; Texte nicht (Stimme: die Länge)
    private var estimateKey: String {
        guard let p = plan() else { return "none|\(modeKey)" }
        var body = p.body
        for key in ["prompt", "negative_prompt", "voice", "voice_text", "notes"] { body[key] = nil }
        if let text = body["text"]?.stringValue { body["text"] = .int(text.count / 20) }
        return p.kind + "|" + (String(data: JSON.data(JSONValue.object(body).any), encoding: .utf8) ?? "")
            + "|\(state.flowModels.count)|\(state.jobs.filter { $0.isFinished }.count)"
    }

    private func imageBody() -> [String: JSONValue]? {
        let size = fixedSize.map { (label: "", w: $0, h: $0) } ?? sizes[min(sizeIndex, sizes.count - 1)]
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ausgangsbild nur, wenn das Modell es nimmt; Erweitern nur mit Ausgangsbild (seit 0.5.9: Mit Z-Image war über
        // Vorschau oder Kontextmenü eins gewählt, die Box aber ausgeblendet, und jeder Auftrag scheiterte; ein Schalter
        // „Erweitern“, der nach dem Abwählen des Ausgangsbilds an blieb, verwarf still die Referenzbilder)
        let start = takesImages ? startID : nil
        let extending = start != nil && outpaintOn && !isCoreML && edges.contains { $0 > 0 }
        guard !text.isEmpty || extending else { return nil }
        var body: [String: JSONValue] = [
            // Nur erweitern ohne eigenen Text: der Ersatz-Prompt beschreibt die fortgesetzte Szene
            "prompt": .string(text.isEmpty && extending ? Self.extendPrompt : text),
            "width": .int(size.w), "height": .int(size.h),
            "steps": .int(steps), "batch_size": .int(batch),
            "model_id": .string(state.activeModelID),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        if isCoreML {
            body["negative_prompt"] = .string(negative)
            body["cfg"] = .double(guidance)
        }
        if let start, extending {
            body["image_asset_id"] = .string(start)
            body["outpaint"] = .array(edges.map { .int(max(0, min(Outpaint.maxEdge, $0))) })
        } else if let start {
            body["image_asset_id"] = .string(start)
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
        return body
    }

    private func videoBody() -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "prompt": .string(videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "width": .int(videoSize.w), "height": .int(videoSize.h), "frames": .int(videoFrames),
            "fps": .int(VideoCatalog.fps), "model_id": .string(videoModel.id),
        ]
        if videoWay == "start", let start = videoStartID, startImageUsable { body["image_asset_id"] = .string(start) }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        return body
    }

    private func audioBody() -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "prompt": .string(audioPrompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "seconds": .double(audioSeconds), "model_id": .string(AudioCatalog.id),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        return body
    }

    private func speechBody() -> [String: JSONValue]? {
        let text = speechText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var body: [String: JSONValue] = ["text": .string(text), "language": .string(speechLanguage), "model_id": .string(SpeechCatalog.id)]
        if speechFromRecording, let id = speechRecordingID {
            body["voice_asset_id"] = .string(id)
            body["voice_text"] = .string(speechVoiceText)
        } else {
            body["voice"] = .string(speechVoice)
        }
        if let seed = Int(speechSeed.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        return body
    }

    private func restoreBody() -> [String: JSONValue]? {
        guard let photoID else { return nil }
        var body: [String: JSONValue] = [
            "image_asset_id": .string(photoID),
            "repair": .bool(repairOn), "repair_mode": .string(repairMode), "colorize": .bool(colorizeOn),
            "sharpen": .bool(sharpenOn), "scale": .int(sharpenScale),
            "notes": .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)), "batch_size": .int(batch),
        ]
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        return body
    }

    /// Einen Auftrag nach Art abschicken (großer Knopf und nächste Schritte), mit denselben Prüfungen wie die API
    private func send(_ kind: String, _ body: [String: JSONValue]) async throws -> JobRecord {
        switch kind {
        case "txt2video": return await JobQueue.shared.submitVideo(try VideoJobRequest.parse(.object(body)))
        case "txt2audio": return await JobQueue.shared.submitAudio(try AudioJobRequest.parse(.object(body)))
        case "tts": return await JobQueue.shared.submitSpeech(try SpeechJobRequest.parse(.object(body)))
        case "restore": return await JobQueue.shared.submitRestore(try RestoreJobRequest.parse(.object(body)))
        default: return await JobQueue.shared.submit(try ImageJobRequest.parse(.object(body)))
        }
    }

    private func submitCurrent() async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        message = nil
        pruneSelection()
        guard let p = plan() else { return }
        await launch(p.kind, p.body, title: actionLabel, modelID: mainModelID, estimate: mainEstimate, next: nextWord)
    }

    /// Abschicken und rechts mit Phasen zeigen
    private func launch(_ kind: String, _ body: [String: JSONValue], title: String, modelID: String?, estimate: JobEstimate?,
                        next: String) async {
        do {
            let job = try await send(kind, body)
            FlowJobs.shared.note(job.id, estimate)
            let m = flowModel(modelID)
            run = RunInfo(job: job.id, title: title, model: m.map { "\($0.short), \(FlowFormat.gb($0.sizeGB))" },
                          expected: estimate?.seconds, next: next)
            state.generateJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
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
        Task {
            // Liegt es als Clip im Schnitt eines Projekts, bleibt es (und bleibt gewählt), seit 0.5.9
            if let notice = await AssetDeletion.deleteWithNotice(id) {
                message = notice
                return
            }
            if startID == id { startID = nil }
            if maskID == id { maskID = nil }
            if photoID == id { photoID = nil }
            if videoStartID == id { videoStartID = nil }
            referenceIDs.removeAll { $0 == id }
            await state.refresh()
        }
    }

    /// Gelöschte Bilder abwählen (seit 0.5.9): Im Verlauf oder Studio gelöscht, blieb die ID gewählt, die Überschrift
    /// sagte „1 gewählt“, und der Auftrag scheiterte mit „nicht gefunden“.
    private func pruneSelection() {
        func exists(_ id: String) -> Bool { AssetSnapshot.shared.get(id) != nil }
        if let id = startID, !exists(id) { startID = nil }
        if let id = maskID, !exists(id) { maskID = nil }
        if let id = photoID, !exists(id) { photoID = nil }
        if let id = videoStartID, !exists(id) { videoStartID = nil }
        referenceIDs.removeAll { !exists($0) }
    }

    // MARK: Ergebnisse (Bildschirm C)

    private var jobAssets: [AssetRecord] {
        guard let job = currentJob else { return [] }
        let ids = Set(job.assetIDs)
        return (state.images + state.audios + state.videos).filter { $0.jobID == job.id || ids.contains($0.id) }
    }

    /// Mit welchem Ergebnis es weitergeht (mehrere Bilder: „weiter damit“), Vorgabe das erste
    private var picked: AssetRecord? {
        let list = jobAssets
        return list.first { $0.id == pickedID } ?? list.first
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = busyJob {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        FlowLabel(text: run?.job == job.id ? run!.title : t("Auftrag", "Job"))
                        Spacer()
                        Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
                            .controlSize(.small)
                    }
                    JobPhasesView(job: job, modelName: run?.job == job.id ? run?.model : nil,
                                  expected: run?.job == job.id ? run?.expected : nil,
                                  next: run?.job == job.id ? run?.next : nil)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if let job = currentJob, job.status == "error", let error = job.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let job = currentJob, job.status == "cancelled" {
                Text(t("Abgebrochen.", "Cancelled.")).foregroundStyle(.secondary)
            }
            let list = jobAssets
            if !list.isEmpty, let job = currentJob {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        resultHead(job, list)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(list.filter { $0.kind == "audio" }) { asset in AudioRow(asset: asset) }
                            ForEach(list.filter { $0.kind == "video" }) { asset in VideoRow(asset: asset) }
                            ForEach(list.filter { $0.kind == "image" || $0.kind == "upload" }) { asset in imageCard(asset, many: list.count > 1) }
                        }
                        if !FlowJobs.isActive(job) { nextSteps }
                    }
                }
            } else if currentJob == nil {
                Spacer()
                Text(t("Ergebnisse erscheinen hier.", "Results appear here.")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    /// Kopf über dem Ergebnis: „Fertig nach 3:38“, Modell · Größe, Seed genau zum Kopieren (Konzept, Bildschirm C)
    private func resultHead(_ job: JobRecord, _ list: [AssetRecord]) -> some View {
        let first = picked ?? list[0]
        let took = job.finishedAt.map { $0 - job.createdAt }
        let modelName = flowModel(first.modelID)?.short ?? (first.meta["model_name"]?.stringValue ?? first.modelID)
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let w = first.meta["width"]?.intValue, h = first.meta["height"]?.intValue
        let size = w != nil && h != nil ? "\(w!) × \(h!)"
            : first.meta["seconds"]?.doubleValue.map { formatDecimal($0, digits: 1) + " s" } ?? ""
        let seeds = Array(Set(list.compactMap { $0.meta["seed"]?.intValue }))
        return VStack(alignment: .leading, spacing: 4) {
            Text(took.map { t("Fertig nach \(FlowFormat.clock($0))", "Done after \(FlowFormat.clock($0))") } ?? t("Fertig", "Done"))
                .font(.headline)
            Text([modelName, size, list.count > 1 ? t("\(list.count) Ergebnisse", "\(list.count) results") : ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if seeds.count == 1 { SeedCopyView(seed: String(seeds[0])) }
        }
    }

    private func imageCard(_ asset: AssetRecord, many: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AssetThumbnail(asset: asset, maxSide: 720)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
                .onTapGesture { preview = asset }
                .help(AssetActions.help(click: t("Klick: große Vorschau", "Click: large preview")))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(many && picked?.id == asset.id ? Color.green : .clear, lineWidth: 2))
            HStack(spacing: 6) {
                Text(details(asset)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Mehrere Bilder: Mit welchem es weitergeht, wählt man hier (Vorgabe das erste)
                if many {
                    Button(picked?.id == asset.id ? t("✓ weiter damit", "✓ continue with this") : t("weiter damit", "continue with this")) {
                        pickedID = asset.id
                        nextNeed = nil
                    }
                    .controlSize(.small)
                }
            }
        }
        .contextMenu {
            Button(t("Große Vorschau", "Large preview")) { preview = asset }
            if takesImages {
                Button(t("Als Ausgangsbild verwenden", "Use as start image")) {
                    formMode = .generate
                    startID = asset.id
                }
            }
            AssetMenuItems(asset: asset)
        }
    }

    private func details(_ asset: AssetRecord) -> String {
        var parts: [String] = []
        if let seed = asset.meta["seed"]?.intValue, Set(jobAssets.compactMap { $0.meta["seed"]?.intValue }).count > 1 { parts.append("Seed \(seed)") }
        if let s = asset.meta["duration_s"]?.doubleValue { parts.append(String(format: "%.1f s", s)) }
        if let mb = asset.meta["peak_memory_mb"]?.intValue { parts.append(t("\(mb) MB Spitze", "\(mb) MB peak")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Nächste Schritte (Bildschirm C: „Jedes Ergebnis führt weiter“)

    private var nextKey: String { "\(currentJob?.id ?? "")|\(currentJob?.status ?? "")|\(picked?.id ?? "")|\(state.flowModels.count)" }

    /// Das Videoformat, in das ein Bild erweitert wird: das gewählte Format unter „Video“
    private var outTarget: (w: Int, h: Int) { (videoSize.w, videoSize.h) }

    /// Rand fürs Erweitern auf ein Seitenverhältnis (links, oben, rechts, unten), auf 8 px gerundet; nil, wenn das Bild
    /// schon passt oder das Ergebnis die Grenzen sprengt (je Seite 1024, zusammen 2048)
    private func padToAspect(_ w: Int, _ h: Int, _ aspect: Double) -> [Int]? {
        guard w > 0, h > 0, abs(log(Double(w) / Double(h) / aspect)) > 0.03 else { return nil }
        var pad: [Int]
        if Double(w) / Double(h) < aspect {
            let add = Int((Double(h) * aspect / 16).rounded()) * 16 - w
            let left = Int((Double(add) / 2 / 8).rounded()) * 8
            pad = [left, 0, max(0, add - left), 0]
        } else {
            let add = Int((Double(w) / aspect / 16).rounded()) * 16 - h
            let top = Int((Double(add) / 2 / 8).rounded()) * 8
            pad = [0, top, 0, max(0, add - top)]
        }
        guard pad.max()! <= Outpaint.maxEdge, w + pad[0] + pad[2] <= 2048, h + pad[1] + pad[3] <= 2048 else { return nil }
        return pad
    }

    private var fluxID: String? { (ModelCatalog.status(ModelCatalog.recommended).installed ? ModelCatalog.recommended : Models.expansionModel)?.id }

    /// Aufträge der nächsten Schritte (Art und Angaben), für Zeit und Abschicken
    private func nextPlans(_ a: AssetRecord, _ job: JobRecord) -> [String: (kind: String, body: [String: JSONValue])] {
        var out: [String: (kind: String, body: [String: JSONValue])] = [:]
        if a.kind == "image", let size = pixelSize(a.id) {
            // Video daraus: Startbild, im Videoformat mit dem nächsten Seitenverhältnis
            let aspect = Double(size.width) / Double(max(1, size.height))
            let fit = videoSizes.min { abs(log(Double($0.w) / Double($0.h) / aspect)) < abs(log(Double($1.w) / Double($1.h) / aspect)) } ?? videoSize
            out["video"] = ("txt2video", ["prompt": .string("x"), "model_id": .string(videoSpec.id), "width": .int(fit.w), "height": .int(fit.h),
                                          "frames": .int(videoFrames), "fps": .int(VideoCatalog.fps), "image_asset_id": .string(a.id)])
            if let pad = padToAspect(size.width, size.height, Double(outTarget.w) / Double(outTarget.h)) {
                out["outpaint"] = ("txt2img", ["prompt": .string(Self.extendPrompt), "model_id": .string(fluxID ?? ModelCatalog.recommended.id),
                                               "width": .int(Int((Double(size.width + pad[0] + pad[2]) / 16).rounded()) * 16),
                                               "height": .int(Int((Double(size.height + pad[1] + pad[3]) / 16).rounded()) * 16),
                                               "steps": .int(4), "batch_size": .int(1), "image_asset_id": .string(a.id),
                                               "outpaint": .array(pad.map { .int($0) })])
            }
        }
        // ⟳ Varianten: derselbe Auftrag noch einmal mit neuem Seed (Bilder und Fotos zu viert, Ton und Stimme einmal)
        var again = job.params.objectValue ?? [:]
        again["seed"] = nil
        switch job.kind {
        case "txt2img", "img2img":
            again["batch_size"] = .int(4)
            out["variants"] = ("txt2img", again)
        case "restore" where (again["repair"]?.boolValue ?? true) || (again["colorize"]?.boolValue ?? false):
            again["batch_size"] = .int(4)
            out["variants"] = ("restore", again)
        case "txt2audio":
            out["variants"] = ("txt2audio", again)
        case "tts":
            out["variants"] = ("tts", again)
        default:
            break
        }
        return out
    }

    private func loadNextEstimates() async {
        guard let job = currentJob, job.status == "done", let a = picked else { return }
        var out: [String: JobEstimate] = [:]
        for (key, p) in nextPlans(a, job) { out[key] = await Estimate.one(kind: p.kind, params: .object(p.body)) }
        nextEstimates = out
    }

    private func eta(_ key: String) -> String { FlowFormat.eta(nextEstimates[key]?.total) }

    private func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: ", ") }

    @ViewBuilder
    private var nextSteps: some View {
        if let job = currentJob, job.status == "done", let a = picked {
            let plans = nextPlans(a, job)
            let speech = a.meta["speech"]?.boolValue == true
            let heading = a.kind == "video" ? t("Weiter mit diesem Video", "Continue with this video")
                : a.kind == "audio" ? (speech ? t("Weiter mit diesem Satz", "Continue with this line") : t("Weiter mit diesem Ton", "Continue with this sound"))
                : t("Weiter mit diesem Bild", "Continue with this image")
            NextStepsView(heading: heading, steps: steps(a, job, plans)) {
                if let need = nextNeed {
                    ModelNeedView(model: need.model, why: need.why, alternative: need.alternative, onUseAlternative: need.useAlternative)
                }
                if let studioNote { Text(studioNote).font(.caption).foregroundStyle(.green) }
            }
        }
    }

    private func steps(_ a: AssetRecord, _ job: JobRecord, _ plans: [String: (kind: String, body: [String: JSONValue])]) -> [FlowNextStep] {
        var out: [FlowNextStep] = []
        let videoName = flowModel(VideoCatalog.recommended.id)?.short ?? "LTX-Video"
        if a.kind == "image" {
            let videoReady = state.videoInstalled
            out.append(FlowNextStep(id: "video", icon: "▶", label: t("Video daraus", "Video from it"),
                                    small: join(t("Startbild", "start image"), (videoReady ? (flowModel(videoSpec.id)?.short ?? videoName) : videoName + t(" fehlt", " missing")),
                                                videoReady ? eta("video") : ""),
                                    primary: true) {
                guard videoReady else {
                    if let m = flowModel(VideoCatalog.recommended.id) { nextNeed = NextNeed(why: t("für ein Video aus diesem Bild", "for a video from this image"), model: m, alternative: nil, useAlternative: nil) }
                    return
                }
                nextNeed = nil
                formMode = .video
                videoWay = "start"
                videoStartID = a.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { promptFocused = true }
            })
            if let plan = plans["outpaint"] {
                let ready = fluxID != nil
                out.append(FlowNextStep(id: "outpaint", icon: "⤢", label: t("Erweitern", "Extend"),
                                        small: join(ready ? (flowModel(fluxID)?.short ?? "FLUX.2 Klein") : "FLUX.2 Klein" + t(" fehlt", " missing"),
                                                    t("ins Videoformat \(outTarget.w) × \(outTarget.h)", "to the video format \(outTarget.w) × \(outTarget.h)"),
                                                    ready ? eta("outpaint") : ""),
                                        disabled: busyJob != nil) {
                    guard ready else {
                        if let m = flowModel(ModelCatalog.recommended.id) { nextNeed = NextNeed(why: t("zum Erweitern ins Videoformat", "to extend to the video format"), model: m, alternative: nil, useAlternative: nil) }
                        return
                    }
                    nextNeed = nil
                    Task { await launch(plan.kind, plan.body, title: t("Bild erweitern", "Extend image"), modelID: fluxID, estimate: nextEstimates["outpaint"], next: t("das nächste Bild", "the next image")) }
                })
            }
        }
        if let plan = plans["variants"] {
            let four = plan.kind == "txt2img" || plan.kind == "restore"
            out.append(FlowNextStep(id: "variants", icon: "⟳", label: four ? t("4 Varianten", "4 variants") : t("Noch eine Variante", "One more variant"),
                                    small: join(plan.kind == "tts" ? t("gleicher Text, neuer Seed", "same text, new seed")
                                                : plan.kind == "restore" ? t("gleiches Foto, neuer Seed", "same photo, new seed")
                                                : t("gleicher Prompt", "same prompt"), eta("variants")),
                                    disabled: busyJob != nil) {
                nextNeed = nil
                Task {
                    await launch(plan.kind, plan.body, title: four ? t("4 Varianten", "4 variants") : t("Noch eine Variante", "One more variant"),
                                 modelID: plan.body["model_id"]?.stringValue ?? job.modelKey, estimate: nextEstimates["variants"], next: nextWord)
                }
            })
        }
        if a.kind == "image" {
            let ready = fluxID != nil
            out.append(FlowNextStep(id: "edit", icon: "✎", label: t("Überarbeiten", "Rework"),
                                    small: join(t("mit Referenz", "with reference"), ready ? (flowModel(fluxID)?.short ?? "FLUX.2 Klein") : "FLUX.2 Klein" + t(" fehlt", " missing"))) {
                guard let flux = fluxID else {
                    if let m = flowModel(ModelCatalog.recommended.id) { nextNeed = NextNeed(why: t("zum Überarbeiten mit Referenz", "to rework with a reference"), model: m, alternative: nil, useAlternative: nil) }
                    return
                }
                nextNeed = nil
                formMode = .generate
                state.setActiveModel(flux)
                startID = nil
                outpaintOn = false
                referenceIDs = [a.id]
                refsOpen = true
                // Format wie das Bild, sonst schnitte das Bearbeiten es neu zu
                if let size = pixelSize(a.id) {
                    let aspect = Double(size.width) / Double(max(1, size.height))
                    if let i = sizes.indices.min(by: { abs(log(Double(sizes[$0].w) / Double(sizes[$0].h) / aspect)) < abs(log(Double(sizes[$1].w) / Double(sizes[$1].h) / aspect)) }) {
                        sizeIndex = i
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { promptFocused = true }
            })
        }
        if a.kind == "audio" && a.meta["speech"]?.boolValue == true {
            out.append(FlowNextStep(id: "voice", icon: "◎", label: t("Als Stimmvorlage", "As voice template"),
                                    small: t("gleiche Stimme für den nächsten Satz", "same voice for the next line")) {
                nextNeed = nil
                formMode = .speech
                speechFromRecording = true
                speechRecordingID = a.id
                speechVoiceText = a.meta["text"]?.stringValue ?? a.prompt
            })
        }
        let target = StudioModel.shared.project
        out.append(FlowNextStep(id: "studio", icon: "➜", label: t("Ins Studio", "To the Studio"),
                                small: target.map { t("als Szene in „\($0.name)“", "as a scene in “\($0.name)”") }
                                    ?? t("als Szene in ein neues Projekt", "as a scene in a new project")) {
            nextNeed = nil
            Task { await toStudio(a) }
        })
        return out
    }

    /// „Ins Studio“: Ein Bild wird das Startbild einer Videoszene (die Bewegung beschreibt man dort); Video, Ton und Stimme
    /// kommen als Take und gleich in den Schnitt
    private func toStudio(_ a: AssetRecord) async {
        let studio = StudioModel.shared
        await studio.start()
        if studio.project == nil { await studio.newProject() }
        guard let p = studio.project else { return }
        let title = String(a.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let secs = a.meta["seconds"]?.doubleValue
        var params: StudioParams = ["title": .string(title)]
        let isSpeech = a.meta["speech"]?.boolValue == true
        switch a.kind {
        case "image", "upload":
            params["lane"] = .string("video")
            params["kind"] = .string("video")
            params["prompt"] = .string("")
            params["params"] = .object(["image_asset_id": .string(a.id), "way": .string("start")])
        case "video":
            params["lane"] = .string("video")
            params["kind"] = .string("video")
            params["prompt"] = .string(a.prompt)
            params["model_id"] = .string(a.modelID)
        default:
            params["lane"] = .string(isSpeech ? "voice" : "music")
            params["kind"] = .string("audio")
            params["prompt"] = .string(isSpeech ? (a.meta["text"]?.stringValue ?? a.prompt) : a.prompt)
            params["model_id"] = .string(a.modelID)
            if isSpeech {
                params["params"] = .object(["voice": .string(a.meta["voice"]?.stringValue ?? ""),
                                            "language": .string(a.meta["language"]?.stringValue ?? "auto")])
            }
        }
        if a.kind != "image" && a.kind != "upload" {
            params["takes"] = .array([.string(a.id)])
            params["take"] = .string(a.id)
            if let secs { params["duration_s"] = .double(secs) }
        }
        guard let r = await studio.run("scene.add", params), let id = r["id"]?.stringValue else {
            message = studio.notice
            return
        }
        if a.kind != "image" && a.kind != "upload" { await studio.run("edit.conform", ["scenes": .array([.string(id)])]) }
        studioNote = a.kind == "image" || a.kind == "upload"
            ? t("Als Szene mit diesem Startbild im Studio-Projekt „\(p.name)“; dort die Bewegung beschreiben.",
                "Added as a scene with this start image to the Studio project “\(p.name)”; describe the motion there.")
            : t("Als Szene im Studio-Projekt „\(p.name)“ und im Schnitt.", "Added as a scene to the Studio project “\(p.name)” and to the edit.")
        state.selectedTab = "studio"
        studio.focus(id, field: a.kind == "image" || a.kind == "upload" ? "prompt" : nil)
    }
}
