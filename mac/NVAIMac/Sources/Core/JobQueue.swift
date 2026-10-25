import Foundation
import CoreGraphics

/// Ein Auftrag – Felder wie `Job` im NVAI-open-Vertrag.
struct JobRecord: Sendable, Identifiable {
    var id: String
    var kind: String                 // txt2img | img2img | download
    var status: String               // queued | running | done | error | cancelled
    var progress: Double = 0
    var stage: String = ""
    var params: JSONValue
    var assetIDs: [String] = []
    var error: String?
    var createdAt: Double
    var startedAt: Double?
    var finishedAt: Double?
    var request: ImageJobRequest?
    /// Foto restaurieren (seit 0.4.6, `POST /api/image/restore`).
    var restore: RestoreJobRequest?
    var downloadModelID: String?
    /// „Prompt ausbauen“: Eingabe und Ergebnis. Der Auftrag verschwindet danach wieder.
    var expandPrompt: String?
    var expanded: String?
    var cancelRequested = false
    /// Sprache des Clients bzw. der App; Stufen und Fehler des Auftrags folgen ihr.
    var lang: Lang = .en
    /// Je Bild: Sekunden und Speicherspitze – für den Messbericht.
    var timings: [Timing] = []

    struct Timing: Sendable {
        var seconds: Double
        var peakMB: Double
        var loadSeconds: Double
        var width: Int
        var height: Int
        var steps: Int
        var mode: String
        var modelID: String
    }

    var isFinished: Bool { ["done", "error", "cancelled"].contains(status) }

    var json: [String: Any] {
        [
            "id": id, "kind": kind, "status": status, "progress": progress, "stage": stage,
            "params": params.any, "asset_ids": assetIDs,
            "error": error ?? NSNull(),
            "created_at": createdAt,
            "started_at": startedAt ?? NSNull(),
            "finished_at": finishedAt ?? NSNull(),
        ]
    }
}

