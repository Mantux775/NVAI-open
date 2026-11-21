import FluxTextEncoders
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// „Übersetzen“ der Übersetzer-Spur auf dem Mac (seit 0.5.11), nach `audio_forensic._translate` unter Windows: zwei
/// Stufen (Paare ohne Englisch sind schwächer), erst nach Englisch, dann aus dem Original in die Zielsprache mit dem
/// englischen Entwurf als Hilfe; nummerierte Zeilen in Stapeln zu 12, fehlende einzeln nachgefragt, nur kopierte Zeilen
/// noch einmal und sonst als „nicht übersetzt“ vermerkt, Schleifen gekürzt (`tame`). Modell nach Speicher (Wahl des
/// Nutzers 20.11.2026): ab 16 GB Qwen3.5-9B (4 Bit, 6,0 GB) wie unter Windows, darunter Qwen3.5-4B (4 Bit, 3,1 GB,
/// dieselbe Datei wie „Automatisch“ beim Restaurieren). Gerechnet wird mit MLXLLM (mlx-swift-lm), ohne Denkmodus.
enum ForensicTranslate {
    typealias Progress = (Double, String) -> Void

    struct Request: Sendable {
        var folder: URL
        /// Zielsprache; nil = die der Übersetzer-Spur (Vorgabe Deutsch)
        var target: String? = nil
        /// auch schon übersetzte Blöcke neu
        var all: Bool = false
    }

    struct Outcome: Sendable {
        var translated: Int
        var untranslated: Int
        var seconds: Double
        var model: String
    }

    // MARK: Modell

    static let repo9B = "mlx-community/Qwen3.5-9B-4bit"
    static var large: Bool { ForensicCredits.memoryGB >= 16 }
    static var modelID: String { large ? "qwen3.5-9b-4bit" : "qwen3.5-4b-4bit" }
    static var modelName: String { large ? "Qwen3.5-9B (4 Bit)" : "Qwen3.5-4B (4 Bit)" }
    static var sizeGB: Double { large ? 5.98 : 3.06 }

