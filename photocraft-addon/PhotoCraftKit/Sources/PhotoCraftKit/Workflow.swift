import Foundation

public enum WorkflowError: Error, LocalizedError, Equatable {
    case message(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .cancelled: return t("abgebrochen", "cancelled")
        }
    }
}

public struct Variant: Equatable, Sendable {
    public var index: Int
    /// relativ zum Austauschordner, z. B. `jobs/<id>/result-1.png`
    public var file: String
    public var thumb: String
    public var seed: Int?
    public var assetID: String?
    /// FLUX 3: Bildbeschreibung des Prompt-Upsamplers
    public var caption: String?

    public init(index: Int, file: String, thumb: String = "", seed: Int? = nil, assetID: String? = nil, caption: String? = nil) {
        self.index = index
        self.file = file
        self.thumb = thumb
        self.seed = seed
        self.assetID = assetID
        self.caption = caption
    }
}

/// Ein Auftrag aus dem Panel – Zustand wie `bridge/tasks.py`, `Task`.
public final class GenerationTask: @unchecked Sendable {
    public let id: String
    public let mode: String
    public let prompt: String
    public let params: JSONValue
    public var docName = ""
    public var docIndex = -1
    public var docSize = (0, 0)
    public var region: Rect?
    public var selection: Rect?
    public var hasMask = false
    public var alphaMask = false
    public var working: (Int, Int)?
    public var modelName = ""
    public var technique = ""
    public var warning: String?
    public var variants: [Variant] = []
    public var placedLayer: Int?
    public var placedVariant: Int?
    public var nvJob: String?
    public var isCancelled = false

    public init(id: String, mode: String, prompt: String, params: JSONValue = [:]) {
        self.id = id
        self.mode = mode
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.params = params
    }

    var margin: Double { params["margin"]?.doubleValue ?? 0.35 }
}

/// Erfassen → Rechnen → Einfügen (Referenz: bridge/tasks.py, docs/mac-port.md Abschnitt 4).
public final class Workflow {
    /// Namen der Arbeitskopie und des Kanals mit der gesicherten Auswahl – absichtlich in jeder
    /// Sprache gleich, die Abläufe finden sie über den Namen (wie `bridge/tasks.py`).
    public static let workingCopy = "NVAI-open working copy"
    public static let maskChannel = "NVAI-open selection"

    public let pc: PhotoCraftControlling
    /// Austauschordner = `--automation-read-root` und `--automation-write-root`.
    public let exchange: URL
    /// Für Statusabfragen: Während Erfassen/Einfügen sind kurz Hilfsdokumente aktiv.
    public private(set) var busy = false

    public init(pc: PhotoCraftControlling, exchange: URL) {
        self.pc = pc
        self.exchange = exchange
    }

    func url(_ rel: String) -> URL { exchange.appendingPathComponent(rel) }

    // MARK: Erfassen

    /// Ausschnitt (und ggf. Maske) des aktiven Dokuments holen; setzt Region, Auswahl und Maske am Auftrag.
    public func capture(_ task: GenerationTask) async throws -> (context: RGBAImage?, mask: GrayImage?) {
        let rel = "jobs/\(task.id)"
        try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true)
        var ui = try await pc.inspect()
        guard var doc = ui["document"], !doc.isNull else {
            throw WorkflowError.message(t("In PhotoCraft ist kein Dokument geöffnet.", "No document is open in PhotoCraft."))
        }
        // „Erweitern“; Füllen mit `extend` nehmen ältere Apps (0.4.2) weiter an.
        let steps = task.mode == "fill" || task.mode == "extend" ? Planning.extendSteps(task.params["extend"]) : []
        let mode = Planning.baseMode(task.mode)
        if !steps.isEmpty {
            // Outpainting: Arbeitsfläche transparent erweitern, danach füllt der übliche Weg ohne
            // Auswahl die leeren Ränder. Jeder Schritt lässt sich in PhotoCraft einzeln zurücknehmen.
            if doc["hasSelection"]?.truthy ?? false {
                throw WorkflowError.message(t("Zum Erweitern bitte erst die Auswahl aufheben (Auswahl › Aufheben).",
                                              "To extend, please deselect first (Select › Deselect)."))
            }
            for step in steps { _ = try await pc.execute("image.canvasSize", step) }
            ui = try await pc.inspect()
            if let fresh = ui["document"], !fresh.isNull { doc = fresh }
        }
        let width = doc["width"]?.intValue ?? 0, height = doc["height"]?.intValue ?? 0
        task.docName = doc["name"]?.stringValue ?? ""
        task.docIndex = ui["session"]?["active"]?.intValue ?? 0
        task.docSize = (width, height)
        let canvas = Rect(0, 0, width, height)
        let sel = (doc["hasSelection"]?.truthy ?? false) ? doc["selectionBounds"]?.rectValue : nil
        task.selection = sel
        var region = Planning.regionFor(mode: mode, selection: sel, width: width, height: height, margin: task.margin)

