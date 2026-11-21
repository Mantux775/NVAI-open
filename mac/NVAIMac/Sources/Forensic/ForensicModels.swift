import Foundation

/// KI-Modelle der Ton-Forensik auf dem Mac (seit 0.5.11). Wahl des Nutzers (20.11.2026): Whisper **large-v3** wie unter
/// Windows (Core ML von Argmax, 3,1 GB), davor der Sprachfinder Silero VAD (Core ML, 1 MB), damit Whisper nur hört, wo
/// jemand spricht (sonst erfindet es auf Wind und Lärm Sätze). Geladen wird über den fortsetzbaren `Downloader` in den
/// Modellordner der App, Dateiliste von der Hugging-Face-Schnittstelle.
enum ForensicModel: String, CaseIterable, Identifiable, Sendable {
    case whisper = "whisper-large-v3-coreml"
    case vad = "silero-vad-coreml"

    var id: String { rawValue }

    static func find(_ id: String?) -> ForensicModel? { id.flatMap { ForensicModel(rawValue: $0) } }

    var name: String {
        switch self {
        case .whisper: return t("Whisper large-v3 (Spracherkennung, Core ML)", "Whisper large-v3 (speech recognition, Core ML)")
        case .vad: return t("Silero VAD (Sprache finden, Core ML)", "Silero VAD (find speech, Core ML)")
        }
    }

    /// Hugging-Face-Repo und Unterordner
    var repo: String {
        switch self {
        case .whisper: return "argmaxinc/whisperkit-coreml"
        case .vad: return "FluidInference/silero-vad-coreml"
        }
    }

    var folder: String {
        switch self {
        case .whisper: return "openai_whisper-large-v3"
        case .vad: return "silero-vad-unified-v6.0.0.mlmodelc"
        }
    }

    var sizeGB: Double { self == .whisper ? 3.09 : 0.001 }

    var by: String { self == .whisper ? "OpenAI, Core ML: Argmax" : "Silero, Core ML: FluidInference" }
    var license: String { "MIT" }
    var licenseURL: String {
        self == .whisper ? "https://huggingface.co/argmaxinc/whisperkit-coreml"
            : "https://huggingface.co/FluidInference/silero-vad-coreml"
    }

    /// Tokenizer von Whisper (klein, nicht gesperrt): WhisperKit sucht ihn unter `<Basis>/models/openai/whisper-large-v3`.
    static let tokenizerRepo = "openai/whisper-large-v3"

    var directory: URL { Settings.modelsDirectory.appendingPathComponent("\(repo)/\(folder)", isDirectory: true) }

    static var tokenizerDirectory: URL { Settings.modelsDirectory.appendingPathComponent(tokenizerRepo, isDirectory: true) }

    /// Basis für WhisperKit (`tokenizerFolder`): der Ordner über „models“
    static var tokenizerBase: URL { Settings.modelsDirectory.deletingLastPathComponent() }

    private var marker: URL { directory.appendingPathComponent(".nvai-complete") }

    var installed: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: marker.path) else { return false }
        return self != .whisper || fm.fileExists(atPath: Self.tokenizerDirectory.appendingPathComponent("tokenizer.json").path)
    }

    struct RemoteFile {
        let path: String
        let size: Int64
    }

    /// Dateien eines Ordners im Repo (rekursiv) laut Hugging Face.
    static func listFiles(repo: String, folder: String) async throws -> [RemoteFile] {
        let path = folder.isEmpty ? "" : "/\(folder)"
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main\(path)?recursive=1") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token = Settings.hfToken, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ForensicError(t("Dateiliste von Hugging Face nicht lesbar (\(repo)).", "Could not read the file list from Hugging Face (\(repo))."))
        }
        return items.compactMap { item in
            guard item["type"] as? String == "file", let p = item["path"] as? String else { return nil }
            let lfs = (item["lfs"] as? [String: Any])?["size"] as? NSNumber
            let size = lfs ?? (item["size"] as? NSNumber) ?? 0
            return RemoteFile(path: p, size: size.int64Value)
        }
    }

    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var files = try await Self.listFiles(repo: repo, folder: folder).map { (repo, $0) }
        if self == .whisper {
            // Tokenizer und kleine Begleitdateien, keine Gewichte (die liegen in Core ML vor)
            let weights = [".safetensors", ".bin", ".msgpack", ".h5", ".onnx", ".ot", ".pt", ".gguf"]
            let tok = try await Self.listFiles(repo: Self.tokenizerRepo, folder: "")
                .filter { f in !weights.contains { f.path.hasSuffix($0) } && !f.path.contains("/") && f.size < 20_000_000 }
            files += tok.map { (Self.tokenizerRepo, $0) }
        }
        files.removeAll { $0.1.path.hasSuffix(".gitattributes") || $0.1.path.hasSuffix("README.md") }
        guard !files.isEmpty else { throw ForensicError(t("Keine Dateien gefunden.", "No files found.")) }
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.1.size })
        var before: Int64 = 0
        let fm = FileManager.default
        for (repo, file) in files {
            try Task.checkCancellation()
            let target = Settings.modelsDirectory.appendingPathComponent("\(repo)/\(file.path)")
            let have = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? -1
            if have != file.size {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoded = file.path.split(separator: "/").map {
                    String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
                }.joined(separator: "/")
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)") else { continue }
                let offset = before
                let name = (file.path as NSString).lastPathComponent
                var headers: [String: String] = [:]
                if let token = Settings.hfToken, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
                let tmp = try await Downloader().lade(url, headers: headers) { stand in
                    progress(min(0.99, Double(offset + stand.geladen) / Double(total)), t("lädt \(name)", "downloading \(name)"))
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: tmp, to: target)
            }
            before += file.size
        }
        try Data().write(to: marker)
        progress(1, t("fertig", "done"))
    }

    func delete() throws {
        try? FileManager.default.removeItem(at: directory)
        if self == .whisper { try? FileManager.default.removeItem(at: Self.tokenizerDirectory) }
    }

    /// Für den Hinweis in der Übersetzer-Spur (`credits`, wie `audio_forensic.transcript_credits`)
    var credit: [String: Any] {
        ["role": self == .whisper ? "asr" : "vad", "id": self == .whisper ? "whisper_large_v3" : "silero_vad",
         "name": self == .whisper ? "Whisper large-v3 (Core ML)" : "Silero VAD 6.0 (Core ML)", "by": by,
         "license": license, "license_url": licenseURL]
    }
}
