import Foundation

/// Ein erzeugtes Bild oder ein Upload – Felder wie `Asset` im NVAI-open-Vertrag.
struct AssetRecord: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var jobID: String?
    var kind: String            // image | upload
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

/// Ablage unter ~/Library/Application Support/NV-AI/assets mit einer index.json.
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
    }

    private func save() {
        if let data = try? JSONEncoder().encode(assets) {
            try? data.write(to: indexURL, options: .atomic)
        }
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

    func addUpload(data: Data, originalName: String) throws -> AssetRecord {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (originalName as NSString).pathExtension.lowercased()
        let suffix = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "heic"].contains(ext) ? ext : "png"
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

    @discardableResult
    func delete(_ id: String) -> Bool {
        load()
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        try? FileManager.default.removeItem(at: fileURL(assets[index].filename))
        assets.remove(at: index)
        save()
        return true
    }
}
