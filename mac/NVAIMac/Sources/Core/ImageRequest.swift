import Foundation

/// Fehler mit HTTP-Status und Text wie bei FastAPI (`{"detail": "…"}`).
struct APIError: Error, LocalizedError {
    let status: Int
    let detail: String
    init(_ status: Int, _ detail: String) { self.status = status; self.detail = detail }
    var errorDescription: String? { detail }
}

/// Ein Bildauftrag, geprüft und mit Standardwerten ergänzt.
/// Quelle ist `GenerateImageRequest` aus dem NVAI-open-Vertrag; was das gewählte Modell nicht kann,
/// wird klar abgelehnt statt still ignoriert – außer dem negativen Prompt bei FLUX.2 Klein: der
/// wirkt bei destillierten Modellen (cfg 1) nicht, und die PhotoCraft-App schickt ihn beim Füllen mit.
struct ImageJobRequest: Sendable {
    var prompt: String
    var negativePrompt: String
    var modelID: String
    /// "mlx" (FLUX.2 Klein) oder "coreml" (Stable Diffusion).
    var engine: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Float
    var seed: UInt64?
    var batch: Int
    var imageAssetID: String?
    var denoise: Double
    var maskAssetID: String?
    var referenceAssetIDs: [String]
    /// Outpainting: Ränder in Pixeln; Format und Prompt setzt dann JobQueue.runImage.
    var outpaint: Outpaint.Edges? = nil
    /// LoRAs für FLUX.2 Klein (seit 0.4.7), wie unter Windows `loras=[{model_id, strength}]`.
    var loras: [LoRAChoice] = []
    /// Der Auftrag, wie er ankam – erscheint im Job unter `params`.
    var params: JSONValue
    /// Sprache des Clients (Accept-Language) bzw. der App – für Stufen und Fehler des Jobs.
    var lang: Lang = Lang.current

    var kind: String {
        (imageAssetID != nil || maskAssetID != nil || !referenceAssetIDs.isEmpty) ? "img2img" : "txt2img"
    }

