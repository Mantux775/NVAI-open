import Foundation

/// Wofür „Prompt ausbauen“ schreibt. Bild nimmt BFLs Systemprompt aus dem FLUX.2-Paket; Video (seit 0.4.8,
/// Nutzerwunsch 26.10.2026) den eigenen unten, nach der Windows-Fassung (`server/nvai/prompt_targets.py`), für das
/// kleinere Qwen3-4B satzweise vorgegeben; Kürzen und Aufräumen wie dort.
enum PromptTarget: String, Codable, Sendable, CaseIterable {
    case image, video
}

enum PromptTargets {
    private static let common =
        "Output only the finished prompt in English, no heading, no quotation marks, no explanation, no lists. Keep "
        + "every detail the user gave; where the user's words are not English, translate them. Invent only what is "
        + "needed to make the result concrete, and nothing that contradicts the user's request."
    private static let noInvent =
        " Do not invent extra people, objects, text, clothing details or story that the idea does not imply."

    /// Eigener Systemprompt; nil = BFLs Bild-Systemprompt aus dem Paket.
    static func system(_ target: PromptTarget) -> String? {
        switch target {
        case .image:
            return nil
        case .video:
            // Satzweise statt der Windows-Fassung: Qwen3-4B übernahm deren Beispielliste wörtlich („Cinematic wide shot,
            // handheld close-up:“ in zwei von zwei Texten) und ließ die Kamerabewegung weg (gemessen 26.10.2026).
            return "You write prompts for a text-to-video model (LTX-Video). Turn the user's idea into one paragraph of "
                + "4 to 5 sentences, 40 to 70 words, in the present tense, in this order. First sentence: one shot type "
                + "that fits the idea, chosen from wide shot, medium shot or close-up, and the main subject with its "
                + "look. Next one or two sentences: the motion, what moves, in which direction and how fast, from the "
                + "beginning to the end of the clip. Then one sentence about the camera that names exactly one camera "
                + "movement: pushing in, pulling back, panning, tracking, orbiting or staying still. Last sentence: the "
                + "setting, the light and the time of day. One continuous shot of about four seconds, no cuts. "
                + common + noInvent
        }
    }

    /// Die Form steht auch in der Nutzernachricht; dort wirkt sie stärker als im Systemprompt (gemessen unter Windows).
    static func userText(_ target: PromptTarget, _ prompt: String) -> String {
        switch target {
        case .image: return prompt
        case .video: return "Idea: \(prompt)\nWrite 4 to 5 sentences, 40 to 70 words, no more, with one camera movement."
        }
    }

    /// Höchstlänge in Wörtern nach dem Kürzen.
    static func budget(_ target: PromptTarget) -> Int? {
        switch target {
        case .image: return nil
        case .video: return 70
        }
    }

    /// Denkblock, Überschrift und äußere Anführungszeichen entfernen, „Create a video of …“ streichen, dann kürzen.
    static func clean(_ target: PromptTarget, _ text: String) -> String {
        var out = text
        if let end = out.range(of: "</think>") { out = String(out[end.upperBound...]) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Prompt:", "Output:"] where out.lowercased().hasPrefix(prefix.lowercased()) {
            out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.count > 1, let first = out.first, let last = out.last, first == last || (first == "“" && last == "”"),
           "\"'“".contains(first), !out.dropFirst().dropLast().contains("\"") {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if target == .video,
           let range = out.range(of: #"^(create|generate|make|write)\s+(a|an)\s+[\w\s-]{0,40}?\b(video|clip|prompt)\s+(of|showing)\s+"#,
                                 options: [.regularExpression, .caseInsensitive]) {
            out = String(out[range.upperBound...])
        }
        // „medium shot of a medieval blacksmith …“ (gemessen): den ersten Buchstaben groß.
        out = out.prefix(1).uppercased() + out.dropFirst()
        return shorten(target, out)
    }

    /// Kürzt auf `budget` Wörter, ohne einen Satz zu zerschneiden: Der erste Satz (Stil, Motiv), Sätze mit wörtlichem
    /// Text in Anführungszeichen und der Schlusssatz (Ort, Licht) bleiben; mit den übrigen wird der Reihe nach
    /// aufgefüllt. Gestrichen werden so vor allem erfundene Nebendetails aus der Mitte.
    static func shorten(_ target: PromptTarget, _ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let budget = budget(target) else { return trimmed }
        let sentences = splitSentences(trimmed)
        func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        guard sentences.reduce(0, { $0 + words($1) }) > budget, sentences.count > 1 else { return trimmed }
        var keep: Set<Int> = [0, sentences.count - 1]
        for (i, s) in sentences.enumerated() where s.contains("\"") || s.contains("“") { keep.insert(i) }
        var used = keep.reduce(0) { $0 + words(sentences[$1]) }
        for (i, s) in sentences.enumerated() where !keep.contains(i) && used + words(s) <= budget {
            keep.insert(i)
            used += words(s)
        }
        return keep.sorted().map { sentences[$0] }.joined(separator: " ")
    }

    /// Sätze trennen nach . ! ? gefolgt von Leerraum und einem Großbuchstaben oder Anführungszeichen.
    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if ".!?".contains(chars[i]) {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j > i + 1, j < chars.count, chars[j].isUppercase || chars[j] == "\"" || chars[j] == "“" {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i = j
                    continue
                }
            }
            i += 1
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}
