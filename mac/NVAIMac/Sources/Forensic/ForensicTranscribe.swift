import CryptoKit
import Foundation
import WhisperKit

/// „Sprache erkennen“ für einen Fall auf dem Mac (seit 0.5.11), nach `forensic_tools.cmd_transcribe` und
/// `audio_forensic._transcribe` unter Windows:
/// 1. Sprachkarte je Spur mit Silero VAD (`.vad`, je 0,1 s), sonst die grobe Aktivität (`.act`),
/// 2. Abschnitte planen: Mikrofone gemeinsam (je Abschnitt die Spur mit der höchsten Sprachwahrscheinlichkeit, die
///    zweitbeste als Gegenprobe), Lücken unter 0,6 s überbrückt, höchstens 28 s, Spurwechsel nach 2 s klarem Vorsprung,
/// 3. Tor: Silero prüft jeden Abschnitt und kürzt ihn auf die Sprachstrecken (ohne Tor erfand Whisper auf Wind Sätze),
/// 4. Whisper large-v3 (WhisperKit, Core ML) je Abschnitt, mit Wortzeiten,
/// 5. verworfen wird „keine Sprache“ (no_speech > 0,6 und unsicher), Leeres und bekannte Erfindungen; Wiederholungs-
///    schleifen werden abgeschnitten und vermerkt,
/// 6. in die Übersetzer-Spur: ungeprüfte KI-Blöcke dieser Spuren im Bereich ersetzen, Geprüftes bleibt.
/// Geschrieben wird nach `fall/transkript.json` (Prüfsummen neu); gibt es schon eine Bearbeitung, in deren Fassung
/// (`bearbeitung/transkript.json`) samt Eintrag im Prüfprotokoll.
enum ForensicTranscribe {
    typealias Progress = (Double, String) -> Void

    struct Request: Sendable {
        var folder: URL
        var tracks: [String]? = nil
        var region: [Double]? = nil
        /// Sprache vorgeben (ISO-Code); nil = je Abschnitt erkennen
        var language: String? = nil
    }

    struct Region {
        var id: String
        var start: Double
        var end: Double
        var track: String
        var second: String?
        var vad: Double?
    }

    struct Outcome: Sendable {
        var added: Int
        var dropped: Int
        var rejectedVAD: Int
        var regions: Int
        var speechSeconds: Double
        var seconds: Double
        var target: String
    }

    static let hallucinations = ["thank you for watching", "thanks for watching", "see you in the next video",
                                 "see you in the other video", "please subscribe", "subscribe to", "like and subscribe",
                                 "subtitles by", "amara.org", "untertitel im auftrag", "untertitelung", "copyright",
                                 "www.", "http"]

