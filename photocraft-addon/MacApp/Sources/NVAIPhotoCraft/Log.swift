import Foundation

/// Schlichtes Protokoll in `…/ArtCraft-LocalAI/logs/mac-app.log` – für die Fehlersuche, auch per ssh.
enum Log {
    private static let queue = DispatchQueue(label: "NVAIPhotoCraft.Log")
    static let file = AppSettings.dataDirectory.appendingPathComponent("logs/mac-app.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