    static func parse(_ body: JSONValue?) throws -> ImageJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (GenerateImageRequest).", "Expected a JSON object (GenerateImageRequest)."))
        }
        func int(_ key: String) throws -> Int? {
            guard let v = o[key], !v.isNull else { return nil }
            guard let i = v.intValue else { throw APIError(422, t("\(key) muss eine ganze Zahl sein.", "\(key) must be an integer.")) }
            return i
        }
        func number(_ key: String) throws -> Double? {
            guard let v = o[key], !v.isNull else { return nil }
            guard let d = v.doubleValue else { throw APIError(422, t("\(key) muss eine Zahl sein.", "\(key) must be a number.")) }
            return d
        }
        func string(_ key: String) throws -> String? {
            guard let v = o[key], !v.isNull else { return nil }
            guard let s = v.stringValue else { throw APIError(422, t("\(key) muss Text sein.", "\(key) must be a string.")) }
            return s
        }
        func flag(_ key: String) -> Bool { o[key]?.boolValue ?? false }

        guard let prompt = try string("prompt") else { throw APIError(422, t("Das Feld prompt fehlt.", "The field prompt is missing.")) }

        let width = try int("width") ?? 1024
        let height = try int("height") ?? 1024
        guard (256...2048).contains(width), (256...2048).contains(height) else {
            throw APIError(422, t("width und height müssen zwischen 256 und 2048 liegen.", "width and height must be between 256 and 2048."))
        }
        let seed = try int("seed")
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }
        let batch = try int("batch_size") ?? 1
        guard (1...8).contains(batch) else { throw APIError(422, t("batch_size muss zwischen 1 und 8 liegen.", "batch_size must be between 1 and 8.")) }
        let denoise = try number("denoise") ?? 1.0
        guard (0...1).contains(denoise) else { throw APIError(422, t("denoise muss zwischen 0 und 1 liegen.", "denoise must be between 0 and 1.")) }

        var refs: [String] = []
        if let v = o["reference_asset_ids"], !v.isNull {
            guard let list = v.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                throw APIError(422, t("reference_asset_ids muss eine Liste von Asset-IDs sein.", "reference_asset_ids must be a list of asset IDs."))
            }
            refs = list.compactMap(\.stringValue)
        }
        let image = try string("image_asset_id")
        let mask = try string("mask_asset_id")
        if mask != nil && image == nil {
            throw APIError(422, t("Eine Maske (mask_asset_id) braucht ein Ausgangsbild (image_asset_id).", "A mask (mask_asset_id) needs a start image (image_asset_id)."))
        }
        var outpaint: Outpaint.Edges?
        if let v = o["outpaint"], !v.isNull {
            let values = v.arrayValue?.compactMap(\.intValue) ?? []
            guard v.arrayValue?.count == 4, values.count == 4,
                  values.allSatisfy({ (0...Outpaint.maxEdge).contains($0) }) else {
                throw APIError(422, t("outpaint muss [links, oben, rechts, unten] in Pixeln sein, je 0 bis 1024.",
                                      "outpaint must be [left, top, right, bottom] in pixels, 0 to 1024 each."))
            }
            let edges = Outpaint.Edges(left: values[0], top: values[1], right: values[2], bottom: values[3])
            if edges.any {
                guard image != nil else {
                    throw APIError(422, t("Outpainting braucht ein Ausgangsbild (image_asset_id).", "Outpainting needs a source image (image_asset_id)."))
                }
                if mask != nil || !refs.isEmpty {
                    throw APIError(422, t("Outpainting nimmt genau ein Bild, ohne Maske und weitere Referenzen.", "Outpainting takes exactly one image, without a mask or further references."))
                }
                outpaint = edges
            }
        }
        if flag("hires") {
            throw APIError(422, t("hires gibt es in NVAI-open für Mac nicht (features.hires = false). Größeres Format wählen.", "NVAI-open for Mac has no hires pass (features.hires = false). Choose a larger size instead."))
        }
        if flag("slg") {
            throw APIError(422, t("slg wirkt nur bei SD-3.5-Modellen und gibt es hier nicht.", "slg only applies to SD 3.5 models and is not available here."))
        }
        if try string("controlnet_model_id") != nil {
            throw APIError(422, t("ControlNet gibt es in NVAI-open für Mac nicht.", "NVAI-open for Mac has no ControlNet."))
        }

        var loras: [LoRAChoice] = []
        if let v = o["loras"], !v.isNull {
            guard let list = v.arrayValue else {
                throw APIError(422, t("loras muss eine Liste sein: [{\"model_id\": …, \"strength\": …}].",
                                      "loras must be a list: [{\"model_id\": …, \"strength\": …}]."))
            }
            for entry in list {
                guard let id = entry["model_id"]?.stringValue, let lora = LoRACatalog.find(id) else {
                    throw APIError(404, t("Unbekannte LoRA: \(entry["model_id"]?.stringValue ?? "?")",
                                          "Unknown LoRA: \(entry["model_id"]?.stringValue ?? "?")"))
                }
                guard lora.installed else {
                    throw APIError(409, t("„\(lora.name)“ ist nicht geladen. Unter „Modelle“ → LoRAs herunterladen.",
                                          "\"\(lora.name)\" is not downloaded. Download it under \"Models\" → LoRAs."))
                }
                let strength = entry["strength"]?.doubleValue ?? lora.strength
                guard (0...2).contains(strength) else {
                    throw APIError(422, t("strength muss zwischen 0 und 2 liegen.", "strength must be between 0 and 2."))
                }
                if !loras.contains(where: { $0.id == id }) { loras.append(LoRAChoice(id: id, strength: strength)) }
            }
            guard loras.count <= 3 else {
                throw APIError(422, t("Höchstens 3 LoRAs zugleich.", "At most 3 LoRAs at a time."))
            }
        }

        let model: AnyModel
        if let id = try string("model_id") {
            guard let found = Models.find(id) else { throw APIError(404, t("Unbekanntes Modell: \(id)", "Unknown model: \(id)")) }
            model = found
        } else {
            model = Models.active
        }
        guard model.installed else {
            throw APIError(409, t("„\(model.name)“ ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.", "\"\(model.name)\" is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        let features = model.features
        let steps = try int("steps") ?? (features["steps"] as? Int ?? 4)
        guard (1...80).contains(steps) else { throw APIError(422, t("steps muss zwischen 1 und 80 liegen.", "steps must be between 1 and 80.")) }
        let cfg = try number("cfg") ?? (features["cfg"] as? Double ?? 1.0)
        var negative = try string("negative_prompt") ?? ""

        switch model {
        case .flux:
            if refs.count > 3 {
                throw APIError(422, t("FLUX.2 Klein nimmt höchstens 3 Referenzbilder (features.references = 3).", "FLUX.2 Klein takes at most 3 reference images (features.references = 3)."))
            }
            negative = ""   // destilliert, cfg 1: wirkt nicht
        case .coreml(let m):
            if !refs.isEmpty {
                throw APIError(422, t("„\(m.name)“ kann keine Referenzbilder (features.references = 0).", "\"\(m.name)\" cannot use reference images (features.references = 0)."))
            }
            if !loras.isEmpty {
                throw APIError(422, t("LoRAs gibt es nur für FLUX.2 Klein.", "LoRAs are only available for FLUX.2 Klein."))
            }
            if outpaint != nil {
                throw APIError(422, t("„\(m.name)“ kann nicht erweitern (features.outpaint = null). FLUX.2 Klein wählen.", "\"\(m.name)\" cannot extend images (features.outpaint = null). Use FLUX.2 Klein."))
            }
            if mask != nil {
                throw APIError(422, t("„\(m.name)“ kann keine Masken (features.mask = false). Für Füllen FLUX.2 Klein wählen.", "\"\(m.name)\" cannot use masks (features.mask = false). Use FLUX.2 Klein for fills."))
            }
            if image != nil && denoise < 0.999 && !CoreMLCatalog.hasEncoder(m) {
                throw APIError(422, t("„\(m.name)“ bringt keinen VAE-Encoder mit und kann deshalb kein Bild-zu-Bild.", "\"\(m.name)\" has no VAE encoder and therefore cannot do image-to-image."))
            }
            if negative.trimmingCharacters(in: .whitespaces).isEmpty {
                negative = features["default_negative"] as? String ?? ""
            }
        }

        return ImageJobRequest(prompt: prompt, negativePrompt: negative, modelID: model.id, engine: model.engine,
                               width: width, height: height, steps: steps, guidance: Float(cfg),
                               seed: seed.map { UInt64($0) }, batch: batch, imageAssetID: image, denoise: denoise,
                               maskAssetID: mask, referenceAssetIDs: refs, outpaint: outpaint, loras: loras, params: body)
    }
}
