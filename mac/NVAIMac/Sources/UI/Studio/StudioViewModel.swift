import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// Zustand der Studio-Oberfläche wie in panels/Studio.tsx unter Windows: offenes Projekt, Auswahl (eine Art, wahlweise
/// mehrere), Zwischenablage, Werkzeug, Magnet, Abspielkopf, Zoom, Exportstand. Jede Änderung ist ein Befehl an den
/// StudioStore; Änderungen von außen (Claude per REST, fertige Aufträge) kommen über onChange.
@MainActor
final class StudioModel: ObservableObject {
    static let shared = StudioModel()

    enum Tool: String { case select, razor, scale }
    enum Kind: String { case scene, clip, marker, transition, media }

    @Published var projects: [(id: String, name: String)] = []
    @Published var project: StudioProject?
    @Published var undoCount = 0
    @Published var redoCount = 0
    /// Auswahl: immer nur eine Art (Szene, Clip, Marker, Übergang = Clip-ID, Material), wahlweise mehrere davon.
    @Published var kind: Kind?
    @Published var selected: Set<String> = []
    @Published var playhead = 0  // Ticks
    @Published var pxPerSecond = UserDefaults.standard.object(forKey: "studio.zoom") as? Double ?? 40 {
        didSet { UserDefaults.standard.set(pxPerSecond, forKey: "studio.zoom") }
    }
    @Published var notice: String?
    @Published var playing = false
    @Published var tool: Tool = .select
    /// Magnet (S): Ziehen rastet an 0, Abspielkopf, Szenen- und Clipkanten und Markern ein (9 px); aus: Umschalttaste.
    @Published var magnet = UserDefaults.standard.object(forKey: "studio.magnet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(magnet, forKey: "studio.magnet") }
    }
    @Published var shiftHeld = false
    /// Weiße Linie, solange ein Ziehen an einem Rastpunkt hängt.
    @Published var snapLine: Int?
    /// Wo die Maus über der Zeitleiste steht (für „hier“ in den Rechtsklick-Menüs und die Schnittlinie).
    @Published var hoverTicks = 0
    @Published var hoverTrack: String?
    /// Exportstand in der Leiste.
    @Published var exportJob: JobRecord?
    @Published var conformItems: [JSONValue]?
    @Published var conformSummary: [String: JSONValue] = [:]
    /// Tempo-Rückfrage: Meldung und Wiederholen mit overlap.
    @Published var collision: (message: String, retry: (String) -> Void)?
    /// Versatz einer gezogenen Gruppe (Szenen, Clips, Marker) bis zum Loslassen.
    @Published var groupDrag: CGFloat = 0
    @Published var groupDragY: CGFloat = 0
    /// Quellansicht: der Monitor zeigt ein Material statt des Schnitts (Klick in der Materialliste, Esc zurück).
    @Published var source: AssetRecord?

    private(set) var clipboard: (kind: Kind, items: [JSONValue], cut: Bool)?

    let store = StudioStore.shared
    let preview = StudioPreview()
    private var started = false
    private var poll: Task<Void, Never>?
    private var exportPoll: Task<Void, Never>?
    private var keyMonitor: Any?
    /// Eingaben in den Eigenschaften, die noch nicht gespeichert sind (ein Feld übernimmt erst bei Enter oder beim
    /// Verlassen; ein Klick auf einen Knopf nimmt ihm auf dem Mac den Fokus nicht), und laufende Befehle.
    private var pendingEdits: [UUID: () -> Void] = [:]
    private var inflight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var fps: Double { project.map { Double($0.settings.fps[0]) / Double($0.settings.fps[1]) } ?? 24 }
    var snapping: Bool { magnet != shiftHeld }
    var busyScenes: Int { project?.scenes.filter { !$0.jobs.isEmpty || $0.waitingFor != nil }.count ?? 0 }

    // MARK: Projekt

    func start() async {
        guard !started else { return }
        started = true
        await store.setOnChange { p in Task { @MainActor in StudioModel.shared.changed(p) } }
        await reloadList()
        let last = UserDefaults.standard.string(forKey: "studio.project") ?? ""
        if let id = projects.first(where: { $0.id == last })?.id ?? projects.first?.id {
            await open(id)
        }
        watchExports()
    }

    private func changed(_ p: StudioProject) {
        if p.id == project?.id {
            if p.updatedAt != project?.updatedAt {
                project = p
                prune()
                preview.invalidate()
                showFrame()
            }
            Task { await updateHistory() }
        } else if project == nil {
            Task { await open(p.id) }  // wie unter Windows: ein neues Projekt öffnet sich, wenn keins offen ist
        }
        Task { await reloadList() }
        watchJobs()
    }

