import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Das Studio der Mac-Fassung wie panels/Studio.tsx unter Windows: oben die Leiste, darunter Material | Monitor |
/// Eigenschaften (330 px), ein Teiler, unten die Zeitleisten (Anteil gemerkt, 20–75 %).
struct StudioView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = StudioModel.shared
    @State private var exportPreset = "youtube-1080p"
    @State private var deleteArmed = false
    @AppStorage("studio.split") private var split = 0.44
    @AppStorage("studio.binWidth") private var binWidth = 240.0
    @State private var dragStart: Double?  // Wert eines Teilers zu Beginn des Ziehens

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let notice = model.notice {
                Text(notice).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.yellow.opacity(0.15))
                    .onTapGesture { model.notice = nil }
                    .help(t("Klick schließt", "Click to close"))
            }
            if model.project == nil { start } else { panes }
        }
        .task { await model.start() }
        .onAppear { model.installKeys() }
        .onDisappear {
            model.removeKeys()
            if model.playing { model.togglePlay() }  // anderer Reiter: nicht unsichtbar weiterspielen
        }
        .sheet(isPresented: Binding(get: { model.conformItems != nil }, set: { if !$0 { model.conformItems = nil } })) {
            ConformSheet(model: model)
        }
        // presenting: Die Knöpfe bekommen die Rückfrage mitgegeben, auch wenn das Schließen sie im Modell schon leert
        .confirmationDialog(t("Clip wird länger", "The clip gets longer"),
                            isPresented: Binding(get: { model.collision != nil }, set: { if !$0 { model.collision = nil } }),
                            presenting: model.collision) { c in
            Button(t("Bis zum nächsten Clip", "Up to the next clip")) { c.retry("clamp") }
            Button(t("Nachfolgende verschieben", "Push the later clips")) { c.retry("ripple") }
            Button(t("Überdecken", "Cover them")) { c.retry("overwrite") }
            Button(t("Abbrechen", "Cancel"), role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    // MARK: Startbild und Bereiche

    private var start: some View {
        VStack(spacing: 12) {
            Text("Studio").font(.largeTitle.weight(.semibold))
            Text(t("Ganze Videos aus Szenen: oben komponieren, unten schneiden, mit den Modellen dieses Macs erzeugen.",
                   "Whole videos from scenes: compose at the top, edit below, generate with this Mac's models."))
                .foregroundStyle(.secondary)
            HStack {
                Button(t("+ Neues Projekt", "+ New project")) { Task { await model.newProject() } }.buttonStyle(.borderedProminent).tint(.green)
                Button(t("Projekt importieren …", "Import project …")) { importPackage() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        GeometryReader { geo in
            let timeline = geo.size.height * min(0.75, max(0.2, split))
            let maxBin = max(180, geo.size.width - 330 - 320)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    StudioMaterial(model: model).frame(width: min(maxBin, max(180, binWidth)), alignment: .leading).clipped()
                    // Teiler: Startwert plus Weg in festen Koordinaten (vorher wurde der ganze Weg bei jedem Schritt
                    // erneut addiert bzw. mit dem wandernden Teiler gemessen)
                    splitter(vertical: true)
                        .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                            let start = dragStart ?? min(maxBin, max(180, binWidth))
                            dragStart = start
                            binWidth = min(maxBin, max(180, start + g.translation.width))
                        }.onEnded { _ in dragStart = nil })
                        .onTapGesture(count: 2) { binWidth = 240 }
                    StudioMonitor(model: model).frame(maxWidth: .infinity)
                    Divider()
                    StudioInspector(model: model).frame(width: 330)
                }
                .frame(height: geo.size.height - timeline - 6)
                splitter(vertical: false)
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                        let start = dragStart ?? min(0.75, max(0.2, split))
                        dragStart = start
                        split = min(0.75, max(0.2, start - Double(g.translation.height / max(1, geo.size.height))))
                    }.onEnded { _ in dragStart = nil })
                StudioTimeline(model: model).frame(height: timeline)
            }
        }
    }

    private func splitter(vertical: Bool) -> some View {
        Rectangle().fill(Color.secondary.opacity(0.18))
            .frame(width: vertical ? 5 : nil, height: vertical ? nil : 6)
            .pointerStyle(vertical ? .columnResize : .rowResize)
    }

    // MARK: Leiste (Reihenfolge wie unter Windows, bündig)

    /// Volle Leiste; reicht die Breite nicht, die kompakte (Symbole statt Wörter), notfalls seitlich verschiebbar.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbar(compact: false)
            toolbar(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { toolbar(compact: true) }
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { model.project?.id ?? "" }, set: { id in
                if id == model.project?.id { model.clearSelection() } else { Task { await model.open(id) } }
            })) {
                if model.project == nil { Text(t("– Projekt –", "– project –")).tag("") }
                // Die Auswahl wächst nicht auf eine feste Breite (sie stünde mittig mit Lücken): so breit wie der
                // längste Name, lange Namen gekürzt
                ForEach(model.projects, id: \.id) { p in
                    Text(verbatim: p.name.count > (compact ? 18 : 28) ? String(p.name.prefix(compact ? 17 : 27)) + "…" : p.name).tag(p.id)
                }
            }
            .labelsHidden().fixedSize()
            .help(model.project?.name ?? t("Projekt wählen", "Choose a project"))
            .simultaneousGesture(TapGesture().onEnded { model.clearSelection() })
            Menu {
                Button(t("Neues Projekt", "New project")) { Task { await model.newProject() } }
                Menu(t("Projekt exportieren", "Export project")) {
                    if let p = model.project {
                        let info = StudioPackage.info(p)
                        Button(t("Mit Material (.zip, \(size(info.bytes)))", "With media (.zip, \(size(info.bytes)))")) { exportPackage(p) }
                        Button(t("Mit verlustfreien Kopien (gibt es auf dem Mac nicht)", "With lossless copies (not on the Mac)")) {}.disabled(true)
                    }
                }
                .disabled(model.project == nil)
                Button(t("Projekt importieren …", "Import project …")) { importPackage() }
            } label: { Image(systemName: "plus") }
                .menuIndicator(.visible).fixedSize()
                .help(t("Neues Projekt, Projekt exportieren oder importieren", "New project, export or import a project"))
            Button {
                if deleteArmed {
                    deleteArmed = false
                    Task { await model.deleteProject() }
                } else {
                    deleteArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { deleteArmed = false }
                }
            } label: {
                if deleteArmed { Text(t("Wirklich löschen?", "Really delete?")) }
                else if compact { Image(systemName: "trash") }
                else { Text(t("Löschen", "Delete")) }
            }
            .fixedSize()
            .foregroundStyle(deleteArmed ? Color.red : Color.primary)
            .disabled(model.project == nil)
            .help(t("Projekt in den Papierkorb (zweiter Klick bestätigt)", "Move the project to the trash (a second click confirms)"))
            separator
            Button { Task { await model.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(model.undoCount == 0).help(t("Rückgängig (⌘Z)", "Undo (⌘Z)"))
            Button { Task { await model.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(model.redoCount == 0).help(t("Wiederholen (⇧⌘Z)", "Redo (⇧⌘Z)"))
            separator
            Button((compact ? t("Erzeugen", "Generate") : t("Szenen erzeugen", "Generate scenes"))
                   + (model.busyScenes > 0 ? " (\(model.busyScenes))" : "")) {
                Task { await model.generate() }
            }
            .buttonStyle(.borderedProminent).tint(.green).fixedSize()
            .help(t("Erzeugt alle Szenen ohne Take mit den Modellen dieses Macs", "Generates every scene without a take with this Mac's models"))
            Button(t("Übernehmen ↓", "Conform ↓")) { Task { await model.conform() } }
                .fixedSize()
                .help(t("Legt die gewählten Takes in den Schnitt", "Puts the chosen takes into the edit"))
            Menu(compact ? "+ ◆" : t("+ Marker", "+ Marker")) {
                ForEach(Studio.markerKinds, id: \.self) { kind in
                    Button(StudioInspector.markerName(kind)) { Task { await model.addMarker(kind) } }
                }
            }
            .fixedSize()
            .help(t("Marker am Abspielkopf (M: Notiz)", "Marker at the playhead (M: note)"))
            separator
            Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                .help(t("Abspielen (Leertaste)", "Play (space)"))
            Button { model.pxPerSecond = max(4, model.pxPerSecond * 0.8) } label: { Image(systemName: "minus") }
                .help(t("Verkleinern (-)", "Zoom out (-)"))
            Button { model.pxPerSecond = min(400, model.pxPerSecond * 1.25) } label: { Image(systemName: "plus") }
                .help(t("Vergrößern (+)", "Zoom in (+)"))
            separator
            Picker("", selection: $exportPreset) {
                ForEach(StudioRender.presets, id: \.id) { pr in Text(Lang.current == .de ? pr.label.de : pr.label.en).tag(pr.id) }
            }
            .labelsHidden().frame(width: compact ? 150 : 190)
            Button(t("Exportieren", "Export")) { Task { await model.export(exportPreset) } }
                .buttonStyle(.borderedProminent).tint(.green).fixedSize()
                .disabled(model.project?.clips.isEmpty ?? true || exporting)
            exportStatus
            Spacer(minLength: 8)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                if compact { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                else { Label(t("Vollbild", "Full screen"), systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            .fixedSize()
            .help(t("Vollbild", "Full screen"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var separator: some View { Divider().frame(height: 18).padding(.horizontal, 2) }

    private var exporting: Bool { ["queued", "running"].contains(model.exportJob?.status ?? "") }

    /// Exportstand: „NN % · Stufe“, fertig ein Verweis, bei Fehler rot.
    @ViewBuilder private var exportStatus: some View {
        if let job = model.exportJob {
            switch job.status {
            case "queued", "running":
                Text("\(Int((job.progress * 100).rounded())) % · \(job.stage)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case "done":
                Button(t("Fertig – ansehen (auch im Projektordner)", "Done – view (also in the project folder)")) {
                    if let id = job.assetIDs.first, let r = AssetSnapshot.shared.get(id) {
                        NSWorkspace.shared.open(AssetStore.shared.fileURL(r.filename))
                    }
                }
                .buttonStyle(.link).font(.caption)
            case "error":
                Text(job.error ?? t("Export fehlgeschlagen", "Export failed")).font(.caption).foregroundStyle(.red).lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading).help(job.error ?? "")
            default:
                EmptyView()
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    // MARK: Pakete

    private func exportPackage(_ p: StudioProject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = StudioPackage.fileName(p)
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.notice = t("Das Paket wird gebaut …", "The package is being built …")
        Task.detached {
            do {
                try StudioPackage.build(p, to: url)
                await MainActor.run { StudioModel.shared.notice = t("Paket gespeichert: \(url.lastPathComponent)", "Package saved: \(url.lastPathComponent)") }
            } catch {
                await MainActor.run { StudioModel.shared.notice = error.localizedDescription }
            }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.notice = t("„\(url.lastPathComponent)“ wird importiert …", "Importing \"\(url.lastPathComponent)\" …")
        Task {
            do {
                let p = try await StudioPackage.importFile(url, store: model.store)
                await state.refresh()
                await model.reloadList()
                await model.open(p.id)
                model.notice = t("Importiert als „\(p.name)“.", "Imported as \"\(p.name)\".")
            } catch {
                model.notice = error.localizedDescription
            }
        }
    }
}

/// „Komposition in den Schnitt übernehmen“ wie ConformDialog.tsx: neue Clips und ausgetauschtes Material mit Häkchen.
struct ConformSheet: View {
    @ObservedObject var model: StudioModel
    @State private var checked: Set<String> = []

    private var items: [JSONValue] { model.conformItems ?? [] }

    var body: some View {
        let creates = items.filter { $0["action"]?.stringValue == "create" }
        let replaces = items.filter { $0["action"]?.stringValue == "replace" }
        let errors = items.filter { $0["action"]?.stringValue == "error" }
        let same = items.filter { $0["action"]?.stringValue == "same" }.count
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Komposition in den Schnitt übernehmen", "Conform the composition into the edit")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !creates.isEmpty {
                        Text(t("Neue Clips", "New clips")).font(.subheadline.weight(.semibold))
                        ForEach(creates.indices, id: \.self) { i in line(creates[i]) }
                    }
                    if !replaces.isEmpty {
                        Text(t("Neuer Take für Clips im Schnitt (überschreiben?)", "New take for clips in the edit (overwrite?)"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(replaces.indices, id: \.self) { i in line(replaces[i]) }
                    }
                    ForEach(errors.indices, id: \.self) { i in
                        Text("\(errors[i]["title"]?.stringValue ?? ""): \(errors[i]["error"]?.stringValue ?? "")").font(.caption).foregroundStyle(.red)
                    }
                    let without = model.conformSummary["without_take"]?.intValue ?? 0
                    let markers = model.conformSummary["transition_markers"]?.intValue ?? 0
                    Text([same > 0 ? t("\(same) Clip(s) passen schon.", "\(same) clip(s) already match.") : nil,
                          without > 0 ? t("\(without) Szene(n) ohne Take bleiben weg.", "\(without) scene(s) without a take are left out.") : nil,
                          markers > 0 ? t("\(markers) Übergang-Marker werden angewendet.", "\(markers) transition marker(s) are applied.") : nil]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Spacer()
                Button(t("Abbrechen", "Cancel"), role: .cancel) { model.conformItems = nil }
                Button(t("Übernehmen (\(checked.count) gewählt)", "Conform (\(checked.count) checked)")) {
                    let overwrite = items.filter { i in
                        guard let id = i["scene_id"]?.stringValue, checked.contains(id) else { return false }
                        return !(i["overlaps"]?.arrayValue ?? []).isEmpty
                    }.compactMap { $0["scene_id"]?.stringValue }
                    let scenes = Array(checked)
                    model.conformItems = nil
                    Task { await model.conform(scenes: scenes, overwrite: overwrite) }
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            checked = Set(items.filter { $0["default"]?.boolValue == true }.compactMap { $0["scene_id"]?.stringValue })
        }
    }

    private func line(_ item: JSONValue) -> some View {
        let id = item["scene_id"]?.stringValue ?? ""
        let overlaps = item["overlaps"]?.arrayValue ?? []
        let warned = !overlaps.isEmpty || item["in_edit"]?.boolValue == true
        var text = "\(item["title"]?.stringValue ?? "") · \(item["track"]?.stringValue ?? "") · "
            + formatDecimal(item["start_s"]?.doubleValue ?? 0) + " s · " + formatDecimal(item["length_s"]?.doubleValue ?? 0) + " s"
        if let o = overlaps.first {
            text += t(" · würde überdecken: „\(o["title"]?.stringValue ?? "")“ (\(formatDecimal(o["seconds"]?.doubleValue ?? 0)) s) – das Häkchen erlaubt das Überschreiben",
                      " · would cover: \"\(o["title"]?.stringValue ?? "")\" (\(formatDecimal(o["seconds"]?.doubleValue ?? 0)) s) – the tick allows overwriting")
        }
        if item["in_edit"]?.boolValue == true { text += t(" · dieser Take liegt schon im Schnitt", " · this take is already in the edit") }
        if item["action"]?.stringValue == "replace" {
            text += item["edited"]?.boolValue == true
                ? t(" · von dir geschnitten: der Schnitt bleibt, das Material wird getauscht", " · cut by you: the cut stays, the material is swapped")
                : t(" · unverändert: bekommt den neuen Take", " · unchanged: gets the new take")
        }
        return Toggle(isOn: Binding(get: { checked.contains(id) }, set: { if $0 { checked.insert(id) } else { checked.remove(id) } })) {
            Text(text).font(.caption).foregroundStyle(warned ? Color.orange : Color.primary)
        }
    }
}
