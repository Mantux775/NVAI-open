import Foundation
import CoreGraphics

/// Ein Auftrag – Felder wie `Job` im NV-AI-Vertrag.
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

/// Arbeitet Aufträge nacheinander ab – ein Modell, ein Rechenwerk, wie NV-AI unter Windows.
actor JobQueue {
    static let shared = JobQueue()

    private var jobs: [String: JobRecord] = [:]
    private var order: [String] = []
    private var runningID: String?
    private var worker: Task<Void, Never>?
    /// Laufender Download als eigene Task, damit „Abbrechen“ ihn mitten in der Datei stoppen kann.
    private var downloadTask: Task<Void, Error>?
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

    /// Wartende Aufträge fallen sofort weg; ein laufender endet nach dem aktuellen Bild,
    /// weil das Rechenpaket mitten im Bild nicht abbrechen kann.
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
                $0.stage = $0.request?.engine == "coreml" ? t("bricht ab", "cancelling")
                                                          : t("bricht nach dem aktuellen Bild ab", "cancelling after the current image")
            }
            if job.request?.engine == "coreml" { CoreMLEngine.shared.requestCancel() }
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
                                  + "er endet dann nach dem aktuellen Bild.",
                                  "The job is running. Cancel it with POST /api/jobs/current/cancel; "
                                  + "it then ends after the current image."))
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

    private func runImage(_ id: String, _ req: ImageJobRequest) async throws {
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
            mode = .text
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
            let seed = baseSeed &+ UInt64(index)
            update(id) { $0.stage = req.batch > 1 ? t("Bild \(index + 1) von \(req.batch)", "image \(index + 1) of \(req.batch)") : t("rechnet", "generating") }
            let sampler = PeakMemorySampler()
            sampler.start()
            let started = Date()
            let job = EngineJob(mode: mode, prompt: req.prompt, width: req.width, height: req.height,
                                steps: req.steps, guidance: req.guidance, seed: seed)
            let result: CGImage
            do {
                result = try await Flux2Engine.shared.generate(job) { step, total in
                    Task { await JobQueue.shared.stepProgress(id, index: index, of: req.batch, step: step, total: total) }
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
}