    func reloadList() async {
        projects = await store.list().compactMap { v in
            guard let id = v["id"]?.stringValue else { return nil }
            return (id, v["name"]?.stringValue ?? id)
        }
    }

    private func updateHistory() async {
        guard let id = project?.id else { return }
        let h = await store.history(id)
        undoCount = h.undo
        redoCount = h.redo
    }

    func open(_ id: String) async {
        do {
            let p = try await StudioGenerator.shared.refresh(store, id)
            project = p
            UserDefaults.standard.set(id, forKey: "studio.project")
            clearSelection()
            playhead = 0
            preview.invalidate()
            await updateHistory()
            showFrame()
            watchJobs()
        } catch {
            notice = error.localizedDescription
        }
    }

    func newProject() async {
        do {
            let p = try await store.create()
            await reloadList()
            await open(p.id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func deleteProject() async {
        guard let id = project?.id else { return }
        do {
            try await store.delete(id)
            project = nil
            await reloadList()
            if let first = projects.first { await open(first.id) }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Befehl ausführen; Fehler erscheinen in der Hinweisleiste.
    @discardableResult
    func registerEdit(_ token: UUID, _ flush: (() -> Void)?) { pendingEdits[token] = flush }

    /// Offene Eingaben übernehmen und warten, bis alle Befehle gespeichert sind: vor Erzeugen, Übernehmen und Export
    /// (sonst lief „Erzeugen“ direkt nach dem Tippen mit dem alten Prompt).
    func commitEdits() async {
        let flushes = Array(pendingEdits.values)
        pendingEdits.removeAll()
        flushes.forEach { $0() }
        await Task.yield()  // die eben angestoßenen Befehle beginnen (Hauptthread, der Reihe nach)
        while inflight > 0 { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    func run(_ command: String, _ params: StudioParams = [:]) async -> JSONValue? {
        guard let id = project?.id else { return nil }
        inflight += 1
        defer {
            inflight -= 1
            if inflight == 0 {
                idleWaiters.forEach { $0.resume() }
                idleWaiters.removeAll()
            }
        }
        do {
            let (p, result) = try await store.apply(id, command, params)
            project = p
            prune()
            notice = nil
            await updateHistory()
            return result
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Mehrere Befehle als ein Schritt im Rückgängig.
    @discardableResult
    func batch(_ commands: [(String, StudioParams)]) async -> [JSONValue]? {
        guard !commands.isEmpty else { return [] }
        if commands.count == 1 { return await run(commands[0].0, commands[0].1).map { [$0] } }
        let list: [JSONValue] = commands.map { .object(["command": .string($0.0), "params": .object($0.1)]) }
        return await run("batch", ["commands": .array(list)])?["results"]?.arrayValue
    }

    func undo() async {
        guard let id = project?.id else { return }
        do { project = try await store.undo(id); prune(); await updateHistory() } catch { notice = error.localizedDescription }
    }

    func redo() async {
        guard let id = project?.id else { return }
        do { project = try await store.redo(id); prune(); await updateHistory() } catch { notice = error.localizedDescription }
    }

    // MARK: Erzeugen, Übernehmen, Export

    func generate(_ sceneIDs: [String]? = nil) async {
        await commitEdits()
        guard let id = project?.id else { return }
        if sceneIDs == nil, let p = project, !p.scenes.contains(where: { $0.take == nil && $0.jobs.isEmpty && $0.waitingFor == nil }) {
            notice = t("Alle Szenen haben schon einen Take. Eine Szene auswählen, um sie neu zu erzeugen.",
                       "Every scene already has a take. Select a scene to generate it again.")
            return
        }
        do {
            let result = try await StudioGenerator.shared.generate(store, id, sceneIDs: sceneIDs)
            let jobs = result["jobs"]?.objectValue?.count ?? 0
            let waiting = result["waiting"]?.objectValue?.count ?? 0
            let errors = (result["errors"]?.objectValue ?? [:]).values.compactMap(\.stringValue)
            var text = t("\(jobs) Szene(n) abgeschickt. Fertige erscheinen als Takes.", "\(jobs) scene(s) queued. Finished ones appear as takes.")
            if waiting > 0 { text += " " + t("\(waiting) Anschluss-Szene(n) folgen danach.", "\(waiting) chained scene(s) follow afterwards.") }
            if !errors.isEmpty {
                text = t("\(jobs) abgeschickt, \(errors.count) nicht: ", "\(jobs) queued, \(errors.count) not: ") + errors.joined(separator: " · ")
            }
            notice = text
            project = try await store.load(id)
            watchJobs()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// „Übernehmen ↓“: erst der Plan; nichts zu entscheiden → sofort, sonst der Dialog (wie ConformDialog.tsx).
    func conform() async {
        await commitEdits()
        guard let id = project?.id else { return }
        do {
            let p = try await StudioGenerator.shared.refresh(store, id)
            await StudioMediaProbe.prefetch(StudioMediaProbe.referencedAssets([:], p))
            let plan = StudioCommands.conformPlan(p, store.env)
            let items = plan["items"]?.arrayValue ?? []
            let attention = items.contains { i in
                let action = i["action"]?.stringValue
                return action == "replace" || action == "error"
                    || !(i["overlaps"]?.arrayValue ?? []).isEmpty || i["in_edit"]?.boolValue == true
            }
            if attention {
                conformSummary = plan.objectValue ?? [:]
                conformItems = items
            } else {
                await conform(scenes: nil, overwrite: [])
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func conform(scenes: [String]?, overwrite: [String]) async {
        var params: StudioParams = ["overwrite": .array(overwrite.map(JSONValue.string))]
        if let scenes { params["scenes"] = .array(scenes.map(JSONValue.string)) }
        if let r = await run("edit.conform", params) {
            let skipped = r["skipped"]?.arrayValue?.count ?? 0
            notice = t("Übernommen: \(r["created"]?.intValue ?? 0) neu, \(r["updated"]?.intValue ?? 0) ersetzt, \(r["transitions"]?.intValue ?? 0) Übergänge.",
                       "Conformed: \(r["created"]?.intValue ?? 0) new, \(r["updated"]?.intValue ?? 0) replaced, \(r["transitions"]?.intValue ?? 0) transition(s).")
                + (skipped > 0 ? t(" \(skipped) ausgelassen.", " \(skipped) skipped.") : "")
        }
    }

    func export(_ preset: String) async {
        await commitEdits()
        guard let p = project, !p.clips.isEmpty else {
            notice = t("Der Schnitt ist leer: erst Szenen übernehmen oder Clips anlegen.", "The edit is empty: conform scenes or add clips first.")
            return
        }
        exportJob = await JobQueue.shared.submitStudioExport(StudioExportRequest(projectID: p.id, preset: preset))
    }

    /// Exportstand in der Leiste, auch für Exporte, die Claude per REST/MCP gestartet hat.
    private func watchExports() {
        exportPoll?.cancel()
        exportPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let pid = self.project?.id else { continue }
                let jobs = await JobQueue.shared.list(limit: 60)
                let mine = jobs.filter { $0.kind == "studio_export" && $0.params["project_id"]?.stringValue == pid }
                    .max { $0.createdAt < $1.createdAt }
                if let mine, mine.id != self.exportJob?.id || mine.status != self.exportJob?.status
                    || abs(mine.progress - (self.exportJob?.progress ?? -1)) > 0.004 {
                    self.exportJob = mine
                }
            }
        }
    }

    /// Solange Szenen erzeugt werden: alle 2 s fertige Aufträge als Takes eintragen.
    private func watchJobs() {
        guard poll == nil, busyScenes > 0 else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let id = self.project?.id else { break }
                let p = try? await StudioGenerator.shared.refresh(self.store, id)
                if let p, !p.scenes.contains(where: { !$0.jobs.isEmpty || $0.waitingFor != nil }) { break }
            }
            self?.poll = nil
        }
    }

    // MARK: Auswahl

    func isSelected(_ kind: Kind, _ id: String) -> Bool { self.kind == kind && selected.contains(id) }

    /// Klick wählt; mit Umschalt/Cmd hinzu oder weg; Klick auf ein Mitglied einer Gruppe behält die Gruppe.
    func select(_ kind: Kind, _ id: String, additive: Bool = false) {
        if kind != .media { source = nil }  // wie unter Windows: die Quelle nur, solange Material gewählt ist
        if additive, self.kind == kind {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            if selected.isEmpty { self.kind = nil }
            return
        }
        if self.kind == kind, selected.contains(id), selected.count > 1 { return }
        self.kind = kind
        selected = [id]
    }

    func select(_ kind: Kind, _ ids: Set<String>) {
        if kind != .media { source = nil }
        self.kind = ids.isEmpty ? nil : kind
        selected = ids
    }

    func clearSelection() {
        kind = nil
        selected = []
        source = nil
    }

    /// Für das Selbstfoto: per ID auswählen (cl_ Clip, sc_ Szene, mk_ Marker, ast_ Material als Quelle).
    func snapshotSelect(_ id: String) {
        if id.hasPrefix("ast_"), let r = AssetSnapshot.shared.get(id) {
            showSource(r)
        } else if let kind: Kind = id.hasPrefix("cl_") ? .clip : id.hasPrefix("sc_") ? .scene : id.hasPrefix("mk_") ? .marker : nil {
            select(kind, id)
        }
    }

    /// Ausgewähltes, das es nicht mehr gibt, fällt aus der Auswahl.
    private func prune() {
        guard let p = project, let kind else { return }
        let alive: Set<String>
        switch kind {
        case .scene: alive = Set(p.scenes.map(\.id))
        case .clip: alive = Set(p.clips.map(\.id))
        case .marker: alive = Set(p.markers.map(\.id))
        case .transition: alive = Set(p.clips.filter { $0.transition != nil }.map(\.id))
        case .media: return
        }
        selected.formIntersection(alive)
        if selected.isEmpty { self.kind = nil }
    }

    var scene: StudioScene? { kind == .scene && selected.count == 1 ? project?.scenes.first { $0.id == selected.first } : nil }
    var clip: StudioClip? { kind == .clip && selected.count == 1 ? project?.clips.first { $0.id == selected.first } : nil }
    var marker: StudioMarker? { kind == .marker && selected.count == 1 ? project?.markers.first { $0.id == selected.first } : nil }
    var transitionClip: StudioClip? { kind == .transition ? project?.clips.first { $0.id == selected.first } : nil }
    var mediaID: String? { kind == .media ? selected.first : nil }

    /// Alle Objekte einer Art, die ein Befehl über das Menü treffen soll: die Gruppe, wenn `id` dazugehört.
    func targets(_ kind: Kind, _ id: String) -> [String] {
        isSelected(kind, id) ? Array(selected) : [id]
    }

    // MARK: Zwischenablage (eine Art)

    var pasteCount: Int { clipboard?.items.count ?? 0 }

    func copy(cut: Bool = false) async {
        guard let p = project, let kind, !selected.isEmpty else { return }
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T) -> JSONValue { (try? encoder.encode(v)).flatMap { JSON.parse($0) } ?? .null }
        switch kind {
        case .clip:
            clipboard = (.clip, p.clips.filter { selected.contains($0.id) }.map(json), cut)
            if cut { await run("clip.delete", ["ids": .array(selected.map(JSONValue.string))]) }
        case .scene:
            clipboard = (.scene, p.scenes.filter { selected.contains($0.id) }.map(json), cut)
            if cut { await batch(selected.map { ("scene.delete", ["id": .string($0)]) }) }
        case .marker:
            clipboard = (.marker, p.markers.filter { selected.contains($0.id) }.map(json), cut)
            if cut { await batch(selected.map { ("marker.delete", ["id": .string($0)]) }) }
        default:
            return
        }
        if cut { clearSelection() }
    }

    /// Einfügen am Abspielkopf (oder `at`): Clips auf ihre Spuren, mit allem; Szenen mit allen Feldern; Marker.
    func paste(at: Int? = nil) async {
        guard let p = project, let board = clipboard, !board.items.isEmpty else { return }
        let at = at ?? playhead
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ v: JSONValue, _ type: T.Type) -> T? { try? decoder.decode(type, from: JSON.data(v.any)) }
        switch board.kind {
        case .clip:
            let clips = board.items.compactMap { decode($0, StudioClip.self) }
            guard let first = clips.map(\.start).min() else { return }
            let commands: [(String, StudioParams)] = clips.map { c in
                let kind = c.track.hasPrefix("V") ? "video" : "audio"
                var params: StudioParams = [
                    "track": .string(p.trackOrHighest(c.track, kind: kind)), "asset_id": .string(c.assetID),
                    "start": .int(at + c.start - first), "in": .int(c.inPoint), "out": .int(c.outPoint),
                    "speed": .double(c.speed), "gain_db": .double(c.gainDB), "muted": .bool(c.muted)]
                if let tr = c.transition { params["transition"] = .object(["kind": .string(tr.kind), "duration": .int(tr.duration)]) }
                if kind == "video" {
                    if let s = c.scale { params["scale"] = .double(s) }
                    if let a = c.anchor { params["anchor"] = .array(a.map(JSONValue.double)) }
                    if let k = c.scaleKeys { params["scale_keys"] = .array(k.map { .object(["at": .int($0.at), "value": .double($0.value)]) }) }
                }
                if board.cut, let scene = c.sceneID { params["scene_id"] = .string(scene) }
                return ("clip.add", params)
            }
            if let results = await batch(commands) {
                let ids = Set(results.compactMap { $0["id"]?.stringValue })
                select(.clip, ids)
                if let end = project?.clips.filter({ ids.contains($0.id) }).map(\.end).max() { seek(end) }
            }
        case .scene:
            let scenes = board.items.compactMap { decode($0, StudioScene.self) }
            guard let first = scenes.map(\.start).min() else { return }
            let commands: [(String, StudioParams)] = scenes.map { s in
                var params: StudioParams = [
                    "lane": .string(s.lane), "start": .int(at + s.start - first), "duration": .int(s.duration),
                    "title": .string(s.title), "prompt": .string(s.prompt), "kind": .string(s.kind),
                    "lyrics": .string(s.lyrics), "params": .object(s.params), "takes": .array(s.takes.map(JSONValue.string))]
                if let m = s.modelID { params["model_id"] = .string(m) }
                if let take = s.take { params["take"] = .string(take) }
                return ("scene.add", params)
            }
            if let results = await batch(commands) { select(.scene, Set(results.compactMap { $0["id"]?.stringValue })) }
        case .marker:
            let markers = board.items.compactMap { decode($0, StudioMarker.self) }
            guard let first = markers.map(\.at).min() else { return }
            let commands: [(String, StudioParams)] = markers.map { m in
                ("marker.add", ["at": .int(at + m.at - first), "kind": .string(m.kind), "name": .string(m.name),
                                "comment": .string(m.comment), "color": .string(m.color), "duration": .int(m.duration),
                                "params": .object(m.params)])
            }
            if let results = await batch(commands) { select(.marker, Set(results.compactMap { $0["id"]?.stringValue })) }
        default:
            return
        }
    }

    // MARK: Schnitt-Aktionen (Menüs und Tastatur)

    /// Löschen der Auswahl; `ripple` schließt bei Clips die Lücken.
    func deleteSelection(ripple: Bool = false) async {
        guard let kind, !selected.isEmpty else { return }
        let ids = Array(selected)
        switch kind {
        case .clip: await run("clip.delete", ["ids": .array(ids.map(JSONValue.string)), "ripple": .bool(ripple)])
        case .scene: await batch(ids.map { ("scene.delete", ["id": .string($0)]) })
        case .marker: await batch(ids.map { ("marker.delete", ["id": .string($0)]) })
        case .transition: await batch(ids.map { ("clip.update", ["id": .string($0), "transition": .null]) })
        case .media: return
        }
        clearSelection()
    }

    /// ⌘K: am Abspielkopf schneiden, nur auf den Spuren der gewählten Clips, sonst auf allen.
    func razorAtPlayhead() async {
        guard let p = project else { return }
        let tracks = kind == .clip ? Set(p.clips.filter { selected.contains($0.id) }.map(\.track)) : []
        if tracks.isEmpty {
            await run("clip.razor", ["at": .int(playhead)])
        } else {
            await batch(tracks.sorted().map { ("clip.razor", ["at": .int(playhead), "track": .string($0)]) })
        }
    }

    /// ⌘D: 0,5 s Überblendung auf die gewählten Clips, sonst auf den Schnitt ±0,5 s um den Abspielkopf.
    func dissolve() async {
        guard let p = project else { return }
        let transition: JSONValue = .object(["kind": .string("dissolve"), "duration_s": .double(0.5)])
        if kind == .clip, !selected.isEmpty {
            await batch(selected.map { ("clip.update", ["id": .string($0), "transition": transition]) })
            return
        }
        let half = Studio.ticks(0.5)
        if let c = p.clips.filter({ $0.track.hasPrefix("V") && $0.start > 0 && abs($0.start - playhead) <= half })
            .min(by: { StudioTrack.number($0.track) < StudioTrack.number($1.track) }) {
            await run("clip.update", ["id": .string(c.id), "transition": transition])
        } else {
            notice = t("Kein Schnitt in der Nähe des Abspielkopfs.", "No cut near the playhead.")
        }
    }

    func addMarker(_ kind: String, at: Int? = nil) async {
        if let r = await run("marker.add", ["at": .int(at ?? playhead), "kind": .string(kind)]), let id = r["id"]?.stringValue {
            select(.marker, id)
        }
    }

    /// Tempo setzen; stößt der längere Clip an spätere derselben Spur, erst fragen (wie Studio.tsx).
    func setSpeed(_ ids: [String], _ speed: Double, overlap: String? = nil) async {
        guard let id = ids.first, let p = project, let c = p.clips.first(where: { $0.id == id }) else { return }
        var params: StudioParams = ["id": .string(id), "speed": .double(speed)]
        if let overlap {
            params["overlap"] = .string(overlap)
        } else {
            var longer = c
            longer.speed = speed
            let hit = p.clips.filter { $0.id != c.id && $0.track == c.track && $0.start >= c.start && $0.start < longer.end }
            if longer.end > c.end, !hit.isEmpty {
                let names = hit.prefix(3).map { StudioCommands.clipLabel(p, $0, StudioMediaProbe.environment) }
                let pct = Int((speed * 100).rounded())
                let s = formatSeconds(longer.end - c.end, digits: 2)
                collision = (t("Mit \(pct) % wird der Clip \(s) s länger und stößt an \(names.map { "„\($0)“" }.joined(separator: ", ")).",
                               "At \(pct) % the clip becomes \(s) s longer and runs into \(names.map { "\"\($0)\"" }.joined(separator: ", "))."),
                             { [weak self] choice in Task { await self?.setSpeed(ids, speed, overlap: choice) } })
                return
            }
        }
        await run("clip.update", params)
    }

    // MARK: Quellansicht

    func showSource(_ record: AssetRecord) {
        if playing { togglePlay() }
        source = record
        kind = .media
        selected = [record.id]
    }

    func leaveSource() {
        source = nil
        if kind == .media { clearSelection() }
    }

    // MARK: Abspielen

    func seek(_ ticks: Int) {
        if playing { togglePlay() }
        playhead = max(0, ticks)
        showFrame()
    }

    func showFrame() {
        guard let p = project, !playing else { return }
        preview.show(p, at: Studio.seconds(playhead))
    }

    func togglePlay() {
        guard let p = project else { return }
        if playing {
            preview.stop()
            playing = false
            return
        }
        if source != nil { leaveSource() }  // abgespielt wird der Schnitt, nicht die Quelle
        playing = true
        preview.play(p, from: Studio.seconds(playhead)) { [weak self] seconds, ended in
            guard let self else { return }
            self.playhead = Studio.ticks(seconds)
            if ended { self.playing = false }
        }
    }

    // MARK: Zeit und Rasten

    func ticks(atX x: Double) -> Int { max(0, Studio.ticks(x / pxPerSecond)) }
    func x(_ ticks: Int) -> Double { Studio.seconds(ticks) * pxPerSecond }
    func roundFrame(_ ticks: Int) -> Int {
        guard let f = project?.frameTicks else { return max(0, ticks) }
        return max(0, Int((Double(ticks) / Double(f)).rounded()) * f)
    }

    /// Rastpunkte: 0, Abspielkopf, Anfang und Ende aller Szenen und Clips, Marker; `excluding` sind die gezogenen.
    func snapPoints(excluding: Set<String>, playhead withPlayhead: Bool = true) -> [Int] {
        guard let p = project else { return [] }
        var points = (withPlayhead ? [0, playhead] : [0]) + p.markers.filter { !excluding.contains($0.id) }.map(\.at)
        points += p.clips.filter { !excluding.contains($0.id) }.flatMap { [$0.start, $0.end] }
        points += p.scenes.filter { !excluding.contains($0.id) }.flatMap { [$0.start, $0.end] }
        return points
    }

    /// Zeit auf ganze Bilder; mit Magnet an einen Rastpunkt innerhalb 9 px (Linie sichtbar).
    /// `playhead: false` beim Ziehen des Abspielkopfs selbst (sonst hielte er sich an der eigenen Stelle fest).
    func snapped(_ ticks: Int, excluding: Set<String> = [], playhead withPlayhead: Bool = true) -> Int {
        if snapping {
            let range = Studio.ticks(9 / pxPerSecond)
            if let best = snapPoints(excluding: excluding, playhead: withPlayhead).min(by: { abs($0 - ticks) < abs($1 - ticks) }),
               abs(best - ticks) <= range {
                snapLine = best
                return max(0, best)
            }
        }
        snapLine = nil
        return roundFrame(ticks)
    }

    /// Verschiebung einer Gruppe: der Versatz, bei dem eine ihrer Kanten einrastet.
    func snappedDelta(_ delta: Int, edges: [Int], excluding: Set<String>) -> Int {
        snapLine = nil
        if snapping {
            let range = Studio.ticks(9 / pxPerSecond)
            let points = snapPoints(excluding: excluding)
            var best: (Int, Int)?
            for e in edges {
                for pt in points where abs(pt - (e + delta)) <= range {
                    if best == nil || abs(pt - (e + delta)) < abs(best!.0 - (best!.1 + delta)) { best = (pt, e) }
                }
            }
            if let best {
                snapLine = best.0
                return best.0 - best.1
            }
        }
        guard let f = project?.frameTicks else { return delta }
        return Int((Double(delta) / Double(f)).rounded()) * f
    }

    // MARK: Tastatur (wie panels/Studio.tsx; nicht beim Tippen)

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }
            return self.key(event) ? nil : event
        }
    }

    func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func key(_ e: NSEvent) -> Bool {
        guard project != nil, AppState.shared.selectedTab == "studio" else { return false }
        // nicht in Dialogen (Übernehmen als Blatt, Import/Export als eigene Dateifenster) und nicht im Lizenzfenster
        guard NSApp.modalWindow == nil, let window = e.window, !(window is NSPanel), window.sheetParent == nil,
              window.attachedSheet == nil, window.identifier?.rawValue.contains("licenses") != true else { return false }
        if let responder = window.firstResponder, responder is NSText || responder is NSTextView { return false }
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        // ⌘-Befehle nach dem Zeichen, nicht nach der Tastenposition (auf QWERTZ liegt Z, wo US-Tastaturen Y haben)
        if cmd {
            switch chars {
            case "z": Task { if shift { await redo() } else { await undo() } }
            case "y": Task { await redo() }
            case "c": Task { await copy() }
            case "x": Task { await copy(cut: true) }
            case "v": Task { await paste() }
            case "k": Task { await razorAtPlayhead() }
            case "d": Task { await dissolve() }
            case "a": if let p = project { select(.clip, Set(p.clips.map(\.id))) }
            default: return false
            }
            return true
        }
        switch e.keyCode {
        case 49:  // Leertaste
            if kind == .media { return false }
            togglePlay()
        case 51, 117: Task { await deleteSelection(ripple: shift) }  // Rücktaste, Entf
        case 123, 124:  // ← →
            guard let p = project else { return false }
            let step = shift ? Studio.ticksPerSecond : p.frameTicks
            seek(roundFrame(playhead + (e.keyCode == 123 ? -step : step)))
        case 115: seek(0)  // Pos1
        case 119: seek(project?.editDuration ?? 0)  // Ende
        case 53:  // Esc
            if tool != .select { tool = .select } else { leaveSource(); clearSelection() }
            snapLine = nil
        default:
            switch chars {
            case "v": tool = .select
            case "c": tool = .razor
            case "z": tool = .scale
            case "s": magnet.toggle()
            case "m": Task { await addMarker("note") }
            case "+", "=": pxPerSecond = min(400, pxPerSecond * 1.25)
            case "-": pxPerSecond = max(4, pxPerSecond * 0.8)
            default: return false
            }
        }
        return true
    }
}

/// Monitor: dieselben Bilder wie der Export (StudioRender.Compositor), kleiner gerechnet; Ton beim Abspielen über
/// eine AVFoundation-Komposition mit Lautstärke, Einblenden und dem Auslaufen des vorigen Clips.
@MainActor
final class StudioPreview: ObservableObject {
    @Published var image: CGImage?
    private let renderer = PreviewRenderer()
    private var player: AVPlayer?
    private var audioTask: Task<Void, Never>?
    private var timer: Timer?
    private var started = Date()
    private var origin = 0.0
    private var duration = 0.0
    private var rendering = false
    private var wanted: (project: StudioProject, seconds: Double)?
    private var showing = false

    func invalidate() { Task { await renderer.reset() } }

    /// Ein Bild zur Zeit `seconds`. Kommen Aufrufe schneller, als gerechnet wird (Abspielkopf ziehen, Pfeiltaste
    /// gedrückt halten), rechnet immer nur eines und danach das zuletzt gewünschte; die dazwischen entfallen.
    func show(_ p: StudioProject, at seconds: Double) {
        wanted = (p, seconds)
        guard !showing else { return }
        showing = true
        Task {
            while let next = wanted {
                wanted = nil
                if let img = await renderer.frame(next.project, at: next.seconds) { image = img }
            }
            showing = false
        }
    }

    func play(_ p: StudioProject, from seconds: Double, onTime: @escaping (Double, Bool) -> Void) {
        stop()
        duration = Studio.seconds(p.editDuration)
        origin = seconds >= duration ? 0 : seconds
        started = Date()
        // Der Ton läuft nebenher und setzt dort ein, wo die Uhr inzwischen steht; die Uhr bestimmt den Abspielkopf
        // (vorher der Player: Endete die Musik vor dem Schnitt, blieb der Abspielkopf dort stehen)
        audioTask = Task {
            guard let item = await PreviewRenderer.audioItem(p), !Task.isCancelled, timer != nil else { return }
            let player = AVPlayer(playerItem: item)
            let at = origin + Date().timeIntervalSince(started)
            await player.seek(to: CMTime(seconds: at, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, timer != nil else { return }  // inzwischen angehalten
            self.player = player
            player.play()
        }
        // eigene Uhr, rund 20 Aktualisierungen je Sekunde (wie Monitor.tsx), Bilder so schnell wie gerechnet
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil else { return }
                let now = self.origin + Date().timeIntervalSince(self.started)
                let ended = now >= self.duration
                onTime(min(now, self.duration), ended)
                if ended { self.stop(); return }
                guard !self.rendering else { return }
                self.rendering = true
                if let img = await self.renderer.frame(p, at: now) { self.image = img }
                self.rendering = false
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        audioTask?.cancel()
        audioTask = nil
        player?.pause()
        player = nil
    }
}

/// Rechnet Monitorbilder nacheinander (der Compositor liest Videos vorwärts und ist nicht für Parallelzugriff).
/// Der Actor allein genügt dafür nicht: `Compositor.frame` ist async und nicht an ihn gebunden, während es läuft,
/// nimmt der Actor den nächsten Aufruf an. So lasen beim Ziehen des Abspielkopfs mehrere Aufrufe gleichzeitig
/// denselben AVAssetReader, einer legte ihn neu an → Absturz in copyNextSampleBuffer (31.10.). Deshalb eine Sperre.
actor PreviewRenderer {
    private var compositor: StudioRender.Compositor?
    private var key: Double = -1
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }  // bekommt die Sperre direkt von release()
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    func reset() async {
        await acquire()
        compositor?.close()
        compositor = nil
        key = -1
        release()
    }

    /// Plan in Monitorgröße (höchstens 960 px breit), neu, wenn sich das Projekt geändert hat.
    private func ensure(_ p: StudioProject) async -> StudioRender.Compositor? {
        if compositor != nil && key == p.updatedAt { return compositor }
        compositor?.close()
        compositor = nil
        key = p.updatedAt
        guard !p.clips.isEmpty else { return nil }
        await StudioMediaProbe.prefetch(StudioMediaProbe.referencedAssets([:], p))
        guard var plan = try? StudioRender.plan(p, preset: "project") else { return nil }
        let scale = min(1, 960 / Double(plan.width))
        plan.width = Int(Double(plan.width) * scale) / 2 * 2
        plan.height = Int(Double(plan.height) * scale) / 2 * 2
        compositor = StudioRender.Compositor(plan: plan)
        return compositor
    }

    func frame(_ p: StudioProject, at seconds: Double) async -> CGImage? {
        await acquire()
        defer { release() }
        guard let c = await ensure(p) else {
            let w = 640, h = max(2, Int(640 * Double(p.settings.height) / Double(p.settings.width)))
            return context.createCGImage(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)),
                                         from: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let img = try? await c.frame(at: seconds) else { return nil }
        return context.createCGImage(img, from: CGRect(x: 0, y: 0, width: c.width, height: c.height))
    }

    /// Ton für das Abspielen: jeder Clip mit Ton als Spur einer Komposition (Tempo mit erhaltener Tonhöhe),
    /// Lautstärke (bis 0 dB; lauter kann AVAudioMix nicht), Einblenden an Übergängen und das Auslaufen des vorigen
    /// Clips über sein Ende hinaus.
    static func audioItem(_ p: StudioProject) async -> AVPlayerItem? {
        await StudioMediaProbe.prefetch(StudioMediaProbe.referencedAssets([:], p))
        guard let plan = try? StudioRender.plan(p, preset: "project") else { return nil }
        let composition = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }
        for c in plan.clips where !c.muted && (c.media == "audio" || c.audio) {
            let asset = AVURLAsset(url: c.url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let available = (try? await asset.load(.duration).seconds) ?? c.outPoint
            // Auslaufen: der nächste Clip derselben Spur mit Übergang beginnt hier
            let next = plan.clips.first { $0.track == c.track && abs($0.start - c.end) < 1e-3 && ($0.transition?.seconds ?? 0) > 0 }
            let tail = min(max(0, available - c.outPoint), (next?.transition?.seconds ?? 0) * c.speed)
            let range = CMTimeRange(start: time(c.inPoint), end: time(c.outPoint + tail))
            do { try track.insertTimeRange(range, of: source, at: time(c.start)) } catch { continue }
            if abs(c.speed - 1) > 1e-6 {
                track.scaleTimeRange(CMTimeRange(start: time(c.start), duration: range.duration),
                                     toDuration: time(c.length + tail / c.speed))
            }
            let mix = AVMutableAudioMixInputParameters(track: track)
            let volume = Float(min(1, pow(10, c.gainDB / 20)))
            mix.setVolume(volume, at: .zero)
            if let tr = c.transition, tr.seconds > 0 {
                mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: time(c.start), duration: time(tr.seconds)))
            }
            if tail > 0, let next {
                mix.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                  timeRange: CMTimeRange(start: time(c.end), duration: time(next.transition!.seconds)))
            }
            params.append(mix)
        }
        guard !params.isEmpty else { return nil }
        let item = AVPlayerItem(asset: composition)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = params
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}
