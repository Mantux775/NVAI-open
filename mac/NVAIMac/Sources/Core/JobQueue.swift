import Foundation
import CoreGraphics
import LTXV

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
    /// Musik oder Klang (seit 0.4.7, `POST /api/generate/audio`).
    var audio: AudioJobRequest?
    /// Video (seit 0.4.8, `POST /api/generate/video`).
    var video: VideoJobRequest?
    var downloadModelID: String?
    /// „Prompt ausbauen“: Eingabe und Ergebnis. Der Auftrag verschwindet danach wieder.
    var expandPrompt: String?
    /// Wofür ausgebaut wird (seit 0.4.8 auch Video); nil = Bild.
    var expandTarget: PromptTarget?
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
    private var videoTask: Task<VideoEngine.Result, Error>?
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

    func submitAudio(_ request: AudioJobRequest) -> JobRecord {
        var job = JobRecord(id: AssetStore.newID("job"), kind: "txt2audio", status: "queued",
                            stage: t("wartet", "queued"), params: request.params, createdAt: Date().timeIntervalSince1970,
                            lang: request.lang)
        job.audio = request
        add(job)
        return job
    }

    func submitVideo(_ request: VideoJobRequest) -> JobRecord {
        var job = JobRecord(id: AssetStore.newID("job"), kind: request.imageAssetID == nil ? "txt2video" : "img2video",
                            status: "queued",
                            stage: t("wartet", "queued"), params: request.params, createdAt: Date().timeIntervalSince1970,
                            lang: request.lang)
        job.video = request
        add(job)
        return job
    }

    /// LTX-Video 2B laden.
    func submitVideoDownload() -> JobRecord {
        if let existing = jobs.values.first(where: { $0.downloadModelID == VideoCatalog.id && !$0.isFinished }) {
            return existing
        }
        let job = JobRecord(id: AssetStore.newID("job"), kind: "download", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["model_id": .string(VideoCatalog.id)]),
                            createdAt: Date().timeIntervalSince1970, downloadModelID: VideoCatalog.id, lang: Lang.current)
        add(job)
        return job
    }

    /// Stable Audio 3 laden.
    func submitAudioDownload() -> JobRecord {
        if let existing = jobs.values.first(where: { $0.downloadModelID == AudioCatalog.id && !$0.isFinished }) {
            return existing
        }
        let job = JobRecord(id: AssetStore.newID("job"), kind: "download", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["model_id": .string(AudioCatalog.id)]),
                            createdAt: Date().timeIntervalSince1970, downloadModelID: AudioCatalog.id, lang: Lang.current)
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

    /// LoRA laden (FLUX.2 Klein).
    func submitDownload(_ lora: LoRAModel) -> JobRecord {
        if let existing = jobs.values.first(where: { $0.downloadModelID == lora.id && !$0.isFinished }) {
            return existing
        }
        let job = JobRecord(id: AssetStore.newID("job"), kind: "download", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["model_id": .string(lora.id)]),
                            createdAt: Date().timeIntervalSince1970, downloadModelID: lora.id, lang: Lang.current)
        add(job)
        return job
    }

    /// Zusatzmodell laden (Qwen3.5 für „Automatisch“ beim Restaurieren).
    func submitDownload(_ helper: HelperModel) -> JobRecord {
        if let existing = jobs.values.first(where: { $0.downloadModelID == helper.id && !$0.isFinished }) {
            return existing
        }
        let job = JobRecord(id: AssetStore.newID("job"), kind: "download", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["model_id": .string(helper.id)]),
                            createdAt: Date().timeIntervalSince1970, downloadModelID: helper.id, lang: Lang.current)
        add(job)
        return job
    }

    func submitExpand(_ prompt: String, target: PromptTarget = .image) -> JobRecord {
        let job = JobRecord(id: AssetStore.newID("job"), kind: "expand_prompt", status: "queued", stage: t("wartet", "queued"),
                            params: .object(["prompt": .string(prompt), "target": .string(target.rawValue)]),
                            createdAt: Date().timeIntervalSince1970,
                            expandPrompt: prompt, expandTarget: target, lang: Lang.current)
        add(job)
        return job
    }

    /// Prompt ausbauen und warten: läuft in der Warteschlange (ein Modell zur Zeit), danach wird der
    /// Auftrag gelöscht, damit er nicht im Verlauf steht. Für die Generieren-Seite und die API.
    static func expandAndWait(_ prompt: String, target: PromptTarget = .image) async throws -> (expanded: String, seconds: Double) {
        guard Models.expansionModel != nil else {
            throw APIError(409, t("Prompt ausbauen braucht FLUX.2 Klein (dessen Text-Encoder schreibt die Beschreibung). "
                                  + "Bitte unter „Modelle“ laden.",
                                  "Expand prompt needs FLUX.2 Klein (its text encoder writes the description). "
                                  + "Please download it under \"Models\"."))
        }
        let started = Date()
        let job = await shared.submitExpand(prompt, target: target)
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
            videoTask?.cancel()
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
                try await runExpand(id, prompt: prompt, target: job.expandTarget ?? .image)
            } else if let audio = job.audio {
                AppLog.info("Job \(id) started: audio, \(Int(audio.seconds)) s, \(audio.steps) steps")
                try await runAudio(id, audio)
            } else if let video = job.video {
                AppLog.info("Job \(id) started: video, \(video.width)×\(video.height), \(video.frames) frames, \(video.fps) fps")
                try await runVideo(id, video)
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
        if modelID == VideoCatalog.id {
            update(id) { $0.stage = t("lädt \(VideoCatalog.name)", "downloading \(VideoCatalog.name)") }
            let report: @Sendable (Double, String) -> Void = { fraction, message in
                Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: true) }
            }
            let work = Task { try await VideoCatalog.download(progress: report) }
            downloadTask = work
            defer { downloadTask = nil }
            try await work.value
            return
        }
        if modelID == AudioCatalog.id {
            update(id) { $0.stage = t("lädt \(AudioCatalog.name)", "downloading \(AudioCatalog.name)") }
            let report: @Sendable (Double, String) -> Void = { fraction, message in
                Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: true) }
            }
            let work = Task { try await AudioCatalog.download(progress: report) }
            downloadTask = work
            defer { downloadTask = nil }
            try await work.value
            return
        }
        if let lora = LoRACatalog.find(modelID) {
            update(id) { $0.stage = t("lädt \(lora.name)", "downloading \(lora.name)") }
            let report: @Sendable (Double, String) -> Void = { fraction, message in
                Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: true) }
            }
            let work = Task { try await lora.download(progress: report) }
            downloadTask = work
            defer { downloadTask = nil }
            try await work.value
            return
        }
        if let helper = HelperModel.find(modelID) {
            update(id) { $0.stage = t("lädt \(helper.name)", "downloading \(helper.name)") }
            let report: @Sendable (Double, String) -> Void = { fraction, message in
                Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: true) }
            }
            let work = Task { try await helper.download(progress: report) }
            downloadTask = work
            defer { downloadTask = nil }
            try await work.value
            if jobs[id]?.cancelRequested == true { throw CancellationError() }
            return
        }
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
            case .zimage(let m):
                try await m.download(progress: report)
            }
        }
        downloadTask = work
        defer { downloadTask = nil }
        try await work.value
        // Das FLUX.2-Paket bricht nicht mitten in der Datei ab; dann endet es hier.
        if jobs[id]?.cancelRequested == true { throw CancellationError() }
    }

    private func runExpand(_ id: String, prompt: String, target: PromptTarget) async throws {
        guard let model = Models.expansionModel else {
            throw APIError(409, t("FLUX.2 Klein ist nicht geladen.", "FLUX.2 Klein is not downloaded."))
        }
        await CoreMLEngine.shared.unload()
        // Qwen3 neben einem geladenen Video- oder Klangmodell sprengt 8 GB (wie vor einem Video, siehe runVideo).
        if SystemInfo.memoryGB <= 16 {
            await VideoEngine.shared.unload()
            await AudioEngine.shared.unload()
            await SeedVR2Engine.shared.unload()
            await VisionEngine.shared.unload()
            await ZImageEngine.shared.unload()
            MemoryLog.release()
        }
        update(id) { $0.stage = t("baut den Prompt aus", "expanding the prompt") }
        let text = try await Flux2Engine.shared.expand(prompt, model: model, target: target)
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
        if case .zimage(let m) = any {
            try await runZImage(id, req, model: m)
            return
        }
        guard case .flux(let model) = any else { return }
        // Nur ein Modell im Speicher: Core ML (und auf kleinen Macs Klang und Schärfen) vorher freigeben.
        await CoreMLEngine.shared.unload()
        await freeHelpers()

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
        try await Flux2Engine.shared.load(model, loras: req.loras) { fraction, message in
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
            if !req.loras.isEmpty {
                meta["loras"] = .array(req.loras.map { .object(["model_id": .string($0.id), "strength": .double($0.strength)]) })
            }

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

    /// Auf Macs bis 16 GB passt neben FLUX.2 kein weiteres Modell: Klang, SeedVR2, Qwen3.5 und Z-Image freigeben.
    private func freeHelpers() async {
        guard SystemInfo.memoryGB <= 16 else { return }
        await AudioEngine.shared.unload()
        await SeedVR2Engine.shared.unload()
        await VisionEngine.shared.unload()
        await ZImageEngine.shared.unload()
        await VideoEngine.shared.unload()
    }

    /// Z-Image Turbo (`ZImageEngine`): Text zu Bild, 8 Schritte.
    private func runZImage(_ id: String, _ req: ImageJobRequest, model: ZImageModel) async throws {
        await CoreMLEngine.shared.unload()
        if SystemInfo.memoryGB <= 16 {
            await Flux2Engine.shared.unload()
            await AudioEngine.shared.unload()
            await SeedVR2Engine.shared.unload()
            await VisionEngine.shared.unload()
            await VideoEngine.shared.unload()
            MemoryLog.release()
        }
        let baseSeed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        for index in 0..<req.batch {
            if jobs[id]?.cancelRequested == true { break }
            let seed = baseSeed &+ UInt64(index)
            update(id) {
                $0.stage = req.batch > 1 ? t("Bild \(index + 1) von \(req.batch)", "image \(index + 1) of \(req.batch)")
                    : t("rechnet", "generating")
            }
            let sampler = PeakMemorySampler()
            sampler.start()
            let started = Date()
            let work = Task {
                try await ZImageEngine.shared.generate(
                    model: model, prompt: req.prompt, width: req.width, height: req.height, steps: req.steps, seed: seed,
                    onStep: { step, total in
                        Task { await JobQueue.shared.stepProgress(id, index: index, of: req.batch, step: step, total: total) }
                    },
                    onDecode: { done, total in
                        Task { await JobQueue.shared.decodeProgress(id, index: index, of: req.batch, done: done, total: total) }
                    })
            }
            imageTask = work
            if jobs[id]?.cancelRequested == true { work.cancel() }
            let result: CGImage
            do {
                result = try await work.value
            } catch {
                imageTask = nil
                _ = sampler.stop()
                if jobs[id]?.cancelRequested == true { break }
                throw error
            }
            imageTask = nil
            let seconds = Date().timeIntervalSince(started)
            let peak = sampler.stop()
            MemoryLog.line("after Z-Image")
            let png = try ImageFiles.pngData(ImageFiles.resized(result, width: req.width, height: req.height))
            let meta: [String: JSONValue] = [
                "seed": .int(Int(seed)), "width": .int(req.width), "height": .int(req.height), "steps": .int(req.steps),
                "cfg": .double(0), "model_name": .string(model.name), "workflow": .string(model.workflow),
                "engine": .string("mlx"), "mode": .string("txt2img"),
                "duration_s": .double((seconds * 10).rounded() / 10), "peak_memory_mb": .int(Int(peak)),
                "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
            ]
            let asset = try await AssetStore.shared.addImage(png: png, jobID: id, prompt: req.prompt, modelID: model.id, meta: meta)
            let timing = JobRecord.Timing(seconds: seconds, peakMB: peak, loadSeconds: 0, width: req.width, height: req.height,
                                          steps: req.steps, mode: "txt2img", modelID: model.id)
            update(id) {
                $0.assetIDs.append(asset.id)
                $0.timings.append(timing)
            }
        }
    }

    // MARK: Musik und Klänge

    /// Stable Audio 3 Medium (`AudioEngine`), wie unter Windows 8 Schritte mit cfg 1; WAV in die Ablage.
    private func runAudio(_ id: String, _ req: AudioJobRequest) async throws {
        await CoreMLEngine.shared.unload()
        if SystemInfo.memoryGB <= 16 {
            await Flux2Engine.shared.unload()
            await SeedVR2Engine.shared.unload()
            await VisionEngine.shared.unload()
            await ZImageEngine.shared.unload()
            await VideoEngine.shared.unload()
            MemoryLog.release()
        }
        update(id) { $0.stage = t("lädt Stable Audio 3", "loading Stable Audio 3") }
        let sampler = PeakMemorySampler()
        sampler.start()
        let loadStart = Date()
        let wasLoaded = await AudioEngine.shared.isLoaded
        do {
            try await AudioEngine.shared.load()
        } catch {
            _ = sampler.stop()
            throw error
        }
        let loadSeconds = wasLoaded ? 0 : Date().timeIntervalSince(loadStart)
        let seed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        update(id) {
            $0.stage = t("rechnet \(Int(req.seconds)) s Klang", "generating \(Int(req.seconds)) s of audio")
            $0.progress = 0.1
        }
        let started = Date()
        let wav: Data
        do {
            wav = try await AudioEngine.shared.generate(prompt: req.prompt, seconds: req.seconds, steps: req.steps,
                                                        cfg: req.cfg, seed: seed)
        } catch {
            _ = sampler.stop()
            throw error
        }
        let seconds = Date().timeIntervalSince(started)
        let peak = sampler.stop()
        MemoryLog.line("after Stable Audio 3")
        var meta: [String: JSONValue] = [
            "seed": .int(Int(seed)), "seconds": .double(req.seconds), "steps": .int(req.steps), "cfg": .double(req.cfg),
            "model_name": .string(AudioCatalog.name), "workflow": .string("stable_audio_3"), "engine": .string("mlx"),
            "sample_rate": .int(44_100), "format": .string("wav"),
            "duration_s": .double((seconds * 10).rounded() / 10), "peak_memory_mb": .int(Int(peak)),
            "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
        ]
        if loadSeconds >= 0.1 { meta["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
        let asset = try await AssetStore.shared.addAudio(wav: wav, jobID: id, prompt: req.prompt, modelID: AudioCatalog.id,
                                                         meta: meta)
        update(id) { $0.assetIDs.append(asset.id) }
    }

    // MARK: Video

    /// LTX-Video 2B (`VideoEngine`): Startbild-Encoder, T5, Transformer und Decoder nacheinander, MP4 in die Ablage.
    private func runVideo(_ id: String, _ req: VideoJobRequest) async throws {
        var startImage: CGImage?
        if let image = req.imageAssetID { startImage = try await loadImage(image, t("Startbild", "Start image")) }
        await CoreMLEngine.shared.unload()
        if SystemInfo.memoryGB <= 16 {
            await Flux2Engine.shared.unload()
            await AudioEngine.shared.unload()
            await SeedVR2Engine.shared.unload()
            await VisionEngine.shared.unload()
            await ZImageEngine.shared.unload()
            MemoryLog.release()
        }
        let seed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        update(id) { $0.stage = t("liest den Prompt", "reading the prompt") }
        let sampler = PeakMemorySampler()
        sampler.start()
        let started = Date()
        let work = Task {
            try await VideoEngine.shared.generate(
                prompt: req.prompt, width: req.width, height: req.height, frames: req.frames, fps: req.fps, seed: seed,
                startImage: startImage,
                onStep: { step, total in
                    Task { await JobQueue.shared.videoProgress(id, phase: 0, done: step, total: total) }
                },
                onDecode: { done, total in
                    Task { await JobQueue.shared.videoProgress(id, phase: 1, done: done, total: total) }
                })
        }
        videoTask = work
        defer { videoTask = nil }
        let result: VideoEngine.Result
        do {
            result = try await work.value
        } catch {
            _ = sampler.stop()
            throw error
        }
        let seconds = Date().timeIntervalSince(started)
        let peak = sampler.stop()
        MemoryLog.line("after LTX-Video")
        var meta: [String: JSONValue] = [
            "seed": .int(Int(seed)), "width": .int(req.width), "height": .int(req.height), "frames": .int(result.frames),
            "fps": .int(req.fps), "seconds": .double((Double(result.frames) / Double(req.fps) * 100).rounded() / 100),
            "steps": .int(8), "cfg": .double(1), "model_name": .string(VideoCatalog.name),
            "workflow": .string(req.imageAssetID == nil ? "ltxv_distilled" : "ltxv_distilled_i2v"),
            "engine": .string("mlx"), "format": .string("mp4"),
            "duration_s": .double((seconds * 10).rounded() / 10), "peak_memory_mb": .int(Int(peak)),
            "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
        ]
        for (key, value) in result.timings { meta["\(key)_s"] = .double((value * 10).rounded() / 10) }
        if let image = req.imageAssetID {
            meta["image_asset_id"] = .string(image)
            meta["image_noise_scale"] = .double((Double(LTXPipeline.imageNoiseScale) * 100).rounded() / 100)
        }
        let asset = try await AssetStore.shared.addVideo(mp4: result.url, jobID: id, prompt: req.prompt,
                                                         modelID: VideoCatalog.id, meta: meta)
        update(id) { $0.assetIDs.append(asset.id) }
    }

    /// Phase 0: Entrauschen (bis 85 %), Phase 1: Dekodieren in Kacheln.
    private func videoProgress(_ id: String, phase: Int, done: Int, total: Int) {
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            if phase == 0 {
                $0.progress = min(0.85, 0.85 * fraction)
                $0.stage = t("Schritt \(done) von \(total)", "step \(done) of \(total)")
            } else {
                $0.progress = min(0.99, 0.85 + 0.14 * fraction)
                $0.stage = t("dekodiert · Kachel \(done) von \(total)", "decoding · tile \(done) of \(total)")
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

    /// Z-Image dekodiert auf kleinen Macs in Kacheln (1024² am 8-GB-M1: vier).
    private func decodeProgress(_ id: String, index: Int, of count: Int, done: Int, total: Int) {
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let prefix = count > 1 ? t("Bild \(index + 1) von \(count), ", "image \(index + 1) of \(count), ") : ""
            $0.stage = prefix + t("dekodiert · Kachel \(done) von \(total)", "decoding · tile \(done) of \(total)")
        }
    }

    private func sharpenProgress(_ id: String, run: Int, of count: Int, done: Int, total: Int) {
        guard jobs[id]?.status == "running" else { return }
        update(id) {
            let inRun = total > 0 ? Double(done) / Double(total) : 0
            $0.progress = min(0.99, (Double(run) + inRun) / Double(max(1, count)))
            $0.stage = t("Schärfen · Kachel \(done) von \(total)", "Sharpening · tile \(done) of \(total)")
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
    /// das Foto mit der Anweisung neu, `RestoreTools.align` rückt es aufs Foto; schonend setzt
    /// `RestoreTools.mergeDamage` davon nur die Schäden ins Foto in voller Auflösung), dann die Farbe (FLUX.2 Klein
    /// färbt, übernommen wird nur Lab a/b auf die Helligkeit des Fotos bzw. des restaurierten Bildes). Ohne
    /// Restaurieren behält das eingefärbte Foto seine volle Auflösung. „auto“ fragt vorher Qwen3.5 4B nach der Art
    /// der Schäden (`VisionEngine`), einmal je Auftrag und vor dem Laden von FLUX.2 (beide passen auf 8 GB nicht
    /// zugleich).
    private func runRestore(_ id: String, _ req: RestoreJobRequest) async throws {
        var fluxModel: CatalogModel?
        if req.repair || req.colorize {
            guard case .flux(let m)? = Models.find(req.modelID) else {
                throw APIError(404, t("Unbekanntes Modell: \(req.modelID)", "Unknown model: \(req.modelID)"))
            }
            fluxModel = m
        }
        let photo = try await loadImage(req.imageAssetID, t("Foto", "Photo"))
        await CoreMLEngine.shared.unload()
        if SystemInfo.memoryGB <= 16 {
            await AudioEngine.shared.unload()
            await ZImageEngine.shared.unload()
            await VideoEngine.shared.unload()
        }
        var kind: (mode: String, answer: String?)?
        if req.repair && req.repairMode == "auto" {
            if HelperModel.vision.installed {
                update(id) { $0.stage = t("Schäden entfernen · prüft die Art der Schäden", "Removing damage · checking the kind of damage") }
                if SystemInfo.memoryGB <= 16, await VisionEngine.shared.cachedAnswer(req.imageAssetID) == nil {
                    await Flux2Engine.shared.unload()
                }
                let started = Date()
                let r = try await VisionEngine.shared.restoreKind(photo, assetID: req.imageAssetID)
                MemoryLog.release()
                MemoryLog.line("after Qwen3.5")
                kind = (r.gentle ? "gentle" : "thorough", r.answer)
                AppLog.info("Job \(id): automatic restore picked \(kind!.mode) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(r.answer))")
            } else {
                // Ohne Bild-Sprachmodell wie unter Windows ohne Upsampler: gründlich lässt keine Schäden stehen.
                kind = ("thorough", nil)
            }
        }
        let repairMode = kind?.mode ?? req.repairMode
        let baseSeed = req.seed ?? UInt64.random(in: 0..<4_294_967_296)
        let runsPerVariant = (req.repair ? 1 : 0) + (req.colorize ? 1 : 0)
        // Läufe für den Fortschritt: je Variante die FLUX-Schritte, dazu das Schärfen.
        let count = (runsPerVariant + (req.sharpen ? 1 : 0)) * req.batch
        func baseMeta(_ seed: UInt64, _ variant: Int) -> [String: JSONValue] {
            [
                "restore": .object(["repair": .bool(req.repair), "colorize": .bool(req.colorize), "sharpen": .bool(req.sharpen)]),
                "source_asset_id": .string(req.imageAssetID),
                "source_size": .array([.int(photo.width), .int(photo.height)]),
                "seed": .int(Int(seed)), "engine": .string("mlx"), "notes": .string(req.notes), "variant": .int(variant),
                "chip": .string(SystemInfo.chip), "ram_gb": .int(SystemInfo.memoryGB),
            ]
        }
        // Ergebnis je Variante nach dem letzten Schritt; gespeichert wird erst am Ende (Schärfen kommt nach allen
        // FLUX-Läufen, weil SeedVR2 und FLUX.2 auf 8 GB nicht zugleich passen).
        var outputs: [(image: CGImage, meta: [String: JSONValue], seconds: [String: JSONValue], peak: Double)] = []

        if let model = fluxModel {
            update(id) { $0.stage = t("lädt \(model.name)", "loading \(model.name)") }
            let loadStart = Date()
            let alreadyLoaded = await Flux2Engine.shared.currentModelID() == model.id
            try await Flux2Engine.shared.load(model) { fraction, message in
                Task { await JobQueue.shared.loadProgress(id, fraction: fraction, message: message, isDownload: false) }
            }
            let loadSeconds = alreadyLoaded ? 0 : Date().timeIntervalSince(loadStart)
            MemoryLog.line("FLUX.2 loaded")
            let features = AnyModel.flux(model).features
            let steps = features["steps"] as? Int ?? 4
            let guidance = Float(features["cfg"] as? Double ?? 1.0)
            func instruction(_ text: String) -> String { req.notes.isEmpty ? text : "\(text) \(req.notes)" }
            let repairLabel = t("Schäden entfernen", "Removing damage"), colorLabel = t("Einfärben", "Colorizing")

            for k in 0..<req.batch {
                if jobs[id]?.cancelRequested == true { break }
                let seed = baseSeed &+ UInt64(k)
                let sampler = PeakMemorySampler()
                sampler.start()
                var current = photo
                var seconds: [String: JSONValue] = [:]
                var meta = baseMeta(seed, k + 1)
                meta["model_name"] = .string(model.name)
                meta["workflow"] = .string(model.workflow)
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
                            "mode": .string(req.repairMode), "width": .int(size.width), "height": .int(size.height),
                            "align": alignment.json,
                        ]
                        if let kind { info["auto"] = .string(kind.mode); info["auto_answer"] = kind.answer.map { .string($0) } ?? .null }
                        if repairMode == "gentle" {
                            // Schonend: Foto in voller Auflösung, nur die Schäden aus dem Ergebnis von FLUX.2.
                            update(id) { $0.stage = repairLabel + " · " + t("setzt ein", "merging") }
                            let (merged, mergeInfo) = await Task.detached { RestoreTools.mergeDamage(aligned, onto: photo) }.value
                            current = merged
                            info["merge"] = mergeInfo
                        }
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
                MemoryLog.line("after variant \(k + 1)")
                if jobs[id]?.cancelRequested == true { break }
                if k == 0 && loadSeconds >= 0.1 { meta["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
                outputs.append((current, meta, seconds, peak))
            }
        } else {
            var meta = baseMeta(baseSeed, 1)
            meta["model_name"] = .string(HelperModel.sharpen.name)
            meta["workflow"] = .string("seedvr2")
            outputs = [(photo, meta, [:], 0)]
        }

        // Schärfen und vergrößern: auf Foto × scale, höchstens sharpenMaxPixels (wie unter Windows features.max_pixels).
        if req.sharpen && jobs[id]?.cancelRequested != true && !outputs.isEmpty {
            guard let dir = HelperModel.sharpen.localPath else {
                throw APIError(409, t("SeedVR2 3B ist nicht geladen (unter „Modelle“ → Zusätze).",
                                      "SeedVR2 3B is not downloaded (under \"Models\" → Add-ons)."))
            }
            var w = Int((Double(photo.width) * req.scale).rounded()), h = Int((Double(photo.height) * req.scale).rounded())
            let limit = Double(HelperModel.sharpenMaxPixels)
            if Double(w * h) > limit {
                let k = (limit / Double(w * h)).squareRoot()
                w = Int(Double(w) * k)
                h = Int(Double(h) * k)
            }
            let label = t("Schärfen", "Sharpening")
            if SystemInfo.memoryGB <= 16 {
                await Flux2Engine.shared.unload()
                MemoryLog.release()
            }
            MemoryLog.line("before SeedVR2")
            update(id) { $0.stage = label + " · " + t("lädt SeedVR2", "loading SeedVR2") }
            let loadStart = Date()
            let wasLoaded = await SeedVR2Engine.shared.isLoaded
            try await SeedVR2Engine.shared.load(dir)
            let loadSeconds = wasLoaded ? 0 : Date().timeIntervalSince(loadStart)
            MemoryLog.line("SeedVR2 loaded")
            for i in outputs.indices {
                if jobs[id]?.cancelRequested == true { break }
                let started = Date()
                let sampler = PeakMemorySampler()
                sampler.start()
                let source = outputs[i].image
                let run = runsPerVariant * req.batch + i
                let seed = baseSeed &+ 201 &+ UInt64(i)
                let work = Task {
                    try await SeedVR2Engine.shared.upscale(source, width: w, height: h, seed: seed) { done, total in
                        Task { await JobQueue.shared.sharpenProgress(id, run: run, of: count, done: done, total: total) }
                    }
                }
                imageTask = work
                if jobs[id]?.cancelRequested == true { work.cancel() }
                let sharpened: CGImage
                do {
                    sharpened = try await work.value
                } catch {
                    imageTask = nil
                    _ = sampler.stop()
                    throw error
                }
                imageTask = nil
                outputs[i].image = sharpened
                var info: [String: JSONValue] = [
                    "model_id": .string(HelperModel.sharpen.id), "width": .int(w), "height": .int(h),
                    "scale": .double(req.scale), "tile": .int(SeedVR2Engine.tile),
                ]
                if i == 0 && loadSeconds >= 0.1 { info["load_s"] = .double((loadSeconds * 10).rounded() / 10) }
                outputs[i].meta["sharpen"] = .object(info)
                outputs[i].meta["upscale_model_name"] = .string(HelperModel.sharpen.name)
                outputs[i].seconds["sharpen"] = .double((Date().timeIntervalSince(started) * 10).rounded() / 10)
                outputs[i].peak = max(outputs[i].peak, sampler.stop())
            }
            MemoryLog.line("after SeedVR2")
            // Auf kleinen Macs Platz machen für das nächste Bild mit FLUX.2.
            if SystemInfo.memoryGB <= 16 { await SeedVR2Engine.shared.unload() }
        }
        if jobs[id]?.cancelRequested == true { return }

        // Im Verlauf soll stehen, wie restauriert wurde (bei „auto“ die getroffene Wahl).
        let repaired = repairMode == "gentle" ? t("schonend restauriert", "restored gently")
            : t("gründlich restauriert", "restored thoroughly")
        let parts = [req.repair ? repaired : nil, req.colorize ? t("eingefärbt", "colorized") : nil,
                     req.sharpen ? t("geschärft", "sharpened") : nil].compactMap { $0 }
        let label = t("Foto ", "Photo ") + parts.joined(separator: ", ")
        for out in outputs {
            var meta = out.meta
            meta["seconds"] = .object(out.seconds)
            meta["width"] = .int(out.image.width)
            meta["height"] = .int(out.image.height)
            meta["peak_memory_mb"] = .int(Int(out.peak))
            let asset = try await AssetStore.shared.addImage(png: try ImageFiles.pngData(out.image), jobID: id,
                                                             prompt: req.notes.isEmpty ? label : "\(label): \(req.notes)",
                                                             modelID: fluxModel?.id ?? HelperModel.sharpen.id, meta: meta)
            update(id) { $0.assetIDs.append(asset.id) }
        }
    }
}