/// Arbeitet Aufträge nacheinander ab – ein Modell, ein Rechenwerk, wie NVAI-open unter Windows.
actor JobQueue {
    static let shared = JobQueue()

    private var jobs: [String: JobRecord] = [:]
    private var order: [String] = []
    private var runningID: String?
    private var worker: Task<Void, Never>?
    /// Laufender Download als eigene Task, damit „Abbrechen“ ihn mitten in der Datei stoppen kann.
    private var downloadTask: Task<Void, Error>?
    /// Die laufende FLUX.2-Rechnung. Das Paket prüft nach jedem Schritt auf Abbruch
    /// (Packages/flux-2-swift-mlx/NVAI-OPEN-CHANGES.md), ein Abbrechen wirkt also innerhalb eines Schritts.
    private var imageTask: Task<CGImage, Error>?
    private var onChange: (@Sendable () -> Void)?

    func setOnChange(_ handler: @escaping @Sendable () -> Void) { onChange = handler }

    private func changed() { onChange?() }

    private func update(_ id: String, _ change: (inout JobRecord) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        changed()
    }

    // MARK: Abfragen

    func job(_ id: String) -> JobRecord? { jobs[id] }

    /// Neueste zuerst.
    func list(limit: Int = 100) -> [JobRecord] {
        Array(order.reversed().compactMap { jobs[$0] }.prefix(max(0, limit)))
    }

    var currentJobID: String? { runningID }

    var queueDepth: Int { jobs.values.filter { $0.status == "queued" && $0.kind != "download" }.count }

    var downloadDepth: Int { jobs.values.filter { $0.status == "queued" && $0.kind == "download" }.count }

    var currentDownloadID: String? {
        guard let id = runningID, jobs[id]?.kind == "download" else { return nil }
        return id
    }

    // MARK: Einreichen

    func submit(_ request: ImageJobRequest) -> JobRecord {
        let job = JobRecord(id: AssetStore.newID("job"), kind: request.kind, status: "queued",
                            stage: t("wartet", "queued"), params: request.params, createdAt: Date().timeIntervalSince1970,
                            request: request, lang: request.lang)
        add(job)
        return job
    }

    func submitRestore(_ request: RestoreJobRequest) -> JobRecord {
        var job = JobRecord(id: AssetStore.newID("job"), kind: "restore", status: "queued",
                            stage: t("wartet", "queued"), params: request.params, createdAt: Date().timeIntervalSince1970,
                            lang: request.lang)
        job.restore = request
        add(job)
        return job
    }

    func submitDownload(_ model: AnyModel) -> JobRecord {
        if let existing = jobs.values.first(where: { $0.downloadModelID == model.id && !$0.isFinished }) {
            return existing
        }
        let job = JobRecord(id: AssetStore.newID("job"), kind: "download", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["model_id": .string(model.id)]),
                            createdAt: Date().timeIntervalSince1970, downloadModelID: model.id, lang: Lang.current)
        add(job)
        return job
    }

    func submitExpand(_ prompt: String) -> JobRecord {
        let job = JobRecord(id: AssetStore.newID("job"), kind: "expand_prompt", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["prompt": .string(prompt)]), createdAt: Date().timeIntervalSince1970,
                            expandPrompt: prompt, lang: Lang.current)
        add(job)
        return job
    }

    /// Prompt ausbauen und warten: läuft in der Warteschlange (ein Modell zur Zeit), danach wird der
    /// Auftrag gelöscht, damit er nicht im Verlauf steht. Für die Generieren-Seite und die API.
    static func expandAndWait(_ prompt: String) async throws -> (expanded: String, seconds: Double) {
        guard Models.expansionModel != nil else {
            throw APIError(409, t("Prompt ausbauen braucht FLUX.2 Klein (dessen Text-Encoder schreibt die Beschreibung). "
                                  + "Bitte unter „Modelle“ laden.",
                                  "Expand prompt needs FLUX.2 Klein (its text encoder writes the description). "
                                  + "Please download it under \"Models\"."))
        }
        let started = Date()
        let job = await shared.submitExpand(prompt)
        var record = job
        while !record.isFinished {
            try? await Task.sleep(for: .milliseconds(300))
            guard let current = await shared.job(job.id) else { break }
            record = current
        }
        try? await shared.delete(job.id)
        if let error = record.error { throw APIError(500, error) }
        guard let text = record.expanded, !text.isEmpty else {
            throw APIError(500, t("Der Prompt kam leer zurück.", "The prompt came back empty."))
        }
        return (text, Date().timeIntervalSince(started))
    }

    private func add(_ job: JobRecord) {
        jobs[job.id] = job
        order.append(job.id)
        // Verlauf begrenzen: alte, fertige Aufträge fallen weg (die Bilder bleiben).
        while order.count > 300, let oldest = order.first, jobs[oldest]?.isFinished ?? true {
            order.removeFirst()
            jobs[oldest] = nil
        }
        changed()
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    // MARK: Abbrechen

    /// Wartende Aufträge fallen sofort weg; ein laufendes Bild endet nach dem aktuellen
    /// Rechenschritt (FLUX.2) bzw. sofort (Core ML).
    func cancel(_ id: String) throws -> JobRecord {
        guard let job = jobs[id] else { throw APIError(404, t("Unbekannter Auftrag: \(id)", "Unknown job: \(id)")) }
        switch job.status {
        case "queued":
            update(id) {
                $0.status = "cancelled"
                $0.stage = t("abgebrochen", "cancelled")
                $0.finishedAt = Date().timeIntervalSince1970
            }
        case "running" where job.kind == "download":
            update(id) {
                $0.cancelRequested = true
                $0.stage = t("bricht ab", "cancelling")
            }
            downloadTask?.cancel()
        case "running":
            update(id) {
                $0.cancelRequested = true
                $0.stage = t("bricht ab", "cancelling")
            }
            if job.request?.engine == "coreml" { CoreMLEngine.shared.requestCancel() }
            imageTask?.cancel()
        default:
            break
        }
        return jobs[id]!
    }

    func cancelCurrent() -> JobRecord? {
        guard let id = runningID else { return nil }
        return try? cancel(id)
    }

    /// Aus dem Verlauf entfernen (fertige) bzw. abbrechen (wartende).
    func delete(_ id: String) throws {
        guard let job = jobs[id] else { throw APIError(404, t("Unbekannter Auftrag: \(id)", "Unknown job: \(id)")) }
        if job.status == "running" {
            throw APIError(409, t("Der Auftrag läuft gerade. Abbrechen über POST /api/jobs/current/cancel; "
                                  + "er endet dann nach dem aktuellen Rechenschritt.",
                                  "The job is running. Cancel it with POST /api/jobs/current/cancel; "
                                  + "it then ends after the current step."))
        }
        jobs[id] = nil
        order.removeAll { $0 == id }
        changed()
    }

    // MARK: Abarbeiten

    private func nextQueued() -> String? {
        // Downloads und Bilder in Eingangsreihenfolge – ein Modell muss geladen sein, bevor es rechnet.
        order.first { jobs[$0]?.status == "queued" }
    }

    private func drain() async {
        while let id = nextQueued() {
            runningID = id
            await run(id)
            runningID = nil
            changed()
        }
        worker = nil
    }

    private func run(_ id: String) async {
        let lang = jobs[id]?.lang ?? Lang.ui
        await Lang.$request.withValue(lang) { await runInLanguage(id) }
    }

    private func runInLanguage(_ id: String) async {
        update(id) {
            $0.status = "running"
            $0.startedAt = Date().timeIntervalSince1970
            $0.stage = t("startet", "starting")
        }
        guard let job = jobs[id] else { return }
        let started = Date()
        if let r = job.request {
            // job.kind folgt dem Vertrag (txt2img/img2img); fürs Protokoll zählt die Technik --
            // ein Füllen-Auftrag stand dort sonst als „img2img“.
            let technique = r.maskAssetID != nil ? "inpaint"
                : r.imageAssetID != nil ? "img2img"
                : !r.referenceAssetIDs.isEmpty ? "references" : "txt2img"
            AppLog.info("Job \(id) started: \(technique), \(r.modelID), \(r.width)×\(r.height), \(r.steps) steps, \(r.batch) image(s)")
        } else if let m = job.downloadModelID {
            AppLog.info("Download \(id) started: \(m)")
        }
        do {
            if let modelID = job.downloadModelID {
                try await runDownload(id, modelID: modelID)
            } else if let prompt = job.expandPrompt {
                try await runExpand(id, prompt: prompt)
            } else if let restore = job.restore {
                AppLog.info("Job \(id) started: restore, \(restore.modelID), repair \(restore.repair), colorize \(restore.colorize), \(restore.batch) variant(s)")
                try await runRestore(id, restore)
            } else if let request = job.request {
                try await runImage(id, request)
            }
            update(id) {
                let cancelled = $0.cancelRequested
                $0.status = cancelled ? "cancelled" : "done"
                $0.stage = cancelled ? t("abgebrochen", "cancelled") : t("fertig", "done")
                $0.progress = 1
            }
        } catch where jobs[id]?.cancelRequested == true {
            // Abgebrochen (z. B. Download mitten in der Datei): kein Fehler.
            update(id) {
                $0.status = "cancelled"
                $0.stage = t("abgebrochen", "cancelled")
            }
            AppLog.info("Job \(id) cancelled by the user")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            update(id) {
                $0.status = "error"
                $0.error = message
                $0.stage = t("Fehler", "error")
            }
            AppLog.error("Job \(id) failed: \(message)")
        }
        update(id) { $0.finishedAt = Date().timeIntervalSince1970 }
        if let done = jobs[id] {
            let peak = done.timings.map(\.peakMB).max().map { ", peak \(Int($0)) MB" } ?? ""
            AppLog.info("Job \(id) \(done.status) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s\(peak)")
        }
    }

    private func loadProgress(_ id: String, fraction: Double, message: String, isDownload: Bool) {
        // Fortschrittsmeldungen kommen über Tasks und können nach dem Ende eintreffen.
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let percent = Int((max(0, min(1, fraction)) * 100).rounded())
            $0.stage = message.isEmpty ? t("lädt Modell (\(percent) %)", "loading model (\(percent) %)") : "\(message) (\(percent) %)"
            if isDownload { $0.progress = max(0, min(0.99, fraction)) }
        }
    }

    private func stepProgress(_ id: String, index: Int, of count: Int, step: Int, total: Int) {
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let inImage = total > 0 ? Double(step) / Double(total) : 0
            $0.progress = min(0.99, (Double(index) + inImage) / Double(max(1, count)))
            let prefix = count > 1 ? t("Bild \(index + 1) von \(count), ", "image \(index + 1) of \(count), ") : ""
            $0.stage = prefix + t("Schritt \(step) von \(total)", "step \(step) of \(total)")
        }
    }

    private func runDownload(_ id: String, modelID: String) async throws {
        guard let model = Models.find(modelID) else { throw APIError(404, t("Unbekanntes Modell: \(modelID)", "Unknown model: \(modelID)")) }
        update(id) { $0.stage = t("lädt \(model.name)", "loading \(model.name)") }
        let report: @Sendable (Double, String) -> Void = { fraction, message in
            Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: true) }
        }
        let work = Task {
            switch model {
            case .flux(let m):
                await CoreMLEngine.shared.unload()
                try await Flux2Engine.shared.load(m, progress: report)
            case .coreml(let m):
                try await CoreMLInstaller.install(m, progress: report)
            }
        }
        downloadTask = work
        defer { downloadTask = nil }
        try await work.value
        // Das FLUX.2-Paket bricht nicht mitten in der Datei ab; dann endet es hier.
        if jobs[id]?.cancelRequested == true { throw CancellationError() }
    }

    private func runExpand(_ id: String, prompt: String) async throws {
        guard let model = Models.expansionModel else {
            throw APIError(409, t("FLUX.2 Klein ist nicht geladen.", "FLUX.2 Klein is not downloaded."))
        }
        await CoreMLEngine.shared.unload()
        update(id) { $0.stage = t("baut den Prompt aus", "expanding the prompt") }
        let text = try await Flux2Engine.shared.expand(prompt, model: model)
        update(id) { $0.expanded = text }
        AppLog.info("Expanded prompt: \(prompt.split(separator: " ").count) → \(text.split(separator: " ").count) words")
    }

    private func loadImage(_ assetID: String, _ what: String) async throws -> CGImage {
        guard let asset = await AssetStore.shared.get(assetID) else {
            throw APIError(404, t("\(what): Asset \(assetID) nicht gefunden.", "\(what): asset \(assetID) not found."))
        }
        return try ImageFiles.load(AssetStore.shared.fileURL(asset.filename))
    }

    private func runImage(_ id: String, _ request: ImageJobRequest) async throws {
        var req = request
        guard let any = Models.find(req.modelID) else { throw APIError(404, t("Unbekanntes Modell: \(req.modelID)", "Unknown model: \(req.modelID)")) }
        if case .coreml(let m) = any {
            try await runCoreML(id, req, model: m)
            return
        }
        guard case .flux(let model) = any else { return }
        // Nur ein Modell im Speicher: Core ML vorher freigeben.
        await CoreMLEngine.shared.unload()

        // Eingangsbilder zuerst: ein falsches Asset soll scheitern, bevor das Modell lädt.
        var image: CGImage?
        var mask: CGImage?
        var refs: [CGImage] = []
        if let a = req.imageAssetID { image = try await loadImage(a, t("Ausgangsbild", "Start image")) }
        if let m = req.maskAssetID { mask = try await loadImage(m, t("Maske", "Mask")) }
        for r in req.referenceAssetIDs { refs.append(try await loadImage(r, t("Referenzbild", "Reference image"))) }

        // Outpainting: Bild auf grauem Rand als Referenz, Format = Bild plus Rand (siehe Outpaint).
        var original: CGImage?
        if let edges = req.outpaint, let source = image {
            let size = Outpaint.size(of: source, edges)
            guard size.width <= 2048, size.height <= 2048 else {
                throw APIError(422, t("Erweitert wäre das Bild \(size.width) × \(size.height) px, erlaubt sind höchstens 2048.",
                                      "Extended, the image would be \(size.width) × \(size.height) px; at most 2048 is allowed."))
            }
            original = source
            image = nil
            refs = []
            req.width = size.width
            req.height = size.height
        }

        let mode: EngineMode
        if let image, let mask {
            mode = .inpaint(ImageFiles.resized(image, width: req.width, height: req.height),
                            mask: ImageFiles.resized(mask, width: req.width, height: req.height), references: refs)
        } else if let image {
            // denoise 1.0 hieße: Ausgangsbild verwerfen. Dann dient es als Referenz (wie FLUX 3 unter Windows).
            mode = req.denoise >= 0.999
                ? .references([image] + refs)
                : .imageToImage(image, strength: Float(req.denoise), references: refs)
        } else if !refs.isEmpty {
            mode = .references(refs)
        } else {
            mode = .text   // auch beim Erweitern; dort setzt jeder Durchgang seine Referenz selbst
        }

        update(id) { $0.stage = t("lädt \(model.name)", "loading \(model.name)") }
        let loadStart = Date()
        let alreadyLoaded = await Flux2Engine.shared.currentModelID() == model.id
        try await Flux2Engine.shared.load(model) { fraction, message in
            Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: false) }
        }
        let loadSeconds = alreadyLoaded ? 0 : Date().timeIntervalSince(loadStart)

        let baseSeed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        for index in 0..<req.batch {
            if jobs[id]?.cancelRequested == true { break }
            var seed = baseSeed &+ UInt64(index)
            update(id) { $0.stage = req.batch > 1 ? t("Bild \(index + 1) von \(req.batch)", "image \(index + 1) of \(req.batch)") : t("rechnet", "generating") }
            let sampler = PeakMemorySampler()
            sampler.start()
            let started = Date()
            var result: CGImage
            do {
                func render(_ m: EngineMode, _ w: Int, _ h: Int, _ s: UInt64) async throws -> CGImage {
                    let job = EngineJob(mode: m, prompt: req.prompt, width: w, height: h,
                                        steps: req.steps, guidance: req.guidance, seed: s)
                    // Eigener Task, damit „Abbrechen“ die Rechnung mitten im Bild beenden kann.
                    let work = Task {
                        try await Flux2Engine.shared.generate(job) { step, total in
                            Task { await JobQueue.shared.stepProgress(id, index: index, of: req.batch, step: step, total: total) }
                        }
                    }
                    imageTask = work
                    defer { imageTask = nil }
                    // Kam der Abbruch, bevor der Task stand, gleich beenden.
                    if jobs[id]?.cancelRequested == true { work.cancel() }
                    return try await work.value
                }
                if let original, let edges = req.outpaint {
                    // Erweitern per Maske in einem Durchgang (OutpaintMask.swift); der Referenzweg ließ
                    // mit FLUX.2 Klein den Rand grau.
                    let padded = Outpaint.padded(original, edges)
                    guard let fill = Outpaint.mask(for: original, edges) else {
                        throw APIError(500, t("Maske fürs Erweitern ließ sich nicht anlegen.", "Could not build the extension mask."))
                    }
                    let gen = Outpaint.generationSize(req.width, req.height)
                    func attempt(_ s: UInt64) async throws -> CGImage {
                        let m = EngineMode.inpaint(ImageFiles.resized(padded, width: gen.width, height: gen.height),
                                                   mask: ImageFiles.resized(fill, width: gen.width, height: gen.height),
                                                   references: [])
                        return ImageFiles.resized(try await render(m, gen.width, gen.height, s),
                                                  width: padded.width, height: padded.height)
                    }
                    var raw = try await attempt(seed)
                    // Blieb Grau im neuen Rand stehen, einmal mit anderem Seed nachrechnen.
                    if Outpaint.greyShare(raw, original: original, edges) > Outpaint.greyLimit,
                       jobs[id]?.cancelRequested != true {
                        AppLog.info("Job \(id): grey left in the border, retrying with the next seed")
                        seed = seed &+ 1000
                        raw = try await attempt(seed)
                    }
                    result = Outpaint.compositeOriginal(result: raw, original: original, edges)
                } else {
                    result = try await render(mode, req.width, req.height, seed)
                }
            } catch {
                _ = sampler.stop()
                throw error
            }
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()

            let png = try ImageFiles.pngData(ImageFiles.resized(result, width: req.width, height: req.height))
            var meta: [String: JSONValue] = [
                "seed": .int(Int(seed)), "width": .int(req.width), "height": .int(req.height),
                "steps": .int(req.steps), "cfg": .double(Double(req.guidance)),
                "model_name": .string(model.name), "workflow": .string(model.workflow), "engine": .string("mlx"),
                "mode": .string(mode.name), "duration_s": .double((seconds * 10).rounded() / 10),
                "peak_memory_mb": .int(Int(peak)), "chip": .string(SystemInfo.chip),
                "ram_gb": .int(SystemInfo.memoryGB),
            ]
            if index == 0 && loadSeconds >= 0.1 { meta["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
            if let a = req.imageAssetID { meta["image_asset_id"] = .string(a); meta["denoise"] = .double(req.denoise) }
            if let m = req.maskAssetID { meta["mask_asset_id"] = .string(m) }
            if let e = req.outpaint {
                meta["outpaint"] = .array([e.left, e.top, e.right, e.bottom].map { .int($0) })
            }
            if !req.referenceAssetIDs.isEmpty { meta["reference_asset_ids"] = .array(req.referenceAssetIDs.map { .string($0) }) }

            let asset = try await AssetStore.shared.addImage(png: png, jobID: id, prompt: req.prompt,
                                                             modelID: model.id, meta: meta)
            let timing = JobRecord.Timing(seconds: seconds, peakMB: peak, loadSeconds: index == 0 ? loadSeconds : 0,
                                          width: req.width, height: req.height, steps: req.steps,
                                          mode: mode.name, modelID: model.id)
            update(id) {
                $0.assetIDs.append(asset.id)
                $0.timings.append(timing)
            }
        }
    }

    private func runCoreML(_ id: String, _ req: ImageJobRequest, model: CoreMLModel) async throws {
        var start: CGImage?
        if let a = req.imageAssetID, req.denoise < 0.999 {
            start = ImageFiles.resized(try await loadImage(a, t("Ausgangsbild", "Start image")), width: model.resolution, height: model.resolution)
        }
        update(id) { $0.stage = t("lädt \(model.name)", "loading \(model.name)") }
        await Flux2Engine.shared.unload()
        let loadStart = Date()
        let alreadyLoaded = await CoreMLEngine.shared.currentModelID() == model.id
        try await CoreMLEngine.shared.load(model)
        let loadSeconds = alreadyLoaded ? 0 : Date().timeIntervalSince(loadStart)

        let baseSeed = UInt32(truncatingIfNeeded: req.seed ?? UInt64.random(in: 0..<4_294_967_296))
        for index in 0..<req.batch {
            if jobs[id]?.cancelRequested == true { break }
            let seed = baseSeed &+ UInt32(index)
            update(id) { $0.stage = req.batch > 1 ? t("Bild \(index + 1) von \(req.batch)", "image \(index + 1) of \(req.batch)") : t("rechnet", "generating") }
            let sampler = PeakMemorySampler()
            sampler.start()
            let started = Date()
            let result: CGImage
            do {
                result = try await CoreMLEngine.shared.generate(
                    model: model, prompt: req.prompt, negative: req.negativePrompt, steps: req.steps,
                    guidance: req.guidance, seed: seed, startingImage: start, strength: Float(req.denoise)
                ) { step, total in
                    Task { await JobQueue.shared.stepProgress(id, index: index, of: req.batch, step: step, total: total) }
                }
            } catch {
                _ = sampler.stop()
                if jobs[id]?.cancelRequested == true { break }
                throw error
            }
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()
            let png = try ImageFiles.pngData(ImageFiles.resized(result, width: req.width, height: req.height))
            var meta: [String: JSONValue] = [
                "seed": .int(Int(seed)), "width": .int(req.width), "height": .int(req.height),
                "native_size": .int(model.resolution), "steps": .int(req.steps), "cfg": .double(Double(req.guidance)),
                "negative_prompt": .string(req.negativePrompt),
                "model_name": .string(model.name), "workflow": .string(model.workflow), "engine": .string("coreml"),
                "mode": .string(start == nil ? "txt2img" : "img2img"),
                "duration_s": .double((seconds * 10).rounded() / 10), "peak_memory_mb": .int(Int(peak)),
                "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
            ]
            if index == 0 && loadSeconds >= 0.1 { meta["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
            if let a = req.imageAssetID { meta["image_asset_id"] = .string(a); meta["denoise"] = .double(req.denoise) }
            let asset = try await AssetStore.shared.addImage(png: png, jobID: id, prompt: req.prompt,
                                                             modelID: model.id, meta: meta)
            let timing = JobRecord.Timing(seconds: seconds, peakMB: peak, loadSeconds: index == 0 ? loadSeconds : 0,
                                          width: req.width, height: req.height, steps: req.steps,
                                          mode: start == nil ? "txt2img" : "img2img", modelID: model.id)
            update(id) {
                $0.assetIDs.append(asset.id)
                $0.timings.append(timing)
            }
        }
    }

    // MARK: Restaurieren

    private func restoreProgress(_ id: String, run: Int, of count: Int, label: String, step: Int, total: Int) {
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let inRun = total > 0 ? Double(step) / Double(total) : 0
            $0.progress = min(0.99, (Double(run) + inRun) / Double(max(1, count)))
            $0.stage = "\(label) · " + t("Schritt \(step) von \(total)", "step \(step) of \(total)")
        }
    }

    /// Ein Lauf von FLUX.2 Klein mit dem Bild als Referenz, in genau der bestellten Größe zurück.
    private func renderReference(_ id: String, image: CGImage, prompt: String, size: (width: Int, height: Int),
                                 steps: Int, guidance: Float, seed: UInt64, run: Int, of count: Int,
                                 label: String) async throws -> CGImage {
        let source = ImageFiles.resized(image, width: size.width, height: size.height)
        let job = EngineJob(mode: .references([source]), prompt: prompt, width: size.width, height: size.height,
                            steps: steps, guidance: guidance, seed: seed)
        let work = Task {
            try await Flux2Engine.shared.generate(job) { step, total in
                Task { await JobQueue.shared.restoreProgress(id, run: run, of: count, label: label, step: step, total: total) }
            }
        }
        imageTask = work
        defer { imageTask = nil }
        if jobs[id]?.cancelRequested == true { work.cancel() }
        return ImageFiles.resized(try await work.value, width: size.width, height: size.height)
    }

    /// Foto restaurieren, wie `jobs._restore` unter Windows: je Variante erst die Schäden (FLUX.2 Klein rechnet
    /// das Foto mit der Anweisung neu, `RestoreTools.align` rückt es aufs Foto), dann die Farbe (FLUX.2 Klein
    /// färbt, übernommen wird nur Lab a/b auf die Helligkeit des Fotos bzw. des restaurierten Bildes). Ohne
    /// Restaurieren behält das eingefärbte Foto seine volle Auflösung.
    private func runRestore(_ id: String, _ req: RestoreJobRequest) async throws {
        guard case .flux(let model)? = Models.find(req.modelID) else {
            throw APIError(404, t("Unbekanntes Modell: \(req.modelID)", "Unknown model: \(req.modelID)"))
        }
        let photo = try await loadImage(req.imageAssetID, t("Foto", "Photo"))
        await CoreMLEngine.shared.unload()
        update(id) { $0.stage = t("lädt \(model.name)", "loading \(model.name)") }
        let loadStart = Date()
        let alreadyLoaded = await Flux2Engine.shared.currentModelID() == model.id
        try await Flux2Engine.shared.load(model) { fraction, message in
            Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: false) }
        }
        let loadSeconds = alreadyLoaded ? 0 : Date().timeIntervalSince(loadStart)
        let features = AnyModel.flux(model).features
        let steps = features["steps"] as? Int ?? 4
        let guidance = Float(features["cfg"] as? Double ?? 1.0)
        let baseSeed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        let runsPerVariant = (req.repair ? 1 : 0) + (req.colorize ? 1 : 0)
        let count = runsPerVariant * req.batch
        func instruction(_ text: String) -> String { req.notes.isEmpty ? text : "\(text) \(req.notes)" }
        let repairLabel = t("Schäden entfernen", "Removing damage"), colorLabel = t("Einfärben", "Colorizing")

        for k in 0..<req.batch {
            if jobs[id]?.cancelRequested == true { break }
            let seed = baseSeed &+ UInt64(k)
            let sampler = PeakMemorySampler()
            sampler.start()
            var current = photo
            var seconds: [String: JSONValue] = [:]
            var meta: [String: JSONValue] = [
                "restore": .object(["repair": .bool(req.repair), "colorize": .bool(req.colorize), "sharpen": .bool(false)]),
                "source_asset_id": .string(req.imageAssetID),
                "source_size": .array([.int(photo.width), .int(photo.height)]),
                "seed": .int(Int(seed)), "model_name": .string(model.name), "workflow": .string(model.workflow),
                "engine": .string("mlx"), "notes": .string(req.notes), "variant": .int(k + 1),
                "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
            ]
            do {
                if req.repair {
                    let started = Date()
                    let size = RestoreJobRequest.workingSize(photo.width, photo.height,
                                                             megapixels: req.megapixels ?? RestoreJobRequest.repairMegapixels)
                    let raw = try await renderReference(id, image: photo, prompt: instruction(RestoreJobRequest.repairInstruction),
                                                        size: size, steps: steps, guidance: guidance, seed: seed,
                                                        run: k * runsPerVariant, of: count, label: repairLabel)
                    let (aligned, alignment) = RestoreTools.align(raw, to: photo)
                    current = aligned
                    var info: [String: JSONValue] = [
                        "mode": .string("thorough"), "width": .int(size.width), "height": .int(size.height),
                        "align": alignment.json,
                    ]
                    // „auto“ trifft unter Windows ein Bild-Sprachmodell; hier sieht der Text-Encoder keine Bilder.
                    if req.repairMode == "auto" { info["auto"] = .string("thorough"); info["auto_answer"] = .null }
                    meta["repair"] = .object(info)
                    seconds["repair"] = .double((Date().timeIntervalSince(started) * 10).rounded() / 10)
                }
                if req.colorize && jobs[id]?.cancelRequested != true {
                    let started = Date()
                    let size = RestoreJobRequest.workingSize(current.width, current.height,
                                                             megapixels: RestoreJobRequest.colorizeMegapixels)
                    let raw = try await renderReference(id, image: current, prompt: instruction(RestoreJobRequest.colorizeInstruction),
                                                        size: size, steps: steps, guidance: guidance, seed: seed &+ 101,
                                                        run: k * runsPerVariant + (req.repair ? 1 : 0), of: count,
                                                        label: colorLabel)
                    let (aligned, alignment) = RestoreTools.align(raw, to: current)
                    let (colored, info) = RestoreTools.colorize(aligned, onto: current)
                    current = colored
                    var colorInfo = info.objectValue ?? [:]
                    colorInfo["width"] = .int(size.width)
                    colorInfo["height"] = .int(size.height)
                    colorInfo["align"] = alignment.json
                    meta["colorize"] = .object(colorInfo)
                    seconds["colorize"] = .double((Date().timeIntervalSince(started) * 10).rounded() / 10)
                }
            } catch {
                _ = sampler.stop()
                throw error
            }
            let peak = sampler.stop()
            if jobs[id]?.cancelRequested == true { break }
            meta["seconds"] = .object(seconds)
            meta["width"] = .int(current.width)
            meta["height"] = .int(current.height)
            meta["peak_memory_mb"] = .int(Int(peak))
            if k == 0 && loadSeconds >= 0.1 { meta["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
            let parts = [req.repair ? t("gründlich restauriert", "restored thoroughly") : nil,
                         req.colorize ? t("eingefärbt", "colorized") : nil].compactMap { $0 }
            let label = t("Foto ", "Photo ") + parts.joined(separator: ", ")
            let asset = try await AssetStore.shared.addImage(png: try ImageFiles.pngData(current), jobID: id,
                                                             prompt: req.notes.isEmpty ? label : "\(label): \(req.notes)",
                                                             modelID: model.id, meta: meta)
            update(id) { $0.assetIDs.append(asset.id) }
        }
    }
}
