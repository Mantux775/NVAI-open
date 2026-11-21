import Foundation

/// „Neuer Fall“ aus einem VDR-Export (Furuno VR-7000, Ordner „VDR Data files“; seit 0.5.11), wie `cmd_import` in
/// `server/nvai/vdr.py` und das Projekt aus `audio_vdr.py`, im Format des Prüfpakets: je Toneingang eine Mono-Spur
/// (Spur-IDs v_vhf1, v_mic1 … wie unter Windows; Original 16 Bit, AAC, Wellenform, Spektrogramm, Aktivität), dazu
/// data/vdr.json, series.json, events.json, ais.json, images.json, levels.json, act_<Spur>.json und die Radar-/ECDIS-
/// Bilder unter images/<quelle>/. Gerechnet wird auf eigenen Threads: zuerst ein Durchgang über alle Blöcke (Bilder und
/// Schnittlage des Tons) neben Daten und Prüfsummen, dann je Ogg-Datei ein Dekoder für zwei Spuren.
enum VDRImport {
    typealias Progress = (Double, String) -> Void

    static func create(_ folder: URL, name: String, progress: @escaping Progress,
                       isCancelled: @escaping () -> Bool) async throws -> URL {
        let fm = FileManager.default
        let root = ForensicCases.directory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // gesperrter Arbeitsordner: Bleibt er nach einem Absturz liegen, räumt ihn der nächste Start weg
        let lock = try ForensicCases.Work(in: root)
        defer { lock.finish() }
        let work = lock.url
        do {
            try fm.createDirectory(at: work.appendingPathComponent("fall", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: work.appendingPathComponent("bearbeitung", isDirectory: true), withIntermediateDirectories: true)
            return try await build(folder, name: name, work: work, progress: progress, isCancelled: isCancelled)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Rechenaufträge auf eigenen Threads (Dienstgüte „utility“, die Oberfläche bleibt flüssig); Ende, Dauer und der erste
    /// Fehler werden gesammelt, der Auftrag fragt nur ab.
    private final class Workers: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private var done: Set<String> = []
        private var seconds: [(String, Double)] = []
        private var error: Error?

        func start(_ key: String, _ body: @escaping () throws -> Void) {
            lock.lock(); running += 1; lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                let started = Date()
                var failure: Error?
                do { try body() } catch { failure = error }
                self.lock.lock()
                self.running -= 1
                self.done.insert(key)
                self.seconds.append((key, Py.round(Date().timeIntervalSince(started), 1)))
                if let failure, self.error == nil || self.error is CancellationError { self.error = failure }
                self.lock.unlock()
            }
        }

        var busy: Bool { lock.lock(); defer { lock.unlock() }; return running > 0 }
        var firstError: Error? { lock.lock(); defer { lock.unlock() }; return error }
        func finished(_ keys: [String]) -> Bool { lock.lock(); defer { lock.unlock() }; return keys.allSatisfy(done.contains) }
        var timings: [(String, Double)] { lock.lock(); defer { lock.unlock() }; return seconds }
    }

    /// Ergebnisse der Threads (unter Sperre gesammelt)
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        subscript(key: String) -> Any? {
            get { lock.lock(); defer { lock.unlock() }; return values[key] }
            set { lock.lock(); values[key] = newValue; lock.unlock() }
        }
    }

