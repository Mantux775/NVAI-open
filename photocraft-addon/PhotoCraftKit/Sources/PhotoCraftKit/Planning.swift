import Foundation

/// Fehler, mit dem sich ein Auftrag so nicht rechnen lässt. `code` ist fest (Golden-Daten).
public struct PlanError: Error, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

public struct PlanWarning: Equatable, Sendable {
    public let code: String
    public let message: String
}

/// Ergebnis der Planung: Request an `/api/generate/image` ohne die Asset-IDs.
public struct Plan: Equatable {
    public var modelID: String?
    public var modelName: String
    public var workflow: String?
    public var technique: String // txt2img | img2img | inpaint | reference
    public var working: (Int, Int)
    public var payload: [String: JSONValue]
    public var sendImage: Bool
    public var sendMask: Bool
    public var maskGrow: Int
    public var maskBlur: Double
    public var warnings: [PlanWarning]

    public static func == (a: Plan, b: Plan) -> Bool {
        a.modelID == b.modelID && a.modelName == b.modelName && a.workflow == b.workflow
            && a.technique == b.technique && a.working == b.working && a.payload == b.payload
            && a.sendImage == b.sendImage && a.sendMask == b.sendMask && a.maskGrow == b.maskGrow
            && a.maskBlur == b.maskBlur && a.warnings == b.warnings
    }
}

