import Foundation

/// Protokoll unter ~/Library/Logs/NV-AI/nvai.log – die Datei, die Tester mitschicken.
/// Dazu NSLog, damit es auch in `log show --predicate 'process == "NV-AI"'` erscheint.
enum AppLog {
    private static let queue = DispatchQueue(label: "nvai.log")
    private static let maxBytes = 5 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NV-AI", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("nvai.log") }

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("FEHLER", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        NSLog("NV-AI %@ %@", level, message)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // Einfache Rotation: ab 5 MB wird die alte Datei zu nvai.1.log.
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("nvai.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
