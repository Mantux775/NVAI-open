import SwiftUI

/// Suche nach weiteren Core-ML-Bildmodellen auf Hugging Face – wie in NVAILocal:
/// Treffer nach Dateinamen einordnen, beim Öffnen gegen die echten Dateien prüfen
/// (bei ZIPs per Inhaltsverzeichnis, ohne Download) und erst dann anbieten.
struct ModelSearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var hits: [HuggingFace.Treffer] = []
    @State private var searching = false
    @State private var error: String?
    @State private var selected: HuggingFace.Treffer?
    @State private var offers: [HuggingFace.Angebot] = []
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(t("Suchen, z. B. „coreml stable diffusion“, „anime“, „realistic“",
                            "Search, e.g. \"coreml stable diffusion\", \"anime\", \"realistic\""), text: $query)
                    .onSubmit { Task { await search() } }
                Button(t("Suchen", "Search")) { Task { await search() } }.disabled(searching)
                Button(t("Schließen", "Close")) { dismiss() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HSplitView {
                List(hits, selection: Binding(get: { selected?.id }, set: { id in
                    selected = hits.first { $0.id == id }
                    if let s = selected { Task { await check(s) } }
                })) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name).font(.headline)
                        Text(t("\(hit.autor) · \(hit.downloads) Downloads · \(hit.angebote.count) Paket(e)",
                               "\(hit.autor) · \(hit.downloads) downloads · \(hit.angebote.count) package(s)"))
                            .font(.caption).foregroundStyle(.secondary)
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
                        if checking { ProgressView(t("prüft die Dateien …", "checking the files …")) }
                        ForEach(offers) { offer in offerRow(offer) }
                        Text(t("Lizenz im Repo prüfen, bevor Bilder weiterverwendet werden.",
                               "Check the license in the repository before using the images."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(t("Treffer auswählen, um die Pakete zu prüfen.", "Select a result to check its packages."))
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
        defer { searching = false }
        do {
            hits = try await HuggingFace.suche(query)
            if hits.isEmpty {
                error = t("Keine ladbaren Core-ML-Bildmodelle gefunden.", "No loadable Core ML image models found.")
            }
        } catch {
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
