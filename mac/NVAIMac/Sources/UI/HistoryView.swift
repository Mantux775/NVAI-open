import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: String?
    @State private var preview: AssetRecord?
    /// Größe der Vorschaubilder und Breite der Bildvorschau rechts, über Neustarts gemerkt (Nutzerwunsch 25.10.2026).
    @AppStorage("history.thumbSize") private var thumbSize = 150.0
    @AppStorage("history.previewWidth") private var previewWidth = 380.0

    private var selected: AssetRecord? { state.images.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            // HStack statt HSplitView: Die geteilte Ansicht verteilte die Breite selbst und überging den Regler.
            HStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], spacing: 8) {
                        ForEach(state.images) { asset in
                            // Zwei Stufen statt jeder Reglerstellung: sonst dekodiert jede Größe neu.
                            AssetThumbnail(asset: asset, maxSide: thumbSize > 180 ? 640 : 320)
                                .frame(height: thumbSize)
                                .padding(3)
                                .background(selection == asset.id ? Color.accentColor.opacity(0.35) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { preview = asset }
                                .onTapGesture { selection = asset.id }
                                .help(t("Doppelklick: große Vorschau", "Double-click: large preview"))
                        }
                    }
                    .padding(10)
                }
                .frame(minWidth: 240, maxWidth: .infinity)
                Divider()
                detail.frame(width: previewWidth)
            }
        }
        .sheet(item: $preview) { asset in
            PreviewSheet(assets: state.images, index: state.images.firstIndex(of: asset) ?? 0).environmentObject(state)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Label(t("Vorschaubilder", "Thumbnails"), systemImage: "square.grid.2x2")
            Slider(value: $thumbSize, in: 80...320, step: 10).frame(width: 150)
            Text("\(Int(thumbSize)) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Divider().frame(height: 16)
            Label(t("Bildvorschau", "Image preview"), systemImage: "sidebar.right")
            Slider(value: $previewWidth, in: 280...1000, step: 20).frame(width: 150)
            Text("\(Int(previewWidth)) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Spacer()
            Text(state.images.count == 1 ? t("1 Bild", "1 image") : t("\(state.images.count) Bilder", "\(state.images.count) images"))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var detail: some View {
        if let asset = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AssetThumbnail(asset: asset, maxSide: previewWidth > 600 ? 1600 : 900)
                        .contentShape(Rectangle())
                        .onTapGesture { preview = asset }
                        .help(t("Klick: große Vorschau", "Click: large preview"))
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
                        Button(t("Große Vorschau", "Large preview")) { preview = asset }
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
