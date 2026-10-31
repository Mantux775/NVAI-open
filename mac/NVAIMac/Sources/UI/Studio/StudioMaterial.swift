import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Material wie studio/Bin.tsx unter Windows: Projektordner (was ein Projekt erzeugt, exportiert oder dort hochlädt)
/// und „Verlauf“, Filter, Suche über alle Ordner, Liste oder Kacheln, je 100 geladen. Klick zeigt das Material im
/// Monitor (Quelle) und in den Eigenschaften; Ziehen legt es auf eine Spur oder macht es zum Take einer Szene.
struct StudioMaterial: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: StudioModel
    @State private var filter = "all"
    @State private var search = ""
    @State private var importing = false
    @State private var shown = 100
    @State private var folder: String?  // Projekt-ID des offenen Ordners, nil = oberste Ebene
    @State private var picked: String?  // markierter Ordner („..“ = "..")
    @State private var armed: String?
    @State private var probed = 0  // neu vermessene Dateien: zeichnet die Liste neu
    @AppStorage("studio.binTiles") private var tiles = false
    @AppStorage("studio.binFolders") private var folders = true

    static func isVideo(_ r: AssetRecord) -> Bool {
        r.kind == "video" || ["mp4", "mov", "m4v"].contains((r.filename as NSString).pathExtension.lowercased())
    }

    static func isAudio(_ r: AssetRecord) -> Bool {
        r.kind == "audio" || ["wav", "mp3", "m4a", "aac", "aif", "aiff", "flac", "caf"].contains((r.filename as NSString).pathExtension.lowercased())
    }

    static func label(_ r: AssetRecord) -> String {
        if !r.prompt.isEmpty { return r.prompt }
        return r.meta["original_name"]?.stringValue ?? r.filename
    }

    static func symbol(_ r: AssetRecord) -> String { isVideo(r) ? "film" : isAudio(r) ? "waveform" : "photo" }

    private var all: [AssetRecord] {
        let list: [AssetRecord]
        switch filter {
        case "video": list = state.videos + state.mediaUploads.filter(Self.isVideo)
        case "image": list = state.images + state.uploads
        case "audio": list = state.audios + state.mediaUploads.filter(Self.isAudio)
        default: list = state.videos + state.images + state.audios + state.uploads + state.mediaUploads
        }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Was in der aktuellen Ebene liegt: Suche über alles; im Ordner dessen Material; oben das ohne Projektordner.
    private var items: [AssetRecord] {
        if searching {
            let q = search.lowercased()
            return all.filter { Self.label($0).lowercased().contains(q) }
        }
        if let folder { return all.filter { $0.meta["studio_project"]?.stringValue == folder } }
        let projects = Set(model.projects.map(\.id))
        return all.filter { r in r.meta["studio_project"]?.stringValue.map { !projects.contains($0) } ?? true }
    }

    private var inEdit: Set<String> { Set(model.project?.clips.map(\.assetID) ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Filter als vier Knöpfe wie unter Windows (das Segment-Steuerelement wurde je nach Auswahl im Studio
            // breiter als die Spalte und schob sie nach links)
            HStack(spacing: 2) {
                ForEach([("all", t("Alle", "All")), ("image", t("Bilder", "Images")), ("video", t("Videos", "Videos")),
                         ("audio", t("Ton", "Audio"))], id: \.0) { id, label in
                    Button { filter = id; shown = 100 } label: {
                        Text(label).font(.callout).padding(.horizontal, 8).padding(.vertical, 2)
                            .foregroundStyle(filter == id ? Color.primary : Color.secondary)
                            .background(Capsule().strokeBorder(filter == id ? Color.green : .clear, lineWidth: 1.2))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            TextField(t("Suchen (in allen Ordnern) …", "Search (all folders) …"), text: $search).textFieldStyle(.roundedBorder)
            if !searching, let folder {
                HStack(spacing: 4) {
                    Button(t("Material", "Media")) { self.folder = nil; shown = 100 }.buttonStyle(.link)
                    Text("›").foregroundStyle(.secondary)
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.projects.first { $0.id == folder }?.name ?? folder).lineLimit(1)
                }
                .font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !searching && folders {
                        if let from = folder {
                            folderRow("..", id: "..", detail: t("Eine Ebene hoch", "Up one level"),
                                      help: t("Doppelklick: eine Ebene hoch", "Double-click: up one level")) {
                                folder = nil
                                picked = from  // der Ordner, aus dem man kommt, bleibt markiert
                                shown = 100
                            }
                        } else {
                            ForEach(model.projects, id: \.id) { p in
                                let n = all.filter { $0.meta["studio_project"]?.stringValue == p.id }.count
                                folderRow(p.name, id: p.id,
                                          detail: (n == 1 ? t("1 Datei", "1 file") : t("\(n) Dateien", "\(n) files")) + (p.id == model.project?.id ? t(" · offenes Projekt", " · open project") : ""),
                                          help: t("Doppelklick: öffnen", "Double-click: open"),
                                          highlight: p.id == model.project?.id) { open(p.id) }
                            }
                            Text(t("Verlauf", "History")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                    if tiles {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                            ForEach(items.prefix(shown)) { tile($0) }
                        }
                    } else {
                        ForEach(items.prefix(shown)) { row($0) }
                    }
                    if items.isEmpty {
                        Text(searching ? t("Nichts gefunden.", "Nothing found.")
                             : folder != nil ? t("Der Ordner ist leer. Was das Projekt erzeugt, exportiert oder hier hochlädt, landet hier.",
                                                 "The folder is empty. What the project generates, exports or uploads here lands here.")
                             : t("Noch nichts hier.", "Nothing here yet."))
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    if items.count > shown {
                        Button(t("Weitere 100 laden", "Load 100 more")) { shown += 100 }.padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(6)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .audio, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await upload(urls) }
        }
        // Wie unter Windows: das Studio öffnet den Ordner des Projekts, ein Projektwechsel ebenso
        .onAppear { if folder == nil { folder = model.project?.id } }
        .onChange(of: model.project?.id) { _, id in
            folder = id
            picked = nil
            shown = 100
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(t("Material", "Media")).font(.headline)
            Text(verbatim: "\(items.count)").foregroundStyle(.secondary)
            Spacer()
            toggle("list.bullet", on: !tiles, help: t("Liste", "List")) { tiles = false }
            toggle("square.grid.2x2", on: tiles, help: t("Kacheln", "Tiles")) { tiles = true }
            toggle("folder", on: folders, help: folders ? t("Ordner ausblenden: nur das Material des geöffneten Ordners", "Hide folders: only the media of the open folder")
                                                       : t("Ordner einblenden: „..“, die Projektordner und der Verlauf", "Show folders: \"..\", the project folders and the history")) {
                folders.toggle()
            }
            toggle("arrow.up.to.line", on: false, help: folder != nil ? t("Bilder, Videos oder Ton hochladen, in diesen Ordner", "Upload images, videos or audio into this folder")
                                                                     : t("Bilder, Videos oder Ton hochladen, in den allgemeinen Verlauf", "Upload images, videos or audio into the general history")) {
                importing = true
            }
        }
    }

    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20)
                .background(on ? Color.green.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless).help(help)
    }

    private func open(_ id: String) {
        folder = id
        picked = nil
        shown = 100
    }

    /// Ordnerzeile wie in Bin.tsx: Klick markiert, Doppelklick öffnet.
    private func folderRow(_ name: String, id: String, detail: String, help: String, highlight: Bool = false,
                           open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: id == ".." ? "arrow.turn.left.up" : "folder.fill")
                .foregroundStyle(highlight ? .green : .secondary).frame(width: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.caption).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(highlight ? .green : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 3)
        .background(picked == id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded(open).exclusively(before: TapGesture().onEnded { picked = id }))
        .help(help)
        .contextMenu {
            Button(t("Öffnen", "Open"), action: open)
            if id != "..", let dir = folderURL(id) {
                Button(t("Im Finder zeigen", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            }
        }
    }

    /// Die Mac-Fassung hat keine echten Projektordner (die Zuordnung steht am Asset): „Im Finder zeigen“ markiert
    /// die Dateien des Projekts in der Ablage.
    private func folderURL(_ id: String) -> URL? {
        let files = all.filter { $0.meta["studio_project"]?.stringValue == id }.map { AssetStore.shared.fileURL($0.filename) }
        return files.first
    }

    private func facts(_ r: AssetRecord) -> String {
        _ = probed
        let m = model.project?.media[r.id] ?? StudioMediaCache.shared.get(r.id)
        var parts: [String] = []
        if let d = m?.duration { parts.append(formatSeconds(d, digits: 1) + " s") }
        if let w = m?.width ?? r.meta["width"]?.intValue, let h = m?.height ?? r.meta["height"]?.intValue { parts.append("\(w)×\(h)") }
        if searching, let p = r.meta["studio_project"]?.stringValue, let name = model.projects.first(where: { $0.id == p })?.name {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ r: AssetRecord) -> some View {
        HStack(spacing: 6) {
            StudioThumb(assetID: r.id, symbol: Self.symbol(r))
                .frame(width: 48, height: 27).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(r)).font(.caption).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Self.isVideo(r) ? "▶" : Self.isAudio(r) ? "♪" : "▣")
                    Text(facts(r))
                    if inEdit.contains(r.id) { Text("●").foregroundStyle(.green).help(t("im Schnitt", "in the edit")) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            deleteButton(r)
        }
        .padding(.vertical, 2).padding(.horizontal, 3)
        .background(model.mediaID == r.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { model.showSource(r) }
        .draggable(r.id)
        .contextMenu { menu(r) }
        .task(id: r.id) { await probeIfNeeded(r) }
    }

    private func tile(_ r: AssetRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                StudioThumb(assetID: r.id, symbol: Self.symbol(r)).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
                deleteButton(r).padding(2)
            }
            Text(Self.label(r)).font(.caption2).lineLimit(1)
        }
        .padding(2)
        .background(model.mediaID == r.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { model.showSource(r) }
        .draggable(r.id)
        .contextMenu { menu(r) }
        .task(id: r.id) { await probeIfNeeded(r) }
    }

    /// Länge und Größe für Material, das noch keiner vermessen hat (etwa Exporte), einmal nachtragen.
    private func probeIfNeeded(_ r: AssetRecord) async {
        guard Self.isVideo(r) || Self.isAudio(r), model.project?.media[r.id] == nil,
              StudioMediaCache.shared.get(r.id) == nil else { return }
        if let m = try? await StudioMediaProbe.probe(url: AssetStore.shared.fileURL(r.filename)) {
            StudioMediaCache.shared.set(r.id, m)
            probed += 1
        }
    }

    /// ✕ → 4 s „Löschen?“, zweiter Klick löscht; im Schnitt verweigert.
    private func deleteButton(_ r: AssetRecord) -> some View {
        Button {
            if inEdit.contains(r.id) {
                model.notice = t("Liegt im Schnitt: erst den Clip löschen.", "It is in the edit: delete the clip first.")
            } else if armed == r.id {
                Task { await delete(r) }
            } else {
                armed = r.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == r.id { armed = nil } }
            }
        } label: {
            Text(armed == r.id ? t("Löschen?", "Delete?") : "✕").font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(t("Löschen", "Delete"))
    }

    @ViewBuilder private func menu(_ r: AssetRecord) -> some View {
        Button(t("Im Monitor zeigen", "Show in the monitor")) { model.showSource(r) }
        if let p = model.project {
            Menu(t("Auf die Spur legen (am Abspielkopf)", "Send to track (at the playhead)")) {
                ForEach(p.tracks.filter { Self.isAudio(r) ? $0.kind == "audio" : $0.kind == "video" }, id: \.id) { tr in
                    Button(tr.id) {
                        Task {
                            if let res = await model.run("clip.add", ["track": .string(tr.id), "asset_id": .string(r.id), "start": .int(model.playhead)]),
                               let id = res["id"]?.stringValue {
                                model.leaveSource()
                                model.select(.clip, id)
                            }
                        }
                    }
                }
            }
        }
        Button(t("Im Finder zeigen", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(r.filename)]) }
        Button(t("Datei öffnen", "Open file")) { NSWorkspace.shared.open(AssetStore.shared.fileURL(r.filename)) }
        Divider()
        if inEdit.contains(r.id) {
            Button(t("Löschen (im Schnitt)", "Delete (in the edit)")) {}.disabled(true)
        } else {
            Button(t("Löschen …", "Delete …"), role: .destructive) { armed = r.id }
        }
    }

    private func delete(_ r: AssetRecord) async {
        armed = nil
        await AssetStore.shared.delete(r.id)
        if model.mediaID == r.id { model.leaveSource() }
        await state.refresh()
    }

    /// Wie POST /api/upload: Video und Ton prüft AVFoundation, Bilder ImageIO. Landet im offenen Ordner.
    private func upload(_ urls: [URL]) async {
        var added: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            do {
                if AssetStore.mediaSuffixes.contains(url.pathExtension.lowercased()) {
                    let asset = try await AssetStore.shared.addUpload(data: data, originalName: name)
                    do {
                        StudioMediaCache.shared.set(asset.id, try await StudioMediaProbe.probe(url: AssetStore.shared.fileURL(asset.filename)))
                        added.append(asset.id)
                    } catch {
                        await AssetStore.shared.delete(asset.id)
                        model.notice = t("Diese Datei kann NVAI-open für Mac nicht lesen: \(name)", "NVAI-open for Mac cannot read this file: \(name)")
                    }
                } else {
                    _ = try ImageFiles.load(data)
                    added.append(try await AssetStore.shared.addUpload(data: data, originalName: name).id)
                }
            } catch {
                model.notice = error.localizedDescription
            }
        }
        if let folder, !added.isEmpty { await AssetStore.shared.tag(added, project: folder) }
        await state.refresh()
    }
}
