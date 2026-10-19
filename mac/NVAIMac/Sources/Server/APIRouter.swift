import Foundation

/// Die REST-API von NV-AI, so weit sie die Clients (PhotoCraft-App, eigene Skripte) brauchen.
/// Formen genau wie in server/openapi.json des Windows-Servers (Vertrag api 1).
enum APIRouter {
    static let apiVersion = 1
    /// Was dieser Server von GenerateImageRequest versteht – kein „upsampler“: FLUX 3 gibt es hier nicht.
    static let features = ["model_features", "mask", "references", "upload", "model_search"]

    static func handle(_ req: HTTPRequest) async -> HTTPResponse {
        // Texte (Beschreibungen, Hinweise, Fehler) in der Sprache des Clients: de → Deutsch, sonst Englisch.
        let lang = Lang.from(acceptLanguage: req.headers["accept-language"])
        return await Lang.$request.withValue(lang) { await dispatch(req) }
    }

    private static func dispatch(_ req: HTTPRequest) async -> HTTPResponse {
        guard isLocal(req) else {
            return .error(403, t("NV-AI für Mac nimmt nur Anfragen von diesem Mac an.", "NV-AI for Mac only accepts requests from this Mac."))
        }
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        /// "/api/jobs/:id" passt auf /api/jobs/job_123 und liefert ["job_123"].
        func route(_ method: String, _ pattern: String) -> [String]? {
            guard req.method == method else { return nil }
            let pat = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard pat.count == parts.count else { return nil }
            var captures: [String] = []
            for (p, actual) in zip(pat, parts) {
                if p.hasPrefix(":") { captures.append(actual) } else if p != actual { return nil }
            }
            return captures
        }
        do {
            if route("GET", "/api/version") != nil { return .json(version()) }
            if route("GET", "/api/health") != nil { return .json(await health()) }
            if route("GET", "/api/models") != nil { return .json(models(kind: req.query["kind"])) }
            if route("POST", "/api/models/download") != nil { return try await download(req) }
            if route("GET", "/api/models/search") != nil { return try await search(req) }
            if route("GET", "/api/models/inspect") != nil { return try await inspect(req) }
            if route("POST", "/api/models/active") != nil { return try setActive(req) }
            if route("POST", "/api/generate/image") != nil {
                let request = try ImageJobRequest.parse(req.json)
                return .json(await JobQueue.shared.submit(request).json)
            }
            if let c = route("POST", "/api/generate/:kind") {
                throw APIError(404, t("NV-AI für Mac erzeugt nur Bilder (\(c[0]) gibt es hier nicht).",
                                      "NV-AI for Mac only generates images (\(c[0]) is not available here)."))
            }
            if route("GET", "/api/jobs") != nil {
                let limit = Int(req.query["limit"] ?? "") ?? 100
                return .json(await JobQueue.shared.list(limit: limit).map(\.json))
            }
            if route("POST", "/api/jobs/current/cancel") != nil {
                guard let job = await JobQueue.shared.cancelCurrent() else {
                    return .json(["cancelled": false, "detail": t("Es läuft kein Auftrag.", "No job is running.")])
                }
                return .json(["cancelled": true, "job_id": job.id,
                              "detail": t("Der Auftrag endet nach dem aktuellen Bild.", "The job ends after the current image.")])
            }
            if let c = route("GET", "/api/jobs/:id") {
                guard let job = await JobQueue.shared.job(c[0]) else { throw APIError(404, t("Unbekannter Auftrag: \(c[0])", "Unknown job: \(c[0])")) }
                return .json(job.json)
            }
            if let c = route("DELETE", "/api/jobs/:id") {
                if let job = await JobQueue.shared.job(c[0]), job.status == "queued" {
                    return .json(try await JobQueue.shared.cancel(c[0]).json)
                }
                try await JobQueue.shared.delete(c[0])
                return .json(["deleted": true, "id": c[0]])
            }
            if let c = route("GET", "/api/jobs/:id/assets") {
                let known = await JobQueue.shared.job(c[0]) != nil
                let assets = await AssetStore.shared.assets(ofJob: c[0])
                guard known || !assets.isEmpty else { throw APIError(404, t("Unbekannter Auftrag: \(c[0])", "Unknown job: \(c[0])")) }
                return .json(assets.map(\.json))
            }
            if route("GET", "/api/assets") != nil {
                let limit = Int(req.query["limit"] ?? "") ?? 200
                let kind = req.query["kind"].flatMap { $0.isEmpty ? nil : $0 }
                return .json(await AssetStore.shared.list(kind: kind, limit: limit).map(\.json))
            }
            if let c = route("GET", "/api/assets/:id") {
                guard let asset = await AssetStore.shared.get(c[0]) else { throw APIError(404, t("Unbekanntes Asset: \(c[0])", "Unknown asset: \(c[0])")) }
                return .json(asset.json)
            }
            if let c = route("DELETE", "/api/assets/:id") {
                guard await AssetStore.shared.delete(c[0]) else { throw APIError(404, t("Unbekanntes Asset: \(c[0])", "Unknown asset: \(c[0])")) }
                return .json(["deleted": true, "id": c[0]])
            }
            if route("POST", "/api/upload") != nil { return try await upload(req) }
            if let c = route("GET", "/files/:name") { return try file(c[0]) }
            return .error(404, t("Nicht gefunden: \(req.method) \(req.path)", "Not found: \(req.method) \(req.path)"))
        } catch let error as APIError {
            return .error(error.status, error.detail)
        } catch {
            return .error(500, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Wie NV-AI unter Windows: lokal heißt Loopback-Verbindung (erzwingt der Server), dazu
    /// ein lokaler Host-Header (gegen DNS-Rebinding) und kein fremder Origin (fremde Webseiten).
    static func isLocal(_ req: HTTPRequest) -> Bool {
        let local: Set<String> = ["127.0.0.1", "localhost", "::1"]
        func host(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return URLComponents(string: value.contains("//") ? value : "//\(value)")?.host?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        guard let h = host(req.headers["host"]), local.contains(h) else { return false }
        if let origin = req.headers["origin"] {
            guard let o = host(origin), local.contains(o) else { return false }
        }
        return true
    }

    // MARK: Endpunkte

    static func version() -> [String: Any] {
        [
            "name": "NV-AI", "version": SystemInfo.appVersion, "api": apiVersion, "features": features,
            "comfyui": NSNull(), "auth": "local", "authorized": true,
            "platform": "macos", "engine": "mlx",
        ]
    }

    static func health() async -> [String: Any] {
        let active = Models.active
        let fluxLoaded = await Flux2Engine.shared.currentModelID()
        let coremlLoaded = await CoreMLEngine.shared.currentModelID()
        var loadedList: [[String: String]] = []
        if let id = fluxLoaded, let m = Models.find(id) { loadedList.append(["backend": "MLX", "model": m.name]) }
        if let id = coremlLoaded, let m = Models.find(id) { loadedList.append(["backend": "Core ML", "model": m.name]) }
        let queue = JobQueue.shared
        return [
            "ok": true,
            "comfy_running": false,
            "engine": "mlx",
            "gpu": ["name": SystemInfo.chip, "vram_total_mb": SystemInfo.memoryMB, "vram_free_mb": NSNull(),
                    "unified_memory": true],
            "active_models": ["image": active.installed ? active.id as Any : NSNull(),
                              "audio": NSNull(), "video": NSNull(), "3d": NSNull()],
            "queue_depth": await queue.queueDepth,
            "current_job": await queue.currentJobID ?? NSNull(),
            "download_queue_depth": await queue.downloadDepth,
            "current_download": await queue.currentDownloadID ?? NSNull(),
            "hf_token": Settings.hfToken != nil,
            "vram_budget_gb": max(0, SystemInfo.memoryGB - 4),
            "vram_loaded": loadedList,
            "mesh_workers": [String: Any](),
            "models_dir": Settings.modelsDirectory.path,
        ]
    }

    static func models(kind: String?) -> [[String: Any]] {
        guard kind == nil || kind == "image" || kind == "" else { return [] }
        return Models.all.map(\.info)
    }

    static func download(_ req: HTTPRequest) async throws -> HTTPResponse {
        if let id = req.json?["model_id"]?.stringValue {
            guard let model = Models.find(id) else { throw APIError(404, t("Unbekanntes Modell: \(id)", "Unknown model: \(id)")) }
            return .json(await JobQueue.shared.submitDownload(model).json)
        }
        // Wie unter Windows: freies Repo + Datei (hier ein ZIP oder ein compiled-Ordner aus der Suche).
        guard let repo = req.json?["repo"]?.stringValue, let file = req.json?["file"]?.stringValue else {
            throw APIError(400, t("model_id oder repo+file erforderlich", "model_id or repo+file required"))
        }
        let offer = try await checkedOffer(repo: repo, file: file)
        guard offer.istLauffaehig else {
            if case .nicht(let reason) = offer.stand { throw APIError(422, reason) }
            throw APIError(422, t("Das Paket lässt sich nicht ausführen.", "This package cannot be run."))
        }
        let model = UserCoreMLCatalog.model(from: offer)
        UserCoreMLCatalog.add(model)
        Task { @MainActor in AppState.shared.refreshModels() }
        return .json(await JobQueue.shared.submitDownload(.coreml(model)).json)
    }

    /// GET /api/models/search?q=…: Core-ML-Bildmodelle auf Hugging Face. `files` sind die ladbaren
    /// Pakete (ZIP oder compiled-Ordner) – geprüft wird erst mit /api/models/inspect.
    static func search(_ req: HTTPRequest) async throws -> HTTPResponse {
        let limit = min(max(Int(req.query["limit"] ?? "") ?? 20, 1), 50)
        let hits: [HuggingFace.Treffer]
        do {
            hits = try await HuggingFace.suche(req.query["q"] ?? "")
        } catch {
            throw APIError(502, t("Hugging Face nicht erreichbar: ", "Hugging Face not reachable: ") + error.localizedDescription)
        }
        return .json(hits.prefix(limit).map { hit -> [String: Any] in
            ["repo": hit.id, "downloads": hit.downloads, "likes": hit.likes, "license": "", "gated": false,
             "pipeline_tag": "text-to-image", "files": hit.angebote.map(\.ordner),
             "note": t("Core-ML-Pipeline (\(hit.angebote.count) Paket(e))", "Core ML pipeline (\(hit.angebote.count) package(s))")]
        })
    }

    /// GET /api/models/inspect?repo=…&file=…: prüft ein Paket vor dem Laden, ohne Download.
    static func inspect(_ req: HTTPRequest) async throws -> HTTPResponse {
        guard let repo = req.query["repo"], let file = req.query["file"] else {
            throw APIError(422, t("repo und file sind nötig.", "repo and file are required."))
        }
        let offer = try await checkedOffer(repo: repo, file: file)
        var verdict = ""
        switch offer.stand {
        case .lauffaehig(let text): verdict = text
        case .nicht(let reason): verdict = reason
        case .ungeprueft: verdict = t("nicht geprüft", "not checked")
        }
        return .json([
            "repo": repo, "file": file, "ok": offer.istLauffaehig,
            "family": offer.isXL ? "sdxl" : "sd", "workflow": offer.isXL ? "coreml_sdxl" : "coreml_sd",
            "size_gb": offer.groesseGb, "verdict": verdict, "resolution": offer.aufloesung,
            "engine": "coreml",
        ])
    }

    private static func checkedOffer(repo: String, file: String) async throws -> HuggingFace.Angebot {
        let tree: [HuggingFace.Datei]
        do {
            tree = try await HuggingFace.dateien(in: repo)
        } catch {
            throw APIError(502, t("Hugging Face nicht erreichbar: ", "Hugging Face not reachable: ") + error.localizedDescription)
        }
        guard let offer = HuggingFace.angebote(repo: repo, pfade: tree.map(\.pfad)).first(where: { $0.ordner == file }) else {
            throw APIError(404, t("In \(repo) gibt es kein ladbares Paket „\(file)“.", "\(repo) has no loadable package \"\(file)\"."))
        }
        return await HuggingFace.pruefe(offer, baum: tree)
    }

    static func setActive(_ req: HTTPRequest) throws -> HTTPResponse {
        guard let id = req.json?["model_id"]?.stringValue, let model = Models.find(id) else {
            throw APIError(404, t("Unbekanntes Modell.", "Unknown model."))
        }
        Settings.activeModelID = model.id
        Task { @MainActor in AppState.shared.refreshModels() }
        return .json(["ok": true, "active": ["image": model.id]])
    }

    static func upload(_ req: HTTPRequest) async throws -> HTTPResponse {
        guard let boundary = Multipart.boundary(from: req.headers["content-type"]) else {
            throw APIError(422, t("Erwartet wird multipart/form-data mit dem Feld file.", "Expected multipart/form-data with the field file."))
        }
        guard let part = Multipart.parts(req.body, boundary: boundary).first(where: { $0.name == "file" }),
              !part.data.isEmpty else {
            throw APIError(422, t("Das Feld file fehlt oder ist leer.", "The field file is missing or empty."))
        }
        // Nur Bilder: was ImageIO nicht lesen kann, landet gar nicht erst in der Ablage.
        _ = try ImageFiles.load(part.data)
        let asset = try await AssetStore.shared.addUpload(data: part.data, originalName: part.filename ?? "upload.png")
        return .json(asset.json)
    }

    static func file(_ name: String) throws -> HTTPResponse {
        let url = AssetStore.shared.fileURL(name)
        guard let data = try? Data(contentsOf: url) else { throw APIError(404, t("Datei nicht gefunden", "File not found")) }
        let ext = url.pathExtension.lowercased()
        let type = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
                    "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic"][ext] ?? "application/octet-stream"
        return .file(data, contentType: type)
    }
}
