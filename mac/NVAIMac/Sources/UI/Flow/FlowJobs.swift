import Foundation
import SwiftUI

/// Alle Aufträge der App an einer Stelle, mit ihren Phasen (seit Mac 1.0, wie flow/jobs.ts unter Windows; Konzept „NVAI
/// im Fluss“: Phasen mit Restzeit, eine Auftragsleiste über alle Reiter). Gespeist aus der Auftragsliste, die AppState
/// bei jeder Änderung liest (höchstens viermal je Sekunde): Jeder Wechsel der Phase bekommt hier seinen Zeitpunkt.
@MainActor
final class FlowJobs: ObservableObject {
    static let shared = FlowJobs()

    /// queue: wartet · prepare: bereitet vor · load: Modell lädt · run: rechnet · save: speichert
    struct Mark: Equatable {
        let key: String
        let at: Date
    }

    struct Track {
        var marks: [Mark]
        /// Ab hier wird gerechnet (Zeitpunkt und Fortschritt): Grundlage der Restzeit
        var runFrom: (at: Date, progress: Double)?
        /// erst mitten im Lauf gesehen (Zeiten der früheren Phasen unbekannt)
        var partial: Bool
        var status: String
    }

    private(set) var tracks: [String: Track] = [:]
    /// Schätzung je Auftrag (Rechenzeit, Laden), sobald sie jemand kennt: Restzeit auch vor dem Rechnen ehrlich
    private var expectations: [String: JobEstimate] = [:]
    @Published private(set) var version = 0

    static func isActive(_ j: JobRecord) -> Bool { j.status == "queued" || j.status == "running" }

    /// Phase eines Auftrags; nil, wenn er fertig ist. Downloads rechnen nur (ohne eigene Phasen).
    static func phaseKey(_ j: JobRecord) -> String? {
        switch j.status {
        case "queued": return "queue"
        case "running": return j.kind == "download" ? "run" : (j.phase.isEmpty ? "prepare" : j.phase)
        default: return nil
        }
    }

    func note(_ id: String, _ e: JobEstimate?) {
        if let e, e.seconds != nil { expectations[id] = e }
    }

    func expectation(_ id: String) -> JobEstimate? { expectations[id] }

    /// Mit der Auftragsliste abgleichen (AppState.refresh)
    func update(_ jobs: [JobRecord]) {
        let now = Date()
        var changed = false
        var next: [String: Track] = [:]
        for j in jobs {
            let key = Self.phaseKey(j)
            if var tr = tracks[j.id] {
                if let key, tr.marks.last?.key != key {
                    tr.marks.append(Mark(key: key, at: now))
                    changed = true
                }
                if key == "run", tr.runFrom == nil, j.progress < 0.97 { tr.runFrom = (now, j.progress) }
                if tr.status != j.status {
                    tr.status = j.status
                    changed = true
                }
                next[j.id] = tr
            } else if let key {
                // Neu gesehen: ein wartender Auftrag ab seiner Erstellung, ein laufender ab jetzt (frühere Phasen unbekannt)
                let at = key == "queue" ? Date(timeIntervalSince1970: j.createdAt) : now
                next[j.id] = Track(marks: [Mark(key: key, at: at)], runFrom: key == "run" ? (now, j.progress) : nil,
                                   partial: key != "queue" && key != "prepare", status: j.status)
                changed = true
            } else {
                next[j.id] = Track(marks: [], runFrom: nil, partial: true, status: j.status)
            }
        }
        if next.count != tracks.count { changed = true }
        tracks = next
        expectations = expectations.filter { next[$0.key] != nil }
        if changed { version &+= 1 }
    }

    func currentPhase(_ j: JobRecord) -> String? { Self.isActive(j) ? Self.phaseKey(j) : nil }

    /// Wie lange eine Phase dauerte bzw. bis jetzt dauert (Sekunden); nil, wenn unbekannt
    func phaseSeconds(_ j: JobRecord, _ key: String, now: Date = Date()) -> Double? {
        guard let tr = tracks[j.id], let i = tr.marks.firstIndex(where: { $0.key == key }) else { return nil }
        if tr.partial && i == 0 && key != "queue" { return nil }
        let end: Date = i + 1 < tr.marks.count ? tr.marks[i + 1].at
            : Self.isActive(j) ? now : Date(timeIntervalSince1970: j.finishedAt ?? now.timeIntervalSince1970)
        return max(0, end.timeIntervalSince(tr.marks[i].at))
    }

