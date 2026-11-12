import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    /// Bis 0.5.0 ein Schalter „Nur Empfehlungen für diesen Mac“; heute der Filter „Für diesen Mac“ (wird übernommen).
    @AppStorage("models.recommendedOnly") private var recommendedOnly = false
    /// Filter und Suche wie unter Windows (Nutzer 31.10.2026: „video modelle solle in der mac version als erstes stehen
    /// und es fehlen filter zum schnell suchen.“): Video steht zuerst, die Suche verlangt jedes Wort irgendwo in Name,
    /// Kennung oder Beschreibung.
    @AppStorage("models.filter") private var filter = "all"
    @State private var query = ""
    /// Eigene LoRA-Datei (seit 0.5.5): gewählte Datei für das Blatt und die Meldung danach
    @State private var loraFile: LoRAFileChoice?
    @State private var loraMessage: String?

    private static let filters: [(id: String, de: String, en: String)] = [
        ("all", "Alle", "All"), ("rec", "Für diesen Mac", "For this Mac"), ("video", "Video", "Video"),
        ("image", "Bild", "Image"), ("lora", "LoRA", "LoRA"), ("audio", "Ton", "Sound"), ("extras", "Zusätze", "Add-ons"),
    ]

    private func shows(_ section: String) -> Bool { filter == "all" || filter == "rec" || filter == section }

    private func visible(_ id: String, installed: Bool) -> Bool {
        filter != "rec" || installed || MacRecommendations.isRecommended(id)
    }

    private func matches(_ texts: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = texts.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    private func rowText(_ row: AppState.ModelRow) -> [String] {
        switch row.model {
        case .flux(let m): return [m.name, m.id, m.description]
        case .zimage(let m): return [m.name, m.id, m.description]
        case .coreml(let m): return [m.name, m.id, m.noteText]
        }
    }

    private func rows(_ engine: String) -> [AppState.ModelRow] {
        guard shows("image") else { return [] }
        return state.models.filter { $0.model.engine == engine && visible($0.id, installed: $0.installed) && matches(rowText($0)) }
    }
    private var fluxRows: [AppState.ModelRow] { rows("mlx") }
    private var zimageRows: [AppState.ModelRow] { rows("zimage") }
    private var coremlRows: [AppState.ModelRow] { rows("coreml") }
    private var videos: [VideoModel] {
        guard shows("video") else { return [] }
        return VideoCatalog.models.filter {
            visible($0.id, installed: state.videoInstalledIDs.contains($0.id)) && matches([$0.name, $0.id, $0.description])
        }
    }
    private var loraRows: [AppState.LoRARow] {
        guard shows("lora") else { return [] }
        let rows = state.loras.filter { matches([$0.model.name, $0.model.id, $0.model.description]) }
        return rows.filter(\.model.uploaded) + rows.filter { !$0.model.uploaded }  // eigene Dateien zuerst
    }
    private var showAudio: Bool {
        shows("audio") && visible(AudioCatalog.id, installed: state.audioInstalled)
            && matches([AudioCatalog.name, AudioCatalog.id, AudioCatalog.description])
    }
    /// Sprecherstimme unter dem Filter „Ton“ (seit 0.5.3).
    private var showSpeech: Bool {
        shows("audio") && visible(SpeechCatalog.id, installed: state.speechInstalled)
            && matches([SpeechCatalog.name, SpeechCatalog.id, SpeechCatalog.description, "TTS", "speech", "Sprache"])
    }
    private var helperRows: [AppState.HelperRow] {
        guard shows("extras") else { return [] }
        return state.helpers.filter { visible($0.id, installed: $0.installed) && matches([$0.model.name, $0.model.id, $0.model.description]) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Ganz oben und gut sichtbar (Nutzerwunsch 26.10.2026).
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Weitere Modelle suchen", "Find more models")).font(.headline)
                            Text(t("Auf Hugging Face; NVAI-open prüft jeden Treffer vor dem Laden.",
                                   "On Hugging Face; NVAI-open checks every result before downloading."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(t("Suchen …", "Search …")) { state.showSearch = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    .padding(6)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { filterBar; Spacer(minLength: 8); macInfo }
                    VStack(alignment: .leading, spacing: 6) { HStack(spacing: 10) { filterBar }; macInfo }
                }

                let videos = self.videos
                if !videos.isEmpty {
                    Text(t("Video", "Video")).font(.title2.bold())
                    Text(t("Empfohlen nach Arbeitsspeicher: unter 16 GB LTX-Video 2B, ab 16 GB der 13B in 4 Bit, ab 24 GB in 8 Bit, ab 32 GB LTX-2.3 mit Ton, ab 64 GB LTX-2.5 mit Ton (LTX-2 ab macOS 26.3).",
                           "Recommended by memory: below 16 GB LTX-Video 2B, from 16 GB the 13B in 4-bit, from 24 GB in 8-bit, from 32 GB LTX-2.3 with sound, from 64 GB LTX-2.5 with sound (LTX-2 from macOS 26.3)."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(videos) { VideoModelCard(model: $0) }
                }

                let flux = fluxRows
                if !flux.isEmpty {
                    Text("FLUX.2 Klein (MLX)").font(.title2.bold()).padding(.top, 10)
                    Text(t("Das Hauptmodell: Generieren, Überarbeiten, Füllen mit Maske, Referenzbilder. Modellordner: ",
                           "The main model: generate, refine, masked fills, reference images. Model folder: ")
                         + state.modelsDirectory.path)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(flux) { row in ModelCard(row: row) }
                }

                let zimage = zimageRows
                if !zimage.isEmpty {
                    Text("Z-Image Turbo (MLX)").font(.title2.bold()).padding(.top, 10)
                    Text(t("Ein zweites Bildmodell für Text zu Bild: fotorealistisch und gut mit Schrift, 8 Schritte. Auf Macs "
                           + "bis 16 GB laden Text-Encoder und Bildmodell nacheinander.",
                           "A second image model for text to image: photorealistic and good with lettering, 8 steps. On Macs "
                           + "with up to 16 GB the text encoder and the image model load one after another."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(zimage) { row in ModelCard(row: row) }
                }

                let coreml = coremlRows
                if !coreml.isEmpty {
                    Text("Stable Diffusion (Core ML)").font(.title2.bold()).padding(.top, 10)
                    Text(t("Kleinere Modelle mit festem Format, laufen auch auf 8 GB. Weitere fertig konvertierte "
                           + "Pipelines findet die Suche auf Hugging Face; NVAI-open prüft sie vor dem Laden.",
                           "Smaller models with a fixed size that also run on 8 GB. The search finds more converted "
                           + "pipelines on Hugging Face; NVAI-open checks them before downloading."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(coreml) { row in ModelCard(row: row) }
                }

                let loras = loraRows
                if !loras.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t("LoRAs (FLUX.2 Klein)", "LoRAs (FLUX.2 Klein)")).font(.title2.bold())
                        Spacer()
                        Button(t("LoRA-Datei hinzufügen", "Add LoRA file")) {
                            if let url = Panels.chooseLoRAFile() { loraFile = LoRAFileChoice(url: url) }
                        }
                        .help(t("Eine LoRA-Datei von diesem Rechner, etwa selbst trainiert, einem Modell zuordnen",
                                "Assign a LoRA file from this computer, for example one you trained, to a model"))
                    }
                    .padding(.top, 10)
                    Text(t("Kleine Zusatzgewichte für einen Stil, eine Aufgabe oder eine Figur. Beim Generieren unter "
                           + "„LoRAs“ anhaken; das Auslösewort gehört in den Prompt. Eigene LoRAs (selbst trainiert oder von "
                           + "anderswo): „LoRA-Datei hinzufügen“. NVAI-open erkennt am Dateikopf, zu welchem Modell sie gehört; "
                           + "unter „Zuordnung“ an der LoRA lassen sich das, Name und Trigger-Wörter ändern.",
                           "Small add-on weights for a style, a task or a character. Tick them under \"LoRAs\" when "
                           + "generating; the trigger word goes into the prompt. Your own LoRAs (trained yourself or from "
                           + "elsewhere): \"Add LoRA file\". NVAI-open detects from the file header which model it belongs to; "
                           + "\"Assignment\" on the LoRA changes that, as well as the name and the trigger words."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let loraMessage {
                        Text(loraMessage).font(.callout).foregroundStyle(.green).textSelection(.enabled)
                            .onTapGesture { self.loraMessage = nil }
                    }
                    ForEach(loras) { row in LoRACard(row: row) { loraMessage = $0 } }
                }

                if showAudio {
                    Text(t("Musik und Klänge", "Music and sounds")).font(.title2.bold()).padding(.top, 10)
                    AudioModelCard()
                }
                if showSpeech {
                    Text(t("Sprecherstimme", "Narrator voice")).font(.title2.bold()).padding(.top, 10)
                    SpeechModelCard()
                }

                let helpers = helperRows
                if !helpers.isEmpty {
                    Text(t("Zusätze", "Add-ons")).font(.title2.bold()).padding(.top, 10)
                    Text(t("Keine Bildmodelle, sondern Werkzeuge für einzelne Funktionen.",
                           "Not image models, but tools for single features."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(helpers) { row in HelperCard(row: row) }
                }

                if videos.isEmpty && flux.isEmpty && zimage.isEmpty && coreml.isEmpty && loras.isEmpty && !showAudio && !showSpeech && helpers.isEmpty {
                    Text(t("Kein Modell passt zu Filter und Suche.", "No model matches the filter and search."))
                        .foregroundStyle(.secondary).padding(.top, 10)
                }
            }
            .padding(16)
        }
        .onAppear {
            state.refreshModels()
            if recommendedOnly {  // alter Schalter: einmal in den Filter übernehmen
                filter = "rec"
                recommendedOnly = false
            }
        }
        .sheet(isPresented: $state.showSearch) {
            ModelSearchView().environmentObject(state).frame(minWidth: 760, minHeight: 560)
        }
        .sheet(item: $loraFile) { choice in
            LoRAAddSheet(url: choice.url) { loraMessage = $0.message }.environmentObject(state)
        }
    }

    private var filterBar: some View {
        Group {
            Picker("", selection: $filter) {
                ForEach(Self.filters, id: \.id) { f in Text(t(f.de, f.en)).tag(f.id) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField(t("Modelle durchsuchen …", "Search models …"), text: $query)
                .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 240)
        }
    }

    private var macInfo: some View {
        Text(t("Dieser Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB Arbeitsspeicher",
               "This Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB memory"))
            .font(.caption).foregroundStyle(.secondary).fixedSize()
    }
}

struct ModelCard: View {
    @EnvironmentObject var state: AppState
    let row: AppState.ModelRow

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == row.model.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == row.model.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    private var description: String {
        switch row.model {
        case .flux(let m): return m.description
        case .coreml(let m): return m.noteText
        case .zimage(let m): return m.description
        }
    }

    private var details: String {
        switch row.model {
        case .flux(let m):
            return t(String(format: "Download %.1f GB · ab %d GB Arbeitsspeicher, empfohlen %d GB · Apache-2.0",
                            m.downloadGB, m.minRAMGB, m.recommendedRAMGB),
                     String(format: "Download %.1f GB · %d GB of memory or more, %d GB recommended · Apache-2.0",
                            m.downloadGB, m.minRAMGB, m.recommendedRAMGB))
        case .zimage(let m):
            return t(String(format: "Download %.1f GB · ab %d GB Arbeitsspeicher, empfohlen %d GB · Apache-2.0",
                            m.downloadGB, m.minRAMGB, m.recommendedRAMGB),
                     String(format: "Download %.1f GB · %d GB of memory or more, %d GB recommended · Apache-2.0",
                            m.downloadGB, m.minRAMGB, m.recommendedRAMGB))
        case .coreml(let m):
            return t(String(format: "Download %.1f GB · braucht rund %.0f GB · %d × %d · %@",
                            m.sizeGb, m.needGb, m.resolution, m.resolution, m.licenseText),
                     String(format: "Download %.1f GB · needs about %.0f GB · %d × %d · %@",
                            m.sizeGb, m.needGb, m.resolution, m.resolution, m.licenseText))
        }
    }

    private var warning: String {
        switch row.model {
        case .flux(let m): return ModelCatalog.warning(m)
        case .zimage(let m): return ZImageCatalog.warning(m)
        case .coreml(let m):
            return CoreMLCatalog.fits(m) == "nein"
                ? t("Braucht mehr Arbeitsspeicher, als dieser Mac hat.", "Needs more memory than this Mac has.") : ""
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(row.model.name).font(.headline)
                    Text(ContentRating.label(row.model.id)).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(.secondary.opacity(0.5)))
                        .foregroundStyle(.secondary)
                        .help(ContentRating.help(row.model.id))
                    FitBadges(fit: row.model.fits, recommended: MacRecommendations.isRecommended(row.model.id))
                    if state.activeModelID == row.model.id {
                        Text(t("aktiv", "active")).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25)).clipShape(Capsule())
                    }
                    Spacer()
                    Text(statusText).foregroundStyle(statusColor)
                }
                Text(description).font(.callout)
                Text(details).font(.caption).foregroundStyle(.secondary)
                if !warning.isEmpty { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let download {
                    ProgressView(value: download.progress)
                    HStack {
                        Text(download.stage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Abbrechen", "Cancel")) {
                            Task {
                                _ = try? await JobQueue.shared.cancel(download.id)
                                await state.refresh()
                            }
                        }
                        .controlSize(.small)
                        .disabled(download.cancelRequested)
                    }
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if !row.installed {
                        Button(row.partial ? t("Fertig herunterladen", "Finish download") : t("Herunterladen", "Download")) {
                            let model = row.model
                            Task { _ = await JobQueue.shared.submitDownload(model) }
                        }
                        .disabled(download != nil || row.model.fits == "nein")
                    }
                    if row.installed && state.activeModelID != row.model.id {
                        Button(t("Als aktives Modell", "Make active")) { state.setActiveModel(row.model.id) }
                    }
                    if case .zimage(let m) = row.model, row.installed {
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            Task {
                                await ZImageEngine.shared.unload()
                                m.delete()
                                state.refreshModels()
                            }
                        }
                    }
                    if case .coreml(let m) = row.model {
                        if row.installed {
                            Button(t("Löschen", "Delete"), role: .destructive) {
                                Task {
                                    await CoreMLEngine.shared.unload()
                                    CoreMLInstaller.remove(m)
                                    state.refreshModels()
                                }
                            }
                        }
                        if m.custom && !row.installed {
                            Button(t("Aus der Liste entfernen", "Remove from list")) {
                                UserCoreMLCatalog.remove(m.id)
                                state.refreshModels()
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var statusText: String {
        if row.installed { return t("geladen", "downloaded") }
        if row.partial { return t("teilweise geladen", "partly downloaded") }
        return t("nicht geladen", "not downloaded")
    }

    private var statusColor: Color {
        row.installed ? .green : (row.partial ? .orange : .secondary)
    }
}

/// Ein Zusatzmodell (Qwen3.5 4B für „Automatisch“ beim Restaurieren): laden, Fortschritt, löschen.
struct HelperCard: View {
    @EnvironmentObject var state: AppState
    let row: AppState.HelperRow

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == row.model.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == row.model.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(row.model.name).font(.headline)
                    FitBadges(fit: MacFit.of(needGB: MacFit.helperNeedGB(row.model)),
                              recommended: MacRecommendations.isRecommended(row.model.id))
                    Spacer()
                    Text(row.installed ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                        .foregroundStyle(row.installed ? .green : .secondary)
                }
                Text(row.model.bestFor).font(.callout.bold())
                Text(row.model.description).font(.callout)
                Text(t(String(format: "Download %.1f GB · %@", row.model.sizeGB, row.model.license),
                       String(format: "Download %.1f GB · %@", row.model.sizeGB, row.model.license)))
                    .font(.caption).foregroundStyle(.secondary)
                if let download {
                    ProgressView(value: download.progress)
                    HStack {
                        Text(download.stage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Abbrechen", "Cancel")) {
                            Task {
                                _ = try? await JobQueue.shared.cancel(download.id)
                                await state.refresh()
                            }
                        }
                        .controlSize(.small)
                        .disabled(download.cancelRequested)
                    }
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if !row.installed {
                        Button(t("Herunterladen", "Download")) {
                            let model = row.model
                            Task { _ = await JobQueue.shared.submitDownload(model) }
                        }
                        .disabled(download != nil)
                    } else {
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            try? row.model.delete()
                            state.refreshModels()
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}

/// Eine LoRA: laden, Fortschritt, löschen; eigene Dateien (seit 0.5.5) mit „Zuordnung“ statt Download.
struct LoRACard: View {
    @EnvironmentObject var state: AppState
    let row: AppState.LoRARow
    /// Meldung für die Zeile über den LoRAs (Zuordnung gespeichert)
    var onMessage: (String) -> Void = { _ in }
    @State private var assigning = false

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == row.model.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == row.model.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.model.name).font(.headline)
                    if row.model.uploaded {
                        Text(t("eigene Datei", "own file")).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(.secondary.opacity(0.5))).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.model.uploaded {
                        Text(row.installed ? t("vorhanden", "present") : t("Datei fehlt", "File missing"))
                            .foregroundStyle(row.installed ? .green : .orange)
                    } else {
                        Text(row.installed ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                            .foregroundStyle(row.installed ? .green : .secondary)
                    }
                }
                Text(row.model.description).font(.callout)
                if row.model.uploaded {
                    Text(ByteCountFormatter.string(fromByteCount: row.model.bytes, countStyle: .file) + " · "
                         + t("vom Rechner hinzugefügt", "added from this computer")
                         + " · " + row.model.baseLabel + (row.model.trigger.isEmpty ? "" : " · " + t("Trigger: ", "Trigger: ") + row.model.trigger))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(String(format: "%.0f MB · %@ · %@", row.model.sizeMB, row.model.license, row.model.repo))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let download {
                    DownloadProgressRow(download: download)
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if row.model.uploaded {
                        if row.installed {
                            Button(t("Zuordnung", "Assignment")) { assigning.toggle() }
                                .help(t("Zu welchem Modell die LoRA gehört, Name, Trigger-Wörter", "Which model the LoRA belongs to, name, trigger words"))
                        }
                        // Vom Rechner hinzugefügt: Löschen nimmt den Eintrag mit (neu laden lässt sie sich nicht)
                        Button(row.installed ? t("Löschen", "Delete") : t("Entfernen", "Remove"), role: .destructive) {
                            row.model.delete()
                            state.refreshModels()
                        }
                    } else if !row.installed {
                        Button(t("Herunterladen", "Download")) {
                            let model = row.model
                            Task { _ = await JobQueue.shared.submitDownload(model) }
                        }
                        .disabled(download != nil)
                    } else {
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            row.model.delete()
                            state.refreshModels()
                        }
                    }
                }
                if assigning {
                    LoRAAssignEditor(model: row.model) { message in
                        assigning = false
                        if let message { onMessage(message) }
                    }
                }
            }
            .padding(6)
        }
    }
}


/// Fortschritt eines Downloads mit „Abbrechen“. Die Karten für Video, Ton und LoRAs zeigten nur den Balken: Große
/// Downloads (bis 70 GB) ließen sich nicht stoppen und hielten die Warteschlange für alle anderen Aufträge auf.
struct DownloadProgressRow: View {
    @EnvironmentObject var state: AppState
    let download: JobRecord

    var body: some View {
        ProgressView(value: download.progress)
        HStack {
            Text(download.stage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(t("Abbrechen", "Cancel")) {
                Task {
                    _ = try? await JobQueue.shared.cancel(download.id)
                    await state.refresh()
                }
            }
            .controlSize(.small)
            .disabled(download.cancelRequested)
        }
    }
}
