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
/// Modelle sind die Einträge aus NVAI-opens `/api/models` (`id`, `name`, `workflow`, `runnable`,
/// `features` – siehe BILDMODELLE.md, Abschnitt 7).
public enum Planning {
    /// Rechenwege (Golden-Daten); „extend“ (Erweitern) rechnet wie Füllen, siehe baseMode.
    public static let modes = ["fill", "generate", "refine"]

    /// „Erweitern“ rechnet wie „Füllen“ ohne Auswahl, nur mit vergrößerter Arbeitsfläche davor;
    /// „Restaurieren“ erfasst wie „Überarbeiten“ (Auswahl mit Rand oder ganzes Bild).
    public static func baseMode(_ mode: String) -> String {
        switch mode {
        case "extend": "fill"
        case "restore": "refine"
        default: mode
        }
    }
    /// Name des Modus in der gewählten Sprache (Oberfläche, Ebenenname).
    public static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "fill": t("Füllen", "Fill")
        case "generate": t("Generieren", "Generate")
        case "refine": t("Überarbeiten", "Refine")
        case "extend": t("Erweitern", "Extend")
        case "restore": t("Restaurieren", "Restore")
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
    /// Modelle mit festem Format (`features.fixed_size`, etwa Core ML in NVAI-open für Mac) rechnen immer
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
        case "outpaint":
            // NVAI-open ab 0.5.4 meldet "reference" (Bearbeitungsmodell, nahtlos) oder "mask".
            if let v = f["outpaint"] { return v.truthy }
            return capable(model, "mask", masksSupported: masksSupported)
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
    /// `extend`: Arbeitsfläche erweitern über NVAI-opens `outpaint`. Ohne eigene Wahl nimmt das ein
    /// Bearbeitungsmodell (features.outpaint == "reference"), denn Maskenmodelle ließen an der alten
    /// Bildkante eine harte Naht (gemessen 23.10.2026).
    public static func chooseModel(mode: String, wanted: String?, active: String?, models: [JSONValue],
                                   masksSupported: Bool, extend: Bool = false) throws -> (JSONValue, PlanWarning?) {
        let runnable = models.filter { $0["runnable"]?.truthy ?? true }
        let need = extend && mode == "fill" ? "outpaint" : needFor(mode)
        if need == "outpaint" && (wanted ?? "").isEmpty {
            let seamless = runnable.filter { features($0)["outpaint"]?.stringValue == "reference" }
            if let first = seamless.first {
                return (seamless.first { $0["id"]?.stringValue == active } ?? first, nil)
            }
        }
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
        let what = need == "mask" ? t("keine Masken", "masks")
            : need == "outpaint" ? t("nicht erweitern", "extending") : t("keine Bilder überarbeiten", "image editing")
        if wantedID != nil, let chosen {
            let name = chosen["name"]?.stringValue ?? ""
            throw PlanError(code: "model_incapable", message: t("„\(name)“ kann \(what) – bitte ein anderes Modell wählen.",
                                                                "\"\(name)\" does not support \(what) – please choose another model."))
        }
        let candidates = runnable.filter { need == nil || capable($0, need!, masksSupported: masksSupported) }
        guard !candidates.isEmpty else {
            let reason = ["mask": t("mit Masken arbeiten.", "work with masks."),
                          "outpaint": t("Bilder erweitern.", "extend images."),
                          "refine": t("Bilder überarbeiten.", "edit images.")][need ?? ""] ?? t("laufen.", "run.")
            throw PlanError(code: "no_capable_model", message: t("Kein installiertes Bildmodell in NVAI-open kann ",
                                                                 "No image model installed in NVAI-open can ") + reason)
        }
        // Stabil: Reihenfolge von NVAI-open, schwache Workflows nach hinten.
        let pick = candidates.filter { !isWeak($0) }.first ?? candidates[0]
        var code = "no_active_model", reason = t("In NVAI-open ist kein Bildmodell aktiv", "No image model is active in NVAI-open")
        if wantedID != nil {
            code = "model_unavailable"
            reason = t("Das gewählte Modell ist in NVAI-open nicht verfügbar", "The chosen model is not available in NVAI-open")
        } else if chosen != nil {
            code = "active_model_incapable"
            reason = t("Das in NVAI-open aktive Modell kann \(what)", "The model active in NVAI-open does not support \(what)")
        }
        let name = pick["name"]?.stringValue ?? ""
        return (pick, PlanWarning(code: code, message: t("\(reason) – verwendet wird „\(name)“.", "\(reason) – using \"\(name)\".")))
    }

