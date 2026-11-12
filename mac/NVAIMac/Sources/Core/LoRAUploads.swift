import Foundation

/// Eigene LoRAs im Nutzer-Katalog (seit 0.5.5), wie die hochgeladenen Einträge in custom_models.json unter Windows:
/// eine JSON-Datei neben den Einstellungen, die Dateien selbst liegen direkt im Ordner loras/.
enum UserLoRACatalog {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var family: String
        var file: String
        var bytes: Int64
        var trigger: String
        var sha256: String
        var added: String
        /// Nur bei Wan 2.2 A14B bedeutsam (high, low, both); auf dem Mac bleibt es leer.
        var expert: String?
    }

    private static var url: URL { Settings.appSupport.appendingPathComponent("eigene-loras.json") }
    private static let lock = NSLock()
    private static var cache: [Entry]?

    private static func loadLocked() -> [Entry] {
        if let cache { return cache }
        let list = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        cache = list
        return list
    }

    private static func saveLocked(_ list: [Entry]) {
        try? FileManager.default.createDirectory(at: Settings.appSupport, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(list) { try? data.write(to: url, options: .atomic) }
        cache = list
    }

    static var entries: [Entry] { lock.withLock { loadLocked() } }
    static var models: [LoRAModel] { entries.map(model) }

    static func model(_ e: Entry) -> LoRAModel {
        LoRAModel(id: e.id, nameDE: e.name, nameEN: e.name, repo: LoRAUploads.uploadRepo, file: e.file, bytes: e.bytes,
                  trigger: e.trigger, strength: 1.0, use: "style", descriptionDE: "", descriptionEN: "",
                  base: e.family, uploaded: true, sha256: e.sha256, added: e.added)
    }

    /// Ändern unter der Sperre: lesen, ändern, schreiben.
    static func mutate<T>(_ change: (inout [Entry]) throws -> T) rethrows -> T {
        try lock.withLock {
            var list = loadLocked()
            let result = try change(&list)
            saveLocked(list)
            return result
        }
    }

    static func remove(_ id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }
}

/// Eine LoRA-Datei vom Rechner aufnehmen (REST `POST /api/loras/upload`, Dateidialog der Oberfläche) und die Zuordnung
/// ändern (`PUT /api/loras/{id}`), wie `add_upload`/`update_lora` in registry.py unter Windows.
enum LoRAUploads {
    /// steht in files[].repo: die Datei kam vom Rechner, nicht aus einem Repo
    static let uploadRepo = "upload"

    static func notDownloadable() -> APIError {
        APIError(400, t("Diese LoRA kam vom Rechner und lässt sich nicht herunterladen. Fehlt die Datei, sie bitte erneut "
                        + "hinzufügen („LoRA-Datei hinzufügen“ unter „Modelle“).",
                        "This LoRA came from this computer and cannot be downloaded. If the file is missing, please add it "
                        + "again (“Add LoRA file” under “Models”)."))
    }

    /// Basis aus einer Anfrage prüfen: bekannt und auf dem Mac nutzbar.
    static func checkFamily(_ value: String) throws -> String {
        let family = LoRAFiles.normalizedBase(value)
        guard LoRAFiles.labels[family] != nil else {
            throw APIError(400, t("Unbekannte LoRA-Basis: \(value)", "Unknown LoRA base: \(value)"))
        }
        guard LoRAFiles.macBases.contains(family) else {
            let bases = LoRAFiles.macBases.joined(separator: ", ")
            throw APIError(400, t("Auf dem Mac nimmt kein Modell LoRAs für \(LoRAFiles.label(family)). Möglich: \(bases).",
                                  "No model on the Mac takes LoRAs for \(LoRAFiles.label(family)). Possible: \(bases)."))
        }
        return family
    }

    static func checkExpert(_ value: String) throws {
        guard value.isEmpty || LoRAFiles.experts.contains(value) else {
            throw APIError(400, t("Unbekannter Experte: \(value) (high, low oder both)", "Unknown expert: \(value) (high, low or both)"))
        }
    }

    /// Die Angaben einer Anfrage, bevor die Datei kommt (sonst liefen 300 MB über die Leitung, nur um am Namen zu
    /// scheitern): Dateiname, Basis, Experte. Gibt den Zielnamen und die Basis (nil = wie erkannt) zurück.
    static func checkRequest(fileName: String, family: String, expert: String) throws -> (target: String, family: String?) {
        let target = try LoRAFiles.fileName(fileName)
        let chosen = family.isEmpty ? nil : try checkFamily(family)
        try checkExpert(expert)
        return (target, chosen)
    }

