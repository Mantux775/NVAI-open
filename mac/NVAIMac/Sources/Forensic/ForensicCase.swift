import Foundation

/// Fälle der Ton-Forensik auf dem Mac (seit 0.5.11, Stufe 2; Nutzer 20.11.2026: „Mac-Modul Stufe 2 angehen“). Ein Fall ist
/// ein Ordner im Format des Prüfpakets (`server/nvai/audio_package.py`, gelesen von `frontend/src/review/local.ts`):
///
///     <Fall>/NVAI-Pruefer.html, LIESMICH.txt, PRUEFSUMMEN.sha256
///     <Fall>/fall/manifest.json, projekt.json, transkript.json (nach der Spracherkennung)
///     <Fall>/fall/original/<Spur>.wav   Originalton je Kanal, bitgenau (Ganzzahl-PCM bleibt Ganzzahl)
///     <Fall>/fall/proxy/<Spur>.m4a      Ton zum Abspielen (AAC)
///     <Fall>/fall/peaks|spec|data/      Wellenform, Spektrogramm in vier Stufen, Sprachaktivität
///     <Fall>/fall/video/<Datei>         das Video, wenn die Quelle eines hatte
///     <Fall>/bearbeitung/               Änderungen der Prüf-App und ihr Prüfprotokoll
///
/// So öffnet dieselbe Prüf-App Fälle vom Mac und Prüfpakete aus Windows, und ein Fall vom Mac lässt sich als Ordner
/// weitergeben (Prüf-App in Edge oder Chrome). Was der Mac selbst rechnet (Fall anlegen, Spracherkennung, Übersetzung),
/// schreibt er nach `fall/` und trägt die Prüfsummen neu ein; was Prüfer ändern, steht nur in `bearbeitung/`.
enum ForensicCases {
    static let format = "nvai-pruefpaket"
    static let formatVersion = 1
    static let reviewApp = "NVAI-Pruefer.html"
    /// Farben der Spuren wie unter Windows (`audio_lab.COLORS`)
    static let colors = ["#76b900", "#7cc4ff", "#ffd166", "#ff8fab", "#b39ddb", "#80cbc4", "#ffab91"]