    private static func build(_ source: URL, name: String, work: URL, progress: @escaping Progress,
                              isCancelled: @escaping () -> Bool) async throws -> URL {
        let fm = FileManager.default
        let fall = work.appendingPathComponent("fall", isDirectory: true)
        let dataDir = fall.appendingPathComponent("data", isDirectory: true)
        let imagesDir = fall.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let started = Date()
        let created = Date().timeIntervalSince1970
        let createdISO = ForensicCases.isoNow()
        let lang = Lang.current
        let L = { (de: String, en: String) in lang == .de ? de : en }

        // 1. Überblick: Blöcke, Zeiten, Kanäle, Geräte
        progress(0.005, L("liest den VDR-Export", "reading the VDR export"))
        let ins = try VDR.inspect(source)
        let ex = ins.export
        let summary = ins.summary
        let t0 = ex.t0
        let duration = Double(ex.end - t0)
        let chans = ins.config["audio"] as? [[String: Any]] ?? []
        let files = Array(Set(chans.map { $0["file"] as! String })).sorted()
        let defaultName = "VDR \(summary["start"] as? String ?? "") UTC"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let caseName = String((trimmed.isEmpty ? defaultName : trimmed).prefix(120))

        // 2. Rechnen: Durchgang (Bilder, Schnittlage) + Daten + Prüfsummen, danach Ton je Ogg-Datei
        let shared = VDRProgress()
        let workers = Workers()
        let results = Results()
        let scanParts = max(1, min(4, ex.blocks.count / 50))
        let step = (ex.blocks.count + scanParts - 1) / scanParts
        let wantedAudio = Set(files)
        var scanKeys: [String] = []
        for i in 0..<scanParts {
            let part = ex.blocks[min(ex.blocks.count, i * step)..<min(ex.blocks.count, (i + 1) * step)]
            guard !part.isEmpty else { continue }
            let key = "scan\(i)"
            scanKeys.append(key)
            shared.add(key, weight: 0.6 / Double(scanParts))
            workers.start(key) {
                // Bilder schreiben und je Block die Granule-Positionen der Tondateien (ohne zu dekodieren)
                var granules: [Int: [String: Int64?]] = [:]
                let imgs = try VDRImages.run(blocks: part, t0: t0, imagesDir: imagesDir, progress: shared, key: key,
                                             alsoRead: wantedAudio) { b, blk in
                    granules[b.id] = VDRAudio.granules(blk, wanted: wantedAudio)
                }
                results[key] = (granules, imgs)
                shared.set(key, 1)
            }
        }
        shared.add("data", weight: 0.6)
        workers.start("data") {
            results["data"] = try VDRData.run(blocks: ex.blocks, t0: t0, duration: duration, config: ins.config, dataDir: dataDir,
                                              lang: lang, progress: shared, key: "data")
        }
        shared.add("verify", weight: 0.2)
        workers.start("verify") {
            results["verify"] = try VDR.verify(ex, progress: shared, key: "verify")
        }
        for f in files { shared.add(f, weight: 2.0) }
        var offsets = JSONObject()
        var audioStarted = files.isEmpty
        while workers.busy || !audioStarted {
            if isCancelled() || Task.isCancelled { shared.cancel() }
            if let error = workers.firstError, !(error is CancellationError) { shared.cancel() }
            if !audioStarted && workers.finished(scanKeys) {
                audioStarted = true
                if !shared.cancelled {
                    var granules: [Int: [String: Int64?]] = [:]
                    for key in scanKeys {
                        if let pair = results[key] as? ([Int: [String: Int64?]], VDRImages.Result) {
                            granules.merge(pair.0) { a, _ in a }
                        }
                    }
                    offsets = VDRAudio.offsets(blocks: ex.blocks, t0: t0, granules: granules, files: files)
                    for f in files {
                        let sides = chans.filter { $0["file"] as? String == f }.map { (tid: $0["id"] as! String, side: $0["side"] as! Int) }
                        let rate = chans.first { $0["file"] as? String == f }?["rate"] as? Int ?? VDR.sampleRate
                        let offset = (offsets[f] as? JSONObject)?["offset_s"] as? Double ?? 0
                        let job = VDRAudio.Job(file: f, sides: sides, blocks: ex.blocks, t0: t0, duration: duration, sr: rate,
                                               offset: offset, fall: fall)
                        workers.start(f) { results[f] = try VDRAudio.run(job, progress: shared, key: f) }
                    }
                }
            }
            progress(0.01 + 0.93 * shared.total, L("Ton, Daten, Bilder", "audio, data, images"))
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                usleep(50_000)   // Auftrag abgebrochen: die Threads halten binnen etwa einer Sekunde an, bis dahin nicht kreiseln
            }
        }
        if let error = workers.firstError { throw error }
        if shared.cancelled || isCancelled() { throw CancellationError() }

        // 3. Ergebnisse zusammenführen
        progress(0.945, L("schreibt die Übersicht", "writing the summary"))
        var sideResults: [String: VDRAudio.SideResult] = [:]
        for f in files {
            for r in results[f] as? [VDRAudio.SideResult] ?? [] { sideResults[r.tid] = r }
        }
        let tracks = chans.compactMap { c in sideResults[c["id"] as! String].map { (c, $0) } }
        guard let dataRes = results["data"] as? VDRData.Result else { throw ForensicError(L("Daten fehlen.", "Data missing.")) }
        let integrity = results["verify"] as? JSONObject

        // Ereignisse: Daten, Lücken aus Track.txt, neu ausgerichteter Ton
        var events = dataRes.events
        for g in ex.gaps {
            let t = Double(g["t"] as! Int), secs = g["seconds"] as! Int, missing = g["missing_ids"] as! Int
            events.append(VDREvent(t: t, end: t + Double(max(0, secs)), kind: "gap",
                                   label: L("Lücke in der Aufnahme", "Gap in the recording"),
                                   detail: L("\(missing) Blöcke fehlen, \(secs) s", "\(missing) blocks missing, \(secs) s"),
                                   source: "Track.txt"))
        }
        let afterGap = Set(ex.gaps.map { $0["next"] as! Int })
        var seenPad = Set<String>()
        for (c, r) in tracks {
            let file = c["file"] as! String
            for p in r.pads.prefix(200) {
                let secs = p["seconds"] as! Double, block = p["block"] as! Int, t = p["t"] as! Double
                guard abs(secs) >= 0.5, !afterGap.contains(block), !seenPad.contains("\(file)|\(block)") else { continue }
                seenPad.insert("\(file)|\(block)")
                events.append(VDREvent(t: t, end: t + max(0.0, secs), kind: "gap", label: L("Ton neu ausgerichtet", "Audio realigned") + " (\(file))",
                                       detail: "\(p["kind"] as! String) \(secs) s, block \(block)", source: file))
            }
        }
        events = VDREvent.sorted(events)
        try ForensicJSON.data(events.map(\.json), compact: true).write(to: dataDir.appendingPathComponent("events.json"), options: .atomic)
        var eventCounts = JSONObject()
        for e in events { eventCounts.set(e.kind, (eventCounts[e.kind] as? Int ?? 0) + 1) }

