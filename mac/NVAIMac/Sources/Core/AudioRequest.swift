import Foundation

/// Musik oder Klang erzeugen (`POST /api/generate/audio`, seit 0.4.7): Felder wie `GenerateAudioRequest` unter
/// Windows, so weit Stable Audio 3 sie nutzt. Gesang (`lyrics`) gibt es nur mit ACE-Step unter Windows.
struct AudioJobRequest: Sendable {
    var prompt: String
    var seconds: Double
    var steps: Int
    var cfg: Double
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    static func parse(_ body: JSONValue?) throws -> AudioJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (GenerateAudioRequest).", "Expected a JSON object (GenerateAudioRequest)."))
        }
        let prompt = (o["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw APIError(422, t("Das Feld prompt fehlt.", "The field prompt is missing.")) }
        if let id = o["model_id"]?.stringValue, !id.isEmpty, id != AudioCatalog.id {
            throw APIError(404, t("Unbekanntes Audiomodell: \(id)", "Unknown audio model: \(id)"))
        }
        if let lyrics = o["lyrics"]?.stringValue, !lyrics.trimmingCharacters(in: .whitespaces).isEmpty {
            throw APIError(422, t("Gesang (lyrics) gibt es nur mit ACE-Step in NVAI-open für Windows; Stable Audio 3 macht Musik ohne Gesang.",
                                  "Vocals (lyrics) are only available with ACE-Step in NVAI-open for Windows; Stable Audio 3 makes music without vocals."))
        }
        guard AudioCatalog.installed else {
            throw APIError(409, t("Stable Audio 3 ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.",
                                  "Stable Audio 3 is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        let seconds = o["seconds"]?.doubleValue ?? 10
        guard seconds >= 1, seconds <= AudioCatalog.maxSeconds else {
            throw APIError(422, t("seconds muss zwischen 1 und \(Int(AudioCatalog.maxSeconds)) liegen (auf diesem Mac).",
                                  "seconds must be between 1 and \(Int(AudioCatalog.maxSeconds)) (on this Mac)."))
        }
        let steps = o["steps"]?.intValue ?? 8
        guard (1...50).contains(steps) else { throw APIError(422, t("steps muss zwischen 1 und 50 liegen.", "steps must be between 1 and 50.")) }
        let cfg = o["cfg"]?.doubleValue ?? 1
        guard (0...10).contains(cfg) else { throw APIError(422, t("cfg muss zwischen 0 und 10 liegen.", "cfg must be between 0 and 10.")) }
        let seed = o["seed"]?.intValue
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }
        return AudioJobRequest(prompt: prompt, seconds: seconds, steps: steps, cfg: cfg, seed: seed.map { UInt64($0) },
                               params: body)
    }
}
