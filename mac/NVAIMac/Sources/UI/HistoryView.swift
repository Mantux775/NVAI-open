import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: String?

    private var selected: AssetRecord? { state.images.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(state.images) { asset in
                        AssetThumbnail(asset: asset, maxSide: 300)
                            .frame(height: 150)
                            .padding(3)
                            .background(selection == asset.id ? Color.accentColor.opacity(0.35) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { selection = asset.id }
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 420)

            detail.frame(minWidth: 320, idealWidth: 380)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let asset = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AssetThumbnail(asset: asset, maxSide: 900)
                    Text(asset.prompt).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(metaRows(asset), id: \.0) { row in
                            GridRow {
                                Text(row.0).foregroundStyle(.secondary)
                                Text(row.1).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                    HStack {
                        Button(t("Im Finder zeigen", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(asset.filename)])
                        }
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            let id = asset.id
                            selection = nil
                            Task { await AssetStore.shared.delete(id) }
                        }
                    }
                }
                .padding(14)
            }
        } else {
            VStack {
                Spacer()
                Text(state.images.isEmpty ? t("Noch keine Bilder.", "No images yet.") : t("Bild auswählen.", "Select an image.")).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metaRows(_ asset: AssetRecord) -> [(String, String)] {
        // Den Modellnamen in der aktuellen Sprache, nicht wie er beim Erzeugen gespeichert wurde.
        let modelName = Models.find(asset.modelID)?.name ?? asset.meta["model_name"]?.stringValue ?? asset.modelID
        var rows: [(String, String)] = [(t("Modell", "Model"), modelName)]
        if let w = asset.meta["width"]?.intValue, let h = asset.meta["height"]?.intValue { rows.append((t("Größe", "Size"), "\(w) × \(h)")) }
        if let s = asset.meta["seed"]?.intValue { rows.append(("Seed", "\(s)")) }
        if let s = asset.meta["steps"]?.intValue { rows.append((t("Schritte", "Steps"), "\(s)")) }
        if let m = asset.meta["mode"]?.stringValue { rows.append((t("Art", "Mode"), m)) }
        if let d = asset.meta["duration_s"]?.doubleValue { rows.append((t("Dauer", "Duration"), String(format: "%.1f s", d))) }
        if let l = asset.meta["load_s"]?.doubleValue { rows.append((t("Laden", "Loading"), String(format: "%.1f s", l))) }
        if let p = asset.meta["peak_memory_mb"]?.intValue { rows.append((t("Speicherspitze", "Peak memory"), "\(p) MB")) }
        rows.append((t("Datei", "File"), asset.filename))
        rows.append((t("Erstellt", "Created"), Date(timeIntervalSince1970: asset.createdAt).formatted(date: .abbreviated, time: .shortened)))
        return rows
    }
}