    /// Genug Platz im Ordner für `bytes` und 256 MB Reserve? Sonst 507 wie unter Windows.
    static func checkSpace(_ bytes: Int64, in folder: URL) throws {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard bytes <= free - 256 * 1024 * 1024 else {
            let f = String(format: "%.1f", Double(free) / 1e9), b = String(format: "%.2f", Double(bytes) / 1e9)
            throw APIError(507, t("Zu wenig Platz in \(folder.path): \(f) GB frei, die Datei hat \(b) GB.",
                                  "Not enough space in \(folder.path): \(f) GB free, the file has \(b) GB."))
        }
    }

    /// Teildatei im Ordner loras/ (versteckt), damit das Ablegen nur ein Umbenennen ist.
    static func newPart() -> URL {
        LoRAFiles.directory.appendingPathComponent(".upl_\(UUID().uuidString.prefix(12).lowercased()).part")
    }

    /// Reste abgebrochener Übertragungen (App beendet mitten im Hochladen) beim Start entfernen.
    static func removeStaleParts() {
        let folder = LoRAFiles.directory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(".upl_") && name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Ergebnis des Hinzufügens: die LoRA, ob dieselbe Datei schon da war, und ein Hinweis, wenn die Zuordnung vom
    /// Dateikopf abweicht.
    struct Result {
        var model: LoRAModel
        var existing: Bool
        var warning: String

        var json: [String: Any] { ["model": model.info, "existing": existing, "warning": warning] }
    }

    /// Eine vollständig empfangene Teildatei (liegt schon in loras/) prüfen und aufnehmen. `family` nil: wie am
    /// Dateikopf erkannt. Die Teildatei ist danach abgelegt oder gelöscht.
    static func add(part: URL, target: String, family: String?, name: String, trigger: String, expert: String,
                    size: Int64, sha256: String) throws -> Result {
        defer { try? FileManager.default.removeItem(at: part) }  // abgelegt heißt umbenannt: dann ist hier nichts mehr
        let header = try LoRAFiles.verifyFile(part)
        let check = LoRAFiles.inspect(header, fileName: target)
        let verdict = check.verdict
        guard check.lora else { throw APIError(400, verdict) }
        let detected = check.family
        guard let chosen = family ?? detected else {
            let bases = LoRAFiles.macBases.joined(separator: ", ")
            throw APIError(400, t("\(verdict) Zuordnung mit family angeben: \(bases).", "\(verdict) Give the assignment as family: \(bases)."))
        }
        guard LoRAFiles.macBases.contains(chosen) else {
            throw APIError(400, t("\(verdict) Auf dem Mac lässt sie sich deshalb nicht hinzufügen.",
                                  "\(verdict) It therefore cannot be added on the Mac."))
        }
        guard LoRAFiles.macLoadable(header) else {
            throw APIError(400, t("Die Datei liegt im kohya-Format (lora_down/lora_up); das lädt NVAI-open für Mac nicht.",
                                  "The file is in kohya format (lora_down/lora_up), which NVAI-open for Mac does not load."))
        }
        let (model, existing) = try store(part: part, target: target, family: chosen,
                                          name: name.isEmpty ? check.name : name,
                                          trigger: trigger.isEmpty ? check.trigger : trigger,
                                          expert: expert, size: size, sha256: sha256)
        var warning = ""
        if let detected, detected != chosen {
            warning = t("Der Dateikopf passt zu \(LoRAFiles.label(detected)), zugeordnet ist \(LoRAFiles.label(chosen)). Passt eine "
                        + "LoRA nicht zum Modell, wirkt sie meist gar nicht.",
                        "The file header fits \(LoRAFiles.label(detected)), it is assigned to \(LoRAFiles.label(chosen)). A LoRA "
                        + "that does not fit the model usually has no effect at all.")
        }
        AppLog.info("LoRA \(existing ? "updated" : "added"): \(model.id) (\(model.file), \(size) bytes, \(chosen))")
        return Result(model: model, existing: existing, warning: warning)
    }

    /// Anzeigename ohne Schrägstriche (eine Auswahl kürzt Namen sonst auf den Teil nach dem letzten „/“).
    static func cleanName(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "\\s*[\\\\/]+\\s*", with: " - ", options: .regularExpression)
        return String(s.trimmingCharacters(in: CharacterSet(charactersIn: " -")).prefix(120))
    }

    /// Teil einer Modell-ID wie `_slug` unter Windows.
    static func slug(_ text: String) -> String {
        let s = text.lowercased().replacingOccurrences(of: "[^\\w.-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "lora" : s
    }

    /// Freier Dateiname in loras/ (Groß- und Kleinschreibung zählt nicht): vorhandene Dateien und Ordner und die
    /// Dateien aller eigenen LoRAs, auch wenn sie gerade fehlen.
    static func freeName(_ name: String, entries: [UserLoRACatalog.Entry]) -> String {
        var taken = Set(entries.map { $0.file.lowercased() })
        taken.formUnion(((try? FileManager.default.contentsOfDirectory(atPath: LoRAFiles.directory.path)) ?? []).map { $0.lowercased() })
        let stem = String(name.dropLast(LoRAFiles.suffix.count))
        var candidate = name, i = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(stem)-\(i)\(LoRAFiles.suffix)"
            i += 1
        }
        return candidate
    }

