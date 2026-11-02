import Foundation

/// Sprecherstimme (`POST /api/generate/speech`, seit 0.5.3): Felder wie `GenerateSpeechRequest` unter Windows. Die
/// Stimme kommt aus einer Beschreibung (`voice`) oder aus einer Aufnahme (`voice_asset_id`, mit `voice_text` wortgenau).
struct SpeechJobRequest: Sendable {
    var text: String
    var voice: String
    var voiceAssetID: String?
    var voiceText: String
    var language: String
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    static func parse(_ body: JSONValue?) throws -> SpeechJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (GenerateSpeechRequest).", "Expected a JSON object (GenerateSpeechRequest)."))
        }
        let text = (o["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError(422, t("Das Feld text fehlt.", "The field text is missing.")) }
        guard text.count <= SpeechCatalog.maxChars else {
            throw APIError(422, t("Der Text ist länger als \(SpeechCatalog.maxChars) Zeichen; in mehrere Zeilen teilen.",
                                  "The text is longer than \(SpeechCatalog.maxChars) characters; split it into several lines."))
        }
        guard SpeechCatalog.matches(o["model_id"]?.stringValue) else {
            throw APIError(404, t("Unbekanntes Sprachmodell: \(o["model_id"]?.stringValue ?? "")",
                                  "Unknown speech model: \(o["model_id"]?.stringValue ?? "")"))
        }
        let voice = (o["voice"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard voice.count <= 600 else {
            throw APIError(422, t("Die Beschreibung der Stimme ist länger als 600 Zeichen.", "The voice description is longer than 600 characters."))
        }
        let voiceText = (o["voice_text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard voiceText.count <= 2000 else {
            throw APIError(422, t("voice_text ist länger als 2000 Zeichen.", "voice_text is longer than 2000 characters."))
        }
        let language = (o["language"]?.stringValue ?? "auto").lowercased()
        guard SpeechCatalog.languages.contains(language) else {
            throw APIError(422, t("Sprache nicht unterstützt: \(language). Möglich: \(SpeechCatalog.languages.joined(separator: ", "))",
                                  "Language not supported: \(language). Possible: \(SpeechCatalog.languages.joined(separator: ", "))"))
        }
        let seed = o["seed"]?.intValue
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }
        guard SpeechCatalog.installed else {
            throw APIError(409, t("Die Sprecherstimme (Qwen3-TTS) ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.",
                                  "The narrator voice (Qwen3-TTS) is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        let asset = o["voice_asset_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return SpeechJobRequest(text: text, voice: voice, voiceAssetID: asset, voiceText: voiceText, language: language,
                                seed: seed.map { UInt64($0) }, params: body)
    }
}
