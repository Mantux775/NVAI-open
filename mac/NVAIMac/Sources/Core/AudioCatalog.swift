import Foundation

/// Musik und Klänge (seit 0.4.7): Stable Audio 3 Medium (Stability AI) über MLX, aus speech-swift übernommen
/// (`Packages/stable-audio-3-swift`). Unter Windows rechnet dasselbe Modell instrumentale Musik; laut Modellkarte ist
/// die Medium-Fassung das allgemeine Modell für Musik und Soundeffekte. Gerechnet wird wie unter Windows mit
/// 8 Schritten und cfg 1; der Prompt bekommt „Length: N seconds“ angehängt, darauf ist das Modell trainiert.
enum AudioCatalog {
    static let id = "stable-audio-3-medium-mlx8"
    static let repo = "aufklarer/Stable-Audio-3-DiT-Medium-MLX-8bit"

    /// Dateien mit Größe laut Hugging Face; den SAME-Encoder (1,7 GB) braucht nur Audio zu Audio.
    static let files: [(name: String, bytes: Int64)] = [
        ("README.md", 4_070), ("config.json", 38), ("manifest.json", 742),
        ("dit_medium/manifest.json", 430), ("same_l_decoder/manifest.json", 434), ("t5gemma/manifest.json", 409),
        ("t5gemma/model.safetensors", 567_416_487), ("dit_medium/model.safetensors", 1_555_822_118),
        ("same_l_decoder/model.safetensors", 1_704_270_957),
    ]

    static var downloadGB: Double { Double(files.reduce(Int64(0)) { $0 + $1.bytes }) / 1e9 }

    static var directory: URL { Settings.modelsDirectory.appendingPathComponent(repo) }

    static var installed: Bool {
        files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            return Double(size) >= Double(file.bytes) * 0.95
        }
    }

    /// Längste Dauer je Auftrag: auf 8 GB gemessen (siehe AudioEngine), darüber wie unter Windows bis 300 s.
    static var maxSeconds: Double { SystemInfo.memoryGB <= 8 ? 60 : SystemInfo.memoryGB <= 16 ? 120 : 300 }

    static func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var before: Int64 = 0
        for file in files {
            let target = directory.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? 0
            if Double(size) < Double(file.bytes) * 0.95 {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.name)")!
                let offset = before
                let tmp = try await Downloader().lade(url) { stand in
                    progress(Double(offset + stand.geladen) / Double(total), t("lädt \(file.name)", "downloading \(file.name)"))
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
            }
            before += file.bytes
        }
        progress(1, t("fertig", "done"))
    }

    static func delete() {
        try? FileManager.default.removeItem(at: directory)
    }

    static var name: String { t("Stable Audio 3 Medium (8 Bit, Musik und Klänge)", "Stable Audio 3 Medium (8-bit, music and sounds)") }

    static var description: String {
        t("Stable Audio 3 Medium von Stability AI als MLX-Fassung (DiT in 8 Bit). Erzeugt Musik ohne Gesang und Klänge, "
          + "Stereo mit 44,1 kHz. Prompt als ein Satz: Gattung mit Hauptinstrumenten, Stimmung, dann „BPM: 100.“; die "
          + "Länge hängt NVAI-open selbst an. Lizenz: Stability AI Community License, frei bis 1 Mio. US-$ Jahresumsatz.",
          "Stable Audio 3 Medium by Stability AI as an MLX build (DiT in 8-bit). Generates music without vocals and "
          + "sounds, stereo at 44.1 kHz. Prompt as one sentence: genre with lead instruments, mood, then \"BPM: 100.\"; "
          + "NVAI-open appends the length itself. License: Stability AI Community License, free below US$1M annual revenue.")
    }

    /// Wie `ModelInfo` eines Audiomodells unter Windows.
    static var info: [String: Any] {
        let ok = installed
        return [
            "id": id, "name": name, "kind": "audio", "family": "stable_audio_3", "workflow": "stable_audio_3",
            "files": files.filter { $0.name.hasSuffix(".safetensors") }.map {
                ["repo": repo, "file": $0.name, "target": "audio", "installed": ok,
                 "local_path": directory.appendingPathComponent($0.name).path,
                 "size_gb": (Double($0.bytes) / 1e7).rounded() / 100] as [String: Any]
            },
            "size_gb": (downloadGB * 100).rounded() / 100, "vram_gb": 5, "license": "Stability AI Community License",
            "commercial_ok": true, "warning": t("Kommerziell nur unter 1 Mio. US-$ Jahresumsatz.",
                                                "Commercial use only below US$1M annual revenue."),
            "best_for": t("Musik ohne Gesang und Klänge", "Music without vocals and sounds"), "description": description,
            "pros": [String](), "cons": [String](), "installed": ok, "partially_installed": false,
            "disk_gb": ok ? (downloadGB * 100).rounded() / 100 : 0, "runnable": ok, "favorite": false, "fits_vram": "ja",
            "engine": "mlx",
            "features": ["steps": 8, "cfg": 1.0, "max_seconds": maxSeconds, "lyrics": false,
                         "prompt_hint": t("Ein Satz: Gattung mit Hauptinstrumenten, Stimmung, dann „BPM: 100.“",
                                          "One sentence: genre with lead instruments, mood, then \"BPM: 100.\"")] as [String: Any],
        ]
    }

    /// Prompt wie unter Windows (`workflows.stable_audio_3`): eine Längenangabe im Text ersetzen, dann
    /// „Length: N seconds“ passend zur Dauer anhängen.
    static func prompt(_ text: String, seconds: Double) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = body.range(of: #"[\s.]*Length:\s*\d+(?:[.,]\d+)?\s*(?:seconds|secs?|s)\b\.?\s*$"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            body.removeSubrange(range)
        }
        while body.hasSuffix(".") || body.hasSuffix(" ") { body.removeLast() }
        return "\(body). Length: \(Int(seconds.rounded())) seconds"
    }
}
