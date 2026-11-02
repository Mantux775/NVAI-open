import Foundation

/// Sprecherstimme (seit 0.5.3): Qwen3-TTS (Alibaba, Apache-2.0) über MLX, Swift-Port aus mlx-audio-swift
/// (`Packages/qwen3-tts-swift`, dort NVAI-OPEN-CHANGES.md). Zwei Fassungen wie unter Windows: VoiceDesign macht eine
/// Stimme aus einer Beschreibung (1.7B, 4 Bit), Base übernimmt eine Stimme aus einer Aufnahme (0.6B, 8 Bit; Qwen maß
/// für Deutsch mit 0.6B sogar weniger Wortfehler als mit 1.7B). Auf dem Mac mini M1 mit 8 GB gemessen: Beschreiben
/// 0,8-fache Echtzeit, Speicherspitze 3,3 GB.
enum SpeechCatalog {
    static let id = "qwen3-tts-mlx"
    /// Die Kennung unter Windows: Studio-Projekte und Clients, die sie nennen, bekommen hier dasselbe Modell.
    static let windowsID = "qwen3-tts-1.7b"
    static let designRepo = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit"
    static let baseRepo = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    static let languages = ["auto", "de", "en", "fr", "es", "it", "pt", "ru", "zh", "ja", "ko"]
    static let maxChars = 1500

    /// Dateien mit Größe laut Hugging Face (README und .gitattributes braucht niemand).
    static let designFiles: [(name: String, bytes: Int64)] = [
        ("config.json", 5_437), ("generation_config.json", 245), ("merges.txt", 1_671_839),
        ("model.safetensors", 1_625_226_859), ("model.safetensors.index.json", 71_786),
        ("preprocessor_config.json", 127), ("speech_tokenizer/config.json", 2_336),
        ("speech_tokenizer/configuration.json", 76), ("speech_tokenizer/model.safetensors", 682_293_092),
        ("speech_tokenizer/preprocessor_config.json", 234), ("tokenizer_config.json", 7_344),
        ("vocab.json", 2_776_833),
    ]
    static let baseFiles: [(name: String, bytes: Int64)] = [
        ("config.json", 5_522), ("generation_config.json", 245), ("merges.txt", 1_671_839),
        ("model.safetensors", 1_304_461_214), ("model.safetensors.index.json", 77_731),
        ("preprocessor_config.json", 127), ("speech_tokenizer/config.json", 2_336),
        ("speech_tokenizer/configuration.json", 76), ("speech_tokenizer/model.safetensors", 682_293_092),
        ("speech_tokenizer/preprocessor_config.json", 234), ("tokenizer_config.json", 7_344),
        ("vocab.json", 2_776_833),
    ]

    static var designDirectory: URL { Settings.modelsDirectory.appendingPathComponent(designRepo) }
    static var baseDirectory: URL { Settings.modelsDirectory.appendingPathComponent(baseRepo) }

    static var downloadGB: Double {
        Double((designFiles + baseFiles).reduce(Int64(0)) { $0 + $1.bytes }) / 1e9
    }

    private static func complete(_ files: [(name: String, bytes: Int64)], in directory: URL) -> Bool {
        files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            return Double(size) >= Double(file.bytes) * 0.95
        }
    }

    static var installed: Bool {
        complete(designFiles, in: designDirectory) && complete(baseFiles, in: baseDirectory)
    }

    /// Gehört eine Modellkennung zur Sprecherstimme (auch die Windows-Kennung)?
    static func matches(_ modelID: String?) -> Bool {
        guard let modelID, !modelID.isEmpty else { return true }
        return modelID == id || modelID == windowsID
    }

    static func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let parts = designFiles.map { (designRepo, designDirectory, $0) } + baseFiles.map { (baseRepo, baseDirectory, $0) }
        let total = parts.reduce(Int64(0)) { $0 + $1.2.bytes }
        var before: Int64 = 0
        for (repo, directory, file) in parts {
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
        try? FileManager.default.removeItem(at: designDirectory)
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    static var name: String { t("Qwen3-TTS (Sprecherstimme)", "Qwen3-TTS (narrator voice)") }

    static var description: String {
        t("Sprecherstimme von Alibabas Qwen-Team als MLX-Fassung: eine Stimme aus einer Beschreibung (VoiceDesign 1.7B, "
          + "4 Bit) oder aus einer Aufnahme von wenigen Sekunden (Base 0.6B, 8 Bit), in zehn Sprachen, darunter Deutsch "
          + "und Englisch. Im Studio wird die erste Zeile einer Stimme zur Vorlage der übrigen. Lizenz: Apache-2.0, "
          + "kommerziell ohne Umsatzgrenze. Stimmen nur aus Aufnahmen übernehmen, deren Sprecher zugestimmt haben.",
          "Narrator voice by Alibaba's Qwen team as an MLX build: a voice from a description (VoiceDesign 1.7B, 4-bit) or "
          + "from a recording of a few seconds (Base 0.6B, 8-bit), in ten languages including English and German. In the "
          + "Studio the first line of a voice becomes the reference for the others. License: Apache-2.0, commercial use "
          + "without a revenue cap. Only take voices over from recordings whose speakers agreed.")
    }

    /// Wie `ModelInfo` des Sprachmodells unter Windows.
    static var info: [String: Any] {
        let ok = installed
        let files = designFiles.filter { $0.name.hasSuffix(".safetensors") }.map { (designRepo, designDirectory, $0) }
            + baseFiles.filter { $0.name.hasSuffix(".safetensors") }.map { (baseRepo, baseDirectory, $0) }
        return [
            "id": id, "name": name, "kind": "speech", "family": "qwen3_tts", "workflow": "qwen3tts",
            "files": files.map { repo, directory, file in
                ["repo": repo, "file": file.name, "target": "speech", "installed": ok,
                 "local_path": directory.appendingPathComponent(file.name).path,
                 "size_gb": (Double(file.bytes) / 1e7).rounded() / 100] as [String: Any]
            },
            "size_gb": (downloadGB * 100).rounded() / 100, "vram_gb": 4, "license": "Apache-2.0",
            "commercial_ok": true, "installed": ok, "best_for": t("Sprecherstimme: beschreiben oder aus einer Aufnahme",
                                                                   "Narrator voice: describe it or take it over"),
            "description": description,
            "features": ["languages": languages, "voice_design": true, "voice_clone": true, "max_chars": maxChars] as [String: Any],
        ]
    }
}
