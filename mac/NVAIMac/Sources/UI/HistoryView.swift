import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var selection: String?
    @State private var preview: AssetRecord?
    @State private var playing: AssetRecord?
    /// Hinweis, wenn ein Asset nicht gelöscht wurde (Clip im Schnitt eines Projekts, seit 0.5.9)
    @State private var notice: String?
    /// „Verlauf leeren“ (seit 0.5.10): Rückfrage, Ergebnis bzw. Fehler
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var cleared: String?
    /// Größe der Vorschaubilder und Breite der Bildvorschau rechts, über Neustarts gemerkt (Nutzerwunsch 25.10.2026).
    @AppStorage("history.thumbSize") private var thumbSize = 150.0
    @AppStorage("history.previewWidth") private var previewWidth = 380.0
    /// Bilder, Videos, Audio oder alles (seit 0.4.8 stehen auch Videos im Verlauf, Nutzerwunsch 26.10.2026; Musik,
    /// Klänge und Sprache seit 0.5.10 wie unter Windows).
    @AppStorage("history.filter") private var filter = "all"

    private var all: [AssetRecord] { (state.images + state.videos + state.audios).sorted { $0.createdAt > $1.createdAt } }

    /// Neueste zuerst, gefiltert.
    private var items: [AssetRecord] {
        switch filter {
        case "images": return state.images
        case "videos": return state.videos
        case "audio": return state.audios
        default: return all
        }
    }

    private var selected: AssetRecord? { all.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            // HStack statt HSplitView: Die geteilte Ansicht verteilte die Breite selbst und überging den Regler.
            HStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], spacing: 8) {
                        ForEach(items) { asset in
                            tile(asset)
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
            // Nie eine leere Liste: Wird das letzte Bild von außen gelöscht (Claude per REST), griff die Großansicht
            // sonst auf assets[-1] zu und die App stürzte ab
            let list = state.images.contains(asset) ? state.images : [asset]
            PreviewSheet(assets: list, index: list.firstIndex(of: asset) ?? 0).environmentObject(state)
        }
        .sheet(item: $playing) { asset in VideoPlayerSheet(asset: asset) }
        .alert(t("Nicht gelöscht", "Not deleted"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .alert(clearTitle, isPresented: $confirmClear) {
            Button(t("Ja, löschen", "Yes, delete"), role: .destructive) { clear() }
            Button(t("Abbrechen", "Cancel"), role: .cancel) {}
        } message: {
            Text(clearQuestion)
        }
        .alert(t("Verlauf leeren", "Clear history"), isPresented: Binding(get: { cleared != nil }, set: { if !$0 { cleared = nil } })) {
            Button("OK") { cleared = nil }
        } message: {
            Text(cleared ?? "")
        }
        .onAppear {
            if let video = state.snapshotPlayVideo {
                state.snapshotPlayVideo = nil
                playing = video
            }
        }
    }

    private func tile(_ asset: AssetRecord) -> some View {
        Group {
            if asset.kind == "video" {
                // Zwei Stufen statt jeder Reglerstellung: sonst dekodiert jede Größe neu.
                VideoThumbnail(url: AssetStore.shared.fileURL(asset.filename), maxSide: thumbSize > 180 ? 640 : 320)
            } else if asset.kind == "audio" {
                audioTile(asset)
            } else {
                AssetThumbnail(asset: asset, maxSide: thumbSize > 180 ? 640 : 320)
            }
        }
        .frame(height: thumbSize)
        .padding(3)
        .background(selection == asset.id ? Color.accentColor.opacity(0.35) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
        .onTapGesture { selection = asset.id }
        .help(AssetActions.help(click: t("Klick: auswählen", "Click: select")))
        .contextMenu {
            if asset.kind == "video" {
                Button(t("Abspielen", "Play")) { playing = asset }
            } else if asset.kind == "audio" {
                Button(playback.playingID == asset.id ? t("Anhalten", "Stop") : t("Abspielen", "Play")) { playback.toggle(asset) }
            } else {
                Button(t("Große Vorschau", "Large preview")) { preview = asset }
            }
            AssetMenuItems(asset: asset)
            Divider()
            Button(t("Löschen", "Delete"), role: .destructive) { delete(asset) }
        }
    }

    /// Kachel für Musik, Klänge und Sprache: Zeichen, Abspielknopf, Prompt und Länge.
    private func audioTile(_ asset: AssetRecord) -> some View {
        let isPlaying = playback.playingID == asset.id
        return VStack(spacing: 6) {
            Image(systemName: SpeechCatalog.matches(asset.modelID) ? "person.wave.2" : "waveform")
                .font(.system(size: thumbSize > 180 ? 30 : 20))
                .foregroundStyle(.secondary)
            Button {
                playback.toggle(asset)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: thumbSize > 180 ? 40 : 28))
            }
            .buttonStyle(.plain)
            .help(isPlaying ? t("Anhalten", "Stop") : t("Abspielen", "Play"))
            if thumbSize >= 120 {
                Text(asset.prompt.isEmpty ? asset.filename : asset.prompt)
                    .font(.caption)
                    .lineLimit(thumbSize > 180 ? 4 : 2)
                    .multilineTextAlignment(.center)
            }
            if let s = asset.meta["seconds"]?.doubleValue {
                Text(verbatim: String(format: "%.1f s", s)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $filter) {
                Text(t("Alle", "All")).tag("all")
                Text(t("Bilder", "Images")).tag("images")
                Text(t("Videos", "Videos")).tag("videos")
                Text("Audio").tag("audio")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            Divider().frame(height: 16)
            Label(t("Vorschaubilder", "Thumbnails"), systemImage: "square.grid.2x2")
            Slider(value: $thumbSize, in: 80...320, step: 10).frame(width: 150)
            Text(verbatim: "\(Int(thumbSize)) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Divider().frame(height: 16)
            Label(t("Vorschau", "Preview"), systemImage: "sidebar.right")
            Slider(value: $previewWidth, in: 280...1000, step: 20).frame(width: 150)
            Text(verbatim: "\(Int(previewWidth)) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Spacer()
            Text(countText).foregroundStyle(.secondary)
            Button(clearTitle, role: .destructive) { confirmClear = true }
                .disabled(items.isEmpty || clearing)
                .help(t("Löscht die Einträge samt Dateien. Was ein Studio-Projekt nutzt oder einem Projekt gehört, bleibt.",
                        "Deletes the entries and their files. Anything a Studio project uses or owns stays."))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countText: String {
        let images = state.images.count == 1 ? t("1 Bild", "1 image") : t("\(state.images.count) Bilder", "\(state.images.count) images")
        let videos = state.videos.count == 1 ? t("1 Video", "1 video") : t("\(state.videos.count) Videos", "\(state.videos.count) videos")
        let audios = state.audios.count == 1 ? t("1 Audiodatei", "1 audio file")
                                             : t("\(state.audios.count) Audiodateien", "\(state.audios.count) audio files")
        return "\(images) · \(videos) · \(audios)"
    }

    // MARK: Verlauf leeren (seit 0.5.10, wie unter Windows)

    /// Art für DELETE /api/history: nil = alles.
    private var clearKind: String? {
        switch filter {
        case "images": return "image"
        case "videos": return "video"
        case "audio": return "audio"
        default: return nil
        }
    }

    private var filterName: String {
        switch filter {
        case "images": return t("Bilder", "Images")
        case "videos": return t("Videos", "Videos")
        case "audio": return "Audio"
        default: return t("Alle", "All")
        }
    }

    private var clearTitle: String {
        clearKind == nil ? t("Verlauf leeren", "Clear history") : t("„\(filterName)“ leeren", "Clear \(filterName)")
    }

    private var clearQuestion: String {
        let keep = t(" Was ein Studio-Projekt nutzt oder einem Projekt gehört, bleibt. Das lässt sich nicht rückgängig machen.",
                     " Anything a Studio project uses or owns stays. This cannot be undone.")
        if clearKind == nil {
            return t("Alle \(items.count) Einträge samt Dateien löschen, dazu hochgeladene Dateien, die kein Projekt nutzt?",
                     "Delete all \(items.count) entries including their files, and uploaded files no project uses?") + keep
        }
        return t("Alle \(items.count) Einträge der Art „\(filterName)“ samt Dateien löschen?",
                 "Delete all \(items.count) \(filterName) entries including their files?") + keep
    }

    private func clear() {
        clearing = true
        let kind = clearKind
        Task {
            defer { clearing = false }
            do {
                let result = try await AssetDeletion.clearHistory(kind: kind)
                AudioPlayback.shared.stop()
                selection = nil
                let mb = String(format: "%.1f", result.freedMB)
                cleared = t("\(result.assets) Dateien gelöscht, \(mb) MB frei.", "\(result.assets) files deleted, \(mb) MB freed.")
            } catch {
                cleared = (error as? APIError)?.detail ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let asset = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if asset.kind == "video" {
                        VideoThumbnail(url: AssetStore.shared.fileURL(asset.filename), maxSide: previewWidth > 600 ? 1600 : 900)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
                            .onTapGesture { playing = asset }
                            .help(AssetActions.help(click: t("Klick: abspielen", "Click: play")))
                    } else if asset.kind == "audio" {
                        audioTile(asset).frame(height: 180)
                    } else {
                        AssetThumbnail(asset: asset, maxSide: previewWidth > 600 ? 1600 : 900)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
                            .onTapGesture { preview = asset }
                            .help(AssetActions.help(click: t("Klick: große Vorschau", "Click: large preview")))
                    }
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
                        if asset.kind == "video" {
                            Button(t("Abspielen", "Play")) { playing = asset }
                        } else if asset.kind == "audio" {
                            Button(playback.playingID == asset.id ? t("Anhalten", "Stop") : t("Abspielen", "Play")) {
                                playback.toggle(asset)
                            }
                        } else {
                            Button(t("Große Vorschau", "Large preview")) { preview = asset }
                        }
                        Button(t("Speicherort öffnen", "Show in Finder")) { AssetActions.revealInFinder(asset) }
                        Button(t("Mit der Standard-App öffnen", "Open with the default app")) {
                            AssetActions.openWithDefaultApp(asset)
                        }
                    }
                    Button(t("Löschen", "Delete"), role: .destructive) { delete(asset) }
                }
                .padding(14)
            }
        } else {
            VStack {
                Spacer()
                Text(items.isEmpty ? t("Noch nichts erzeugt.", "Nothing generated yet.")
                                   : t("Bild, Video oder Audio auswählen.", "Select an image, a video or an audio file."))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func delete(_ asset: AssetRecord) {
        let id = asset.id
        if playback.playingID == id { playback.stop() }
        Task {
            if let message = await AssetDeletion.deleteWithNotice(id) {
                notice = message
            } else if selection == id {
                selection = nil
            }
        }
    }

    private func metaRows(_ asset: AssetRecord) -> [(String, String)] {
        // Den Modellnamen in der aktuellen Sprache, nicht wie er beim Erzeugen gespeichert wurde.
        let modelName = VideoCatalog.model(asset.modelID)?.name
            ?? Models.find(asset.modelID)?.name
            ?? (asset.modelID == AudioCatalog.id ? AudioCatalog.name : nil)
            ?? (asset.kind == "audio" && SpeechCatalog.matches(asset.modelID) ? t("Sprecherstimme (Qwen3-TTS)", "Voice (Qwen3-TTS)") : nil)
            ?? asset.meta["model_name"]?.stringValue ?? asset.modelID
        var rows: [(String, String)] = [(t("Modell", "Model"), modelName)]
        if let w = asset.meta["width"]?.intValue, let h = asset.meta["height"]?.intValue { rows.append((t("Größe", "Size"), "\(w) × \(h)")) }
        if let s = asset.meta["seconds"]?.doubleValue { rows.append((t("Länge", "Length"), String(format: "%.1f s", s))) }
        if let f = asset.meta["frames"]?.intValue { rows.append((t("Bilder", "Frames"), "\(f)")) }
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