    static var directory: URL? {
        if large {
            let dir = Settings.modelsDirectory.appendingPathComponent(repo9B, isDirectory: true)
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(".nvai-complete").path) ? dir : nil
        }
        return TextEncoderModelDownloader.findQwen35ModelPath(for: .qwen35_4B_4bit)
    }

    static var installed: Bool { directory != nil }

    static func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard large else {
            try await HelperModel.vision.download(progress: progress)
            return
        }
        let files = try await ForensicModel.listFiles(repo: repo9B, folder: "")
            .filter { !$0.path.hasSuffix(".gitattributes") && !$0.path.hasSuffix("README.md") }
        let dir = Settings.modelsDirectory.appendingPathComponent(repo9B, isDirectory: true)
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var before: Int64 = 0
        let fm = FileManager.default
        for file in files {
            try Task.checkCancellation()
            let target = dir.appendingPathComponent(file.path)
            let have = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? -1
            if have != file.size {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let url = URL(string: "https://huggingface.co/\(repo9B)/resolve/main/\(file.path)") else { continue }
                let offset = before
                let tmp = try await Downloader().lade(url) { stand in
                    progress(min(0.99, Double(offset + stand.geladen) / Double(total)), t("lädt \(file.path)", "downloading \(file.path)"))
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: tmp, to: target)
            }
            before += file.size
        }
        try Data().write(to: dir.appendingPathComponent(".nvai-complete"))
        progress(1, t("fertig", "done"))
    }

    static var credit: [String: Any] {
        ["role": "translate", "id": modelID, "name": modelName, "by": "Alibaba (Qwen), MLX: mlx-community", "license": "Apache-2.0",
         "license_url": "https://www.apache.org/licenses/LICENSE-2.0"]
    }

    // MARK: Ablauf

    static func run(_ req: Request, progress: @escaping Progress, isCancelled: @escaping () -> Bool) async throws -> Outcome {
        let started = Date()
        guard let dir = directory else {
            throw ForensicError(t("\(modelName) ist nicht geladen (Ton-Forensik → Modelle).", "\(modelName) is not downloaded (Audio forensics → Models)."))
        }
        let fall = req.folder.appendingPathComponent("fall", isDirectory: true)
        let edited = req.folder.appendingPathComponent("bearbeitung/transkript.json")
        let useEdited = FileManager.default.fileExists(atPath: edited.path)
        let docURL = useEdited ? edited : fall.appendingPathComponent("transkript.json")
        guard var doc = ForensicJSON.object(docURL) else {
            throw ForensicError(t("Noch keine Übersetzer-Spur: erst „Sprache erkennen“.", "No translation track yet: run “Recognise speech” first."))
        }
        let project = ForensicJSON.object(fall.appendingPathComponent("projekt.json")) ?? [:]
        let maritime = ((project["source"] as? [String: Any])?["kind"] as? String) == "vdr"
        let target = req.target ?? (doc["target_lang"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "de"
        let source = doc["source_lang"] as? String ?? ""
        var segments = doc["segments"] as? [[String: Any]] ?? []
        // Nur KI-Entwürfe: Geprüfte und von Hand angelegte oder geänderte Blöcke bleiben, wie sie sind (unter Windows
        // übersetzt nur der Lauf, der die Blöcke gerade erkannt hat; die Prüf-App setzt origin auf „human“, sobald
        // jemand Text, Übersetzung oder Notiz ändert). Vorher überschrieb „Übersetzen“ auch geprüfte Übersetzungen.
        let todo = segments.indices.filter { i in
            let s = segments[i]
            guard s["origin"] as? String == "ai", s["status"] as? String != "checked" else { return false }
            let text = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, (s["kind"] as? String) != "note" else { return false }
            let have = ((s["translation"] as? [String: Any])?[target] as? String ?? "")
            return req.all || have.isEmpty
        }
        guard !todo.isEmpty else {
            return Outcome(translated: 0, untranslated: 0, seconds: 0, model: modelName)
        }
        progress(0.02, t("lädt \(modelName)", "loading \(modelName)"))
        let llm = ForensicLLM.shared
        try await llm.load(dir)
        let srcName = Self.languageName(source, maritime: maritime)
        let tgtName = Self.names[target] ?? target
        let stages = target == "en" ? 1 : 2
        // 1. nach Englisch nur, wo noch keins steht: Ein vorhandener englischer Entwurf bleibt (vorher wurde er bei jedem
        // Lauf überschrieben); ist Englisch selbst das Ziel, gilt die Auswahl oben (mit `all` alle KI-Entwürfe neu).
        let stage1 = todo.filter { i in
            let en = (segments[i]["translation"] as? [String: Any])?["en"] as? String ?? ""
            return target == "en" || en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let total = Double(max(1, stage1.count + (stages == 2 ? todo.count : 0)))
        var done = 0.0
        var untranslated = 0
        let batch = 12
        let sysEN = Self.systemEN(srcName, maritime: maritime, examples: source == "tl" || (source.isEmpty && maritime))
        for start in stride(from: 0, to: stage1.count, by: batch) {
            if isCancelled() { throw CancellationError() }
            let part = Array(stage1[start..<min(stage1.count, start + batch)])
            let need = part.filter { (segments[$0]["lang"] as? String) != "en" }
            let res = need.isEmpty ? [] : try await llm.lines(system: sysEN, need.map { segments[$0]["text"] as? String ?? "" })
            var byIndex: [Int: String] = [:]
            for (i, r) in zip(need, res) { byIndex[i] = r }
            for i in part {
                let text = segments[i]["text"] as? String ?? ""
                let raw = (segments[i]["lang"] as? String) == "en" ? text : (byIndex[i] ?? "")
                let (en, cut) = tame(text, raw)
                var tr = segments[i]["translation"] as? [String: Any] ?? [:]
                tr["en"] = en
                segments[i]["translation"] = tr
                if cut { addFlag(&segments[i], "repetition") }
            }
            done += Double(part.count)
            progress(0.05 + 0.93 * done / total, t("übersetzen nach Englisch \(min(Int(done), stage1.count))/\(stage1.count)",
                                                    "translating to English \(min(Int(done), stage1.count))/\(stage1.count)"))
        }
        var done2 = 0
        // 2. in die Zielsprache, Original mit englischem Entwurf
        if stages == 2 {
            let sysT = Self.systemTarget(srcName, tgtName, target, maritime: maritime,
                                         examples: source == "tl" || (source.isEmpty && maritime))
            for start in stride(from: 0, to: todo.count, by: batch) {
                if isCancelled() { throw CancellationError() }
                let part = Array(todo[start..<min(todo.count, start + batch)])
                let input = { (i: Int) -> String in
                    let en = (segments[i]["translation"] as? [String: Any])?["en"] as? String ?? ""
                    return "\(segments[i]["text"] as? String ?? "") || EN: \(en)"
                }
                let res = try await llm.lines(system: sysT, part.map(input))
                for (i, r) in zip(part, res) {
                    let text = segments[i]["text"] as? String ?? ""
                    var (out, cut) = tame(text, r)
                    // nur kopiert: einmal einzeln nachfragen, sonst „nicht übersetzt“
                    let copied = { (x: String) in x.trimmingCharacters(in: .whitespaces).lowercased() == text.trimmingCharacters(in: .whitespaces).lowercased() }
                    if (segments[i]["lang"] as? String) != target, text.split(separator: " ").count > 1, copied(out) {
                        let again = tame(text, (try await llm.lines(system: sysT, [input(i)])).first ?? "").0
                        if !again.isEmpty && !copied(again) {
                            out = again
                        } else {
                            out = ""
                            untranslated += 1
                            addFlag(&segments[i], "untranslated")
                        }
                    }
                    var tr = segments[i]["translation"] as? [String: Any] ?? [:]
                    tr[target] = out
                    segments[i]["translation"] = tr
                    if cut { addFlag(&segments[i], "repetition") }
                }
                done += Double(part.count)
                done2 += part.count
                progress(0.05 + 0.93 * done / total, t("übersetzen nach \(tgtName) \(done2)/\(todo.count)",
                                                        "translating to \(tgtName) \(done2)/\(todo.count)"))
            }
        }
        await llm.unload()
        // 3. schreiben
        doc["segments"] = segments
        doc["target_lang"] = target
        var runs = doc["runs"] as? [[String: Any]] ?? []
        var run: [String: Any] = ["time": Date().timeIntervalSince1970, "model": NSNull(), "translator": modelID]
        run["translator_info"] = credit
        run["hardware"] = ["gpus": [["name": ForensicCredits.chip, "vram_gb": ForensicCredits.memoryGB] as [String: Any]]] as [String: Any]
        run["program"] = ForensicCases.program
        run["segments"] = todo.count
        run["translate_seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        run["target"] = target
        runs.append(run)
        doc["runs"] = runs
        doc["updated"] = Date().timeIntervalSince1970
        doc["credits"] = ForensicCredits.credits(runs)
        try ForensicJSON.data(doc).write(to: docURL, options: .atomic)
        if useEdited {
            try ForensicProtocol.append(folder: req.folder, op: "ki_uebersetzung",
                                        detail: [("bloecke", "\(todo.count)"), ("modell", ForensicJSON.quote(modelName)),
                                                 ("ziel", ForensicJSON.quote(target))])
        }
        try ForensicCases.refreshDelivered(req.folder, segments: nil, isCancelled: isCancelled)
        progress(1, t("fertig", "done"))
        return Outcome(translated: todo.count - untranslated, untranslated: untranslated,
                       seconds: Date().timeIntervalSince(started), model: modelName)
    }

    /// Vermerk der KI („repetition“, „untranslated“) an einen KI-Entwurf. Bei diesen Blöcken ist `note` das Feld der
    /// Vermerke: Whisper schreibt seine dorthin, Windows ebenso (`"note": ", ".join(flags)`), und die Prüf-App liest sie
    /// nur bei origin „ai“ aus `note`. Eine Notiz von Prüfern macht den Block zu „human“; solche Blöcke übersetzt dieser
    /// Lauf nicht mehr (`todo`), ihre Notiz bleibt also unberührt.
    static func addFlag(_ s: inout [String: Any], _ flag: String) {
        guard s["origin"] as? String == "ai" else { return }
        var parts = (s["note"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !parts.contains(flag) { parts.append(flag) }
        s["note"] = parts.joined(separator: ", ")
    }

    // MARK: Anweisungen (wie TRANSLATE_RULES, _sys_en, _sys_target)

    static let names = ["tl": "Tagalog/Filipino", "ceb": "Cebuano", "en": "English", "de": "German", "es": "Spanish",
                        "fr": "French", "it": "Italian", "nl": "Dutch", "pl": "Polish", "ru": "Russian", "uk": "Ukrainian",
                        "zh": "Chinese", "ja": "Japanese", "ko": "Korean", "id": "Indonesian", "vi": "Vietnamese",
                        "hi": "Hindi", "tr": "Turkish", "pt": "Portuguese", "ar": "Arabic", "fa": "Persian", "ro": "Romanian",
                        "hu": "Hungarian", "cs": "Czech", "el": "Greek", "sv": "Swedish", "da": "Danish", "no": "Norwegian",
                        "fi": "Finnish", "bg": "Bulgarian", "hr": "Croatian", "sr": "Serbian", "th": "Thai", "ms": "Malay"]

    static func languageName(_ code: String, maritime: Bool) -> String {
        if let n = names[code] { return n }
        return maritime ? "Tagalog/Filipino (mixed with English)" : "the original language"
    }

    static let rules = "Rules: Every line must come out in the target language; never return a line unchanged in the source language. "
        + "Translate faithfully and literally for a legal review: do not add, omit, summarise, explain or correct anything. "
        + "Only words that are already in the target language, names, numbers, courses, headings, positions, times and "
        + "standard nautical orders (e.g. 'midships', 'hard a port') stay as they are. If a word is unclear, translate the "
        + "rest and write that word as [?word?]. Keep markers such as [unintelligible], [?word?], //overlap// and [sound] "
        + "unchanged. Answer with exactly one line per input line, each starting with its number and a full stop, the same "
        + "numbers in the same order, and nothing else."

    // frei erfundene Beispiele aus dem Bordalltag (wie unter Windows), nur bei Tagalog-Schiffsaufnahmen
    static let examplesEN = [("Sige, sige.", "Okay, okay."), ("Bakit ba? Hindi pwede.", "Why? That is not allowed."),
                             ("Dahan-dahan lang, kapitan.", "Slowly, just slowly, captain."),
                             ("Nasaan na yung barko sa kanan?", "Where is the ship on the right now?"),
                             ("Hard port na, bilisan mo!", "Hard port now, hurry up!"),
                             ("Opo, sir, naka-standby na po ang makina.", "Yes, sir, the engine is on standby now, sir.")]
    static let examplesDE = [("Sige, sige.", "Okay, okay.", "Okay, okay."),
                             ("Bakit ba? Hindi pwede.", "Why? That is not allowed.", "Warum denn? Das geht nicht."),
                             ("Hard port na, bilisan mo!", "Hard port now, hurry up!", "Jetzt hart Backbord, beeil dich!"),
                             ("Opo, sir, naka-standby na po ang makina.", "Yes, sir, the engine is on standby now, sir.",
                              "Jawohl, Sir, die Maschine ist jetzt in Bereitschaft, Sir.")]

    static func what(_ src: String, maritime: Bool) -> String {
        maritime ? "transcripts of ship-bridge audio recordings (seafarers speaking \(src), often mixed with English and maritime orders)"
            : "transcripts of audio recordings (people speaking \(src))"
    }

    static func systemEN(_ src: String, maritime: Bool, examples: Bool) -> String {
        var s = "You are a court interpreter. You translate \(what(src, maritime: maritime)) into English. The input is a numbered list of lines. " + rules
        if examples {
            s += "\nExample input:\n" + examplesEN.enumerated().map { "\($0.offset + 1). \($0.element.0)" }.joined(separator: "\n")
            s += "\nExample answer:\n" + examplesEN.enumerated().map { "\($0.offset + 1). \($0.element.1)" }.joined(separator: "\n")
        }
        return s
    }

    static func systemTarget(_ src: String, _ tgt: String, _ target: String, maritime: Bool, examples: Bool) -> String {
        var s = "You are a court interpreter. You translate \(what(src, maritime: maritime)) into \(tgt). The input is a numbered list; "
            + "each line holds the original, then after \"|| EN:\" an English draft translation. Translate the original into "
            + "\(tgt); use the English draft to understand it, but where the draft differs from the original, the original counts. " + rules
        if examples && target == "de" {
            s += "\nExample input:\n" + examplesDE.enumerated().map { "\($0.offset + 1). \($0.element.0) || EN: \($0.element.1)" }.joined(separator: "\n")
            s += "\nExample answer:\n" + examplesDE.enumerated().map { "\($0.offset + 1). \($0.element.2)" }.joined(separator: "\n")
        }
        return s
    }

    // MARK: Schleifen kürzen (wie _tame)

    static func tame(_ src: String, _ out: String) -> (String, Bool) {
        guard !out.isEmpty else { return (out, false) }
        let limit = 4 * src.count + 120
        let longest = out.split(separator: " ").map(\.count).max() ?? 0
        if out.count <= limit && longest <= 60 { return (out, false) }
        var new = out
        if let re = try? NSRegularExpression(pattern: "(.{1,24}?)\\1{4,}", options: [.dotMatchesLineSeparators]) {
            for _ in 0..<3 {
                let range = NSRange(new.startIndex..., in: new)
                let cut = re.stringByReplacingMatches(in: new, range: range, withTemplate: "$1$1$1…")
                if cut == new { break }
                new = cut
            }
        }
        if new.count > limit { new = String(new.prefix(limit)).trimmingCharacters(in: .whitespaces) + " …" }
        return (new, new != out)
    }

    static func parseLines(_ text: String) -> [Int: String] {
        var out: [Int: String] = [:]
        let re = try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s*[.):\\]]\\s*(.*\\S)?\\s*$")
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re?.firstMatch(in: line, range: range), let r1 = Range(m.range(at: 1), in: line),
                  let n = Int(line[r1]) else { continue }
            let body = Range(m.range(at: 2), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            if out[n] == nil { out[n] = body }
        }
        return out
    }
}

/// Qwen3.5 als Textmodell über MLXLLM; bleibt geladen, solange übersetzt wird.
actor ForensicLLM {
    static let shared = ForensicLLM()
    private var container: ModelContainer?
    private var loadedFrom: URL?

    func load(_ dir: URL) async throws {
        if loadedFrom == dir, container != nil { return }
        container = nil
        container = try await LLMModelFactory.shared.loadContainer(from: dir, using: TransformersTokenizerLoader())
        loadedFrom = dir
    }

    func unload() {
        container = nil
        loadedFrom = nil
        MLX.GPU.clearCache()
    }

    /// Ein Stapel nummerierter Zeilen; fehlende Zeilen einmal einzeln nachgefragt (wie _llm_lines).
    func lines(system: String, _ lines: [String]) async throws -> [String] {
        let one = { (x: String) in x.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let user = lines.enumerated().map { "\($0.offset + 1). \(one($0.element))" }.joined(separator: "\n")
        let budget = min(2048, 96 + lines.reduce(0) { $0 + $1.count } / 2 + 24 * lines.count)
        let got = ForensicTranslate.parseLines(try await complete(system: system, user: user, maxTokens: budget))
        var out = (0..<lines.count).map { got[$0 + 1] ?? "" }
        if lines.count > 1 {
            for (i, x) in lines.enumerated() where out[i].isEmpty {
                let r = try await complete(system: system, user: "1. \(one(x))", maxTokens: 96 + x.count)
                out[i] = ForensicTranslate.parseLines(r)[1] ?? ""
            }
        }
        return out
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let container else { throw ForensicError(t("Das Sprachmodell ist nicht geladen.", "The language model is not loaded.")) }
        let session = ChatSession(container, instructions: system,
                                  generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        var text = try await session.respond(to: user)
        // leerer Denkblock der Qwen-Vorlage
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tokenizer aus swift-transformers für mlx-swift-lm 3.x (das keinen eigenen mehr mitbringt).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(inner: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let inner: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { inner.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { inner.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }
    var bosToken: String? { inner.bosToken }
    var eosToken: String? { inner.eosToken }
    var unknownToken: String? { inner.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try inner.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