    /// Wie NVAI-open den Auftrag rechnet.
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

    // MARK: Erweitern (Outpainting)

    /// Je Seite höchstens so viel neue Arbeitsfläche (Pixel).
    public static let extendMax = 2048

    /// Befehle `image.canvasSize`, die die Arbeitsfläche transparent erweitern. `extend` ist
    /// [links, oben, rechts, unten]; je Seite ein relativer Schritt mit dem Anker auf der Gegenseite,
    /// gleiche Ränder links und rechts (oben und unten) in einem Schritt mit mittigem Anker.
    public static func extendSteps(_ extend: JSONValue?) -> [JSONValue] {
        let list = extend?.arrayValue ?? []
        guard list.count == 4 else { return [] }
        let v = list.map { max(0, min(extendMax, $0.intValue ?? 0)) }
        var steps: [JSONValue] = []
        func step(_ w: Int, _ h: Int, _ anchor: String) {
            steps.append(.object(["width": .int(w), "height": .int(h), "relative": .bool(true),
                                  "anchor": .string(anchor), "extensionColor": .string("transparent")]))
        }
        for (a, b, horizontal, anchorA, anchorB) in [(v[0], v[2], true, "right", "left"), (v[1], v[3], false, "bottom", "top")] {
            func size(_ n: Int) -> (Int, Int) { horizontal ? (n, 0) : (0, n) }
            if a > 0 && a == b { let s = size(a + b); step(s.0, s.1, "center"); continue }
            if a > 0 { let s = size(a); step(s.0, s.1, anchorA) }
            if b > 0 { let s = size(b); step(s.0, s.1, anchorB) }
        }
        return steps
    }

