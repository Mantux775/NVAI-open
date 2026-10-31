import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    /// Nur die Empfehlungen für diesen Mac zeigen (wie „Für deine Karte“ unter Windows, Nutzerwunsch 26.10.2026).
    @AppStorage("models.recommendedOnly") private var recommendedOnly = false

    private func visible(_ id: String, installed: Bool) -> Bool {
        !recommendedOnly || installed || MacRecommendations.isRecommended(id)
    }
    private var fluxRows: [AppState.ModelRow] { state.models.filter { $0.model.engine == "mlx" && visible($0.id, installed: $0.installed) } }
    private var zimageRows: [AppState.ModelRow] { state.models.filter { $0.model.engine == "zimage" && visible($0.id, installed: $0.installed) } }
    private var coremlRows: [AppState.ModelRow] { state.models.filter { $0.model.engine == "coreml" && visible($0.id, installed: $0.installed) } }

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
                HStack {
                    Toggle(t("Nur Empfehlungen für diesen Mac", "Only recommendations for this Mac"), isOn: $recommendedOnly)
                    Spacer()
                    Text(t("Dieser Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB Arbeitsspeicher",
                           "This Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB memory"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text("FLUX.2 Klein (MLX)").font(.title2.bold())
                Text(t("Das Hauptmodell: Generieren, Überarbeiten, Füllen mit Maske, Referenzbilder. Modellordner: ",
                       "The main model: generate, refine, masked fills, reference images. Model folder: ")
                     + state.modelsDirectory.path)
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(fluxRows) { row in ModelCard(row: row) }

                Text("Z-Image Turbo (MLX)").font(.title2.bold()).padding(.top, 10)
                Text(t("Ein zweites Bildmodell für Text zu Bild: fotorealistisch und gut mit Schrift, 8 Schritte. Auf Macs "
                       + "bis 16 GB laden Text-Encoder und Bildmodell nacheinander.",
                       "A second image model for text to image: photorealistic and good with lettering, 8 steps. On Macs "
                       + "with up to 16 GB the text encoder and the image model load one after another."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(zimageRows) { row in ModelCard(row: row) }

                if !coremlRows.isEmpty || !recommendedOnly {
                    Text("Stable Diffusion (Core ML)").font(.title2.bold()).padding(.top, 10)
                }
                Text(t("Kleinere Modelle mit festem Format, laufen auch auf 8 GB. Weitere fertig konvertierte "
                       + "Pipelines findet die Suche auf Hugging Face; NVAI-open prüft sie vor dem Laden.",
                       "Smaller models with a fixed size that also run on 8 GB. The search finds more converted "
                       + "pipelines on Hugging Face; NVAI-open checks them before downloading."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(coremlRows) { row in ModelCard(row: row) }

                Text(t("LoRAs (FLUX.2 Klein)", "LoRAs (FLUX.2 Klein)")).font(.title2.bold()).padding(.top, 10)
                Text(t("Kleine Zusatzgewichte für einen Stil oder eine Aufgabe, alle Apache-2.0. Beim Generieren unter "
                       + "„LoRAs“ anhaken; das Auslösewort gehört in den Prompt.",
                       "Small add-on weights for a style or a task, all Apache-2.0. Tick them under \"LoRAs\" when "
                       + "generating; the trigger word goes into the prompt."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.loras) { row in LoRACard(row: row) }

                if visible(AudioCatalog.id, installed: state.audioInstalled) {
                    Text(t("Musik und Klänge", "Music and sounds")).font(.title2.bold()).padding(.top, 10)
                    AudioModelCard()
                }

                let videos = VideoCatalog.models.filter { visible($0.id, installed: state.videoInstalledIDs.contains($0.id)) }
                if !videos.isEmpty {
                    Text(t("Video", "Video")).font(.title2.bold()).padding(.top, 10)
                    Text(t("Empfohlen nach Arbeitsspeicher: unter 16 GB LTX-Video 2B, ab 16 GB der 13B in 4 Bit, ab 24 GB in 8 Bit, ab 32 GB LTX-2.3 mit Ton, ab 64 GB LTX-2.5 mit Ton (LTX-2 ab macOS 26.3).",
                           "Recommended by memory: below 16 GB LTX-Video 2B, from 16 GB the 13B in 4-bit, from 24 GB in 8-bit, from 32 GB LTX-2.3 with sound, from 64 GB LTX-2.5 with sound (LTX-2 from macOS 26.3)."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(videos) { VideoModelCard(model: $0) }
                }

                Text(t("Zusätze", "Add-ons")).font(.title2.bold()).padding(.top, 10)
                Text(t("Keine Bildmodelle, sondern Werkzeuge für einzelne Funktionen.",
                       "Not image models, but tools for single features."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.helpers.filter { visible($0.id, installed: $0.installed) }) { row in HelperCard(row: row) }
            }
            .padding(16)
        }
        .onAppear { state.refreshModels() }
        .sheet(isPresented: $state.showSearch) {
            ModelSearchView().environmentObject(state).frame(minWidth: 760, minHeight: 560)
        }
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

/// Eine LoRA: laden, Fortschritt, löschen.
struct LoRACard: View {
    @EnvironmentObject var state: AppState
    let row: AppState.LoRARow

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
                    Spacer()
                    Text(row.installed ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                        .foregroundStyle(row.installed ? .green : .secondary)
                }
                Text(row.model.description).font(.callout)
                Text(String(format: "%.0f MB · %@ · %@", row.model.sizeMB, row.model.license, row.model.repo))
                    .font(.caption).foregroundStyle(.secondary)
                if let download {
                    ProgressView(value: download.progress)
                    Text(download.stage).font(.caption).foregroundStyle(.secondary)
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
                            row.model.delete()
                            state.refreshModels()
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
