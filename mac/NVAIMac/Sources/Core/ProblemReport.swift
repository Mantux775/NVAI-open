import Foundation

/// Fehlerbericht für GitHub, wie unter Windows (POST /api/report): Beschreibung, Zeitstempel,
/// Systemangaben, letzte Aufträge ohne Prompts und das Ende von nvai.log – anonymisiert.
/// Ersetzt werden Benutzer- und Rechnername, der Benutzerordner, E-Mail-, IP- und MAC-Adressen,
/// der Hugging-Face-Token und lange Hex-Ketten. Prompts und Bilder sind nicht enthalten.
enum ProblemReport {
    static let issuesURL = "https://github.com/Mantux775/NVAI-open/issues/new"

    struct Result {
        var filename: String
        var text: String
        var time: String
        var lastError: String?
    }

    static func build(description: String, jobs: [JobRecord]) -> Result {
        let now = Date()
        let local = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .medium)
        let iso = ISO8601DateFormatter().string(from: now)
        let offset = TimeZone.current.secondsFromGMT(for: now) / 60
        let zone = String(format: "UTC%@%02d:%02d", offset >= 0 ? "+" : "-", abs(offset) / 60, abs(offset) % 60)
        let lastError = jobs.first { $0.status == "error" && $0.error != nil }?.error

        var out: [String] = [
            "NV-AI for Mac problem report",
            "============================",
            "Created:      \(local) (\(zone)) / \(iso)",
            "",
            "Description",
            "-----------",
            description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : description,
            "",
            "System",
            "------",
            "NV-AI:        \(SystemInfo.appVersion) (\(SystemInfo.build))",
            "Mac:          \(SystemInfo.chip), \(SystemInfo.memoryGB) GB",
            "macOS:        \(SystemInfo.macOS)",
            "Active:       \(Models.active.id)",
            "Installed:    \(Models.all.filter(\.installed).map(\.id).joined(separator: ", "))",
            "Language:     \(Lang.ui.rawValue) (setting \(Lang.setting))",
            "",
            "Recent jobs (newest first, without prompts)",
            "-------------------------------------------",
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for job in jobs.prefix(25) {
            let took = job.startedAt.flatMap { s in job.finishedAt.map { String(format: "%.0f s", $0 - s) } } ?? "-"
            let model = job.request?.modelID ?? job.downloadModelID ?? "-"
            let size = job.request.map { "\($0.width)x\($0.height)" } ?? ""
            out.append("\(formatter.string(from: Date(timeIntervalSince1970: job.createdAt)))  "
                + "\(job.kind.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + "\(job.status.padding(toLength: 9, withPad: " ", startingAt: 0)) \(took)  \(model) \(size)")
            if let error = job.error { out.append("    error: " + error) }
        }
        if jobs.isEmpty { out.append("(none)") }
        let log = tail(AppLog.file, lines: 300)
        if !log.isEmpty {
            out += ["", "nvai.log (last \(log.count) lines)", "--------------------------------", ] + log
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return Result(filename: "nvai-mac-report-\(stamp.string(from: now)).txt",
                      text: anonymize(out.joined(separator: "\n")) + "\n",
                      time: "\(local) (\(zone))",
                      lastError: lastError.map { String(anonymize($0).prefix(600)) })
    }

    /// Neues Issue auf GitHub, vorausgefüllt; die Datei zieht der Nutzer dort hinein.
    static func issueURL(_ report: Result, description: String) -> URL? {
        let first = description.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
        var body = [
            "### What happened / Was ist passiert",
            description.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "When / Wann: \(report.time)",
            "NV-AI for Mac: \(SystemInfo.appVersion) (\(SystemInfo.build)) · macOS \(SystemInfo.macOS)",
            "Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB",
        ]
        if let e = report.lastError { body += ["Last error / Letzter Fehler:", "```", e, "```"] }
        body += ["", "Report / Bericht: please drag `\(report.filename)` into this box / "
                 + "bitte `\(report.filename)` hier hineinziehen."]
        var c = URLComponents(string: issuesURL)
        c?.queryItems = [URLQueryItem(name: "title", value: "[Bug][Mac] \(first)"),
                         URLQueryItem(name: "labels", value: "bug"),
                         URLQueryItem(name: "body", value: body.joined(separator: "\n"))]
        return c?.url
    }

    private static func tail(_ url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).map(String.init))
    }

    static func anonymize(_ input: String) -> String {
        var text = input
        // Benutzerordner zuerst (enthält den Namen), dann Namen nur als ganzes Wort.
        text = text.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .caseInsensitive)
        var words: [(String, String)] = [(NSUserName(), "<USER>"), (NSFullUserName(), "<USER>")]
        if let host = Host.current().localizedName { words.append((host, "<PC>")) }
        words.append((ProcessInfo.processInfo.hostName, "<PC>"))
        if let short = ProcessInfo.processInfo.hostName.split(separator: ".").first { words.append((String(short), "<PC>")) }
        for (value, label) in words.sorted(by: { $0.0.count > $1.0.count }) where value.count >= 2 {
            text = replace(text, "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])", label)
        }
        if let token = Settings.hfToken, token.count >= 8 {
            text = text.replacingOccurrences(of: token, with: "<TOKEN>")
        }
        let patterns: [(String, String)] = [
            ("hf_[A-Za-z0-9]{20,}", "<HF-TOKEN>"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<EMAIL>"),
            ("\\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\\b", "<MAC>"),
            ("(?<![Vv]ersion: )\\b(?!127\\.0\\.0\\.1\\b)(?!0\\.0\\.0\\.0\\b)(?:\\d{1,3}\\.){3}\\d{1,3}\\b", "<IP>"),
            ("\\b[0-9a-fA-F]{32,}\\b", "<HEX>"),
            ("(/Users/)[^/\\s\"']+", "$1<USER>"),
        ]
        for (pattern, label) in patterns { text = replace(text, pattern, label) }
        return text
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
