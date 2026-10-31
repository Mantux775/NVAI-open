import Foundation

/// Ein erzeugtes Bild oder ein Upload – Felder wie `Asset` im NVAI-open-Vertrag.
struct AssetRecord: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var jobID: String?
    var kind: String            // image | upload | audio | video
    var filename: String
    var prompt: String
    var modelID: String
    var meta: [String: JSONValue]
    var createdAt: Double

    var url: String { "/files/\(filename)" }

    var json: [String: Any] {
        [
            "id": id,
            "job_id": jobID ?? NSNull(),
            "kind": kind,
            "filename": filename,
            "url": url,
            "thumb_url": NSNull(),
            "prompt": prompt,
            "model_id": modelID,
            "meta": meta.mapValues(\.any),
            "created_at": createdAt,
        ]
    }
}

/// Ablage mit einer index.json, standardmäßig unter ~/Library/Application Support/NV-AI/assets (seit 0.4.8 wählbar,
/// `Settings.assetsDirectory`).
/// Ein Actor, weil Server-Anfragen und Aufträge gleichzeitig zugreifen.
actor AssetStore {
    static let shared = AssetStore()

    private var assets: [AssetRecord] = []
    private var loaded = false
    private var onChange: (@Sendable () -> Void)?

    private var directory: URL { Settings.assetsDirectory }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func setOnChange(_ handler: @escaping @Sendable () -> Void) { onChange = handler }

    func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([AssetRecord].self, from: data) {
            // Einträge ohne Datei fallen weg (von Hand gelöscht).
            assets = list.filter { FileManager.default.fileExists(atPath: fileURL($0.filename).path) }
        }
        AssetSnapshot.shared.set(assets)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(assets) {
            try? data.write(to: indexURL, options: .atomic)
        }
        AssetSnapshot.shared.set(assets)
        onChange?()
    }

    nonisolated func fileURL(_ filename: String) -> URL {
        // Kein Pfad-Traversal: nur der letzte Bestandteil zählt.
        Settings.assetsDirectory.appendingPathComponent((filename as NSString).lastPathComponent)
    }

    /// Neueste zuerst.
    func list(kind: String? = nil, limit: Int = 200) -> [AssetRecord] {
        load()
        let filtered = assets.reversed().filter { kind == nil || $0.kind == kind }
        return Array(filtered.prefix(max(0, limit)))
    }

    func get(_ id: String) -> AssetRecord? {
        load()
        return assets.first { $0.id == id }
    }

    func assets(ofJob jobID: String) -> [AssetRecord] {
        load()
        return assets.filter { $0.jobID == jobID }
    }

    static func newID(_ prefix: String) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "\(prefix)_\(hex)"
    }

    func addImage(png: Data, jobID: String, prompt: String, modelID: String,
                  meta: [String: JSONValue]) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.newID("ast")
        let filename = "\(id.dropFirst(4))_nvai.png"
        try png.write(to: fileURL(filename), options: .atomic)
        let record = AssetRecord(id: id, jobID: jobID, kind: "image", filename: filename, prompt: prompt,
                                 modelID: modelID, meta: meta, createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    /// Musik oder Klang (seit 0.4.7): WAV, Art „audio“ wie unter Windows.
    func addAudio(wav: Data, jobID: String, prompt: String, modelID: String,
                  meta: [String: JSONValue]) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.newID("ast")
        let filename = "\(id.dropFirst(4))_nvai_audio.wav"
        try wav.write(to: fileURL(filename), options: .atomic)
        let record = AssetRecord(id: id, jobID: jobID, kind: "audio", filename: filename, prompt: prompt,
                                 modelID: modelID, meta: meta, createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    /// Ein MP4 aus dem Temp-Ordner in die Ablage verschieben (seit 0.4.8, LTX-Video).
    func addVideo(mp4: URL, jobID: String, prompt: String, modelID: String,
                  meta: [String: JSONValue]) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.newID("ast")
        let filename = "\(id.dropFirst(4))_nvai_video.mp4"
        try? FileManager.default.removeItem(at: fileURL(filename))
        try FileManager.default.moveItem(at: mp4, to: fileURL(filename))
        let record = AssetRecord(id: id, jobID: jobID, kind: "video", filename: filename, prompt: prompt,
                                 modelID: modelID, meta: meta, createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    /// Export des Studios (MP4 oder MOV) in die Ablage verschieben.
    func addStudioExport(file: URL, ext: String, jobID: String, prompt: String,
                         meta: [String: JSONValue]) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.newID("ast")
        let filename = "\(id.dropFirst(4))_nvai_studio.\(ext)"
        try? FileManager.default.removeItem(at: fileURL(filename))
        try FileManager.default.moveItem(at: file, to: fileURL(filename))
        let record = AssetRecord(id: id, jobID: jobID, kind: "video", filename: filename, prompt: prompt,
                                 modelID: "studio", meta: meta, createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    func addUpload(data: Data, originalName: String) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (originalName as NSString).pathExtension.lowercased()
        // Bilder und, fürs Studio, Video und Ton (was AVFoundation liest); alles andere wurde als Bild geprüft
        let suffix = (Self.imageSuffixes + Self.mediaSuffixes).contains(ext) ? ext : "png"
        let id = Self.newID("ast")
        let filename = "upl_\(id.dropFirst(4)).\(suffix)"
        try data.write(to: fileURL(filename), options: .atomic)
        let record = AssetRecord(id: id, jobID: nil, kind: "upload", filename: filename, prompt: "",
                                 modelID: "", meta: ["original_name": .string(originalName)],
                                 createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    /// Ein Bild, das das Studio selbst ablegt (etwa das letzte Bild einer Szene als Startbild für den Anschluss):
    /// als Upload mit Beschriftung, wie _last_frame_asset unter Windows.
    func addStudioImage(png: Data, label: String, meta: [String: JSONValue]) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.newID("ast")
        let filename = "upl_\(id.dropFirst(4)).png"
        try png.write(to: fileURL(filename), options: .atomic)
        let record = AssetRecord(id: id, jobID: nil, kind: "upload", filename: filename, prompt: label, modelID: "",
                                 meta: meta, createdAt: Date().timeIntervalSince1970)
        assets.append(record)
        save()
        return record
    }

    /// Ordnet ein Asset einem Studio-Projekt zu (sein Ordner im Material, wie assets/Studio/<Projekt> unter Windows).
    /// Was schon einem Projekt gehört, bleibt dort.
    func tag(_ ids: [String], project: String) {
        load()
        var changed = false
        for i in assets.indices where ids.contains(assets[i].id) && assets[i].meta["studio_project"] == nil {
            assets[i].meta["studio_project"] = .string(project)
            changed = true
        }
        if changed { save() }
    }

    /// Asset aus einem Studio-Paket unter seiner ID eintragen (Datei kopiert, freier Dateiname).
    func importAsset(id: String, kind: String, file: URL, prompt: String, modelID: String, meta: [String: JSONValue],
                     createdAt: Double) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = file.lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: fileURL(name).path) {
            name = "\(stem)-\(Self.newID("imp").dropFirst(4).prefix(8)).\(ext)"
        }
        try FileManager.default.copyItem(at: file, to: fileURL(name))
        let record = AssetRecord(id: id, jobID: nil, kind: kind, filename: name, prompt: prompt, modelID: modelID,
                                 meta: meta, createdAt: createdAt)
        assets.removeAll { $0.id == id }
        assets.append(record)
        save()
        return record
    }

    static let imageSuffixes = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "heic"]
    static let mediaSuffixes = ["mp4", "mov", "m4v", "wav", "mp3", "m4a", "aac", "aif", "aiff", "flac", "caf"]

    @discardableResult
    func delete(_ id: String) -> Bool {
        load()
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        try? FileManager.default.removeItem(at: fileURL(assets[index].filename))
        assets.remove(at: index)
        save()
        return true
    }

    // MARK: Ablageordner wechseln (seit 0.4.8)

    struct RelocateResult: Sendable {
        /// Dateien, die in den neuen Ordner umgezogen sind.
        var moved = 0
        /// Dateien, die im alten Ordner bleiben mussten (Fehler, Name im neuen Ordner schon vergeben).
        var failed = 0
        /// Einträge, die im neuen Ordner schon einen Verlauf von NVAI-open hatten.
        var merged = 0
    }

    /// Anzahl und Größe der Dateien im Verlauf – für die Rückfrage beim Ordnerwechsel.
    func summary() -> (count: Int, bytes: Int64) {
        load()
        let bytes = assets.reduce(Int64(0)) { sum, record in
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(record.filename).path))?[.size]
            return sum + ((size as? NSNumber)?.int64Value ?? 0)
        }
        return (assets.count, bytes)
    }

    /// Wechselt die Ablage. Mit `move` ziehen alle Dateien samt Verlauf um; was nicht geht, bleibt mit eigenem Verlauf
    /// im alten Ordner. Liegt im neuen Ordner schon ein Verlauf von NVAI-open, kommen beide zusammen. Ohne `move` gilt
    /// der neue Ordner mit seinem eigenen Verlauf (leer, wenn neu); die alten Dateien bleiben, wo sie sind.
    func relocate(to target: URL, move: Bool) throws -> RelocateResult {
        load()
        let fm = FileManager.default
        let old = directory.standardizedFileURL
        let new = target.standardizedFileURL
        var result = RelocateResult()
        guard new.path != old.path else { return result }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        var combined = Self.readIndex(new.appendingPathComponent("index.json"))
            .filter { fm.fileExists(atPath: new.appendingPathComponent($0.filename).path) }
        result.merged = combined.count
        if move {
            var known = Set(combined.map(\.id))
            var stayed: [AssetRecord] = []
            for record in assets {
                let src = old.appendingPathComponent(record.filename)
                let dst = new.appendingPathComponent(record.filename)
                // Dasselbe Asset liegt schon im neuen Ordner (von Hand kopiert): das alte bleibt, wo es ist.
                if known.contains(record.id) || fm.fileExists(atPath: dst.path) {
                    stayed.append(record)
                    result.failed += 1
                    continue
                }
                do {
                    try fm.moveItem(at: src, to: dst)
                    combined.append(record)
                    known.insert(record.id)
                    result.moved += 1
                } catch {
                    stayed.append(record)
                    result.failed += 1
                }
            }
            let oldIndex = old.appendingPathComponent("index.json")
            if stayed.isEmpty {
                try? fm.removeItem(at: oldIndex)
            } else {
                Self.writeIndex(stayed, to: oldIndex)
            }
        }
        combined.sort { $0.createdAt < $1.createdAt }
        Settings.assetsDirectory = new
        assets = combined
        save()
        return result
    }

    private static func readIndex(_ url: URL) -> [AssetRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AssetRecord].self, from: data)) ?? []
    }

    private static func writeIndex(_ list: [AssetRecord], to url: URL) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }
}


/// Stand der Assets für Leser, die nicht auf den Actor warten können (Studio-Befehle laufen synchron, wie unter
/// Windows). Nach jedem Laden und Speichern des AssetStore nachgeführt, also nie älter als die letzte Änderung.
final class AssetSnapshot: @unchecked Sendable {
    static let shared = AssetSnapshot()
    private let lock = NSLock()
    private var byID: [String: AssetRecord] = [:]

    func set(_ list: [AssetRecord]) {
        let map = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lock.lock()
        byID = map
        lock.unlock()
    }

    func get(_ id: String) -> AssetRecord? {
        lock.lock()
        defer { lock.unlock() }
        return byID[id]
    }
}