        // Bilder
        var labels: [String: String] = [:]
        for x in summary["images"] as? [[String: Any]] ?? [] {
            if let id = x["id"] as? String { labels[id] = (x["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id }
        }
        let parts = scanKeys.compactMap { (results[$0] as? ([Int: [String: Int64?]], VDRImages.Result))?.1 }
        let images = VDRImages.merge(parts, labels: labels)
        try ForensicJSON.data(images.json, compact: true).write(to: dataDir.appendingPathComponent("images.json"), options: .atomic)
        var levels = JSONObject()
        for (_, r) in tracks { levels.set(r.tid, r.levels) }
        try ForensicJSON.data(JSONObject(["dt": 1.0, "unit": "dBFS", "tracks": levels]), compact: true)
            .write(to: dataDir.appendingPathComponent("levels.json"), options: .atomic)

        // Spuren wie audio_vdr._import: Name „Eingang · Position“, Gruppe VDR, Kanalangaben
        var trackList: [[String: Any]] = []
        var originals: [String: Any] = [:]
        var proxies: [String: String] = [:]
        var longest = duration
        for (i, (c, r)) in tracks.enumerated() {
            let input = c["input"] as? String ?? r.tid
            let position = c["position"] as? String ?? ""
            let equipment = c["equipment"] as? String ?? ""
            let extra = !position.isEmpty ? position : (equipment != "" && equipment != input ? equipment : "")
            let act = r.sink.activity
            trackList.append([
                "id": r.tid, "name": extra.isEmpty ? input : "\(input) · \(extra)", "kind": "original", "frames": r.frames,
                "bars": r.bars, "peak": r.peak, "offset": 0.0, "gain_db": 0.0, "mute": false, "solo": false,
                "color": ForensicCases.colors[i % ForensicCases.colors.count], "op": NSNull(), "created": created,
                "sr": c["rate"] as? Int ?? VDR.sampleRate, "group": "VDR", "sample_rate": c["rate"] as? Int ?? VDR.sampleRate,
                "channels": 1, "duration": r.duration, "analysis": r.analysis, "levels": r.rmsDB,
                "channel": ["input": input, "position": position, "category": c["category"] as? String ?? "", "equipment": equipment,
                            "vdr_channel": c["channel"] as? Int ?? 0, "file": c["file"] as? String ?? "",
                            "side": (c["side"] as? Int ?? 0) == 0 ? "L" : "R", "delay_ms": c["delay_ms"] as? Int ?? 0],
                "spec": r.sink.spec,
                "activity": ["method": "energy", "rate": ForensicFormat.actRate, "segments": act.segments.count,
                             "speech_seconds": act.speechSeconds],
            ])
            originals[r.tid] = ["file": "\(r.tid).wav", "sample_rate": c["rate"] as? Int ?? VDR.sampleRate, "channels": 1,
                                "frames": r.frames, "subtype": WavWriter.Kind.int16.subtype, "format": "wav"]
            proxies[r.tid] = "\(r.tid).m4a"
            try ForensicJSON.data(["track": r.tid, "rate": ForensicFormat.actRate, "method": "energy", "segments": act.segments,
                                   "speech_seconds": act.speechSeconds, "floor_db": act.floorDB ?? NSNull()] as [String: Any], indent: nil)
                .write(to: dataDir.appendingPathComponent("act_\(r.tid).json"), options: .atomic)
            longest = max(longest, r.duration)
        }

        // vdr.json (alles, was Windows dort ablegt)
        var timings = JSONObject()
        for (k, s) in workers.timings { timings.set(k, s) }
        timings.set("total", Py.round(Date().timeIntervalSince(started), 1))
        timings.set("workers", ProcessInfo.processInfo.activeProcessorCount)
        let vdr = JSONObject([
            "format": VDR.format, "summary": summary, "t0_utc": t0, "duration": duration,
            "blocks": ex.blocks.map { [$0.id, $0.start - t0, $0.name] as [Any] }, "integrity": integrity,
            "alignment": JSONObject(["method": "median_cut_drift", "files": offsets]), "audio": tracks.map(\.1.info),
            "data": dataRes.info, "ecdis_info": dataRes.ecdis, "events": eventCounts,
            "images": JSONObject(["sources": images.sources.map { s -> JSONObject in var x = s; x.remove("no_signal"); return x },
                                  "stats": images.stats]),
            "timings": timings,
        ])
        try ForensicJSON.data(vdr, compact: true).write(to: dataDir.appendingPathComponent("vdr.json"), options: .atomic)
        if isCancelled() { throw CancellationError() }

        // 4. Fall, Manifest, Prüf-App, Anleitung, Prüfsummen
        progress(0.95, L("schreibt den Fall", "writing the case"))
        let pid = ForensicCases.newProjectID()
        var vdrSmall: [String: Any] = [:]
        for k in ["product", "format", "folder", "layout", "track", "blocks", "first_id", "last_id", "start_utc", "end_utc", "start",
                  "end", "duration", "gap_count", "vessel", "system", "versions", "audio", "serial", "digital", "analog", "images",
                  "size_bytes"] {
            vdrSmall[k] = summary[k] ?? NSNull()
        }
        vdrSmall["events"] = eventCounts
        vdrSmall["images_count"] = images.counts
        vdrSmall["timings"] = timings
        if let integrity {
            let cl = integrity["checklist"] as? JSONObject
            vdrSmall["integrity"] = JSONObject([
                "ok": integrity["ok"], "algorithm": cl?["algorithm"], "listed": cl?["listed"], "ok_count": cl?["ok"],
                "bad_count": cl?["bad_count"], "missing_count": cl?["missing_count"],
                "checkfile_ok": (integrity["checkfile"] as? JSONObject)?["ok"], "note": integrity["note"],
                "time": Date().timeIntervalSince1970,
            ])
        }
        let sourceInfo: [String: Any] = ["kind": "vdr", "folder": ex.folder.lastPathComponent, "name": ex.folder.lastPathComponent,
                                         "layout": ex.layout, "has_video": false]
        let seconds = Py.round(Date().timeIntervalSince(started), 1)
        let project: [String: Any] = [
            "id": pid, "name": caseName, "created": created, "updated": Date().timeIntervalSince1970, "status": "ready",
            "error": NSNull(), "source": sourceInfo, "sample_rate": VDR.sampleRate, "channels": 1,
            "duration": Py.round(longest, 3), "tracks": trackList, "markers": [Any](), "profiles": [Any](), "time_origin": t0,
            "video": NSNull(), "vdr": vdrSmall,
            "history": [["time": Date().timeIntervalSince1970, "op": "vdr_import", "program": ForensicCases.program,
                         "seconds": seconds, "tracks": tracks.map(\.1.tid), "blocks": ex.blocks.count] as [String: Any]],
            "package": ["format": ForensicCases.format, "version": ForensicCases.formatVersion, "created": createdISO],
        ]
        try ForensicJSON.data(project).write(to: fall.appendingPathComponent("projekt.json"), options: .atomic)
        if let app = ForensicImport.reviewAppURL {
            try fm.copyItem(at: app, to: work.appendingPathComponent(ForensicCases.reviewApp))
        }
        try Data(ForensicCases.readme(name: caseName, created: createdISO).utf8)
            .write(to: work.appendingPathComponent("LIESMICH.txt"), options: .atomic)
        var manifest: [String: Any] = [
            "format": ForensicCases.format, "version": ForensicCases.formatVersion, "created": createdISO,
            "program": ForensicCases.program, "project_id": pid, "name": caseName, "time_origin": t0,
            "duration": Py.round(longest, 3), "proxies": proxies, "video": NSNull(), "images": true, "originals": originals,
            "segments": 0, "files": 0,
        ]
        try ForensicJSON.data(manifest).write(to: fall.appendingPathComponent("manifest.json"), options: .atomic)
        progress(0.96, L("Prüfsummen", "checksums"))
        // Anzahl der gelieferten Dateien steht im Manifest selbst: einmal zählen, dann mit der Zahl neu schreiben
        let count = try ForensicCases.writeChecksums(work, isCancelled: isCancelled)
        manifest["files"] = count
        try ForensicJSON.data(manifest).write(to: fall.appendingPathComponent("manifest.json"), options: .atomic)
        var known = try ForensicImport.checksumsOf(work)
        known["fall/manifest.json"] = nil
        _ = try ForensicCases.writeChecksums(work, known: known, isCancelled: isCancelled)

        // 5. Namen geben
        let target = ForensicCases.uniqueFolder(in: ForensicCases.directory, name: ForensicCases.safeName(caseName))
        try fm.moveItem(at: work, to: target)
        progress(1, L("fertig", "done"))
        return target
    }
}