    static func run(_ req: Request, progress: @escaping Progress, isCancelled: @escaping () -> Bool) async throws -> Outcome {
        let started = Date()
        let fall = req.folder.appendingPathComponent("fall", isDirectory: true)
        guard var project = ForensicJSON.object(fall.appendingPathComponent("projekt.json")) else {
            throw ForensicError(t("fall/projekt.json fehlt oder ist beschädigt.", "fall/projekt.json is missing or damaged."))
        }
        guard ForensicModel.whisper.installed else {
            throw ForensicError(t("Whisper large-v3 ist nicht geladen (Ton-Forensik → Modelle).",
                                  "Whisper large-v3 is not downloaded (Audio forensics → Models)."))
        }
        let all = (project["tracks"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String ?? "original") == "original" }
        let chosen = all.filter { tr in req.tracks.map { $0.contains(tr["id"] as? String ?? "") } ?? true }
        guard !chosen.isEmpty else { throw ForensicError(t("Keine Spur gewählt.", "No track chosen.")) }
        let tids = chosen.compactMap { $0["id"] as? String }
        let wav = { (tid: String) in fall.appendingPathComponent("original/\(tid).wav") }
        for tid in tids where !FileManager.default.fileExists(atPath: wav(tid).path) {
            throw ForensicError(t("Originalton der Spur \(tid) fehlt (fall/original).", "Original audio of track \(tid) missing (fall/original)."))
        }

        // 1. Sprachkarten
        var vad: SileroVAD?
        if ForensicModel.vad.installed {
            vad = try SileroVAD(directory: ForensicModel.vad.directory)
            for (k, tid) in tids.enumerated() {
                let out = fall.appendingPathComponent("spec/\(tid).vad")
                if FileManager.default.fileExists(atPath: out.path) { continue }
                _ = try vad!.speechMap(track: wav(tid), out: out, isCancelled: isCancelled) { f in
                    progress(0.15 * (Double(k) + f) / Double(tids.count), t("Sprache finden", "finding speech"))
                }
            }
        }

        // 2. Abschnitte
        let useVAD = tids.allSatisfy { FileManager.default.fileExists(atPath: fall.appendingPathComponent("spec/\($0).vad").path) }
        var acts: [[UInt8]] = []
        for tid in tids {
            let url = fall.appendingPathComponent("spec/\(tid).\(useVAD ? "vad" : "act")")
            acts.append([UInt8]((try? Data(contentsOf: url)) ?? Data()))
        }
        let planned = plan(tids: tids, acts: acts, threshold: useVAD ? 128 : 90, region: req.region)
        let speechSeconds = planned.reduce(0) { $0 + $1.end - $1.start }

        // 3. Tor
        var todo: [Region] = []
        var rejected = 0
        if let vad {
            for (k, r) in planned.enumerated() {
                if isCancelled() { throw CancellationError() }
                var region = r
                var spans: [(Double, Double, Double)] = []
                for tid in [r.track] + (r.second.map { [$0] } ?? []) {
                    spans = try vad.speechSpans(try Audio16k.read(wav(tid), start: r.start, end: r.end))
                    if !spans.isEmpty {
                        if tid != r.track { region = Region(id: r.id, start: r.start, end: r.end, track: tid, second: r.track) }
                        break
                    }
                }
                if spans.isEmpty {
                    rejected += 1
                } else {
                    var groups: [[Double]] = []
                    for (a, b, p) in spans {
                        if let last = groups.last, a - last[1] < 1.5 {
                            groups[groups.count - 1][1] = b
                            groups[groups.count - 1][2] = max(last[2], p)
                        } else {
                            groups.append([a, b, p])
                        }
                    }
                    for g in groups {
                        todo.append(Region(id: "\(region.id)+\(String(format: "%.1f", g[0]))", start: round2(region.start + g[0]),
                                           end: round2(region.start + g[1]), track: region.track, second: region.second,
                                           vad: (g[2] * 1000).rounded() / 1000))
                    }
                }
                if k % 10 == 0 {
                    progress(0.15 + 0.1 * Double(k) / Double(max(1, planned.count)),
                             t("Sprache prüfen \(k)/\(planned.count)", "checking speech \(k)/\(planned.count)"))
                }
            }
        } else {
            todo = planned
        }

        // 4. Whisper
        var segments: [[String: Any]] = []
        var dropped = 0
        var langs: [String: Int] = [:]
        var asrSeconds = 0.0
        if !todo.isEmpty {
            progress(0.26, t("lädt Whisper large-v3 (beim ersten Mal einige Minuten)", "loading Whisper large-v3 (a few minutes the first time)"))
            let asr = try await ForensicASR.shared.load()
            let t1 = Date()
            for (k, r) in todo.enumerated() {
                if isCancelled() { throw CancellationError() }
                let clip = Array(try Audio16k.read(wav(r.track), start: r.start, end: r.end).prefix(30 * 16000))
                var x = try await asr.transcribe(clip, language: req.language)
                let lp = x.logprob
                var flags: [String] = []
                let silent = x.noSpeech > 0.6 && (lp == nil || lp! < -1.0)
                let looped = cutLoops(&x)
                if looped || x.compression > 2.4 { flags.append("repetition") }
                if let lp, lp < -1.0 { flags.append("low_confidence") }
                let low = x.text.lowercased()
                if x.text.isEmpty || silent || hallucinations.contains(where: { low.contains($0) }) {
                    dropped += 1
                } else {
                    langs[x.lang, default: 0] += 1
                    let words: [[Any]] = x.words.map { w in
                        [round2(r.start + w.start), round2(r.start + w.end), w.word, (Double(w.prob) * 1000).rounded() / 1000]
                    }
                    let id = "ai" + Insecure.SHA1.hash(data: Data(r.id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
                    segments.append([
                        "id": id, "start": r.start, "end": r.end, "track": r.track, "speaker": "", "kind": "speech",
                        "text": x.text, "lang": x.lang, "translation": [String: Any](),
                        "conf": lp.map { (exp($0) * 1000).rounded() / 1000 } ?? NSNull(), "status": "draft", "origin": "ai",
                        "note": flags.joined(separator: ", "), "words": words, "second": r.second ?? NSNull(),
                        "alt_text": "", "second_sim": NSNull(), "pinned": false,
                    ])
                }
                progress(0.3 + 0.65 * Double(k + 1) / Double(todo.count),
                         t("Sprache erkennen \(k + 1)/\(todo.count)", "recognising speech \(k + 1)/\(todo.count)"))
            }
            asrSeconds = Date().timeIntervalSince(t1)
        }

        // 5. In die Übersetzer-Spur
        progress(0.96, t("schreibt die Übersetzer-Spur", "writing the translation track"))
        let edited = req.folder.appendingPathComponent("bearbeitung/transkript.json")
        let delivered = fall.appendingPathComponent("transkript.json")
        let useEdited = FileManager.default.fileExists(atPath: edited.path)
        var doc = ForensicJSON.object(useEdited ? edited : delivered)
            ?? ["version": 1, "source_lang": "", "target_lang": "de", "speakers": [Any](), "segments": [Any]()]
        let region = req.region ?? [0, ((project["duration"] as? NSNumber)?.doubleValue ?? 0) + 1]
        let group = Set(tids)
        let old = doc["segments"] as? [[String: Any]] ?? []
        let keep = old.filter { s in
            let stale = s["status"] as? String == "draft" && s["origin"] as? String == "ai"
                && group.contains(s["track"] as? String ?? "") && !(s["pinned"] as? Bool ?? false)
                && num(s["end"]) > region[0] && num(s["start"]) < region[1]
            return !stale
        }
        let blocking = keep.filter { $0["status"] as? String == "checked" || ($0["pinned"] as? Bool ?? false && $0["origin"] as? String == "ai") }
        let fresh = segments.filter { s in
            !blocking.contains { c in num(c["start"]) < num(s["end"]) && num(c["end"]) > num(s["start"]) }
        }
        doc["segments"] = (keep + fresh).sorted { num($0["start"]) < num($1["start"]) }
        let source = req.language ?? langs.max { $0.value < $1.value }?.key ?? (doc["source_lang"] as? String ?? "")
        doc["source_lang"] = source
        if (doc["target_lang"] as? String ?? "").isEmpty { doc["target_lang"] = "de" }
        var runs = doc["runs"] as? [[String: Any]] ?? []
        let names = Dictionary(uniqueKeysWithValues: all.compactMap { tr -> (String, String)? in
            guard let id = tr["id"] as? String else { return nil }
            return (id, tr["name"] as? String ?? id)
        })
        // Schritt für Schritt (ein einziges gemischtes Literal überfordert die Typprüfung)
        var asrInfo: [String: Any] = ["regions": planned.count, "new": todo.count, "kept": segments.count]
        asrInfo["dropped"] = dropped
        asrInfo["rejected_vad"] = rejected
        asrInfo["speech_seconds"] = (speechSeconds * 10).rounded() / 10
        let gpu: [String: Any] = ["name": ForensicCredits.chip, "vram_gb": ForensicCredits.memoryGB]
        var run: [String: Any] = ["time": Date().timeIntervalSince1970, "model": "whisper_large_v3"]
        run["translator"] = NSNull()
        run["second_opinion"] = NSNull()
        run["vad"] = vad != nil ? "silero_vad" as Any : NSNull()
        run["hardware"] = ["gpus": [gpu]] as [String: Any]
        run["program"] = ForensicCases.program
        run["tracks"] = tids.map { names[$0] ?? $0 }
        run["region"] = req.region.map { $0 as Any } ?? NSNull()
        run["fixed_track"] = false
        run["segments"] = fresh.count
        run["asr_seconds"] = (asrSeconds * 10).rounded() / 10
        run["translate_seconds"] = 0
        run["asr"] = asrInfo
        runs.append(run)
        doc["runs"] = runs
        doc["updated"] = Date().timeIntervalSince1970
        doc["credits"] = ForensicCredits.credits(runs)
        try ForensicJSON.data(doc).write(to: useEdited ? edited : delivered, options: .atomic)
        var history = project["history"] as? [[String: Any]] ?? []
        history.append(["time": Date().timeIntervalSince1970, "op": "transcribe", "program": ForensicCases.program,
                        "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                        "label": t("Übersetzer-Spur: \(fresh.count) Blöcke (Whisper large-v3), Entwurf",
                                   "Translation track: \(fresh.count) blocks (Whisper large-v3), draft")])
        project["history"] = history
        project["updated"] = Date().timeIntervalSince1970
        try ForensicJSON.data(project).write(to: fall.appendingPathComponent("projekt.json"), options: .atomic)
        if useEdited {
            try ForensicProtocol.append(folder: req.folder, op: "ki_sprache",
                                        detail: [("bloecke", "\(fresh.count)"), ("modell", "\"Whisper large-v3 (Core ML)\"")])
        }
        try ForensicCases.refreshDelivered(req.folder, segments: (doc["segments"] as? [Any])?.count, isCancelled: isCancelled)
        progress(1, t("fertig", "done"))
        return Outcome(added: fresh.count, dropped: dropped, rejectedVAD: rejected, regions: planned.count,
                       speechSeconds: speechSeconds, seconds: Date().timeIntervalSince(started),
                       target: useEdited ? "bearbeitung" : "fall")
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    // MARK: Abschnitte planen (wie plan_regions)

    static func plan(tids: [String], acts: [[UInt8]], threshold: Float, region: [Double]?, maxSeconds: Double = 28) -> [Region] {
        let rate = Double(ForensicFormat.actRate)
        let n = acts.map(\.count).max() ?? 0
        var lo = 0
        var hi = n
        if let region {
            lo = max(0, Int(region[0] * rate))
            hi = min(n, Int((region[1] * rate).rounded(.up)))
        }
        guard hi > lo else { return [] }
        let width = hi - lo
        // Matrix Spur × Zeit (fehlende Werte 0)
        let sub: [[Float]] = acts.map { a in (lo..<hi).map { $0 < a.count ? Float(a[$0]) : 0 } }
        let curve = (0..<width).map { i in sub.map { $0[i] }.max() ?? 0 }
        var out: [Region] = []
        for (a, b) in runs(curve.map { $0 > threshold }, gap: 6, minLen: 4) {
            for (s0, e0) in split(a, b, curve: curve, step: Int(maxSeconds * rate)) {
                for (s, e) in switchParts(sub, s0, e0) {
                    let seg = sub.map { row -> Float in
                        let slice = row[s..<e]
                        return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
                    }
                    let order = seg.indices.sorted { seg[$0] > seg[$1] }
                    let best = tids[order[0]]
                    let second = order.count > 1 ? tids[order[1]] : nil
                    let t0 = max(0, Double(lo + s) / rate - 0.25)
                    let t1 = Double(lo + e) / rate + 0.25
                    out.append(Region(id: "\(best)@\(String(format: "%.1f", t0))", start: round2(t0), end: round2(t1),
                                      track: best, second: second, vad: nil))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Zusammenhängende Strecken, Lücken unter `gap` überbrückt, kürzer als `minLen` verworfen (wie _runs).
    static func runs(_ mask: [Bool], gap: Int, minLen: Int) -> [(Int, Int)] {
        var out: [[Int]] = []
        var i = 0
        while i < mask.count {
            if mask[i] {
                var j = i
                while j < mask.count && mask[j] { j += 1 }
                if let last = out.last, i - last[1] < gap { out[out.count - 1][1] = j } else { out.append([i, j]) }
                i = j
            } else {
                i += 1
            }
        }
        return out.filter { $0[1] - $0[0] >= minLen }.map { ($0[0], $0[1]) }
    }

    /// Lange Abschnitte an der leisesten Stelle zwischen 60 und 100 % der Höchstlänge teilen.
    static func split(_ a: Int, _ b: Int, curve: [Float], step: Int) -> [(Int, Int)] {
        var parts: [(Int, Int)] = []
        var s = a
        while b - s > step {
            let lo = s + Int(Double(step) * 0.6)
            let hi = min(curve.count, s + step)
            var cut = s + step
            if hi > lo {
                var m = lo
                for i in lo..<hi where curve[i] < curve[m] { m = i }
                cut = m
            }
            parts.append((s, cut))
            s = cut
        }
        parts.append((s, b))
        return parts
    }

    /// Abschnitt teilen, wo ein anderes Mikrofon mindestens 2 s klar vorn liegt (wie _switch_parts).
    static func switchParts(_ sub: [[Float]], _ s: Int, _ e: Int, hold: Int = 20, margin: Float = 16) -> [(Int, Int)] {
        let k = sub.count
        guard k >= 2, e - s >= 2 * hold else { return [(s, e)] }
        let len = e - s
        // gleitender Mittelwert über 10 Werte wie np.convolve(…, mode="same"): Fenster [i-5, i+4]
        let sm: [[Float]] = sub.map { row in
            (0..<len).map { i in
                var acc: Float = 0
                for j in (i - 5)...(i + 4) where j >= 0 && j < len { acc += row[s + j] }
                return acc / 10
            }
        }
        var clear = [Bool](repeating: false, count: len)
        var lab = [Int](repeating: 0, count: len)
        for i in 0..<len {
            let col = (0..<k).map { sm[$0][i] }
            let sorted = col.sorted()
            clear[i] = sorted[k - 1] - sorted[k - 2] >= margin
            lab[i] = col.indices.max { col[$0] < col[$1] || (col[$0] == col[$1] && $0 > $1) } ?? 0
        }
        guard let first = clear.firstIndex(of: true) else { return [(s, e)] }
        for i in 0..<first { lab[i] = lab[first] }
        var last = lab[first]
        for i in first..<len {
            if clear[i] { last = lab[i] } else { lab[i] = last }
        }
        var rs: [[Int]] = []
        for (i, v) in lab.enumerated() {
            if let l = rs.last, l[0] == v { rs[rs.count - 1][2] = i + 1 } else { rs.append([v, i, i + 1]) }
        }
        while rs.count > 1 {
            let short = rs.indices.min { (rs[$0][2] - rs[$0][1]) < (rs[$1][2] - rs[$1][1]) }!
            if rs[short][2] - rs[short][1] >= hold { break }
            let r = rs.remove(at: short)
            if short == 0 {
                rs[0][1] = r[1]
            } else if short >= rs.count {
                rs[rs.count - 1][2] = r[2]
            } else if rs[short - 1][2] - rs[short - 1][1] >= rs[short][2] - rs[short][1] {
                rs[short - 1][2] = r[2]
            } else {
                rs[short][1] = r[1]
            }
            var merged = [rs[0]]
            for q in rs.dropFirst() {
                if q[0] == merged[merged.count - 1][0] { merged[merged.count - 1][2] = q[2] } else { merged.append(q) }
            }
            rs = merged
        }
        guard rs.count > 1 else { return [(s, e)] }
        let curve = (0..<len).map { i in (0..<k).map { sub[$0][s + i] }.max() ?? 0 }
        var bounds = [0]
        for q in rs.dropFirst() {
            let lo = max(bounds[bounds.count - 1] + 1, q[1] - 5)
            let hi = min(len - 1, q[1] + 5)
            if hi > lo {
                var m = lo
                for i in lo..<hi where curve[i] < curve[m] { m = i }
                bounds.append(m)
            } else {
                bounds.append(q[1])
            }
        }
        bounds.append(len)
        return (0..<(bounds.count - 1)).compactMap { i in bounds[i + 1] > bounds[i] ? (s + bounds[i], s + bounds[i + 1]) : nil }
    }

    // MARK: Wiederholungsschleifen (wie _cut_loops)

    static func norm(_ w: String) -> String { String(w.lowercased().filter { $0.isLetter || $0.isNumber }) }

    static func loopKeep(_ words: [String]) -> Int? {
        for i in words.indices {
            for n in 1...4 {
                guard i + n <= words.count else { continue }
                let unit = Array(words[i..<(i + n)])
                guard unit.allSatisfy({ !$0.isEmpty }) else { continue }
                var k = 1
                while i + (k + 1) * n <= words.count, Array(words[(i + k * n)..<(i + (k + 1) * n)]) == unit { k += 1 }
                if k >= (n == 1 ? 5 : 4) { return i + n }
            }
        }
        return nil
    }

    static func cutLoops(_ x: inout ForensicASR.Result) -> Bool {
        let toks = x.text.split(separator: " ").map(String.init)
        guard let keep = loopKeep(toks.map(norm)) else { return false }
        x.text = toks.prefix(keep).joined(separator: " ") + " …"
        if let wk = loopKeep(x.words.map { norm($0.word) }) { x.words = Array(x.words.prefix(wk)) }
        return true
    }
}

/// Whisper large-v3 über WhisperKit (Core ML). Bleibt geladen, bis der Speicher gebraucht wird (`unload`).
actor ForensicASR {
    static let shared = ForensicASR()
    private var kit: WhisperKit?

    struct Word {
        var start: Double
        var end: Double
        var word: String
        var prob: Float
    }

    struct Result {
        var text: String
        var lang: String
        var logprob: Double?
        var noSpeech: Double
        var compression: Double
        var words: [Word]
    }

    func load() async throws -> ForensicASR {
        if kit == nil {
            let config = WhisperKitConfig(model: nil, modelFolder: ForensicModel.whisper.directory.path,
                                          tokenizerFolder: ForensicModel.tokenizerBase, computeOptions: ModelComputeOptions(),
                                          verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            kit = try await WhisperKit(config)
        }
        return self
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    var loaded: Bool { kit != nil }

    func transcribe(_ audio: [Float], language: String?) async throws -> Result {
        guard let kit else { throw ForensicError("Whisper nicht geladen") }
        let options = DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0,
                                      temperatureFallbackCount: 5, usePrefillPrompt: true, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true,
                                      compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let segs = results.flatMap(\.segments)
        let text = segs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        var tokens = 0
        var sum = 0.0
        for s in segs {
            let n = max(1, s.tokens.count)
            tokens += n
            sum += Double(s.avgLogprob) * Double(n)
        }
        let words = segs.flatMap { $0.words ?? [] }.map {
            Word(start: Double($0.start), end: Double($0.end), word: $0.word.trimmingCharacters(in: .whitespaces), prob: $0.probability)
        }.filter { !$0.word.isEmpty }
        return Result(text: text, lang: results.first?.language ?? (language ?? ""), logprob: segs.isEmpty ? nil : sum / Double(tokens),
                      noSpeech: Double(segs.first?.noSpeechProb ?? 0), compression: Double(segs.map(\.compressionRatio).max() ?? 0),
                      words: words)
    }
}

/// Womit gerechnet wurde (für den Hinweis der Prüf-App, wie `audio_forensic.transcript_credits`).
enum ForensicCredits {
    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "Apple Silicon" : s
    }

    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    static func credits(_ runs: [[String: Any]]) -> [String: Any] {
        var models: [[String: Any]] = []
        var seen = Set<String>()
        func add(_ m: [String: Any]) {
            let key = "\(m["role"] ?? "")|\(m["id"] ?? "")"
            if seen.insert(key).inserted { models.append(m) }
        }
        var programs: [String] = []
        for r in runs {
            if r["model"] as? String == "whisper_large_v3" { add(ForensicModel.whisper.credit) }
            if r["vad"] as? String == "silero_vad" { add(ForensicModel.vad.credit) }
            if let tr = r["translator_info"] as? [String: Any] { add(tr) }
            if let p = r["program"] as? String, !programs.contains(p) { programs.append(p) }
        }
        let label = "\(chip) (\(memoryGB) GB)"
        return ["local": true, "models": models, "gpus": [label], "gpus_now": [label], "runs": runs.count, "unrecorded": 0,
                "programs": programs]
    }
}

/// Einträge im Prüfprotokoll (`bearbeitung/protokoll.jsonl`), verkettet wie `logEntry` in der Prüf-App:
/// SHA-256 über `JSON.stringify(eintrag)` (Schlüssel in fester Reihenfolge, ohne Leerzeichen), dann `hash` angehängt.
enum ForensicProtocol {
    static func append(folder: URL, op: String, detail: [(String, String)]) throws {
        let url = folder.appendingPathComponent("bearbeitung/protokoll.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var last = ""
        if let l = lines.last, let d = l.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            last = obj["hash"] as? String ?? ""
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body = "\"n\":\(lines.count + 1),\"zeit\":\(ForensicJSON.quote(f.string(from: Date()))),"
        body += "\"pruefer\":\(ForensicJSON.quote("NVAI-open (Mac)")),\"op\":\(ForensicJSON.quote(op))"
        for (k, v) in detail { body += ",\(ForensicJSON.quote(k)):\(v)" }
        body += ",\"vorher\":\(ForensicJSON.quote(last))"
        let hash = ForensicHash.sha256(Data("{\(body)}".utf8))
        let line = "{\(body),\"hash\":\"\(hash)\"}"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(((lines + [line]).joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}