    func sawPhase(_ j: JobRecord, _ key: String) -> Bool { tracks[j.id]?.marks.contains { $0.key == key } ?? false }

    /// Restzeit in Sekunden: aus der Rate seit Beginn des Rechnens; solange davon noch wenig zu sehen ist, aus der
    /// Schätzung vor dem Start (`expected` bzw. die gemerkte: Rechenzeit, dazu was vom Laden noch fehlt). nil = keine Aussage.
    func remaining(_ j: JobRecord, expected: Double? = nil, now: Date = Date()) -> Double? {
        guard Self.isActive(j) else { return nil }
        let phase = currentPhase(j)
        if phase == "save" { return 2 }
        let est = expectations[j.id]
        if phase == "run", let from = tracks[j.id]?.runFrom {
            let span = max(0.01, 0.99 - from.progress)
            let frac = (j.progress - from.progress) / span
            let elapsed = now.timeIntervalSince(from.at)
            if frac >= 0.04 && elapsed >= 3 { return max(1, elapsed * (1 - frac) / frac) }
        }
        guard let base = expected ?? est?.seconds else { return nil }
        let load = est?.load ?? 0
        if phase == "queue" { return base + load }
        // Anders als unter Windows zählt die Schätzung auf dem Mac den ganzen Lauf ab dem Start: Prompt lesen und das
        // träge Laden der Gewichte (MLX) stecken in der Rechenzeit, die erste Stufe meldet sich erst nach Schritt 1.
        // Also abziehen, was seit dem Start vergangen ist (gemessen: sonst „noch ≈ 35 s“ bei 19 s Rest). Ist die
        // Schätzung aufgebraucht, lieber keine Zahl als eine falsche.
        let spent = j.startedAt.map { now.timeIntervalSince1970 - $0 } ?? 0
        let left = base + load - spent
        return left >= 3 ? left : nil
    }
}

/// Wie ein Auftrag heißt und wohin er gehört (Auftragsleiste, Hinweise)
@MainActor
enum FlowKinds {
    static func label(_ kind: String) -> String {
        switch kind {
        case "txt2img", "img2img": return t("Bild", "Image")
        case "txt2video", "img2video": return "Video"
        case "txt2audio": return t("Ton", "Sound")
        case "tts": return t("Stimme", "Voice")
        case "restore": return t("Foto restaurieren", "Restore photo")
        case "expand_prompt": return t("Prompt ausbauen", "Expand prompt")
        case "studio_export": return "Export"
        case "download": return "Download"
        case "forensic_case": return t("Ton-Forensik: neuer Fall", "Audio forensics: new case")
        case "forensic_transcribe": return t("Sprache erkennen", "Recognise speech")
        case "forensic_translate": return t("Übersetzen", "Translate")
        default: return kind
        }
    }

    /// Reiter, in dem ein Auftrag hingehört
    static func origin(_ j: JobRecord) -> String {
        if j.kind == "studio_export" || j.params["studio_project"]?.stringValue != nil { return "studio" }
        if j.kind.hasPrefix("forensic") { return "forensic" }
        if j.kind == "download" { return "models" }
        return "generate"
    }

    /// Kurz, was entsteht: „Video · 4 s“, „Ton · 60 s“, „Bild · Holzfass mit Eisenbändern“
    static func detail(_ j: JobRecord) -> String {
        let p = j.params
        if j.kind == "txt2video" || j.kind == "img2video", let f = p["frames"]?.intValue {
            return "\(Int((Double(f) / Double(max(1, p["fps"]?.intValue ?? 24))).rounded())) s"
        }
        if j.kind == "txt2audio", let s = p["seconds"]?.doubleValue { return "\(Int(s.rounded())) s" }
        if j.kind == "download", let id = p["model_id"]?.stringValue {
            return AppState.shared.flowModels.first { $0.id == id }?.short ?? id
        }
        let prompt = (p["prompt"]?.stringValue ?? p["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return "" }
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        return words.count > 34 ? String(words.prefix(33)) + "…" : words
    }
}

/// Rendert jede Sekunde neu, solange `on` gilt (Restzeiten laufen herunter)
struct EverySecond<Content: View>: View {
    let on: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if on {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in content(ctx.date) }
        } else {
            content(Date())
        }
    }
}
