import AppKit
import SwiftUI

/// Bilder zur Auswahl wie „Quellbild“ und „Referenzbilder“ der Windows-Oberfläche: die neuesten erzeugten und
/// hochgeladenen als Vorschaubilder zum Anklicken, dazu „Bild hochladen …“ und Ablegen aus dem Finder.
/// Mit `limit` 1 wählt ein Klick ein Bild (Ausgangsbild, Maske, altes Foto), sonst bis zu `limit` mit Nummern
/// in der Reihenfolge „the first image“, „the second image“ … (Referenzen).
struct ImageStrip: View {
    let sources: [AssetRecord]
    @Binding var selection: [String]
    let limit: Int
    let allowNone: Bool
    /// Legt Dateien als Uploads ab und gibt die neuen Asset-IDs zurück.
    let upload: ([URL]) async -> [String]
    let remove: (AssetRecord) -> Void
    /// Gibt es ältere Bilder als die gezeigten, hängt „Weitere laden“ sie an (wie der Verlauf).
    let loadMore: (() -> Void)?
    @State private var targeted = false

    init(sources: [AssetRecord], selection: Binding<[String]>, limit: Int = 1, allowNone: Bool = true,
         upload: @escaping ([URL]) async -> [String], remove: @escaping (AssetRecord) -> Void,
         loadMore: (() -> Void)? = nil) {
        self.sources = sources
        _selection = selection
        self.limit = limit
        self.allowNone = allowNone
        self.upload = upload
        self.remove = remove
        self.loadMore = loadMore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sources.isEmpty {
                Text(t("Noch keine Bilder da. Erst eines generieren oder hochladen.", "No images yet. Generate or upload one first."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        if allowNone && limit == 1 { noneTile }
                        ForEach(sources) { asset in tile(asset) }
                        if let loadMore {
                            Button(action: loadMore) {
                                Text(t("Weitere\nladen", "Load\nmore")).font(.caption).multilineTextAlignment(.center)
                                    .frame(width: 66, height: 66)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
                .frame(height: 76)
            }
            HStack {
                Button(t("Bild hochladen …", "Upload image …")) {
                    let urls = Panels.chooseImages(t("Bild hochladen", "Upload image"), multiple: limit > 1)
                    guard !urls.isEmpty else { return }
                    Task { add(await upload(urls)) }
                }
                Text(t("oder aus dem Finder hierher ziehen", "or drag it here from the Finder"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !sources.isEmpty {
                    Text(sources.count == 1 ? t("1 Bild", "1 image") : t("\(sources.count) Bilder", "\(sources.count) images"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if limit > 1 && !selection.isEmpty {
                    Button(t("Auswahl leeren", "Clear selection")) { selection = [] }.font(.caption)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(targeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6])))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { add(await upload(files)) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private var noneTile: some View {
        Button { selection = [] } label: {
            Text(t("ohne", "none")).font(.caption).foregroundStyle(.secondary).frame(width: 66, height: 66)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection.isEmpty ? Color.accentColor : .clear, lineWidth: 2.5))
    }

    private func tile(_ asset: AssetRecord) -> some View {
        let index = selection.firstIndex(of: asset.id)
        return AssetThumbnail(asset: asset, maxSide: 160)
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(index != nil ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: index != nil ? 2.5 : 1))
            .overlay(alignment: .topLeading) {
                if let index, limit > 1 {
                    Text("\(index + 1)").font(.caption2.bold()).padding(4).background(.ultraThinMaterial, in: Circle()).padding(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(asset.id) }
            .help(asset.prompt.isEmpty ? (asset.meta["original_name"]?.stringValue ?? asset.filename) : asset.prompt)
            .contextMenu {
                Button(t("Im Finder zeigen", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(asset.filename)])
                }
                Button(t("Löschen", "Delete"), role: .destructive) { remove(asset) }
            }
    }

    private func toggle(_ id: String) {
        if limit == 1 {
            selection = selection == [id] && allowNone ? [] : [id]
        } else if let i = selection.firstIndex(of: id) {
            selection.remove(at: i)
        } else if selection.count < limit {
            selection.append(id)
        }
    }

    private func add(_ ids: [String]) {
        for id in ids {
            if limit == 1 {
                selection = [id]
            } else if !selection.contains(id) && selection.count < limit {
                selection.append(id)
            }
        }
    }
}

/// Große Vorschau wie die Lightbox der Windows-Oberfläche: blättern mit ← und →, Esc schließt, bei restaurierten
/// Fotos „Original zeigen“. Wahlweise Knöpfe, um das Bild als Ausgangs- oder Referenzbild weiterzuverwenden.
struct PreviewSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let assets: [AssetRecord]
    @State private var index: Int
    let useAsStart: ((AssetRecord) -> Void)?
    let useAsReference: ((AssetRecord) -> Void)?
    @State private var showOriginal = false

    init(assets: [AssetRecord], index: Int, useAsStart: ((AssetRecord) -> Void)? = nil,
         useAsReference: ((AssetRecord) -> Void)? = nil) {
        self.assets = assets
        _index = State(initialValue: index)
        self.useAsStart = useAsStart
        self.useAsReference = useAsReference
    }

    private var asset: AssetRecord { assets[min(max(0, index), assets.count - 1)] }

    private var original: AssetRecord? {
        guard let id = asset.meta["source_asset_id"]?.stringValue else { return nil }
        return (state.images + state.uploads).first { $0.id == id }
    }

    private var title: String {
        asset.prompt.isEmpty ? (asset.meta["original_name"]?.stringValue ?? asset.filename) : asset.prompt
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail).help(title)
                Spacer()
                if assets.count > 1 { Text("\(index + 1) / \(assets.count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            AssetThumbnail(asset: showOriginal ? (original ?? asset) : asset, maxSide: 1600)
                .frame(minWidth: 640, idealWidth: 960, maxWidth: .infinity, minHeight: 420, idealHeight: 680, maxHeight: .infinity)
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(assets.count < 2)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(assets.count < 2)
                if original != nil {
                    Toggle(t("Original zeigen", "Show original"), isOn: $showOriginal).toggleStyle(.button)
                }
                Spacer()
                if let useAsStart {
                    Button(t("Als Ausgangsbild", "As start image")) { useAsStart(asset); dismiss() }
                }
                if let useAsReference {
                    Button(t("Als Referenz", "As reference")) { useAsReference(asset); dismiss() }
                }
                Button(t("Im Finder zeigen", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(asset.filename)])
                }
                Button(t("Schließen", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 680, minHeight: 520)
    }

    private func step(_ delta: Int) {
        showOriginal = false
        index = (index + delta + assets.count) % assets.count
    }
}
