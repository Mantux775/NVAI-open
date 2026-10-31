import Foundation

/// Video erzeugen (`POST /api/generate/video`, seit 0.4.8): Felder wie `GenerateVideoRequest` unter Windows, so weit
/// LTX-Video 2B sie nutzt, auch das Startbild (`image_asset_id`). Endbild, Schleife, Ton, DFR, Zeitlupe, Verlängern und
/// LoRAs gibt es nur unter Windows mit LTX-2.5; solche Felder werden mit einer Meldung abgelehnt statt still übergangen.
struct VideoJobRequest: Sendable {
    var prompt: String
    /// LTX-Video 2B oder 13B (`model_id`; ohne Angabe die Wahl im Formular bzw. das empfohlene).
    var model: VideoModel = VideoCatalog.active
    /// Startbild (Bild zu Video); wird mittig auf das Videoformat zugeschnitten.
    var imageAssetID: String?
    var width: Int
    var height: Int
    var frames: Int
    var fps: Int
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    /// Fläche × Bilder für das aktive Modell (je Modell: `VideoModel.maxVoxels`).
    static var maxVoxels: Int { VideoCatalog.active.maxVoxels }

    static func parse(_ body: JSONValue?) throws -> VideoJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (GenerateVideoRequest).", "Expected a JSON object (GenerateVideoRequest)."))
        }
        let prompt = (o["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw APIError(422, t("Das Feld prompt fehlt.", "The field prompt is missing.")) }
        var model = VideoCatalog.active
        if let id = o["model_id"]?.stringValue, !id.isEmpty {
            guard let chosen = VideoCatalog.model(id) else {
                let ids = VideoCatalog.models.map(\.id).joined(separator: ", ")
                throw APIError(404, t("Unbekanntes Videomodell: \(id). Auf dem Mac gibt es \(ids).",
                                      "Unknown video model: \(id). On the Mac there are \(ids)."))
            }
            model = chosen
        }
        let windowsOnly: [(String, Bool)] = [
            ("end_image_asset_id", o["end_image_asset_id"]?.stringValue?.isEmpty == false),
            ("loop", o["loop"]?.boolValue == true),
            ("quality", (o["quality"]?.stringValue ?? "standard") != "standard"),
            ("temporal_upscale", o["temporal_upscale"]?.boolValue == true),
            ("auto_duration", o["auto_duration"]?.boolValue == true),
            ("audio_asset_id", o["audio_asset_id"]?.stringValue?.isEmpty == false),
            ("motion_speed", (o["motion_speed"]?.doubleValue ?? 1) != 1),
            ("extend_asset_id", o["extend_asset_id"]?.stringValue?.isEmpty == false),
            ("loras", !(o["loras"]?.arrayValue ?? []).isEmpty),
        ]
        if let field = windowsOnly.first(where: { $0.1 })?.0 {
            throw APIError(422, t("\(field) gibt es nur in NVAI-open für Windows (LTX-2.5); LTX-Video auf dem Mac macht Text oder Startbild zu Video.",
                                  "\(field) is only available in NVAI-open for Windows (LTX-2.5); LTX-Video on the Mac does text or a start image to video."))
        }
        if let steps = o["steps"]?.intValue, steps != 8 {
            throw APIError(422, t("LTX-Video distilled rechnet fest mit 8 Schritten.", "LTX-Video distilled always uses 8 steps."))
        }
        if let cfg = o["cfg"]?.doubleValue, cfg != 1 {
            throw APIError(422, t("LTX-Video distilled rechnet ohne Gewichtung (cfg 1).", "LTX-Video distilled runs without guidance (cfg 1)."))
        }
        guard model.installed else {
            throw APIError(409, t("\(model.name) ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.",
                                  "\(model.name) is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        let image = o["image_asset_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if image != nil && !model.encoderInstalled {
            throw APIError(409, t("Das Startbild braucht den Bild-Encoder von LTX-Video (1,4 GB Download). In NVAI-open unter „Modelle“ bei LTX-Video 2B „Startbild nachrüsten“ wählen.",
                                  "A start image needs LTX-Video's image encoder (1.4 GB download). In NVAI-open under \"Models\", choose \"Add start image\" for LTX-Video 2B."))
        }
        let width = o["width"]?.intValue ?? 768
        let height = o["height"]?.intValue ?? 512
        let step = model.sizeStep
        guard (256 ... 1280).contains(width), (256 ... 1280).contains(height), width % step == 0, height % step == 0 else {
            throw APIError(422, t("width und height müssen Vielfache von \(step) zwischen 256 und 1280 sein.",
                                  "width and height must be multiples of \(step) between 256 and 1280."))
        }
        let frames = o["frames"]?.intValue ?? 97
        guard frames >= 9, frames <= 257, (frames - 1) % 8 == 0 else {
            throw APIError(422, t("frames muss 8n + 1 sein (9 … 257), etwa 49 = 2 s oder 97 = 4 s bei 24 fps.",
                                  "frames must be 8n + 1 (9 … 257), e.g. 49 = 2 s or 97 = 4 s at 24 fps."))
        }
        guard width * height * frames <= model.maxVoxels else {
            throw APIError(422, t("Zu groß für diesen Mac: höchstens \(model.maxVoxels / (768 * 512)) Bilder bei 768 × 512 (Fläche × Bilder).",
                                  "Too large for this Mac: at most \(model.maxVoxels / (768 * 512)) frames at 768 × 512 (area × frames)."))
        }
        let fps = o["fps"]?.intValue ?? VideoCatalog.fps
        guard (12 ... 30).contains(fps) else {
            throw APIError(422, t("fps muss zwischen 12 und 30 liegen (Vorgabe 24).", "fps must be between 12 and 30 (default 24)."))
        }
        let seed = o["seed"]?.intValue
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }
        return VideoJobRequest(prompt: prompt, model: model, imageAssetID: image, width: width, height: height, frames: frames, fps: fps,
                               seed: seed.map { UInt64($0) }, params: body)
    }
}
