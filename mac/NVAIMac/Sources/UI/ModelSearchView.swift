import SwiftUI

/// Suche nach weiteren Modellen auf Hugging Face – wie in NVAILocal: Treffer nach Dateinamen einordnen, beim Öffnen
/// gegen die echten Dateien prüfen (bei ZIPs per Inhaltsverzeichnis, ohne Download) und erst dann anbieten.
/// Bilder oder Videos (Nutzerwunsch 26.10.2026); was sich nicht laden lässt, steht mit Einordnung da.
struct ModelSearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var art: HuggingFace.Art
    @State private var query: String
    @State private var hits: [HuggingFace.Treffer] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selected: HuggingFace.Treffer?
    @State private var offers: [HuggingFace.Angebot] = []
    @State private var checking = false

    init() {
        // Sonst Bilder mit leerem Suchfeld; die Prüfoption --snapshot --tab search kann es vorgeben.
        let preset = AppState.shared.searchPreset
        _art = State(initialValue: preset?.art ?? .bild)
        _query = State(initialValue: preset?.query ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $art) {
                    ForEach(HuggingFace.Art.allCases) { Text($0.titel).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField(placeholder, text: $query)
                    .onSubmit { Task { await search() } }
                Button(t("Suchen", "Search")) { Task { await search() } }.disabled(searching)
                Button(t("Schließen", "Close")) { dismiss() }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HSplitView {
                List(hits, selection: Binding(get: { selected?.id }, set: { id in
                    selected = hits.first { $0.id == id }
                    offers = []
                    if let s = selected, !s.angebote.isEmpty { Task { await check(s) } }
                })) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name).font(.headline)
                        Text("\(hit.autor) · \(hit.downloads) " + t("Downloads", "downloads"))
                            .font(.caption).foregroundStyle(.secondary)
                        status(hit).font(.caption)
                    }
                    .tag(hit.id)
                }
                .frame(minWidth: 280)
                .overlay { if searching { ProgressView() } }

                VStack(alignment: .leading, spacing: 8) {
                    if let hit = selected {
                        Text(hit.id).font(.headline)
                        Link(t("Auf Hugging Face ansehen", "View on Hugging Face"),
                             destination: URL(string: "https://huggingface.co/\(hit.id)")!)
                            .font(.caption)
                        if let einordnung = hit.einordnung {
                            Text(einordnung.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if einordnung.stand == .katalog || einordnung.stand == .familie {
                                Button(t("Zu „Modelle“", "Go to \"Models\"")) { dismiss() }
                            }
                        } else {
                            if checking { ProgressView(t("prüft die Dateien …", "checking the files …")) }
                            ForEach(offers) { offer in offerRow(offer) }
                            Text(t("Lizenz im Repo prüfen, bevor Bilder weiterverwendet werden.",
                                   "Check the license in the repository before using the images."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(t("Treffer auswählen, um Einzelheiten zu sehen.", "Select a result to see the details."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .frame(minWidth: 380)
            }
        }
        .padding(14)
        .task { if hits.isEmpty { await search() } }
        .onChange(of: art) { _, _ in Task { await search() } }
    }

    private var placeholder: String {
        if art == .bild {
            return t("Suchen, z. B. „realistic“, „anime“, „sdxl“", "Search, e.g. \"realistic\", \"anime\", \"sdxl\"")
        }
        return t("Suchen, z. B. „ltx“, „wan“ – leer zeigt die meistgeladenen",
                 "Search, e.g. \"ltx\", \"wan\" – empty shows the most downloaded")
    }

    private var hint: String {
        if art == .bild {
            return t("Laden lassen sich Core-ML-Pipelines (Stable Diffusion 1.5, 2 und XL). FLUX.2 Klein und Z-Image "
                        + "Turbo stehen im Katalog unter „Modelle“.",
                     "Core ML pipelines load from here (Stable Diffusion 1.5, 2 and XL). FLUX.2 Klein and Z-Image Turbo "
                        + "are in the catalog under \"Models\".")
        }
        return t("Auf dem Mac läuft LTX-Video 2B (Katalog). Die Suche zeigt die übrigen Videomodelle mit dem Grund, "
                    + "warum sie hier (noch) nicht laufen.",
                 "On the Mac, LTX-Video 2B runs (catalog). The search shows the other video models and why they do "
                    + "not run here (yet).")
    }

    /// Kurzer Stand in der Trefferliste: ladbar, im Katalog, läuft hier nicht, zu groß.
    @ViewBuilder
    private func status(_ hit: HuggingFace.Treffer) -> some View {
        switch hit.einordnung?.stand {
        case nil:
            Text(t("Core ML · \(hit.angebote.count) Paket(e) zum Laden", "Core ML · \(hit.angebote.count) package(s) to download"))
                .foregroundStyle(.green)
        case .katalog?:
            Text(t("läuft: Katalogmodell", "runs: catalog model")).foregroundStyle(.green)
        case .familie?:
            Text(t("Familie im Katalog, diese Fassung nicht", "family in the catalog, not this version")).foregroundStyle(.blue)
        case .nicht?:
            Text(t("läuft in NVAI-open für Mac (noch) nicht", "does not run in NVAI-open for Mac (yet)")).foregroundStyle(.orange)
        case .zuGross?:
            Text(t("zu groß für diesen Mac", "too big for this Mac")).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func offerRow(_ offer: HuggingFace.Angebot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(offer.titel).font(.callout.bold())
                switch offer.stand {
                case .ungeprueft:
                    Text(t("noch nicht geprüft", "not checked yet")).font(.caption).foregroundStyle(.secondary)
                case .lauffaehig(let text): Text("✓ \(text)").font(.caption).foregroundStyle(.green)
                case .nicht(let grund): Text(grund).font(.caption).foregroundStyle(.orange)
                }
                Text(t(String(format: "%.2f GB · braucht rund %.1f GB · %d px · %@", offer.groesseGb, offer.bedarfGb,
                              offer.aufloesung, offer.nutztGPU ? "GPU" : "Neural Engine"),
                       String(format: "%.2f GB · needs about %.1f GB · %d px · %@", offer.groesseGb, offer.bedarfGb,
                              offer.aufloesung, offer.nutztGPU ? "GPU" : "Neural Engine")))
                    .font(.caption).foregroundStyle(.secondary)
                if offer.groesseBytes > 0 {
                    FitBadges(fit: MacFit.of(needGB: offer.bedarfGb), recommended: false)
                }
                if offer.istLauffaehig {
                    Button(t("Hinzufügen und laden", "Add and download")) {
                        let model = UserCoreMLCatalog.model(from: offer)
                        UserCoreMLCatalog.add(model)
                        state.refreshModels()
                        Task { _ = await JobQueue.shared.submitDownload(.coreml(model)) }
                        dismiss()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func search() async {
        searching = true
        error = nil
        selected = nil
        offers = []
        defer { searching = false }
        let gesucht = art
        do {
            let found = try await HuggingFace.suche(query, art: gesucht)
            guard gesucht == art else { return }  // inzwischen umgeschaltet: die neuere Suche gewinnt
            hits = found
            if hits.isEmpty {
                error = gesucht == .bild
                    ? t("Keine Treffer. Andere Begriffe probieren, z. B. „realistic“ oder „anime“.",
                        "No results. Try other terms, e.g. \"realistic\" or \"anime\".")
                    : t("Keine Videomodelle gefunden.", "No video models found.")
            }
        } catch {
            hits = []
            self.error = error.localizedDescription
        }
    }

    private func check(_ hit: HuggingFace.Treffer) async {
        checking = true
        offers = hit.angebote
        defer { checking = false }
        let tree = try? await HuggingFace.dateien(in: hit.id)
        var checked: [HuggingFace.Angebot] = []
        for offer in hit.angebote {
            checked.append(await HuggingFace.pruefe(offer, baum: tree))
        }
        if selected?.id == hit.id { offers = checked }
    }
}