/// Reine Entscheidungslogik eines Auftrags (Referenz: bridge/planning.py).
///
/// Modelle sind die Einträge aus NV-AIs `/api/models` (`id`, `name`, `workflow`, `runnable`,
/// `features` – siehe BILDMODELLE.md, Abschnitt 7).
public enum Planning {
    public static let modes = ["fill", "generate", "refine"]
    /// Name des Modus in der gewählten Sprache (Oberfläche, Ebenenname).
    public static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "fill": t("Füllen", "Fill")
        case "generate": t("Generieren", "Generate")
        case "refine": t("Überarbeiten", "Refine")
        default: mode
        }
    }

    public static let defaultFillPrompt =
        "The same scene continues seamlessly. Identical subject matter, lighting, colors, texture, "
        + "perspective and photographic style as the visible part of the image."
    public static let defaultFillNegative =
        "text, watermark, frame, border, collage, split image, new object, person, face, portrait, close-up"

    public static let maskGrow = ["fill": 12, "refine": 4]
    public static let maskBlur = ["fill": 10.0, "refine": 8.0]
    public static let outpaintGrow = 24
    public static let outpaintBlur = 20.0
    public static let outpaintMargin = 1.0
    public static let refinePad = 16
    public static let interactiveSteps = ["qwen_image": 28]
    public static let weakPromptWorkflows: Set<String> = ["qwen_image_lightning", "flux"]
    public static let nativePixels = [
        "qwen_image": 1328 * 1328, "qwen_image_lightning": 1328 * 1328,
        "flux3_klein": 1440 * 1440, "flux3_klein_base": 1440 * 1440,
    ]
    /// Modelle mit festem Format (`features.fixed_size`, etwa Core ML in NV-AI für Mac) rechnen immer
    /// N×N und strecken das Ergebnis sonst selbst – deshalb N×N anfragen. Weicht der Ausschnitt um
    /// mehr als diesen Faktor vom Quadrat ab, sagt eine Warnung, was passiert.
    public static let fixedSizeTolerance = 1.1

    // MARK: Modelle

    static func features(_ model: JSONValue?) -> [String: JSONValue] {
        model?["features"]?.objectValue ?? [:]
    }

    /// Festes quadratisches Format des Modells in Pixeln (`features.fixed_size`) – oder `nil`.
    public static func fixedSize(_ model: JSONValue) -> Int? {
        guard let size = features(model)["fixed_size"]?.intValue, size > 0 else { return nil }
        return size
    }

    /// Kann das Modell Bild-zu-Bild (`img2img`), Überarbeiten (`refine`) bzw. Masken (`mask`)?
    public static func capable(_ model: JSONValue, _ need: String, masksSupported: Bool) -> Bool {
        let f = features(model)
        let img2img = f["img2img"]?.truthy ?? true
        switch need {
        case "img2img": return img2img
        case "refine": return img2img || (f["references"]?.intValue ?? 0) > 0
        case "mask": return f["mask"]?.truthy ?? (img2img && masksSupported)
        default: preconditionFailure("unbekannte Fähigkeit: \(need)")
        }
    }

    public static func needFor(_ mode: String) -> String? {
        ["fill": "mask", "refine": "refine"][mode]
    }

    static func isWeak(_ model: JSONValue) -> Bool {
        guard let wf = model["workflow"]?.stringValue else { return false }
        return weakPromptWorkflows.contains(wf)
    }

    /// Modell für den Auftrag; passt das aktive nicht, ein passendes (volle Modelle vor Lightning).
    public static func chooseModel(mode: String, wanted: String?, active: String?, models: [JSONValue],
                                   masksSupported: Bool) throws -> (JSONValue, PlanWarning?) {
        let runnable = models.filter { $0["runnable"]?.truthy ?? true }
        let need = needFor(mode)
        var byID: [String: JSONValue] = [:]
        for m in runnable {
            if let id = m["id"]?.stringValue { byID[id] = m } // wie Pythons dict: der letzte gewinnt
        }
        let wantedID = (wanted?.isEmpty == false) ? wanted : nil
        let activeID = (active?.isEmpty == false) ? active : nil
        let chosen = byID[wantedID ?? activeID ?? ""]
        if let chosen, need == nil || capable(chosen, need!, masksSupported: masksSupported) {
            return (chosen, nil)
        }
        let what = need == "mask" ? t("keine Masken", "masks") : t("keine Bilder überarbeiten", "image editing")
        if wantedID != nil, let chosen {
            let name = chosen["name"]?.stringValue ?? ""
            throw PlanError(code: "model_incapable", message: t("„\(name)“ kann \(what) – bitte ein anderes Modell wählen.",
                                                                "\"\(name)\" does not support \(what) – please choose another model."))
        }
        let candidates = runnable.filter { need == nil || capable($0, need!, masksSupported: masksSupported) }
        guard !candidates.isEmpty else {
            let reason = ["mask": t("mit Masken arbeiten.", "work with masks."),
                          "refine": t("Bilder überarbeiten.", "edit images.")][need ?? ""] ?? t("laufen.", "run.")
            throw PlanError(code: "no_capable_model", message: t("Kein installiertes Bildmodell in NV-AI kann ",
                                                                 "No image model installed in NV-AI can ") + reason)
        }
        // Stabil: Reihenfolge von NV-AI, schwache Workflows nach hinten.
        let pick = candidates.filter { !isWeak($0) }.first ?? candidates[0]
        var code = "no_active_model", reason = t("In NV-AI ist kein Bildmodell aktiv", "No image model is active in NV-AI")
        if wantedID != nil {
            code = "model_unavailable"
            reason = t("Das gewählte Modell ist in NV-AI nicht verfügbar", "The chosen model is not available in NV-AI")
        } else if chosen != nil {
            code = "active_model_incapable"
            reason = t("Das in NV-AI aktive Modell kann \(what)", "The model active in NV-AI does not support \(what)")
        }
        let name = pick["name"]?.stringValue ?? ""
        return (pick, PlanWarning(code: code, message: t("\(reason) – verwendet wird „\(name)“.", "\(reason) – using \"\(name)\".")))
    }

    /// Wie NV-AI den Auftrag rechnet.
    public static func techniqueFor(mode: String, model: JSONValue, hasMask: Bool, masksSupported: Bool) -> String {
        if mode == "generate" { return "txt2img" }
        if mode == "fill" { return "inpaint" }
        let f = features(model)
        if !(f["img2img"]?.truthy ?? true) && (f["references"]?.intValue ?? 0) > 0 { return "reference" }
        return hasMask && capable(model, "mask", masksSupported: masksSupported) ? "inpaint" : "img2img"
    }

    // MARK: Ausschnitt

    public static func regionFor(mode: String, selection: Rect?, width: Int, height: Int, margin: Double = 0.35) -> Rect {
        guard let sel = selection else { return Rect(0, 0, width, height) }
        switch mode {
        case "fill": return Geometry.contextRegion(sel, width: width, height: height, marginFrac: margin)
        case "refine": return Geometry.growRect(sel, refinePad, width: width, height: height)
        default: return sel
        }
    }

    public static func outpaintRegion(_ transparent: Rect, width: Int, height: Int, margin: Double = 0.35) -> Rect {
        Geometry.contextRegion(transparent, width: width, height: height, marginFrac: max(margin, outpaintMargin))
    }

    // MARK: Request

    static func trimmed(_ v: JSONValue?) -> String {
        (v?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func plan(mode: String, prompt: String, params: JSONValue, model: JSONValue?,
                            regionSize: (Int, Int), hasMask: Bool, alphaMask: Bool,
                            masksSupported: Bool) throws -> Plan {
        let model = model ?? .object([:])
        let f = features(model)
        let workflow = model["workflow"]?.stringValue
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let technique = techniqueFor(mode: mode, model: model, hasMask: hasMask, masksSupported: masksSupported)
        var warnings: [PlanWarning] = []

        let gw: Int, gh: Int
        if let fixed = fixedSize(model) {
            gw = fixed
            gh = fixed
            let (w, h) = regionSize
            if Double(max(w, h)) > fixedSizeTolerance * Double(min(w, h)) {
                let effect = mode == "generate"
                    ? t("Das Bild wird auf das Format der Auswahl zugeschnitten.", "The image is cropped to the shape of the selection.")
                    : t("Der Ausschnitt wird dafür gestaucht, Formen können leicht verzerrt wirken.",
                        "The area is squeezed for it, shapes may look slightly distorted.")
                let name = model["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? t("Das Modell", "The model")
                warnings.append(PlanWarning(code: "fixed_size",
                                            message: t("„\(name)“ rechnet nur im Format \(fixed) × \(fixed). \(effect)",
                                                       "\"\(name)\" only works at \(fixed) × \(fixed). \(effect)")))
            }
        } else {
            let native = params["native"]?.truthy ?? false
            let target = native ? (workflow.flatMap { nativePixels[$0] } ?? Geometry.targetPixels) : Geometry.targetPixels
            let size = Geometry.workingSize(regionSize.0, regionSize.1, target: target)
            gw = size.0
            gh = size.1
        }

        if mode == "generate" && prompt.isEmpty {
            throw PlanError(code: "prompt_required", message: t("Zum Generieren bitte beschreiben, was entstehen soll.",
                                                                "To generate, please describe what should be created."))
        }
        if technique == "reference" && prompt.isEmpty {
            throw PlanError(code: "prompt_required",
                            message: t("Für die Bearbeitung mit FLUX 3 bitte beschreiben, was sich ändern soll – und was gleich bleibt.",
                                       "For editing with FLUX 3, please describe what should change – and what stays the same."))
        }

        let variants = (params["variants"]?.truthy ?? false) ? (params["variants"]?.intValue ?? 1) : 1
        var payload: [String: JSONValue] = [
            "prompt": .string(prompt),
            "negative_prompt": .string(trimmed(params["negative_prompt"])),
            "batch_size": .int(max(1, min(4, variants))),
            "width": .int(gw),
            "height": .int(gh),
        ]
        if let id = model["id"]?.stringValue, !id.isEmpty { payload["model_id"] = .string(id) }
        for key in ["steps", "cfg", "seed"] {
            if let v = params[key], !v.isNull, v != .string("") { payload[key] = v }
        }
        if payload["steps"] == nil, let wf = workflow, let steps = interactiveSteps[wf] {
            payload["steps"] = .int(steps)
        }
        if (params["hires"]?.truthy ?? false) && (f["hires"]?.truthy ?? true) {
            payload["hires"] = .bool(true)
        }
        if mode == "fill" && prompt.isEmpty {
            payload["prompt"] = .string(defaultFillPrompt)
            if trimmed(payload["negative_prompt"]).isEmpty {
                let base = f["default_negative"]?.stringValue ?? ""
                payload["negative_prompt"] = .string("\(base) \(defaultFillNegative)".trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if mode == "fill" && !prompt.isEmpty, let wf = workflow, weakPromptWorkflows.contains(wf) {
            warnings.append(PlanWarning(code: "weak_prompt_fill",
                                        message: t("Schnelle Modelle (Lightning/schnell) setzen beim Füllen meist nur die "
                                                    + "Umgebung fort. Für neue Objekte das volle Modell wählen.",
                                                   "Fast models (Lightning/schnell) mostly just continue the surroundings when "
                                                    + "filling. For new objects, choose the full model.")))
        }

        let sendImage = mode == "fill" || mode == "refine"
        if sendImage && technique != "reference" {
            let strength = (params["strength"]?.truthy ?? false) ? (params["strength"]?.doubleValue ?? 0.5) : 0.5
            payload["denoise"] = .double(mode == "fill" ? 1.0 : strength)
        }
        let sendMask = hasMask && technique == "inpaint"
        let grow = alphaMask ? outpaintGrow : (maskGrow[mode] ?? 0)
        let blur = alphaMask ? outpaintBlur : (maskBlur[mode] ?? 0.0)

        return Plan(modelID: model["id"]?.stringValue, modelName: model["name"]?.stringValue ?? "",
                    workflow: workflow, technique: technique, working: (gw, gh), payload: payload,
                    sendImage: sendImage, sendMask: sendMask, maskGrow: sendMask ? grow : 0,
                    maskBlur: sendMask ? blur : 0.0, warnings: warnings)
    }

    /// Name der eingefügten Ebene, etwa „NV-AI Fill: a red barn (2)“ (Deutsch: „NV-AI Füllen: …“).
    public static func layerName(mode: String, prompt: String, k: Int, n: Int) -> String {
        var text = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let scalars = Array(text.unicodeScalars)
        if scalars.count > 48 {
            var cut = String(String.UnicodeScalarView(scalars[0..<47]))
            while cut.last?.isWhitespace == true { cut.removeLast() }
            text = cut + "…"
        }
        var name = "NV-AI \(modeLabel(mode))" + (text.isEmpty ? "" : ": \(text)")
        if n > 1 { name += " (\(k + 1))" }
        return name
    }
}
