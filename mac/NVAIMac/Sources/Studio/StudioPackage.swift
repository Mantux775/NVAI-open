import Foundation

/// Projektpakete wie unter Windows (studio.build_package / import_package): ein ZIP ohne Kompression mit dem Manifest
/// nvai-studio.json (Projekt und Asset-Einträge) und den Dateien unter files/. Dieselbe Datei wandert in beide
/// Richtungen; Assets behalten ihre ID, was es schon gibt, wird nicht doppelt kopiert.
enum StudioPackage {
    static let format = "nvai-studio"
    static let manifestName = "nvai-studio.json"

    private static func safe(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$", options: .regularExpression) != nil
    }

    /// Alle Assets, die das Projekt braucht: Clips, Takes und Bildvorgaben der Szenen.
    static func usedAssets(_ p: StudioProject) -> [String] {
        var ids = Set(p.clips.map(\.assetID))
        for s in p.scenes {
            ids.formUnion(s.takes)
            for key in ["image_asset_id", "end_image_asset_id", "audio_asset_id"] {
                if let v = s.params[key]?.stringValue, !v.isEmpty { ids.insert(v) }
            }
            ids.formUnion((s.params["reference_asset_ids"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        return ids.sorted()
    }

    private static func entries(_ p: StudioProject) -> [(record: AssetRecord, url: URL)] {
        usedAssets(p).compactMap { id in
            guard let r = AssetSnapshot.shared.get(id) else { return nil }
            let url = AssetStore.shared.fileURL(r.filename)
            return FileManager.default.fileExists(atPath: url.path) ? (r, url) : nil  // gelöscht: Clip steht als fehlend
        }
    }

    /// Größe des Pakets für das Menü (die Mac-Fassung hat keine verlustfreien Kopien).
    static func info(_ p: StudioProject) -> (files: Int, bytes: Int64) {
        let files = entries(p)
        let bytes = files.reduce(Int64(0)) { sum, e in
            sum + ((try? FileManager.default.attributesOfItem(atPath: e.url.path)[.size] as? Int64) ?? 0)
        }
        return (files.count, bytes)
    }

    static func fileName(_ p: StudioProject) -> String {
        let slug = p.name.replacingOccurrences(of: "[^\\w.-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return "\(slug.isEmpty ? p.id : slug).nvai-studio.zip"
    }

    /// ZIP nach `out` schreiben.
    static func build(_ p: StudioProject, to out: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("nvai-package-\(UUID().uuidString)", isDirectory: true)
        let files = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var assets: [JSONValue] = []
        for (r, url) in entries(p) {
            let name = url.lastPathComponent
            let target = files.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                do { try fm.linkItem(at: url, to: target) } catch { try fm.copyItem(at: url, to: target) }
            }
            var meta = r.meta
            meta["master"] = nil  // verlustfreie Kopien gibt es auf dem Mac nicht
            meta["preview"] = nil
            assets.append(.object(["id": .string(r.id), "kind": .string(r.kind), "filename": .string(name),
                                   "prompt": .string(r.prompt), "model_id": .string(r.modelID), "meta": .object(meta),
                                   "created_at": .double(r.createdAt)]))
        }
        let project = JSON.parse(try StudioStore.encode(p)) ?? .null
        let manifest: JSONValue = .object(["format": .string(format), "version": .int(1),
                                           "exported_at": .double(Date().timeIntervalSince1970), "masters": .bool(false),
                                           "project": project, "assets": .array(assets)])
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try e.encode(manifest).write(to: stage.appendingPathComponent(manifestName))
        try? fm.removeItem(at: out)
        try run("/usr/bin/zip", ["-0", "-q", "-r", out.path, manifestName, "files"], in: stage)
    }

    /// Paket (.zip) oder nur das Projekt (.json) einlesen; legt das Projekt mit neuer ID und freiem Namen an.
    static func importFile(_ url: URL, store: StudioStore) async throws -> StudioProject {
        let fm = FileManager.default
        let head = (try? FileHandle(forReadingFrom: url).readData(ofLength: 2)) ?? Data()
        var manifest: [String: JSONValue]
        var stage: URL?
        defer { if let stage { try? fm.removeItem(at: stage) } }
        if head == Data("PK".utf8) {
            let dir = fm.temporaryDirectory.appendingPathComponent("nvai-import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            stage = dir
            try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", dir.path], in: dir)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)),
                  let m = JSON.parse(data)?.objectValue else {
                throw StudioError(t("Kein Studio-Paket: nvai-studio.json fehlt.", "Not a Studio package: nvai-studio.json is missing."))
            }
            manifest = m
        } else {
            guard let data = try? Data(contentsOf: url), let m = JSON.parse(data)?.objectValue else {
                throw StudioError(t("Weder Studio-Paket (.zip) noch Projekt (.json).", "Neither a Studio package (.zip) nor a project (.json)."))
            }
            manifest = m["project"] == nil ? ["format": .string(format), "project": .object(m)] : m
        }
        guard manifest["format"]?.stringValue == format, let projectJSON = manifest["project"],
              projectJSON["clips"]?.arrayValue != nil,
              var p = try? JSONDecoder().decode(StudioProject.self, from: JSON.data(projectJSON.any)) else {
            throw StudioError(t("Das ist kein Studio-Projekt.", "This is not a Studio project."))
        }
        try StudioCommands.checkProject(p)  // vor dem Kopieren: ein beschädigtes Projekt brächte die App zum Absturz
        var imported: [String] = []
        if let dir = stage {
            for a in manifest["assets"]?.arrayValue ?? [] {
                guard let id = a["id"]?.stringValue, id.range(of: "^[a-z]{2,5}_[0-9a-f]{6,32}$", options: .regularExpression) != nil,
                      let kind = a["kind"]?.stringValue, ["image", "video", "audio", "upload"].contains(kind),
                      let name = a["filename"]?.stringValue, safe(name) else { continue }
                imported.append(id)
                if let existing = AssetSnapshot.shared.get(id), fm.fileExists(atPath: AssetStore.shared.fileURL(existing.filename).path) {
                    continue  // vorhandenes bleibt
                }
                let file = dir.appendingPathComponent("files").appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { continue }
                var meta = a["meta"]?.objectValue ?? [:]
                meta["master"] = nil
                meta["preview"] = nil
                // Die Projektmarke der anderen Installation gilt hier nicht; ohne sie bekommt das Material unten die
                // des neuen Projekts (vorher blieben erzeugte Takes so außerhalb seines Ordners)
                meta["studio_project"] = nil
                meta["imported"] = .bool(true)
                _ = try await AssetStore.shared.importAsset(id: id, kind: kind, file: file, prompt: a["prompt"]?.stringValue ?? "",
                                                            modelID: a["model_id"]?.stringValue ?? "", meta: meta,
                                                            createdAt: a["created_at"]?.doubleValue ?? Date().timeIntervalSince1970)
            }
        }
        let names = Set(await store.list().compactMap { $0["name"]?.stringValue })
        var name = p.name.isEmpty ? "Import" : p.name
        if names.contains(name) { name = (2..<1000).lazy.map { "\(name) (\($0))" }.first { !names.contains($0) } ?? name }
        let now = Date().timeIntervalSince1970
        p.id = Studio.newID("stu")
        p.name = name
        p.createdAt = now
        p.updatedAt = now
        p.version = Studio.version
        p.folder = nil  // der Ordner der anderen Installation
        for i in p.scenes.indices {  // Aufträge gehören zur anderen Installation
            p.scenes[i].jobs = []
            p.scenes[i].waitingFor = nil
        }
        try await store.put(p)
        if !imported.isEmpty { await AssetStore.shared.tag(imported, project: p.id) }
        return p
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = dir
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw StudioError(t("Paket: \(tool) fehlgeschlagen. \(text)", "Package: \(tool) failed. \(text)"))
        }
    }
}
