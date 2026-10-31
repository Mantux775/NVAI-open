import Foundation

/// Studio-Projekte im Datenordner (`<Ordner>/<id>.json`, wie unter Windows `data/studio`) mit Rückgängig und
/// Wiederholen im Speicher (100 Stände je Projekt). Jede Änderung läuft über `apply`; was Aufträge eintragen (neue
/// Takes, Fehler), über `update` ohne Rückgängig-Eintrag.
actor StudioStore {
    let directory: URL
    let env: StudioEnvironment
    private var undoStack: [String: [StudioProject]] = [:]
    private var redoStack: [String: [StudioProject]] = [:]
    private var onChange: (@Sendable (StudioProject) -> Void)?
    /// Liest vor einem Befehl die Medieninfo der beteiligten Assets (App: AVFoundation, asynchron).
    private var prefetch: (@Sendable (StudioParams, StudioProject) async -> Void)?

    init(directory: URL, env: StudioEnvironment,
         prefetch: (@Sendable (StudioParams, StudioProject) async -> Void)? = nil) {
        self.directory = directory
        self.env = env
        self.prefetch = prefetch
    }

    /// Wird nach jedem Speichern gerufen (Oberfläche lädt nach, auch wenn Claude per REST geändert hat).
    func setOnChange(_ handler: @escaping @Sendable (StudioProject) -> Void) { onChange = handler }

    func setPrefetch(_ handler: @escaping @Sendable (StudioParams, StudioProject) async -> Void) { prefetch = handler }

    // MARK: Dateien

    private func path(_ id: String) throws -> URL {
        guard !id.isEmpty, !id.contains(where: { "/\\.:".contains($0) }) else {
            throw StudioError(t("Unbekanntes Projekt: \(id)", "Unknown project: \(id)"), notFound: true)
        }
        return directory.appendingPathComponent("\(id).json")
    }

    static func encode(_ p: StudioProject) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return try e.encode(p)
    }

    private func save(_ p: StudioProject) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(p).write(to: try path(p.id), options: .atomic)
        onChange?(p)
    }

    func load(_ id: String) throws -> StudioProject {
        let url = try path(id)
        guard let data = try? Data(contentsOf: url) else {
            throw StudioError(t("Unbekanntes Projekt: \(id)", "Unknown project: \(id)"), notFound: true)
        }
        do {
            return try JSONDecoder().decode(StudioProject.self, from: data)
        } catch {
            throw StudioError(t("Projektdatei nicht lesbar: \(id)", "Cannot read the project file: \(id)"))
        }
    }

    /// Alle Projekte, zuletzt geänderte zuerst, mit Kurzangaben wie list_projects() unter Windows.
    func list() -> [JSONValue] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "json" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var out: [JSONValue] = []
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }) {
            // Neben den Projekten kann ein Exportplan liegen (<auftrag>.plan.json): kein Projekt
            guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(StudioProject.self, from: data) else { continue }
            out.append(.object(["id": .string(p.id), "name": .string(p.name), "updated_at": .double(p.updatedAt),
                                "scenes": .int(p.scenes.count), "clips": .int(p.clips.count),
                                "duration_s": .double((Studio.seconds(p.editDuration) * 100).rounded() / 100),
                                "folder": p.folder.map(JSONValue.string) ?? .null]))
        }
        return out
    }

    /// „New 1“, „New 2“ …: Ohne Namen heißt ein Projekt so, mit der nächsten Zahl (in beiden Sprachen gleich).
    private func nextNewName() -> String {
        let numbers = list().compactMap { $0["name"]?.stringValue }.compactMap { name -> Int? in
            guard name.hasPrefix("New "), let n = Int(name.dropFirst(4)), String(n) == name.dropFirst(4) else { return nil }
            return n
        }
        return "New \((numbers.max() ?? 0) + 1)"
    }

    func create(name: String = "", width: Int = 1920, height: Int = 1080, fps: [Int] = [24, 1]) throws -> StudioProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = StudioProject(id: Studio.newID("stu"), name: trimmed.isEmpty ? nextNewName() : trimmed,
                              settings: StudioSettings(width: width, height: height, fps: fps))
        try StudioCommands.checkProject(p)
        try save(p)
        return p
    }

    /// Ein ganzes Projekt ablegen (Paket-Import); ohne Rückgängig-Eintrag.
    func put(_ p: StudioProject) throws { try save(p) }

    /// In den Papierkorb des Studios, nicht endgültig.
    func delete(_ id: String) throws {
        let url = try path(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError(t("Unbekanntes Projekt: \(id)", "Unknown project: \(id)"), notFound: true)
        }
        let trash = directory.appendingPathComponent("papierkorb", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("\(id)-\(Int(Date().timeIntervalSince1970)).json"))
        undoStack[id] = nil
        redoStack[id] = nil
    }

    // MARK: Befehle

    /// Befehl ausführen, speichern, den alten Stand auf den Rückgängig-Stapel legen. Scheitert der Befehl, bleibt
    /// alles beim Alten (auch bei batch).
    func apply(_ id: String, _ name: String, _ params: StudioParams = [:]) async throws -> (StudioProject, JSONValue) {
        if let prefetch { await prefetch(params, try load(id)) }
        var p = try load(id)  // nach dem Warten neu: dazwischen kann ein anderer Befehl gespeichert haben
        let before = p
        let result = try StudioCommands.apply(name, &p, params, env)
        p.updatedAt = Date().timeIntervalSince1970
        try save(p)
        var stack = undoStack[id] ?? []
        stack.append(before)
        if stack.count > Studio.undoLimit { stack.removeFirst(stack.count - Studio.undoLimit) }
        undoStack[id] = stack
        redoStack[id] = nil
        return (p, result)
    }

    func undo(_ id: String) throws -> StudioProject {
        guard var p = undoStack[id]?.popLast() else {
            throw StudioError(t("Nichts zum Rückgängigmachen.", "Nothing to undo."))
        }
        let current = try load(id)
        Self.keepGeneration(&p, current)
        redoStack[id, default: []].append(current)
        p.updatedAt = Date().timeIntervalSince1970
        try save(p)
        return p
    }

    func redo(_ id: String) throws -> StudioProject {
        guard var p = redoStack[id]?.popLast() else {
            throw StudioError(t("Nichts zum Wiederholen.", "Nothing to redo."))
        }
        let current = try load(id)
        Self.keepGeneration(&p, current)
        undoStack[id, default: []].append(current)
        p.updatedAt = Date().timeIntervalSince1970
        try save(p)
        return p
    }

    func history(_ id: String) -> (undo: Int, redo: Int) {
        (undoStack[id]?.count ?? 0, redoStack[id]?.count ?? 0)
    }

    /// Änderung, die kein Befehl ist (fertige Aufträge tragen Takes ein): ohne Rückgängig-Eintrag.
    func update(_ id: String, _ change: (inout StudioProject) throws -> Bool) throws -> StudioProject {
        var p = try load(id)
        if try change(&p) {
            p.updatedAt = Date().timeIntervalSince1970
            try save(p)
        }
        return p
    }

    /// Was Erzeugungsaufträge eingetragen haben, ist kein Befehl: Rückgängig und Wiederholen behalten neue Takes,
    /// laufende Aufträge und wartende Anschlüsse, statt sie mit dem alten Stand zu verlieren.
    static func keepGeneration(_ restored: inout StudioProject, _ current: StudioProject) {
        let now = Dictionary(current.scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in restored.scenes.indices {
            guard let c = now[restored.scenes[i].id] else { continue }
            restored.scenes[i].takes += c.takes.filter { !restored.scenes[i].takes.contains($0) }
            restored.scenes[i].jobs = c.jobs
            restored.scenes[i].error = c.error
            restored.scenes[i].waitingFor = c.waitingFor
            if restored.scenes[i].take == nil, let take = c.take { restored.scenes[i].take = take }
        }
        restored.media.merge(current.media) { _, new in new }
        if let folder = current.folder { restored.folder = folder }
    }
}