    /// Ablegen und eintragen. Ist dieselbe Datei (gleiche SHA-256) schon da, bleibt es bei der einen Kopie, sie
    /// bekommt nur die neuen Angaben.
    static func store(part: URL, target: String, family: String, name: String, trigger: String, expert: String,
                      size: Int64, sha256: String) throws -> (LoRAModel, Bool) {
        if let same = UserLoRACatalog.entries.first(where: { !sha256.isEmpty && $0.sha256 == sha256
                                                             && UserLoRACatalog.model($0).installed }) {
            try? FileManager.default.removeItem(at: part)
            let updated = try update(same.id, family: family, trigger: trigger.isEmpty ? nil : trigger,
                                     name: name.isEmpty ? nil : name, expert: expert.isEmpty ? nil : expert)
            return (updated, true)
        }
        return try UserLoRACatalog.mutate { list -> (LoRAModel, Bool) in
            let final = freeName(target, entries: list)
            try FileManager.default.moveItem(at: part, to: LoRAFiles.directory.appendingPathComponent(final))
            let taken = Set(list.map(\.id) + LoRACatalog.fixed.map(\.id))
            let baseID = "lora-upload-\(slug(String(final.dropLast(LoRAFiles.suffix.count))))"
            var id = baseID, i = 2
            while taken.contains(id) {
                id = "\(baseID)-\(i)"
                i += 1
            }
            let cleaned = cleanName(name)
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let entry = UserLoRACatalog.Entry(
                id: id, name: cleaned.isEmpty ? String(final.dropLast(LoRAFiles.suffix.count)) : cleaned,
                family: family, file: final, bytes: size,
                trigger: String(trigger.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                sha256: sha256, added: day, expert: LoRAFiles.experts.contains(expert) ? expert : nil)
            list.append(entry)
            return (UserLoRACatalog.model(entry), false)
        }
    }

    /// Zuordnung einer eigenen LoRA ändern: Basis (unter welchen Modellen sie erscheint), Trigger-Wörter, Anzeigename,
    /// Experte ("" = nach dem Dateinamen). nil lässt ein Feld, wie es ist. Der feste Katalog ist geprüft und bleibt fest.
    static func update(_ id: String, family: String? = nil, trigger: String? = nil, name: String? = nil,
                       expert: String? = nil) throws -> LoRAModel {
        let family = try family.map(checkFamily)
        if let expert { try checkExpert(expert) }
        guard !LoRACatalog.isFixed(id) else {
            throw APIError(400, t("Diese LoRA gehört zum festen Katalog; ihre Zuordnung ist geprüft und bleibt fest.",
                                  "This LoRA belongs to the fixed catalog; its assignment is tested and stays fixed."))
        }
        return try UserLoRACatalog.mutate { list -> LoRAModel in
            guard let i = list.firstIndex(where: { $0.id == id }) else {
                throw APIError(404, t("Unbekannte LoRA: \(id)", "Unknown LoRA: \(id)"))
            }
            if let family { list[i].family = family }
            if let trigger { list[i].trigger = String(trigger.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
            if let name, !cleanName(name).isEmpty { list[i].name = cleanName(name) }
            if expert == "" { list[i].expert = nil } else if let expert { list[i].expert = expert }
            return UserLoRACatalog.model(list[i])
        }
    }

    /// Eine Datei aus dem Dateidialog blockweise als Teildatei nach loras/ kopieren (8 MB je Block, nie die ganze Datei
    /// im Speicher), mit SHA-256 und Fortschritt.
    static func copyFromDisk(_ source: URL, progress: @escaping @Sendable (Double) -> Void) throws -> (part: URL, size: Int64, sha256: String) {
        let total = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.int64Value ?? 0
        try checkSpace(total, in: LoRAFiles.directory)
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw APIError(400, t("Datei nicht lesbar: \(source.lastPathComponent)", "Cannot read file: \(source.lastPathComponent)"))
        }
        defer { try? input.close() }
        let writer = try HashingFileWriter(url: newPart())
        do {
            while true {
                try Task.checkCancellation()
                let block = try autoreleasepool { try input.read(upToCount: 8 * 1024 * 1024) } ?? Data()
                if block.isEmpty { break }
                try writer.write(block)
                if total > 0 { progress(Double(writer.size) / Double(total)) }
            }
        } catch {
            writer.discard()
            throw error
        }
        return (writer.url, writer.size, writer.finish())
    }
}
