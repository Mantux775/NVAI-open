import AVFoundation
import Foundation

/// Erzeugen im Studio, wie studio.generate unter Windows: Szenen werden Aufträge der JobQueue (dieselben wie
/// `/api/generate/*`, mit denselben Prüfungen), fertige Aufträge ihre Takes. Was die Mac-Fassung rechnet: Video mit
/// LTX-Video 2B (ohne Ton), Standbilder mit dem aktiven Bildmodell, Musik und Klang mit Stable Audio 3.
actor StudioGenerator {
    static let shared = StudioGenerator()
    static let pollNanoseconds: UInt64 = 2_000_000_000
    /// Anschluss-Szenen, die auf ihre Vorlage warten: Szenen-ID → Task (nur im Speicher, wie unter Windows).
    private var chainTasks: [String: Task<Void, Never>] = [:]

    // MARK: Takes nachtragen

    /// Fertige Aufträge als Takes eintragen (auch wenn Claude per REST erzeugen ließ), Fehler an die Szene.
    @discardableResult
    func refresh(_ store: StudioStore, _ pid: String) async throws -> StudioProject {
        let before = try await store.load(pid)
        var jobs: [String: JobRecord] = [:]
        var orphans: [String: [String]] = [:]  // Aufträge, die die Schlange nicht mehr kennt (App neu gestartet)
        for s in before.scenes {
            for id in s.jobs {
                if let job = await JobQueue.shared.job(id) { jobs[id] = job } else {
                    orphans[id] = await AssetStore.shared.assets(ofJob: id).map(\.id)  // fertig gewordene: ihre Dateien
                }
            }
        }
        // Zwischen dem Lesen oben und dem Speichern unten kann generate() Aufträge und Warten eintragen: Was oben noch
        // nicht stand, bleibt unangetastet (vorher fielen so neue Aufträge weg, und Anschlüsse wurden nie abgeschickt)
        let known = Set(before.scenes.flatMap(\.jobs))
        let waitingBefore = Dictionary(before.scenes.compactMap { s in s.waitingFor.map { (s.id, $0) } },
                                       uniquingKeysWith: { a, _ in a })
        // Takes und letzte Bilder gehören in den Ordner des Projekts, auch ältere erzeugte Takes ohne Marke
        // (hochgeladenes Material, das als Take dient, bleibt wie unter Windows im Verlauf)
        let older = before.scenes.flatMap(\.takes).filter { id in
            guard let r = AssetSnapshot.shared.get(id) else { return false }
            return r.kind != "upload" && r.meta["studio_project"] == nil
        }
        let made = jobs.values.filter { $0.status == "done" }.flatMap(\.assetIDs) + orphans.values.flatMap { $0 } + older
        if !made.isEmpty { await AssetStore.shared.tag(made, project: pid) }
        // Sprecherzeilen kennen ihre Länge (meta.seconds): Die Szene wird so lang wie ihr Take (seit 0.5.3), sonst
        // schnitte Übernehmen das Satzende ab
        var speechSeconds: [String: Double] = [:]
        for id in made {
            if let r = AssetSnapshot.shared.get(id), r.meta["speech"]?.boolValue == true, let s = r.meta["seconds"]?.doubleValue {
                speechSeconds[id] = s
            }
        }
        let live = Set(chainTasks.keys)  // nach dem letzten Warten gelesen, so aktuell wie möglich
        return try await store.update(pid) { p in
            var changed = false
            for i in p.scenes.indices {
                var pending: [String] = []
                for id in p.scenes[i].jobs {
                    if let files = orphans[id] {
                        // vergessener Auftrag: Was er fertig hatte, wird Take; sonst fällt er weg
                        changed = true
                        for a in files where !p.scenes[i].takes.contains(a) { p.scenes[i].takes.append(a) }
                        if let last = files.last {
                            p.scenes[i].take = last
                            p.scenes[i].error = nil
                            if p.scenes[i].lane == "voice", let secs = speechSeconds[last] {
                                p.scenes[i].duration = Swift.max(p.frameTicks, Studio.ticks(secs))
                            }
                        }
                        continue
                    }
                    guard let job = jobs[id] else {
                        if !known.contains(id) { pending.append(id) }  // gerade erst abgeschickt: bleibt
                        continue
                    }
                    if job.status == "queued" || job.status == "running" {
                        pending.append(id)
                        continue
                    }
                    changed = true
                    if job.status == "done" {
                        for a in job.assetIDs where !p.scenes[i].takes.contains(a) { p.scenes[i].takes.append(a) }
                        if let last = job.assetIDs.last {
                            p.scenes[i].take = last
                            p.scenes[i].error = nil
                            if p.scenes[i].lane == "voice", let secs = speechSeconds[last] {
                                p.scenes[i].duration = Swift.max(p.frameTicks, Studio.ticks(secs))
                            }
                        }
                    } else if job.status == "error" {
                        p.scenes[i].error = job.error
                    }
                }
                if pending != p.scenes[i].jobs {
                    p.scenes[i].jobs = pending
                    changed = true
                }
                // Nur ausdrücklich gelöschte Takes fallen weg (siehe AssetSnapshot.wasDeleted); vorher leerte ein noch
                // nicht geladener oder gewechselter Verlauf alle Takes eines Projekts
                let alive = p.scenes[i].takes.filter { !AssetSnapshot.shared.wasDeleted($0) }
                if alive != p.scenes[i].takes {
                    p.scenes[i].takes = alive
                    if let take = p.scenes[i].take, !alive.contains(take) { p.scenes[i].take = alive.last }
                    changed = true
                }
                // Wartende Anschluss-Szene ohne lebenden Task (App neu gestartet): wieder freigeben, aber nur, wenn sie
                // schon beim Lesen oben wartete (generate() trägt das Warten ein, während dies hier läuft)
                if let w = p.scenes[i].waitingFor, waitingBefore[p.scenes[i].id] == w, !live.contains(p.scenes[i].id) {
                    p.scenes[i].waitingFor = nil
                    changed = true
                }
            }
            return changed
        }
    }

    // MARK: Erzeugen

    private static let kindOrder = ["audio": 0, "speech": 0, "image": 1, "video": 2]

    private static func jobKind(_ s: StudioScene) -> String {
        s.lane == "voice" ? "speech" : s.lane != "video" ? "audio" : (s.kind == "image" ? "image" : "video")
    }

    private static func busy(_ s: StudioScene) -> Bool { !s.jobs.isEmpty || s.waitingFor != nil }

    /// Das Projekt mit den Anschlüssen aus Markern (nur abgeleitet, nicht gespeichert).
    private static func resolvingChains(_ p: StudioProject) -> StudioProject {
        var p = p
        for (id, chain) in StudioCommands.resolvedChains(p) {
            if let i = p.scenes.firstIndex(where: { $0.id == id }) { p.scenes[i].chainFrom = chain.from }
        }
        return p
    }

    /// Aufträge für die Szenen abschicken (alle ohne Take, wenn keine genannt sind). Fehler je Szene, kein Abbruch.
    /// Eine Szene, deren Vorlage gerade erst entsteht (Anschluss, Stimme einer anderen Sprecher-Szene, auch über ihre
    /// Figur), wartet darauf und wird danach abgeschickt.
    func generate(_ store: StudioStore, _ pid: String, sceneIDs: [String]? = nil) async throws -> JSONValue {
        let env = store.env
        let p = Self.resolvingChains(try await refresh(store, pid))
        var wanted = p.scenes.filter { s in
            s.waitingFor == nil && (sceneIDs.map { $0.contains(s.id) } ?? (s.take == nil && s.jobs.isEmpty))
        }
        // Reihenfolge in der Schlange: Ton und Bilder zuerst (kurz, schnelle Rückmeldung), dann die Videos, Anschluss-
        // Szenen zuletzt: so folgt ein Anschluss direkt auf seine Vorlage, ohne dass LTX-Video entladen wird.
        func waits(_ s: StudioScene) -> Int { StudioCommands.dependencies(p, s, env).isEmpty ? 0 : 1 }
        wanted.sort { a, b in
            (waits(a), Self.kindOrder[Self.jobKind(a)] ?? 9, a.start) < (waits(b), Self.kindOrder[Self.jobKind(b)] ?? 9, b.start)
        }
        let byID = Dictionary(p.scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var submitted: [String: String] = [:], waiting: [String: String] = [:], errors: [String: String] = [:]
        for s in wanted {
            // Auf die erste Vorlage warten, die gerade entsteht
            if let source = StudioCommands.dependencies(p, s, env).compactMap({ byID[$0] }).first(where: { d in
                submitted[d.id] != nil || waiting[d.id] != nil || Self.busy(d)
            }) {
                waiting[s.id] = source.id
                continue
            }
            do {
                submitted[s.id] = try await Self.submit(p, s, env).id
            } catch {
                errors[s.id] = error.localizedDescription
            }
        }
        // Anschluss-Tasks vor dem Speichern anmelden (sie warten erst 2 s): Ein gleichzeitiges refresh() sieht sie
        // so schon als lebend und gibt das Warten nicht frei
        for (id, source) in waiting {
            chainTasks[id] = Task { await self.chainLater(store, pid, sceneID: id, sourceID: source) }
        }
        do {
            _ = try await store.update(pid) { q in
                for i in q.scenes.indices {
                    let id = q.scenes[i].id
                    if let job = submitted[id] {
                        q.scenes[i].jobs.append(job)
                        q.scenes[i].error = nil
                    } else if let source = waiting[id] {
                        q.scenes[i].waitingFor = source
                        q.scenes[i].error = nil
                    } else if let error = errors[id] {
                        q.scenes[i].error = error
                    }
                }
                return true
            }
        } catch {
            for id in waiting.keys {
                chainTasks[id]?.cancel()
                chainTasks[id] = nil
            }
            throw error
        }
        return .object(["jobs": .object(submitted.mapValues(JSONValue.string)),
                        "waiting": .object(waiting.mapValues(JSONValue.string)),
                        "errors": .object(errors.mapValues(JSONValue.string))])
    }

    // MARK: Abbrechen

    /// Erzeugen abbrechen wie studio.cancel unter Windows (Nutzer 31.10.2026: „neben dem Übernehmen den Fortschritt
    /// anzeigen und dort kann ich es auch abbrechen“): alle wartenden und laufenden Aufträge der Szenen, dazu die
    /// Anschluss-Szenen, die noch auf ihre Vorlage warten. Fertige Takes bleiben. Ein laufendes Video endet nach dem
    /// aktuellen Rechenschritt; bis dahin bleibt die Szene „wird erzeugt“.
    func cancel(_ store: StudioStore, _ pid: String) async throws -> JSONValue {
        let p = try await refresh(store, pid)
        var cancelled: [String] = []
        for id in p.scenes.flatMap(\.jobs) {
            guard let job = await JobQueue.shared.job(id), job.status == "queued" || job.status == "running" else { continue }
            if (try? await JobQueue.shared.cancel(id)) != nil { cancelled.append(id) }
        }
        let waiting = p.scenes.filter { $0.waitingFor != nil }.map(\.id)
        for id in waiting {
            chainTasks[id]?.cancel()
            chainTasks[id] = nil
        }
        if !waiting.isEmpty {
            _ = try await store.update(pid) { q in
                var changed = false
                for i in q.scenes.indices where q.scenes[i].waitingFor != nil {
                    q.scenes[i].waitingFor = nil
                    changed = true
                }
                return changed
            }
        }
        _ = try await refresh(store, pid)
        return .object(["cancelled": .array(cancelled.map(JSONValue.string))])
    }

    /// Wartet, bis die Vorlage einer Szene fertig ist, und schickt dann deren Auftrag ab. Hat die Szene zwei Vorlagen
    /// (Anschluss und Satz für die Lippen, wie unter Windows seit 0.5.24), wartet sie danach auf die zweite. Endet
    /// still, wenn Szene oder Projekt gelöscht oder umgestellt wurden.
    private func chainLater(_ store: StudioStore, _ pid: String, sceneID: String, sourceID: String) async {
        defer { chainTasks[sceneID] = nil }
        let env = store.env
        var sourceID = sourceID
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            guard let fresh = try? await refresh(store, pid) else { return }
            var p = Self.resolvingChains(fresh)
            guard let i = p.scenes.firstIndex(where: { $0.id == sceneID }), p.scenes[i].waitingFor == sourceID else { return }
            let byID = Dictionary(p.scenes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let source = byID[sourceID]
            if let source, Self.busy(source) { continue }
            let audioSource = p.scenes[i].params["audio_from"]?.stringValue
            var jobID: String?
            var failure: String?
            var nextID: String?
            if let source, source.error == nil, source.take != nil {
                nextID = StudioCommands.dependencies(p, p.scenes[i], env).first { d in
                    d != sourceID && byID[d].map(Self.busy) == true
                }
                if nextID == nil {
                    // auch wenn der Anschluss nur aus einem Marker kam; nicht für den Satz, dessen Ton das Video nimmt
                    if p.scenes[i].lane == "video" && sourceID != audioSource { p.scenes[i].chainFrom = sourceID }
                    do { jobID = try await Self.submit(p, p.scenes[i], env).id } catch { failure = error.localizedDescription }
                }
            } else {
                failure = p.scenes[i].lane == "voice"
                    ? t("Die Szene, deren Stimme diese übernimmt, ist fehlgeschlagen.", "The scene whose voice this one takes over failed.")
                    : sourceID == audioSource
                    ? t("Die Sprecher-Szene, deren Satz diese Szene spricht, ist fehlgeschlagen.",
                        "The narrator scene whose line this scene speaks failed.")
                    : t("Die Szene, an die diese anschließt, ist fehlgeschlagen.", "The scene this one continues from failed.")
            }
            let next = nextID
            _ = try? await store.update(pid) { q in
                guard let k = q.scenes.firstIndex(where: { $0.id == sceneID }) else { return false }
                if let next {
                    q.scenes[k].waitingFor = next  // die zweite Vorlage entsteht noch: auf sie weiterwarten
                    return true
                }
                q.scenes[k].waitingFor = nil
                if let jobID {
                    q.scenes[k].jobs.append(jobID)
                    q.scenes[k].error = nil
                } else {
                    q.scenes[k].error = failure
                }
                return true
            }
            if let next {
                sourceID = next
                continue
            }
            return
        }
    }

    // MARK: Szene → Auftrag

    /// Die Anfrage, wie sie auch `/api/generate/*` bekäme (dieselbe Prüfung), und gleich abgeschickt.
    static func submit(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment) async throws -> JobRecord {
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StudioError(t("Die Szene hat noch keinen Prompt.", "The scene has no prompt yet.")) }
        let secs = Studio.seconds(s.duration)
        if s.lane == "voice" {
            // Sprecher-Szene (seit 0.5.3): Der Prompt ist der Text; die Stimme aus params.voice, params.voice_from (der
            // gewählte Take einer anderen Sprecher-Szene mit seinem Text) oder params.voice_asset_id (+ voice_text).
            // Mit params.character (seit 0.5.5) die Stimme der Figur statt der eigenen Angaben.
            let voice = StudioCommands.voiceSettings(p, s)
            var body: [String: JSONValue] = ["text": .string(prompt), "model_id": .string(SpeechCatalog.id)]
            for key in ["voice", "voice_asset_id", "voice_text", "language"] {
                if let v = voice[key], !v.isNull, v.stringValue != "" { body[key] = v }
            }
            if let seed = s.params["seed"] { body["seed"] = seed }
            if let from = voice["voice_from"]?.stringValue, !from.isEmpty {
                guard let source = p.scenes.first(where: { $0.id == from }), source.lane == "voice", source.id != s.id else {
                    throw StudioError(t("„Gleiche Stimme wie“ braucht eine andere Sprecher-Szene.",
                                        "“Same voice as” needs another narrator scene."))
                }
                guard let take = source.take else {
                    throw StudioError(t("Die Szene, deren Stimme diese übernimmt, hat noch keinen Take.",
                                        "The scene whose voice this one takes over has no take yet."))
                }
                body["voice_asset_id"] = .string(take)
                // Wortgenau nur, wenn die Vorlage selbst gesprochen wurde (meta.text); sonst der Text, den ihre Szene
                // dafür nennt, oder nur der Stimmklang
                let meta = AssetSnapshot.shared.get(take)?.meta ?? [:]
                let spoken = meta["speech"]?.boolValue == true ? meta["text"]?.stringValue : nil
                body["voice_text"] = .string(spoken ?? source.params["voice_text"]?.stringValue ?? "")
            }
            return await JobQueue.shared.submitSpeech(try SpeechJobRequest.parse(.object(body)))
        }
        if s.lane == "music" || s.lane == "sfx" {
            var body: [String: JSONValue] = ["prompt": .string(prompt), "model_id": .string(AudioCatalog.id),
                                             "seconds": .double((min(secs, AudioCatalog.maxSeconds) * 100).rounded() / 100)]
            for key in ["seed", "steps", "cfg"] { if let v = s.params[key] { body[key] = v } }
            return await JobQueue.shared.submitAudio(try AudioJobRequest.parse(.object(body)))
        }
        if s.kind == "image" {
            let model = Models.find(s.modelID) != nil ? s.modelID! : Models.active.id
            // Figuren im Bild (seit 0.5.5): ihre geladenen LoRAs, die zum Modell passen (auf dem Mac nur FLUX.2 Klein),
            // und ihre Trigger-Wörter vorn im Prompt; eigene LoRAs der Szene gehen vor
            let look = StudioCommands.characterLook(p, s, modelID: model, env)
            var body: [String: JSONValue] = ["prompt": .string(look.prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                                             "model_id": .string(model)]
            let size = imageSize(p, s.params)
            body["width"] = .int(size.width)
            body["height"] = .int(size.height)
            for key in ["seed", "steps", "cfg", "negative_prompt", "reference_asset_ids"] {
                if let v = s.params[key] { body[key] = v }
            }
            if !look.loras.isEmpty { body["loras"] = .array(look.loras) }
            return await JobQueue.shared.submit(try ImageJobRequest.parse(.object(body)))
        }
        // Video: das Modell der Szene, wenn geladen, sonst das aktive (2B oder 13B), 24 fps, Bilder 8n+1 aus der Länge;
        // Format im Seitenverhältnis des Projekts, so groß, wie der Speicher dieses Macs es für die Länge zulässt.
        let video = s.modelID.flatMap(VideoCatalog.model).flatMap { $0.installed ? $0 : nil } ?? VideoCatalog.active
        let fps = VideoCatalog.fps
        let frames = min(257, max(9, Int((secs * Double(fps) / 8).rounded(.toNearestOrEven)) * 8 + 1))
        guard let size = videoSize(p, frames: frames, maxVoxels: video.maxVoxels, step: video.sizeStep) else {
            throw StudioError(t("Die Szene ist für diesen Mac zu lang (\(frames) Bilder). Kürzer machen oder in zwei Szenen teilen.",
                                "The scene is too long for this Mac (\(frames) frames). Shorten it or split it into two scenes."))
        }
        // Figuren im Bild: LoRAs nur, wenn sie zum Videomodell passen (LTX-Video auf dem Mac nimmt keine), sonst bleibt
        // der Prompt, wie er ist
        let look = StudioCommands.characterLook(p, s, modelID: video.id, env)
        var body: [String: JSONValue] = ["prompt": .string(look.prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                                         "model_id": .string(video.id),
                                         "width": .int(size.width), "height": .int(size.height),
                                         "frames": .int(frames), "fps": .int(fps)]
        // Was nur LTX-2.5 unter Windows kann (Endbild, Schleife …), lässt parse mit einer Meldung scheitern; die
        // Qualitätsstufe setzt das Windows-Studio selbst, hier gibt es nur eine. Figuren und „Ton aus“ sind Angaben
        // der Szene, keine des Auftrags.
        let own = ["quality", "width", "height", "frames", "fps", "model_id", "loras", "characters", "character", "audio_from"]
        for (key, v) in s.params where !own.contains(key) {
            body[key] = v
        }
        if !look.loras.isEmpty { body["loras"] = .array(look.loras) }
        // „Ton aus Sprecher-Szene“: nur ein Videomodell, das einen Ton nimmt (unter Windows LTX-2.5), spricht den Satz
        // mit den Lippen. Auf dem Mac kann das keins; die Angabe bleibt im Projekt, und Übernehmen legt den Satz normal.
        if env.takesAudio(s.modelID), let from = s.params["audio_from"]?.stringValue, !from.isEmpty {
            guard let source = p.scenes.first(where: { $0.id == from }), source.lane == "voice" else {
                throw StudioError(t("„Ton aus“ braucht eine Sprecher-Szene.", "“Sound from” needs a narrator scene."))
            }
            guard let take = source.take else {
                throw StudioError(t("Die Sprecher-Szene für den Ton hat noch keinen Take: sie zuerst erzeugen.",
                                    "The narrator scene for the sound has no take yet: generate it first."))
            }
            body["audio_asset_id"] = .string(take)
        }
        if let from = s.chainFrom, let source = p.scenes.first(where: { $0.id == from }) {
            guard let take = source.take else {
                throw StudioError(t("Für den Anschluss braucht die vorherige Szene erst ein Video.",
                                    "For the chain, the previous scene needs a video first."))
            }
            body["image_asset_id"] = .string(try await lastFrameAsset(take, title: source.title))
        }
        return await JobQueue.shared.submitVideo(try VideoJobRequest.parse(.object(body)))
    }

    /// Standbild: etwa 1 MP im Seitenverhältnis des Projekts (1360 × 768 bei 16:9), Kanten Vielfache von 16.
    static func imageSize(_ p: StudioProject, _ params: [String: JSONValue]) -> (width: Int, height: Int) {
        if let w = params["width"]?.intValue, let h = params["height"]?.intValue { return (w, h) }
        let aspect = Double(p.settings.width) / Double(p.settings.height)
        let area = Double(min(1_048_576, ZImageCatalog.maxPixels))
        let w = max(256, min(2048, Int((sqrt(area * aspect) / 16).rounded(.down)) * 16))
        let h = max(256, min(2048, Int((area / Double(w) / 16).rounded(.down)) * 16))
        return (w, h)
    }

    /// Videoformat im Seitenverhältnis des Projekts: die größte Breite (Vielfache von 32, bis 1280), bei der Fläche ×
    /// Bilder in den Speicher dieses Macs passt (8 GB: 768 × 512 × 97, gemessen). nil, wenn auch 256 px zu groß ist.
    static func videoSize(_ p: StudioProject, frames: Int, maxVoxels: Int = VideoJobRequest.maxVoxels,
                          step: Int = 32) -> (width: Int, height: Int)? {
        let aspect = Double(p.settings.width) / Double(p.settings.height)
        for w in stride(from: 1280, through: 256, by: -step) {
            let h = Int((Double(w) / aspect / Double(step)).rounded()) * step
            guard (256...1280).contains(h) else { continue }
            if w * h * frames <= maxVoxels { return (w, h) }
        }
        return nil
    }

    /// Letztes Bild eines Videos als Upload-Asset (Startbild für den Anschluss), beschriftet wie unter Windows.
    static func lastFrameAsset(_ assetID: String, title: String) async throws -> String {
        guard let record = AssetSnapshot.shared.get(assetID) else {
            throw StudioError(t("Unbekanntes Asset: \(assetID)", "Unknown asset: \(assetID)"), notFound: true)
        }
        let asset = AVURLAsset(url: AssetStore.shared.fileURL(record.filename))
        let duration = try await asset.load(.duration)
        let fps = Double((try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 24)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // eine halbe Bilddauer vor dem Ende: genau das letzte Bild
        let time = CMTimeSubtract(duration, CMTime(seconds: 0.5 / max(1, fps), preferredTimescale: 600_000))
        let png: Data
        do {
            png = try ImageFiles.pngData(try await generator.image(at: time).image)
        } catch {
            throw StudioError(t("Letztes Bild nicht lesbar.", "Cannot read the last frame."))
        }
        let label = title.isEmpty ? t("Letztes Bild", "Last frame") : t("Letztes Bild von „\(title)“", "Last frame of \"\(title)\"")
        var meta: [String: JSONValue] = ["studio_last_frame_of": .string(assetID)]
        if let project = record.meta["studio_project"] { meta["studio_project"] = project }
        return try await AssetStore.shared.addStudioImage(png: png, label: label, meta: meta).id
    }
}
