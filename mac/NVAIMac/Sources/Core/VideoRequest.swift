import Foundation

/// Video erzeugen (`POST /api/generate/video`, seit 0.4.8): Felder wie `GenerateVideoRequest` unter Windows, so weit
/// LTX-Video 2B sie nutzt, auch das Startbild (`image_asset_id`). Endbild, Schleife, Ton, DFR, Zeitlupe, Verlängern und
/// LoRAs gibt es nur unter Windows mit LTX-2.5; solche Felder werden mit einer Meldung abgelehnt statt still übergangen.
struct VideoJobRequest: Sendable {
    var prompt: String
    /// Startbild (Bild zu Video); wird mittig auf das Videoformat zugeschnitten.
    var imageAssetID: String?
    var width: Int
    var height: Int
    var frames: Int
    var fps: Int
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    /// Am 8-GB-M1 gemessen bis 768 × 512 × 97 Bilder (Spitze 6,2 GB); darüber das Doppelte bzw. LTX' Empfehlung
    /// (unter 720 × 1280, unter 257 Bildern).
    static var maxVoxels: Int {
        let measured = 768 * 512 * 97
        return SystemInfo.memoryGB <= 8 ? measured : SystemInfo.memoryGB <= 16 ? 2 * measured : 1280 * 704 * 257
    }

    static func parse(_ body: JSONValue?) throws -> VideoJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (GenerateVideoRequest).", "Expected a JSON object (GenerateVideoRequest)."))
        }
        let prompt = (o["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw APIError(422, t("Das Feld prompt fehlt.", "The field prompt is missing.")) }
        if let id = o["model_id"]?.stringValue, !id.isEmpty, id != VideoCatalog.id {
            throw APIError(404, t("Unbekanntes Videomodell: \(id). Auf dem Mac gibt es \(VideoCatalog.id).",
                                  "Unknown video model: \(id). On the Mac there is \(VideoCatalog.id)."))
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
            throw APIError(422, t("\(field) gibt es nur in NVAI-open für Windows (LTX-2.5); LTX-Video 2B auf dem Mac macht Text oder Startbild zu Video.",
                                  "\(field) is only available in NVAI-open for Windows (LTX-2.5); LTX-Video 2B on the Mac does text or a start image to video."))
        }
        if let steps = o["steps"]?.intValue, steps != 8 {
            throw APIError(422, t("LTX-Video 2B distilled rechnet fest mit 8 Schritten.", "LTX-Video 2B distilled always uses 8 steps."))
        }
        if let cfg = o["cfg"]?.doubleValue, cfg != 1 {
            throw APIError(422, t("LTX-Video 2B distilled rechnet ohne Gewichtung (cfg 1).", "LTX-Video 2B distilled runs without guidance (cfg 1)."))
        }
        guard VideoCatalog.installed else {
            throw APIError(409, t("LTX-Video 2B ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.",
                                  "LTX-Video 2B is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        let image = o["image_asset_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if image != nil && !VideoCatalog.encoderInstalled {
            throw APIError(409, t("Das Startbild braucht den Bild-Encoder von LTX-Video (1,4 GB Download). In NVAI-open unter „Modelle“ bei LTX-Video 2B „Startbild nachrüsten“ wählen.",
                                  "A start image needs LTX-Video's image encoder (1.4 GB download). In NVAI-open under \"Models\", choose \"Add start image\" for LTX-Video 2B."))
        }
        let width = o["width"]?.intValue ?? 768
        let height = o["height"]?.intValue ?? 512
        guard (256 ... 1280).contains(width), (256 ... 1280).contains(height), width % 32 == 0, height % 32 == 0 else {
            throw APIError(422, t("width und height müssen Vielfache von 32 zwischen 256 und 1280 sein.",
                                  "width and height must be multiples of 32 between 256 and 1280."))
        }
        let frames = o["frames"]?.intValue ?? 97
        guard frames >= 9, frames <= 257, (frames - 1) % 8 == 0 else {
            throw APIError(422, t("frames muss 8n + 1 sein (9 … 257), etwa 49 = 2 s oder 97 = 4 s bei 24 fps.",
                                  "frames must be 8n + 1 (9 … 257), e.g. 49 = 2 s or 97 = 4 s at 24 fps."))
        }
        guard width * height * frames <= maxVoxels else {
            throw APIError(422, t("Zu groß für diesen Mac: höchstens \(maxVoxels / (768 * 512)) Bilder bei 768 × 512 (Fläche × Bilder).",
                                  "Too large for this Mac: at most \(maxVoxels / (768 * 512)) frames at 768 × 512 (area × frames)."))
        }
        let fps = o["fps"]?.intValue ?? VideoCatalog.fps
        guard (12 ... 30).contains(fps) else {
            throw APIError(422, t("fps muss zwischen 12 und 30 liegen (Vorgabe 24).", "fps must be between 12 and 30 (default 24)."))
        }
        let seed = o["seed"]?.intValue
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }
        return VideoJobRequest(prompt: prompt, imageAssetID: image, width: width, height: height, frames: frames, fps: fps,
                               seed: seed.map { UInt64($0) }, params: body)
    }
}