    /// Ablage der Fälle: ~/Library/Application Support/NV-AI/Forensik, änderbar über `forensicDirectory`.
    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: "forensicDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NV-AI/Forensik", isDirectory: true)
    }

    static var program: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "NVAI-open \(v) (Mac)"
    }

    /// Datei- und Ordnername, den auch Windows annimmt (wie `audio_package._safe`).
    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var out = ""
        var lastBad = false
        for u in name.unicodeScalars {
            if bad.contains(u) {
                if !lastBad { out += "_" }
                lastBad = true
            } else {
                out.unicodeScalars.append(u)
                lastBad = false
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Fall" : String(trimmed.prefix(80))
    }

    /// Freier Ordnername unter `parent`: „Name“, „Name (2)“ …
    static func uniqueFolder(in parent: URL, name: String) -> URL {
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var k = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) (\(k))", isDirectory: true)
            k += 1
        }
        return url
    }

    static func isCase(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("fall/manifest.json").path)
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    static func newProjectID() -> String {
        "aud_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    // MARK: Arbeitsordner von „Neuer Fall“

    /// Ein Fall entsteht im versteckten Ordner „.neu-…“ und bekommt erst am Ende seinen Namen. Daneben liegt
    /// „.neu-….lock“, exklusiv gesperrt (O_EXLOCK), solange der Auftrag läuft; nach einem Absturz gibt macOS die Sperre
    /// frei. So erkennt `removeStaleWork` beim Start, welcher Ordner ein Rest ist und welcher noch entsteht (auch in einem
    /// zweiten Programm, etwa einem Prüfstand).
    final class Work {
        let url: URL
        private let lockPath: String
        private var fd: Int32
        private var done = false

        init(in root: URL) throws {
            let name = ".neu-\(UUID().uuidString.prefix(8))"
            url = root.appendingPathComponent(name, isDirectory: true)
            lockPath = root.appendingPathComponent(name + ".lock").path
            // erst die Sperre, dann der Ordner: Einen entstehenden Ordner ohne gesperrte Sperrdatei gibt es so nie
            fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
            if fd < 0 { fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644) }   // Datenträger ohne Sperren
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                finish()
                throw error
            }
        }

        /// Sperre lösen und ihre Datei löschen, wenn der Ordner umbenannt oder gelöscht ist.
        func finish() {
            guard !done else { return }
            done = true
            unlink(lockPath)
            if fd >= 0 { Darwin.close(fd) }
        }

        deinit { finish() }
    }

    /// Reste von „Neuer Fall“ (die App wurde beendet oder stürzte ab, während ein Fall entstand) beim Start löschen, wie
    /// `FormBody.removeStaleParts`: jeden „.neu-…“-Ordner, dessen Sperrdatei sich sperren lässt oder fehlt (Fassungen
    /// vor der Sperre). Woran noch ein Auftrag arbeitet, bleibt; ebenso alles auf Datenträgern ohne Sperren. Ergebnis:
    /// die Namen der gelöschten Ordner.
    @discardableResult
    static func removeStaleWork() -> [String] {
        let fm = FileManager.default
        let root = directory
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasPrefix(".neu-") && !name.hasSuffix(".lock") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let lock = root.appendingPathComponent(name + ".lock").path
            var fd: Int32 = -1
            if fm.fileExists(atPath: lock) {
                fd = Darwin.open(lock, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { continue }   // gesperrt: Der Fall entsteht noch
            }
            if (try? fm.removeItem(at: folder)) != nil { removed.append(name) }
            if fd >= 0 {
                unlink(lock)
                Darwin.close(fd)
            }
        }
        // Sperrdateien ohne Ordner (Absturz zwischen Umbenennen und Aufräumen)
        for name in names where name.hasPrefix(".neu-") && name.hasSuffix(".lock") && !names.contains(String(name.dropLast(5))) {
            let lock = root.appendingPathComponent(name).path
            let fd = Darwin.open(lock, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            unlink(lock)
            Darwin.close(fd)
        }
        return removed
    }

    /// Die Fälle im Ablageordner, neueste zuerst.
    static func list() -> [ForensicCaseSummary] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { ForensicCaseSummary(folder: $0) }.sorted { $0.created > $1.created }
    }

    /// Kurzanleitung im Fallordner, wie im Prüfpaket aus Windows, dazu der Weg am Mac.
    static func readme(name: String, created: String) -> String {
        """
        NVAI-open · Prüfpaket „\(name)“ (erstellt \(created) mit \(program))

        DEUTSCH
        1. NVAI-Pruefer.html mit Microsoft Edge oder Google Chrome öffnen (Doppelklick; sonst Rechtsklick → Öffnen mit).
           Am Mac: in NVAI-open unter „Ton-Forensik“ → „Fall öffnen …“.
        2. Namen eintragen, „Fall öffnen …“ wählen und diesen Ordner wählen (den Ordner, in dem NVAI-Pruefer.html liegt).
           Das Bearbeiten erlauben, wenn der Browser fragt.
        3. Ansehen, anhören, Blöcke der Übersetzer-Spur prüfen und korrigieren, Notizen setzen, exportieren.
        Ohne Installation, ohne Internet, ohne KI. Änderungen speichert die App im Unterordner „bearbeitung“ (mit einem
        Prüfprotokoll); die gelieferten Dateien bleiben unverändert. Prüfen lassen sie sich mit PRUEFSUMMEN.sha256, z. B.
          Windows (PowerShell):  Get-FileHash -Algorithm SHA256 <Datei>
          Mac/Linux:             shasum -a 256 -c PRUEFSUMMEN.sha256
        Texte der KI (Erkennung, Übersetzung) sind Entwürfe, bis sie als geprüft markiert sind.

        ENGLISH
        1. Open NVAI-Pruefer.html with Microsoft Edge or Google Chrome (double-click; otherwise right-click → Open with).
           On a Mac: in NVAI-open under “Audio forensics” → “Open case …”.
        2. Enter your name, choose “Open case …” and select this folder (the one containing NVAI-Pruefer.html). Allow
           editing when the browser asks.
        3. View, listen, check and correct blocks of the translation track, set notes, export.
        No installation, no internet, no AI. The app saves changes in the subfolder “bearbeitung” (with a review log); the
        delivered files stay unchanged and can be verified with PRUEFSUMMEN.sha256 (see above). AI texts (recognition,
        translation) are drafts until marked as checked.

        """
    }

    /// Nach einem Rechenschritt des Macs (Spracherkennung, Übersetzung): Blockzahl im Manifest und Prüfsummen neu.
    /// Große Dateien, die sich nicht geändert haben (Originalton, Video), werden nicht noch einmal gelesen.
    static func refreshDelivered(_ folder: URL, segments: Int?, isCancelled: () -> Bool = { false }) throws {
        let manifestURL = folder.appendingPathComponent("fall/manifest.json")
        if let segments, var m = ForensicJSON.object(manifestURL) {
            m["segments"] = segments
            try ForensicJSON.data(m).write(to: manifestURL, options: .atomic)
        }
        var known = (try? ForensicImport.checksumsOf(folder)) ?? [:]
        let changed: (String) -> Bool = { $0.hasPrefix("fall/") && ($0.hasSuffix(".json") || $0.hasSuffix(".vad")) }
        for key in known.keys where changed(key) { known[key] = nil }
        _ = try writeChecksums(folder, known: known, isCancelled: isCancelled)
    }

    /// Prüfsummen aller gelieferten Dateien neu schreiben (alles außer `bearbeitung/` und der Summendatei selbst).
    /// `known`: schon bekannte Summen (relativer Pfad → SHA-256), die nicht noch einmal gelesen werden müssen.
    static func writeChecksums(_ folder: URL, known: [String: String] = [:], isCancelled: () -> Bool = { false }) throws -> Int {
        let fm = FileManager.default
        var sums: [String: String] = [:]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let rel = String(full.dropFirst(base.count + 1))
            if rel == "PRUEFSUMMEN.sha256" || rel.hasPrefix("bearbeitung/") || rel.hasSuffix(".part") { continue }
            sums[rel] = try known[rel] ?? ForensicHash.sha256(url, isCancelled: isCancelled)
        }
        let text = sums.keys.sorted().map { "\(sums[$0]!) *\($0)\n" }.joined()
        try Data(text.utf8).write(to: folder.appendingPathComponent("PRUEFSUMMEN.sha256"), options: .atomic)
        return sums.count
    }
}

/// Ein Fall in der Liste des Bereichs „Ton-Forensik“.
struct ForensicCaseSummary: Identifiable, Hashable {
    var id: String { folder.path }
    let folder: URL
    let name: String
    let projectID: String
    let created: String
    let duration: Double
    let tracks: Int
    let hasVideo: Bool
    let segments: Int
    let program: String

    init?(folder: URL) {
        guard let m = ForensicJSON.object(folder.appendingPathComponent("fall/manifest.json")),
              m["format"] as? String == ForensicCases.format else { return nil }
        self.folder = folder
        name = m["name"] as? String ?? folder.lastPathComponent
        projectID = m["project_id"] as? String ?? ""
        created = m["created"] as? String ?? ""
        duration = (m["duration"] as? NSNumber)?.doubleValue ?? 0
        tracks = (m["proxies"] as? [String: Any])?.count ?? 0
        hasVideo = (m["video"] as? String).map { !$0.isEmpty } ?? false
        segments = (m["segments"] as? NSNumber)?.intValue ?? 0
        program = m["program"] as? String ?? ""
    }
}
