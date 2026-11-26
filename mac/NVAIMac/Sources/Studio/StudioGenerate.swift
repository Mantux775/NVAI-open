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
    /// Kennung je Anschluss-Task (seit 0.5.9): Ein abgebrochener alter Task räumt beim Enden nur seinen eigenen Eintrag
    /// ab, nicht den eines gleich danach neu gestarteten (sonst gab refresh() dessen Warten frei, die Szene blieb leer).
    private var chainTokens: [String: UUID] = [:]

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
        // Auch genannte Szenen nur ohne laufenden Auftrag (wie unter Windows seit 0.5.31): Rechtsklick „Erzeugen“ auf eine
        // Auswahl (gesperrt nur für die angeklickte Szene) und scene_ids per REST oder MCP schickten laufende Szenen doppelt
        var wanted = p.scenes.filter { s in
            s.waitingFor == nil && s.jobs.isEmpty && (sceneIDs.map { $0.contains(s.id) } ?? (s.take == nil))
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
            let token = UUID()
            chainTokens[id] = token
            chainTasks[id] = Task { await self.chainLater(store, pid, sceneID: id, sourceID: source, token: token) }
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
                chainTokens[id] = nil
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
            chainTokens[id] = nil
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
    private func chainLater(_ store: StudioStore, _ pid: String, sceneID: String, sourceID: String, token: UUID) async {
        defer {
            if chainTokens[sceneID] == token {
                chainTasks[sceneID] = nil
                chainTokens[sceneID] = nil
            }
        }
        let env = store.env
        var sourceID = sourceID
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            // Abbrechen während des Wartens: nicht mehr abschicken (sleep wirft, try? schluckt es)
            guard !Task.isCancelled else { return }
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
                    guard !Task.isCancelled else { return }
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
        let (kind, body) = try await request(p, s, env)
        switch kind {
        case "tts": return await JobQueue.shared.submitSpeech(try SpeechJobRequest.parse(.object(body)))
        case "txt2audio": return await JobQueue.shared.submitAudio(try AudioJobRequest.parse(.object(body)))
        case "txt2img": return await JobQueue.shared.submit(try ImageJobRequest.parse(.object(body)))
        default: return await JobQueue.shared.submitVideo(try VideoJobRequest.parse(.object(body)))
        }
    }

    /// Angaben einer Szene, die nur das Studio liest und nie in einen Auftrag gehören: der gewählte Weg, ein bestätigter
    /// Take und „So lassen“ einer veralteten Anschluss-Szene (seit Mac 1.0, Konzept „NVAI im Fluss“)
    static let flowParams: Set<String> = ["way", "take_ok", "chain_keep"]

    /// Art und Körper des Auftrags einer Szene (wie `_job_request` unter Windows), ohne ihn abzuschicken. `dry`
    /// (Schätzung, seit Mac 1.0): nichts anlegen, das letzte Bild einer Vorlage nur als vorhanden annehmen.
    static func request(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment,
                        dry: Bool = false) async throws -> (kind: String, body: [String: JSONValue]) {
        let prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StudioError(t("Die Szene hat noch keinen Prompt.", "The scene has no prompt yet.")) }
        let secs = Studio.seconds(s.duration)
        // Zu welchem Projekt der Auftrag gehört (wie studio_project unter Windows): Auftragsleiste und Hinweise
        let project: JSONValue = .string(p.id)
        if s.lane == "voice" {
            // Sprecher-Szene (seit 0.5.3): Der Prompt ist der Text; die Stimme aus params.voice, params.voice_from (der
            // gewählte Take einer anderen Sprecher-Szene mit seinem Text) oder params.voice_asset_id (+ voice_text).
            // Mit params.character (seit 0.5.5) die Stimme der Figur statt der eigenen Angaben.
            let voice = StudioCommands.voiceSettings(p, s)
            var body: [String: JSONValue] = ["text": .string(prompt), "model_id": .string(SpeechCatalog.id),
                                             "studio_project": project]
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
            return ("tts", body)
        }
        if s.lane == "music" || s.lane == "sfx" {
            var body: [String: JSONValue] = ["prompt": .string(prompt), "model_id": .string(AudioCatalog.id),
                                             "seconds": .double((min(secs, AudioCatalog.maxSeconds) * 100).rounded() / 100),
                                             "studio_project": project]
            for key in ["seed", "steps", "cfg"] { if let v = s.params[key] { body[key] = v } }
            return ("txt2audio", body)
        }
        if s.kind == "image" {
            let model = Models.find(s.modelID) != nil ? s.modelID! : Models.active.id
            // Figuren im Bild (seit 0.5.5): ihre geladenen LoRAs, die zum Modell passen (auf dem Mac nur FLUX.2 Klein),
            // und ihre Trigger-Wörter vorn im Prompt; eigene LoRAs der Szene gehen vor
            let look = StudioCommands.characterLook(p, s, modelID: model, env)
            var body: [String: JSONValue] = ["prompt": .string(look.prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                                             "model_id": .string(model), "studio_project": project]
            let size = imageSize(p, s.params)
            body["width"] = .int(size.width)
            body["height"] = .int(size.height)
            for key in ["seed", "steps", "cfg", "negative_prompt", "reference_asset_ids"] {
                if let v = s.params[key] { body[key] = v }
            }
            if !look.loras.isEmpty { body["loras"] = .array(look.loras) }
            return ("txt2img", body)
        }
        // Video: das Modell der Szene, wenn geladen, sonst das aktive (2B oder 13B), 24 fps, Bilder 8n+1 aus der Länge;
        // Format im Seitenverhältnis des Projekts, so groß, wie der Speicher dieses Macs es für die Länge zulässt.
        let video = videoModel(s)
        let fps = VideoCatalog.fps
        let frames = videoFrames(s)
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
                                         "frames": .int(frames), "fps": .int(fps), "studio_project": project]
        // Was nur LTX-2.5 unter Windows kann (Endbild, Schleife …), lässt parse mit einer Meldung scheitern; die
        // Qualitätsstufe setzt das Windows-Studio selbst, hier gibt es nur eine. Figuren und „Ton aus“ sind Angaben
        // der Szene, keine des Auftrags, ebenso Weg, bestätigter Take und „So lassen“ (flowParams).
        let own = ["quality", "width", "height", "frames", "fps", "model_id", "loras", "characters", "character", "audio_from",
                   "studio_project"]
        for (key, v) in s.params where !own.contains(key) && !flowParams.contains(key) {
            body[key] = v
        }
        // „Nur Text“: ein Startbild, das von früher in den Angaben steht, gilt nicht (der Weg entscheidet)
        if s.params["way"]?.stringValue == "text" { body["image_asset_id"] = nil }
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
            body["image_asset_id"] = .string(dry ? take : try await lastFrameAsset(take, title: source.title))
        }
        return ("txt2video", body)
    }

    // MARK: Veraltet und Anschluss (seit Mac 1.0, wie scene_stale und scene_carry unter Windows 0.5.42)

    /// Von welchem Take seiner Vorlage ein Anschluss-Take ausging: Sein Startbild ist das letzte Bild dieses Takes
    /// (`meta.image_asset_id`, dort `meta.studio_last_frame_of`). nil, wenn es sich nicht sagen lässt (eingefügter Take,
    /// Take von vor dem Anschluss). Eine Latent-Kette wie unter Windows gibt es auf dem Mac nicht.
    static func chainSource(_ takeID: String?) -> String? {
        guard let takeID, let take = AssetSnapshot.shared.get(takeID) else { return nil }
        if let chain = take.meta["chain_asset_id"]?.stringValue { return chain }
        guard let image = take.meta["image_asset_id"]?.stringValue, let start = AssetSnapshot.shared.get(image) else { return nil }
        return start.meta["studio_last_frame_of"]?.stringValue
    }

    /// Eine Anschluss-Szene, die noch mit dem alten Ende ihrer Vorlage beginnt (Oberflächentest 26.11.2026: „Wird eine
    /// Szene neu erzeugt, behalten Anschluss-Szenen ihr altes Ende ohne Hinweis“).
    struct Stale: Sendable, Equatable {
        /// Vorlage (Szene), ihr gewählter Take, der Take, von dem diese Szene ausging
        let source: String
        let take: String
        let used: String
        /// take: neuer Take der Vorlage; scene: der Anschluss zeigt inzwischen auf eine andere Szene
        let why: String
        let reason: String

        var json: JSONValue {
            .object(["source": .string(source), "take": .string(take), "used": .string(used), "why": .string(why),
                     "reason": .string(reason)])
        }
    }

    /// Veraltet: Der Take einer Anschluss-Szene ging von einem anderen Take ihrer Vorlage aus als dem jetzt gewählten.
    /// „So lassen“ merkt sich genau dieses Paar in params.chain_keep ({take, source}); ein neuer Take auf einer der beiden
    /// Seiten zeigt den Hinweis wieder. `p` mit aufgelösten Anschluss-Markern.
    static func stale(_ p: StudioProject, _ s: StudioScene) -> Stale? {
        guard s.lane == "video", s.kind == "video", let from = s.chainFrom, let take = s.take,
              let source = p.scenes.first(where: { $0.id == from }), let now = source.take,
              let used = chainSource(take), used != now else { return nil }
        if let keep = s.params["chain_keep"]?.objectValue, keep["take"]?.stringValue == take,
           keep["source"]?.stringValue == now { return nil }
        func name(_ x: StudioScene) -> String { !x.title.isEmpty ? x.title : !x.prompt.isEmpty ? String(x.prompt.prefix(40)) : x.id }
        // Der alte Take gehört einer anderen Szene: Der Anschluss wurde umgestellt (eine eingefügte Kopie teilt die Takes
        // ihrer Vorlage, deshalb zählt die eigene Vorlage zuerst)
        let other = source.takes.contains(used) ? nil : p.scenes.first { $0.id != source.id && $0.takes.contains(used) }
        let reason = other.map {
            t("Diese Szene schließt jetzt an „\(name(source))“ an, beginnt aber noch mit dem Ende von „\(name($0))“.",
              "This scene now continues “\(name(source))” but still begins with the end of “\(name($0))”.")
        } ?? t("„\(name(source))“ hat einen neuen Take. Diese Szene schließt daran an und beginnt noch mit dem alten Ende.",
               "“\(name(source))” has a new take. This scene continues from it and still begins with the old ending.")
        return Stale(source: source.id, take: now, used: used, why: other == nil ? "take" : "scene", reason: reason)
    }

    /// Szene, deren Ende der gewählte Take einer Videoszene fortsetzt, auch wenn der Anschluss aus einem Marker kam;
    /// sonst nil. Liegt die Szene nach dem Umordnen nicht mehr direkt dahinter, warnt die Oberfläche („Anschluss getrennt“).
    static func carry(_ p: StudioProject, _ s: StudioScene) -> String? {
        guard s.lane == "video", s.kind == "video", let used = chainSource(s.take) else { return nil }
        if let own = p.scenes.first(where: { $0.id == s.chainFrom && $0.takes.contains(used) }) { return own.id }
        return p.scenes.first { $0.id != s.id && $0.takes.contains(used) }?.id
    }

    /// Das Projekt mit den Anschlüssen aus Markern (nur abgeleitet), für Ansichten und Schätzung
    static func withChains(_ p: StudioProject) -> StudioProject { resolvingChains(p) }

    // MARK: Schätzen (seit Mac 1.0)

    /// Geschätzte Rechenzeit je Szene aus derselben Anfrage wie beim Erzeugen (`request(dry:)`), nur gelesen. Ohne
    /// `sceneIDs` alle Szenen ohne Take. Szenen, deren Anfrage noch nicht geht (kein Prompt, Vorlage fehlt), bekommen
    /// `error` statt einer Zeit. Antwortform wie `estimate_scenes` unter Windows.
    static func estimateScenes(_ p: StudioProject, _ sceneIDs: [String]?, _ env: StudioEnvironment) async -> [String: JobEstimate] {
        let p = resolvingChains(p)
        var out: [String: JobEstimate] = [:]
        for s in p.scenes where sceneIDs.map({ $0.contains(s.id) }) ?? (s.take == nil) {
            do {
                let (kind, body) = try await request(p, s, env, dry: true)
                var e = await Estimate.one(kind: kind, params: .object(body))
                e.kind = kind
                out[s.id] = e
            } catch {
                var e = JobEstimate.unknown
                e.error = error.localizedDescription
                out[s.id] = e
            }
        }
        return out
    }

    /// Das Videomodell einer Szene: ihr eigenes, wenn es geladen ist, sonst das aktive.
    static func videoModel(_ s: StudioScene) -> VideoModel {
        s.modelID.flatMap(VideoCatalog.model).flatMap { $0.installed ? $0 : nil } ?? VideoCatalog.active
    }

    /// Bilder eines Videoclips aus der Länge der Szene: 8n + 1 bei 24 fps, 9 bis 257. Aufrunden wie unter Windows seit
    /// 0.5.26 (seit 0.5.9 auch hier): Gerundet blieben bei Längen neben dem Raster bis zu 3 Bilder am Szenenende schwarz
    /// (5,5 s: 129 statt 137 Bilder); 4 s bleibt 97
    static func videoFrames(_ s: StudioScene) -> Int {
        min(257, max(9, Int((Studio.seconds(s.duration) * Double(VideoCatalog.fps) / 8 - 1e-6).rounded(.up)) * 8 + 1))
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
        // Standbild-Szene (seit 0.5.9): Das Bild selbst ist ihr letztes Bild. AVFoundation öffnet kein PNG, der Anschluss
        // an eine Bildszene scheiterte deshalb; unter Windows liest PyAV ein PNG als ein Bild.
        if !AssetStore.mediaSuffixes.contains((record.filename as NSString).pathExtension.lowercased()) { return assetID }
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

    // MARK: Hinweise je Szene

    /// Nicht englisch, wie NON_EN unter Windows (studio.py, Wizard.tsx): Umlaute oder häufige deutsche Wörter.
    static let nonEnglish = #"[äöüßÄÖÜ]|\b(der|das|und|ein|eine|einen|eines|einem|einer|mit|auf|bei|vom|zum|zur|dem|des|ist|sind|nicht|sich|unter|hinter|nach|aus|wird|steht|geht|zieht|hebt|langsam|seine|ihre|alten|alte|kleine|kleiner|große|großen|hellem|dunklen)\b"#

    /// Was der Assistent von selbst richtig setzt und bei Szenen von Hand leicht fehlt (seit Mac 0.5.11, wie _hints
    /// unter Windows seit 0.5.30); die Eigenschaften zeigen sie unter dem Fehler der Szene. Statt der zwei Hinweise zur
    /// Grafikkarte nennt der Mac das Format, auf das sein Speicher die Szene bei dieser Länge setzt; den Hinweis zum
    /// Sprechersatz gibt es nur bei einem Videomodell mit eigenem Ton.
    static func hints(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment) -> [String] {
        var out: [String] = []
        guard s.lane != "voice" else { return out }  // der Text eines Sprechersatzes bleibt in seiner Sprache
        let text = s.prompt
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           text.range(of: nonEnglish, options: [.regularExpression, .caseInsensitive]) != nil {
            // Musik und Klang: Zum Ausbauen gibt es auf dem Mac dafür kein Ziel, nur das Übertragen ins Englische
            out.append(s.lane == "video"
                ? t("Der Prompt ist nicht englisch. Die Modelle verstehen ganze englische Sätze am besten: „Prompt ausbauen“ übersetzt und ergänzt ihn.",
                    "The prompt is not in English. The models understand whole English sentences best: “Expand prompt” translates and completes it.")
                : t("Der Prompt ist nicht englisch. Die Modelle verstehen ganze englische Sätze am besten: „Ins Englische übertragen“ übersetzt ihn.",
                    "The prompt is not in English. The models understand whole English sentences best: “Translate into English” translates it."))
        }
        guard s.lane == "video", s.kind == "video" else { return out }
        let video = videoModel(s)
        let frames = videoFrames(s)
        if let size = videoSize(p, frames: frames, maxVoxels: video.maxVoxels, step: video.sizeStep) {
            // nur, wenn die Länge Bildpunkte kostet: kleiner als das Projekt und kleiner als beim kürzesten Clip (9 Bilder)
            let pixels = size.width * size.height
            if let most = videoSize(p, frames: 9, maxVoxels: video.maxVoxels, step: video.sizeStep),
               pixels < most.width * most.height, pixels < p.settings.width * p.settings.height {
                out.append(t("Bei dieser Länge rechnet dieser Mac in \(size.width) × \(size.height) (Speicher). Kürzere Szenen bekommen mehr Bildpunkte.",
                             "At this length this Mac renders in \(size.width) × \(size.height) (memory). Shorter scenes get more pixels."))
            }
        } else {
            out.append(t("Die Szene ist für diesen Mac zu lang (\(frames) Bilder). Kürzer machen oder in zwei Szenen teilen.",
                         "The scene is too long for this Mac (\(frames) frames). Shorten it or split it into two scenes."))
        }
        let chained = !(s.chainFrom ?? "").isEmpty || StudioCommands.resolvedChains(p)[s.id] != nil
        if s.params.truthy("characters"), !s.params.truthy("image_asset_id"), !chained {
            out.append(t("Figur ohne Startbild: Das Videomodell erfindet dann ein Gesicht. „Startbild erzeugen“ oder ein Bild aus dem Material auf „Startbild“ ziehen.",
                         "Character without a start image: the video model then invents a face. Use “Generate start image” or drag a picture from the media onto “Start image”."))
        }
        // „Ton aus Sprecher-Szene“ hilft nur, wenn das Videomodell einen Ton nimmt (auf dem Mac keins); sonst spricht
        // ein Videomodell mit eigenem Ton womöglich über den Satz
        let lips = env.takesAudio(s.modelID) && s.params.truthy("audio_from")
        if video.hasAudio, !lips, !text.lowercased().contains("no speech"),
           p.scenes.contains(where: { $0.lane == "voice" && $0.start < s.end && $0.end > s.start }) {
            out.append(t("Unter dieser Szene liegt ein Sprechersatz, und das Videomodell macht eigenen Ton, auch Stimmen. Für Erzählung „Quiet ambient sound, no speech.“ in den Prompt schreiben.",
                         "A spoken line lies under this scene, and the video model makes its own sound, voices included. For narration add “Quiet ambient sound, no speech.” to the prompt."))
        }
        return out
    }

    // MARK: Startbild erzeugen

    /// Der Satz gegen schwarze Balken aus den Startbildern des Assistenten (Windows: FULL_FRAME).
    static let fullFrame = "The picture fills the whole frame from edge to edge."
    /// Nur Wörter, die allein vom Ton sprechen (wie _SOUND_WORDS unter Windows seit 0.5.31): „heart“, „musician“, „quiet
    /// square“ oder „ambient light“ beschreiben das Bild; vorher fielen solche Sätze weg, und das Startbild hatte kein
    /// Motiv mehr
    private static let soundWords = #"\b(sounds?|sounding|audio|hears?|heard|hearing|voices?|says|said|say|speaks?|speaking|spoken|talks?|talking|tells|music|noises?|noisy|silence|loud|loudly|whisper\w*|shout\w*|sings?|singing|murmur\w*|rumbl\w*|narrator|narration|speech)\b"#

    /// Video-Prompt als Bildbeschreibung (wie _still_prompt unter Windows): ohne die Sätze über Ton, Stimmen und
    /// Gesprochenes (Anführungszeichen landen sonst als Schrift im Bild), dazu der Satz gegen schwarze Balken.
    static func stillPrompt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sätze wie re.split(r"(?<=[.!?])\s+"): getrennt am Leerraum nach . ! ?
        var sentences: [String] = []
        var current = ""
        for c in trimmed {
            if c.isWhitespace, let last = current.last, ".!?".contains(last) {
                sentences.append(current)
                current = ""
            } else if !(c.isWhitespace && current.isEmpty) {
                current.append(c)
            }
        }
        if !current.isEmpty { sentences.append(current) }
        let kept = sentences.filter { x in
            x.range(of: soundWords, options: [.regularExpression, .caseInsensitive]) == nil
                && !x.contains(where: { "\"“”„".contains($0) })
        }
        let out = kept.isEmpty ? trimmed : kept.joined(separator: " ")
        return out.contains(fullFrame) ? out : out + " " + fullFrame
    }

    /// Bildmodell für ein Startbild (wie _start_image_model unter Windows): FLUX.2 Klein wie im Assistenten (die
    /// Fassung, die er für diesen Mac empfiehlt, zuerst), sonst Z-Image Turbo, jeweils nur geladen; haben die Figuren der
    /// Szene LoRAs, das Modell, zu dem die meisten passen (auf dem Mac nur FLUX.2 Klein). Sonst das aktive, wenn geladen.
    static func startImageModel(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment) -> String? {
        let ram = SystemInfo.memoryGB
        let flux = ([ModelCatalog.recommended] + ModelCatalog.all).first { ram >= $0.minRAMGB && ModelCatalog.status($0).installed }
        let zimage = ZImageCatalog.all.first { ram >= $0.minRAMGB && $0.installed }
        let cast = s.params["characters"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let loras = p.characters.filter { cast.contains($0.id) }.flatMap(\.loras)
            .compactMap { env.lora($0.modelID) }.filter(\.installed)
        var best: String?
        var bestFit = -1
        for id in [flux?.id, zimage?.id].compactMap({ $0 }) {
            let bases = env.loraBases(id) ?? []
            let fit = loras.filter { bases.contains($0.family) }.count
            if fit > bestFit {
                best = id
                bestFit = fit
            }
            if fit == loras.count { break }  // ohne LoRAs: das erste geladene
        }
        if let best { return best }
        let active = Models.active
        return active.installed ? active.id : nil
    }

    /// Format wie die Startbilder des Assistenten: 1024 Bildpunkte an der langen Seite im Seitenverhältnis des Projekts
    /// (1024 × 576 bei 16:9, 576 × 1024 hochkant), Kanten Vielfache von 16.
    static func startImageSize(_ p: StudioProject) -> (width: Int, height: Int) {
        let w = Double(p.settings.width), h = Double(p.settings.height)
        let short = max(256, Int((1024 * min(w, h) / max(w, h) / 16).rounded()) * 16)
        return w >= h ? (1024, short) : (short, 1024)
    }

    /// „Startbild erzeugen“ (seit Mac 0.5.11, wie submit_start_image unter Windows seit 0.5.30): zwei Varianten für eine
    /// Videoszene wie die Startbilder des Assistenten, mit den Figuren der Szene (ihre LoRAs und Trigger-Wörter). Die
    /// Oberfläche legt beide in den Projektordner und setzt die erste als Startbild.
    static func submitStartImage(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment) async throws -> JobRecord {
        guard s.lane == "video", s.kind == "video" else {
            throw StudioError(t("Ein Startbild gibt es nur für Videoszenen.", "Only video scenes have a start image."))
        }
        guard !s.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError(t("Die Szene hat noch keinen Prompt.", "The scene has no prompt yet."))
        }
        return await JobQueue.shared.submit(try ImageJobRequest.parse(.object(try startImageRequest(p, s, env))))
    }

    /// Körper des Auftrags „Startbild erzeugen“ (für Schätzung und Abschicken gleich)
    static func startImageRequest(_ p: StudioProject, _ s: StudioScene, _ env: StudioEnvironment) throws -> [String: JSONValue] {
        guard let modelID = startImageModel(p, s, env) else {
            throw StudioError(t("Kein Bildmodell geladen (unter „Modelle“).", "No image model is downloaded (under \"Models\")."))
        }
        var still = s
        still.prompt = stillPrompt(s.prompt)
        still.params["loras"] = nil  // eigene LoRAs einer Videoszene gehören zum Videomodell
        let look = StudioCommands.characterLook(p, still, modelID: modelID, env)
        let size = startImageSize(p)
        var body: [String: JSONValue] = ["prompt": .string(look.prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                                         "model_id": .string(modelID), "width": .int(size.width),
                                         "height": .int(size.height), "batch_size": .int(2), "studio_project": .string(p.id),
                                         "studio_start_image": .string(s.id)]
        if !look.loras.isEmpty { body["loras"] = .array(look.loras) }
        return body
    }
}