    /// Für NVAI-opens `outpaint`: deckender Teil des Ausschnitts (Box im Ausschnitt), Größe des
    /// hochzuladenden Bildes und [links, oben, rechts, unten], schon auf die Arbeitsgröße skaliert.
    public static func outpaintEdges(_ context: RGBAImage, working: (Int, Int)) -> (box: Rect, size: (Int, Int), edges: [Int])? {
        var x0 = context.width, y0 = context.height, x1 = 0, y1 = 0
        for y in 0..<context.height {
            for x in 0..<context.width where context.pixels[(y * context.width + x) * 4 + 3] >= 250 {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            }
        }
        guard x1 > x0, y1 > y0 else { return nil }
        let w = context.width, h = context.height
        if x0 == 0 && y0 == 0 && x1 == w && y1 == h { return nil }
        let sx = Double(working.0) / Double(w), sy = Double(working.1) / Double(h)
        func r(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        let size = (max(1, r(Double(x1 - x0) * sx)), max(1, r(Double(y1 - y0) * sy)))
        let edges = [r(Double(x0) * sx), r(Double(y0) * sy), r(Double(w - x1) * sx), r(Double(h - y1) * sy)].map { min(1024, $0) }
        return (Rect(x0, y0, x1 - x0, y1 - y0), size, edges)
    }

    // MARK: Request

    static func trimmed(_ v: JSONValue?) -> String {
        (v?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func plan(mode: String, prompt: String, params: JSONValue, model: JSONValue?,
                            regionSize: (Int, Int), hasMask: Bool, alphaMask: Bool,
                            masksSupported: Bool, outpaint: Bool = false) throws -> Plan {
        let model = model ?? .object([:])
        let f = features(model)
        let workflow = model["workflow"]?.stringValue
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // „outpaint“: Erweitern über NVAI-opens outpaint-Feld; Rand, Maske und denoise setzt der Server.
        let technique = outpaint && mode == "fill" ? "outpaint"
            : techniqueFor(mode: mode, model: model, hasMask: hasMask, masksSupported: masksSupported)
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
        if sendImage && technique != "reference" && technique != "outpaint" {
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

    // MARK: Restaurieren (seit 0.4.6; NVAI-open für Windows ab 0.5.11, für Mac ab 0.4.6)

    /// Größte Kante, die zum Restaurieren hochgeladen wird. NVAI-open rechnet in seiner Arbeitsgröße, färbt
    /// und setzt schonend aber in der Größe des Fotos ein.
    public static let restoreMaxSide = 4096
    /// Farbmodi von PhotoCraft, in denen eine eingefärbte Ebene grau bliebe.
    public static let grayModes: Set<String> = ["gray", "grayscale", "duotone", "bitmap", "indexed"]

    /// Bearbeitet das Modell Bilder per Referenz (FLUX 3, FLUX.2 Klein)? Stilvorlagen (Krea 2) nicht.
    public static func restoreCapable(_ model: JSONValue) -> Bool {
        let f = features(model)
        return (f["references"]?.intValue ?? 0) > 0 && f["reference_kind"]?.stringValue != "style"
    }

    /// Art des Restaurierens: „auto“ (Vorgabe; NVAI-open für Windows wählt nach der Art der Schäden),
    /// „thorough“ oder „gentle“. Ältere Apps schicken `thorough` als Wahrheitswert.
    public static func repairMode(_ params: JSONValue) -> String {
        if let mode = params["repair_mode"]?.stringValue, ["auto", "thorough", "gentle"].contains(mode) { return mode }
        if let thorough = params["thorough"]?.boolValue { return thorough ? "thorough" : "gentle" }
        return "auto"
    }

    /// Request an `POST /api/image/restore` (ohne die Asset-ID) und was vor dem Einfügen zu tun ist.
    public struct RestorePlan: Equatable {
        public var payload: [String: JSONValue]
        /// Größe des hochgeladenen Fotos (höchstens `restoreMaxSide`).
        public var uploadSize: (Int, Int)
        public var modelName: String
        /// SeedVR2 vergrößert um diesen Faktor; das Dokument wächst vorher mit (nur ohne Auswahl).
        public var enlarge: Double
        /// Graustufendokument wird eingefärbt: Ergebnis in ein neues RGB-Dokument.
        public var toRGB: Bool
        public var warnings: [PlanWarning]

        public static func == (a: RestorePlan, b: RestorePlan) -> Bool {
            a.payload == b.payload && a.uploadSize == b.uploadSize && a.modelName == b.modelName
                && a.enlarge == b.enlarge && a.toRGB == b.toRGB && a.warnings == b.warnings
        }
    }

    /// Wie `bridge/planning.py`, `plan_restore`: Schritte `repair` (Art `repair_mode`), `colorize`, `sharpen`
    /// mit `scale`; `prompt` geht als Hinweis an das Bearbeitungsmodell (Farben, was bleiben soll).
    public static func planRestore(prompt: String, params: JSONValue, models: [JSONValue], upscalers: [JSONValue],
                                   regionSize: (Int, Int), hasSelection: Bool, docMode: String = "") throws -> RestorePlan {
        let repair = params["repair"]?.boolValue ?? true
        let colorize = params["colorize"]?.truthy ?? false
        let sharpen = params["sharpen"]?.truthy ?? false
        guard repair || colorize || sharpen else {
            throw PlanError(code: "restore_nothing",
                            message: t("Bitte mindestens einen Schritt wählen: Schäden entfernen, Einfärben oder Schärfen.",
                                       "Please choose at least one step: remove damage, colorize or sharpen."))
        }
        var warnings: [PlanWarning] = []
        var model: JSONValue?
        if repair || colorize {
            let editors = models.filter { ($0["runnable"]?.truthy ?? true) && restoreCapable($0) }
            let wanted = params["model_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if let wanted {
                guard let found = editors.first(where: { $0["id"]?.stringValue == wanted }) else {
                    throw PlanError(code: "model_incapable",
                                    message: t("Das gewählte Modell bearbeitet keine Fotos – bitte FLUX 3 wählen.",
                                               "The chosen model does not edit photos – please choose FLUX 3."))
                }
                model = found
            } else if editors.isEmpty {
                throw PlanError(code: "no_edit_model",
                                message: t("Restaurieren und Einfärben brauchen FLUX 3 Image Klein in NVAI-open (auf dem Mac "
                                            + "FLUX.2 Klein). Bitte dort unter „Modelle“ laden.",
                                           "Restoring and colorizing need FLUX 3 Image Klein in NVAI-open (on the Mac FLUX.2 "
                                            + "Klein). Please download it there under “Models”."))
            } else {
                // Wie NVAI-open ohne eigene Wahl: FLUX 3 (destilliert) zuerst.
                model = editors.first { $0["workflow"]?.stringValue == "flux3_klein" } ?? editors[0]
            }
        }
        if sharpen && !upscalers.contains(where: { $0["runnable"]?.truthy ?? true }) {
            throw PlanError(code: "no_upscaler",
                            message: t("Schärfen braucht SeedVR2: in NVAI-open unter „Modelle“ → „Hochskalieren“ laden (5,3 GB).",
                                       "Sharpening needs SeedVR2: download it in NVAI-open under “Models” → “Upscale” (5.3 GB)."))
        }
        var scale = sharpen ? (params["scale"]?.doubleValue ?? 1.0) : 1.0
        if scale > 1 && hasSelection {
            warnings.append(PlanWarning(code: "restore_selection_not_enlarged",
                                        message: t("Mit einer Auswahl wird nur geschärft; vergrößern lässt sich nur das ganze Bild.",
                                                   "With a selection the area is only sharpened; only the whole image can be enlarged.")))
            scale = 1.0
        }
        let (w, h) = regionSize
        let k = min(1.0, Double(restoreMaxSide) / Double(max(w, h, 1)))
        var payload: [String: JSONValue] = [
            "repair": .bool(repair),
            "repair_mode": .string(repairMode(params)),
            "colorize": .bool(colorize),
            "sharpen": .bool(sharpen),
            "scale": .double(scale),
            "notes": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "batch_size": .int(max(1, min(4, params["variants"]?.intValue ?? 1))),
        ]
        if let model, let id = params["model_id"]?.stringValue, !id.isEmpty { payload["model_id"] = model["id"] }
        if let seed = params["seed"], !seed.isNull, seed != .string("") { payload["seed"] = seed }
        let mode = docMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return RestorePlan(payload: payload,
                           uploadSize: (max(1, Int((Double(w) * k).rounded())), max(1, Int((Double(h) * k).rounded()))),
                           modelName: model?["name"]?.stringValue ?? "SeedVR2", enlarge: scale,
                           toRGB: colorize && grayModes.contains(mode), warnings: warnings)
    }

    /// Name der eingefügten Ebene, etwa „NVAI-open Fill: a red barn (2)“ (Deutsch: „NVAI-open Füllen: …“).
    public static func layerName(mode: String, prompt: String, k: Int, n: Int) -> String {
        var text = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let scalars = Array(text.unicodeScalars)
        if scalars.count > 48 {
            var cut = String(String.UnicodeScalarView(scalars[0..<47]))
            while cut.last?.isWhitespace == true { cut.removeLast() }
            text = cut + "…"
        }
        var name = "NVAI-open \(modeLabel(mode))" + (text.isEmpty ? "" : ": \(text)")
        if n > 1 { name += " (\(k + 1))" }
        return name
    }
}