        let needContext = mode == "fill" || mode == "refine"
        let needMask = sel != nil
        if needContext || needMask {
            try await export(index: task.docIndex, rel: rel, region: region, canvas: canvas, context: needContext, mask: needMask)
        }
        var context: RGBAImage?
        var mask: GrayImage?
        if needContext { context = try Imaging.readRGBA(url("\(rel)/context.png")) }
        if needMask { mask = try Imaging.readGray(url("\(rel)/mask.png")) }

        if mode == "fill" && mask == nil {
            // Ohne Auswahl füllt „Füllen“ die durchsichtigen Stellen (Arbeitsfläche erweitert).
            guard let ctx = context, let alpha = Imaging.maskFromAlpha(ctx), let box = Imaging.maskBBox(alpha) else {
                throw WorkflowError.message(t("Für „Füllen“ bitte zuerst eine Auswahl treffen – oder die Arbeitsfläche "
                                                + "transparent erweitern, dann werden die leeren Ränder gefüllt.",
                                              "For \"Fill\", please make a selection first – or extend the canvas with "
                                                + "transparency, then the empty edges get filled."))
            }
            let sub = Planning.outpaintRegion(box, width: width, height: height, margin: task.margin)
            context = crop(ctx, sub)
            mask = crop(alpha, sub)
            region = sub
            task.alphaMask = true
        }
        task.region = region
        task.hasMask = mask != nil
        return (context, mask)
    }

    func export(index: Int, rel: String, region: Rect, canvas: Rect, context: Bool, mask: Bool) async throws {
        busy = true
        defer { busy = false }
        let dup = try await pc.execute("image.duplicate", ["name": .string(Self.workingCopy), "mergedOnly": true])
        var failure: Error?
        do {
            if mask { _ = try await pc.execute("select.saveSelection", ["name": .string(Self.maskChannel)]) }
            if region != canvas {
                _ = try await pc.execute("image.crop", ["x": .int(region.x), "y": .int(region.y),
                                                        "width": .int(region.w), "height": .int(region.h)])
            }
            if context { _ = try await pc.call("app.save", ["path": .string("\(rel)/context.png")]) }
            if mask {
                let channelDoc = try await pc.execute("channel.duplicate", ["channel": .string(Self.maskChannel), "document": "new"])
                do {
                    _ = try await pc.call("app.save", ["path": .string("\(rel)/mask.png")])
                } catch { failure = error }
                // engine.execute schließt ohne Rückfrage – nur für eigene Hilfsdokumente.
                _ = try await pc.execute("file.close", ["document": channelDoc["document"] ?? .null])
            }
        } catch { failure = failure ?? error }
        _ = try await pc.execute("file.close", ["document": dup["document"] ?? .null])
        try await activate(index)
        if let failure { throw failure }
    }

    func activate(_ index: Int) async throws {
        let session = try await pc.inspect()["session"]
        if session?["active"]?.intValue != index {
            do {
                try await pc.activate(index)
            } catch {
                throw WorkflowError.message(t("Konnte das Dokument nicht wieder nach vorn holen (\(error.localizedDescription)). "
                                                + "Ist in PhotoCraft ein Dialog offen?",
                                              "Could not bring the document back to the front (\(error.localizedDescription)). "
                                                + "Is a dialog open in PhotoCraft?"))
            }
        }
    }

    func crop(_ img: RGBAImage, _ r: Rect) -> RGBAImage {
        var px = [UInt8](); px.reserveCapacity(r.w * r.h * 4)
        for y in r.y..<r.y1 { px.append(contentsOf: img.pixels[((y * img.width + r.x) * 4)..<((y * img.width + r.x1) * 4)]) }
        return RGBAImage(width: r.w, height: r.h, pixels: px)
    }

    func crop(_ m: GrayImage, _ r: Rect) -> GrayImage {
        var px = [UInt8](); px.reserveCapacity(r.w * r.h)
        for y in r.y..<r.y1 { px.append(contentsOf: m.pixels[(y * m.width + r.x)..<(y * m.width + r.x1)]) }
        return GrayImage(width: r.w, height: r.h, pixels: px)
    }

    // MARK: Rechnen

    /// Kompletter Auftrag mit NVAI-open: planen, hochladen, rechnen, Ergebnisse speichern, erste Variante einfügen.
    public func run(_ task: GenerationTask, nvai: NVAIClient, progress: @escaping (Double, String) -> Void = { _, _ in }) async throws {
        try await nvai.checkCompatible()
        let masks = try await nvai.supportsMasks()
        let mode = Planning.baseMode(task.mode)
        if task.mode == "extend" && Planning.extendSteps(task.params["extend"]).isEmpty {
            throw WorkflowError.message(t("Zum Erweitern bitte angeben, wie viele Pixel links, oben, rechts oder unten dazukommen.",
                                          "To extend, please enter how many pixels to add on the left, top, right or bottom."))
        }
        let outpaintServer = try await nvai.supportsOutpaint()
        if mode == "fill" && !masks && !(task.mode == "extend" && outpaintServer) {
            throw WorkflowError.message(t("Die laufende NVAI-open-Version kennt noch keine Masken.",
                                          "The running NVAI-open version does not know masks yet."))
        }
        progress(0.02, t("liest das Dokument", "reading the document"))
        let (context, mask) = try await capture(task)
        let region = task.region ?? Rect(0, 0, task.docSize.0, task.docSize.1)
        let active = try await nvai.health()["active_models"]?["image"]?.stringValue
        let models = try await nvai.imageModels()
        // Erweitern über NVAI-opens outpaint; ältere Server füllen per Maske wie bisher.
        let outpaint = task.alphaMask && !Planning.extendSteps(task.params["extend"]).isEmpty && outpaintServer
        let (model, warning) = try Planning.chooseModel(mode: mode, wanted: task.params["model_id"]?.stringValue,
                                                        active: active, models: models, masksSupported: masks,
                                                        extend: outpaint)
        let plan = try Planning.plan(mode: mode, prompt: task.prompt, params: task.params, model: model,
                                     regionSize: (region.w, region.h), hasMask: task.hasMask, alphaMask: task.alphaMask,
                                     masksSupported: masks, outpaint: outpaint)
        task.modelName = plan.modelName
        task.technique = plan.technique
        task.working = plan.working
        task.warning = ([warning].compactMap { $0 } + plan.warnings).map(\.message).joined(separator: " ").nilIfEmpty
        var payload = plan.payload
        let (gw, gh) = plan.working
        var uploads: [String] = []
        defer {
            let ids = uploads
            Task { for id in ids { try? await nvai.deleteAsset(id) } }
        }
        if plan.technique == "outpaint" {
            // Nur den deckenden Teil schicken; Rand und weiche Übergänge legt NVAI-open an.
            guard let context, let cut = Planning.outpaintEdges(context, working: (gw, gh)) else {
                throw WorkflowError.message(t("Kein durchsichtiger Rand zum Füllen gefunden.", "No transparent border found to fill."))
            }
            progress(0.06, t("lädt den Ausschnitt zu NVAI-open", "uploading the area to NVAI-open"))
            let src = Imaging.resize(Imaging.flattenForModel(crop(context, cut.box)), to: cut.size)
            let asset = try await nvai.upload(png: try Imaging.pngData(src), filename: "photocraft-\(task.id)-context.png")
            guard let id = asset["id"]?.stringValue else { throw NVAIError.invalidResponse(t("Upload ohne id", "upload without id")) }
            uploads.append(id)
            payload["image_asset_id"] = .string(id)
            payload["outpaint"] = .array(cut.edges.map { .int($0) })
        } else if plan.sendImage, let context {
            progress(0.06, t("lädt den Ausschnitt zu NVAI-open", "uploading the area to NVAI-open"))
            let src = Imaging.resize(Imaging.flattenForModel(context), to: (gw, gh))
            let asset = try await nvai.upload(png: try Imaging.pngData(src), filename: "photocraft-\(task.id)-context.png")
            guard let id = asset["id"]?.stringValue else { throw NVAIError.invalidResponse(t("Upload ohne id", "upload without id")) }
            uploads.append(id)
            if plan.technique == "reference" { payload["reference_asset_ids"] = [.string(id)] } else { payload["image_asset_id"] = .string(id) }
            if plan.sendMask, let mask {
                let m = Imaging.prepareModelMask(mask, size: (gw, gh), grow: plan.maskGrow, blur: plan.maskBlur)
                let masset = try await nvai.upload(png: try Imaging.pngData(m), filename: "photocraft-\(task.id)-mask.png")
                guard let mid = masset["id"]?.stringValue else { throw NVAIError.invalidResponse(t("Upload ohne id", "upload without id")) }
                uploads.append(mid)
                payload["mask_asset_id"] = .string(mid)
            }
        }
        progress(0.08, t("übergibt an NVAI-open", "handing over to NVAI-open"))
        guard let jobID = try await nvai.generateImage(.object(payload))["id"]?.stringValue else {
            throw NVAIError.invalidResponse(t("Job ohne id", "job without id"))
        }
        task.nvJob = jobID
        let job = try await wait(task, jobID: jobID, nvai: nvai, progress: progress)
        progress(0.92, t("holt die Ergebnisse", "fetching the results"))
        let rel = "jobs/\(task.id)"
        for (k, assetValue) in (job["asset_ids"]?.arrayValue ?? []).enumerated() {
            guard let assetID = assetValue.stringValue else { continue }
            let asset = try await nvai.asset(assetID)
            let data = try await nvai.fetch(asset["url"]?.stringValue ?? "")
            let tmp = url("\(rel)/download-\(k + 1).png")
            try data.write(to: tmp)
            let img = try Imaging.readRGBA(tmp)
            let out = task.mode == "generate" ? Imaging.fitCover(img, width: region.w, height: region.h)
                : Imaging.fitExact(img, width: region.w, height: region.h)
            try Imaging.writePNG(out, to: url("\(rel)/result-\(k + 1).png"))
            let meta = asset["meta"]
            task.modelName = meta?["model_name"]?.stringValue ?? task.modelName
            task.variants.append(Variant(index: k, file: "\(rel)/result-\(k + 1).png", seed: meta?["seed"]?.intValue,
                                      assetID: assetID, caption: meta?["caption"]?.stringValue))
        }
        guard !task.variants.isEmpty else { throw NVAIError.invalidResponse(t("kein Bild zurückgegeben", "no image returned")) }
        if task.params["auto_place"]?.truthy ?? true {
            progress(0.97, t("legt das Ergebnis in PhotoCraft ab", "placing the result in PhotoCraft"))
            _ = try await place(task, variant: 0, replace: false)
        }
    }

    func wait(_ task: GenerationTask, jobID: String, nvai: NVAIClient, progress: (Double, String) -> Void) async throws -> JSONValue {
        var unreachableSince: Date?
        while true {
            if task.isCancelled {
                try? await nvai.cancel(jobID: jobID)
                throw WorkflowError.cancelled
            }
            let job: JSONValue
            do {
                job = try await nvai.job(jobID)
                unreachableSince = nil
            } catch NVAIError.unavailable(let u) {
                unreachableSince = unreachableSince ?? Date()
                if Date().timeIntervalSince(unreachableSince!) > 45 { throw NVAIError.unavailable(u) }
                progress(0.1, t("NVAI-open antwortet nicht – warte", "NVAI-open does not answer – waiting"))
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            switch job["status"]?.stringValue {
            case "queued": progress(0.09, t("wartet auf die GPU", "waiting for the GPU"))
            case "running": progress(0.1 + 0.8 * (job["progress"]?.doubleValue ?? 0), job["stage"]?.stringValue ?? t("generiert", "generating"))
            case "done": return job
            case "error": throw WorkflowError.message(job["error"]?.stringValue ?? t("NVAI-open meldet einen Fehler.", "NVAI-open reports an error."))
            case "cancelled":
                if task.isCancelled { throw WorkflowError.cancelled }
                let reason = job["stage"]?.stringValue ?? t("ohne Angabe", "no reason given")
                throw WorkflowError.message(t("NVAI-open hat den Auftrag abgebrochen (\(reason)). Bitte erneut versuchen.",
                                              "NVAI-open cancelled the job (\(reason)). Please try again."))
            default: break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Einfügen

    func findTarget(_ task: GenerationTask, session: JSONValue?) throws -> Int {
        let docs = session?["documents"]?.arrayValue ?? []
        func same(_ d: JSONValue) -> Bool {
            d["name"]?.stringValue == task.docName && d["width"]?.intValue == task.docSize.0 && d["height"]?.intValue == task.docSize.1
        }
        if task.docIndex >= 0 && task.docIndex < docs.count && same(docs[task.docIndex]) { return task.docIndex }
        if let d = docs.first(where: same), let i = d["index"]?.intValue { return i }
        // Nach „Speichern unter“ heißt das Dokument anders: eindeutige Größe genügt dann.
        let sized = docs.filter { $0["width"]?.intValue == task.docSize.0 && $0["height"]?.intValue == task.docSize.1 }
        if sized.count == 1, let i = sized[0]["index"]?.intValue { return i }
        throw WorkflowError.message(t("Das Zieldokument „\(task.docName)“ ist in PhotoCraft nicht mehr geöffnet.",
                                      "The target document \"\(task.docName)\" is no longer open in PhotoCraft."))
    }

    static func layersByID(_ layers: [JSONValue]) -> [Int: JSONValue] {
        var out: [Int: JSONValue] = [:]
        var stack = layers
        while let layer = stack.popLast() {
            if let id = layer["id"]?.intValue { out[id] = layer }
            stack.append(contentsOf: layer["children"]?.arrayValue ?? [])
        }
        return out
    }

    /// Variante `k` als Ebene ins Zieldokument legen; mit `replace` die vorige Variante ersetzen.
    @discardableResult
    public func place(_ task: GenerationTask, variant k: Int, replace: Bool = true) async throws -> Int {
        guard task.variants.indices.contains(k) else {
            throw WorkflowError.message(t("Variante \(k + 1) gibt es nicht.", "There is no variant \(k + 1)."))
        }
        let variant = task.variants[k]
        let region = task.region ?? Rect(0, 0, task.docSize.0, task.docSize.1)
        busy = true
        defer { busy = false }

        let ui = try await pc.inspect()
        let index = try findTarget(task, session: ui["session"])
        try await activate(index)
        let doc = try await pc.document()
        let layers = Self.layersByID(doc["layers"]?.arrayValue ?? [])
        let old = (replace && task.placedLayer.map { layers[$0] != nil } == true) ? task.placedLayer : nil

        // Maske: am liebsten die echte Auswahl als bearbeitbare Ebenenmaske.
        let selectionNow = (doc["hasSelection"]?.truthy ?? false) ? doc["selectionBounds"]?.rectValue : nil
        var useSelection = task.hasMask && !task.alphaMask && selectionNow == task.selection
        if task.hasMask && !useSelection, let old, layers[old]?["hasMask"]?.truthy == true {
            _ = try await pc.execute("select.loadSelection", ["channel": "mask", "layer": .int(old)])
            useSelection = true
        }
        var source = variant.file
        if task.hasMask && !useSelection { source = try baked(task, variant) }

        if let old { _ = try await pc.execute("layer.select", ["layer": .int(old)]) }
        let opened = try await pc.call("app.open", ["path": .string(source)])
        let name = opened["name"]?.stringValue ?? (source as NSString).lastPathComponent
        let temp = try await waitForDocument(name)
        var newID = -1
        var failure: Error?
        do {
            let tempDoc = try await pc.document()
            guard let layerID = tempDoc["layers"]?[0]?["id"] else { throw WorkflowError.message(t("Ergebnis ohne Ebene", "result without a layer")) }
            let copied = try await pc.execute("layer.copyToDocument", [
                "document": .int(index), "source": .int(temp), "layers": [layerID],
                "offset": [.int(region.x), .int(region.y)],
                "name": .string(Planning.layerName(mode: task.mode, prompt: task.prompt, k: k, n: task.variants.count)),
            ])
            newID = copied["layers"]?[0]?.intValue ?? -1
        } catch { failure = error }
        if temp != index { _ = try await pc.execute("file.close", ["document": .int(temp)]) }
        await forgetRecent()
        if let failure { throw failure }
        try await activate(index)
        if useSelection {
            _ = try await pc.execute("layer.layerMask.revealSelection", ["layer": .int(newID)])
            // Die Auswahl wieder aktivieren, damit gleich noch einmal generiert werden kann.
            _ = try await pc.execute("select.loadSelection", ["channel": "mask", "layer": .int(newID)])
        }
        if let old { _ = try await pc.execute("layer.delete", ["layer": .int(old)]) }
        if replace || task.placedLayer == nil {
            task.placedLayer = newID
            task.placedVariant = k
        }
        return newID
    }

    /// Index des gerade geöffneten Dokuments – große Dateien lädt PhotoCraft im Hintergrund.
    func waitForDocument(_ name: String, timeout: TimeInterval = 15) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let session = try await pc.inspect()["session"]
            let docs = session?["documents"]?.arrayValue ?? []
            if let active = session?["active"]?.intValue, docs.indices.contains(active), docs[active]["name"]?.stringValue == name {
                return active
            }
            if Date() > deadline { throw WorkflowError.message(t("PhotoCraft hat „\(name)“ nicht geöffnet.", "PhotoCraft did not open \"\(name)\".")) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Variante mit eingebackener Maske (Alpha), wenn keine passende Auswahl mehr da ist.
    func baked(_ task: GenerationTask, _ variant: Variant) throws -> String {
        let rel = "jobs/\(task.id)/result-\(variant.index + 1)-alpha.png"
        if FileManager.default.fileExists(atPath: url(rel).path) { return rel }
        let img = try Imaging.readRGBA(url(variant.file))
        var mask: GrayImage?
        if task.alphaMask {
            let context = try Imaging.readRGBA(url("jobs/\(task.id)/context.png"))
            if var full = Imaging.maskFromAlpha(context) {
                let region = task.region ?? Rect(0, 0, full.width, full.height)
                if (full.width, full.height) != (region.w, region.h) { full = crop(full, region) }
                mask = Imaging.prepareModelMask(full, size: (img.width, img.height), grow: 12, blur: 8)
            }
        } else {
            mask = try Imaging.readGray(url("jobs/\(task.id)/mask.png"))
        }
        try Imaging.writePNG(mask.map { Imaging.bakeAlpha(img, mask: $0) } ?? img, to: url(rel))
        return rel
    }

    /// `app.open` setzt die Datei auf „Zuletzt geöffnet“ – unsere Hilfsdateien wieder austragen.
    func forgetRecent() async {
        do {
            let recent = try await pc.execute("prefs.get", ["path": "fileHandling.recentFiles"], read: true).arrayValue ?? []
            let kept = recent.filter { !($0.stringValue ?? "").replacingOccurrences(of: "\\", with: "/").hasPrefix("jobs/") }
            if kept != recent {
                _ = try await pc.execute("prefs.set", ["path": "fileHandling.recentFiles", "value": .array(kept)])
            }
        } catch {
            // nicht kritisch
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
