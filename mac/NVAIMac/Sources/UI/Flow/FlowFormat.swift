import Foundation

/// Zeiten und Größen der geführten Oberfläche (seit Mac 1.0, wie flow/time.ts unter Windows; Konzept „NVAI im Fluss“:
/// „Ein Knopf sagt den nächsten Schritt, er nennt Aktion und Zeit“). Überall gleich geschrieben: „≈ 40 s“, „≈ 1:50“,
/// „≈ 13 min“, „≈ 1 h 40 min“.
enum FlowFormat {
    /// Dauer als Uhr: 218 → „3:38“, 3725 → „1:02:05“
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// Geschätzte Dauer ohne Zeichen davor: „40 s“, „1 min“, „1:50“, „13 min“, „1 h 40 min“
    static func span(_ seconds: Double) -> String {
        let s = max(1, seconds)
        if s < 55 { return "\(max(5, Int((s / 5).rounded()) * 5)) s" }
        if s < 75 { return "1 min" }
        if s < 600 { return clock((s / 5).rounded() * 5) }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        let h = Int(s / 3600)
        let m = Int(((s.truncatingRemainder(dividingBy: 3600)) / 60 / 5).rounded()) * 5
        return m >= 60 ? "\(h + 1) h" : m > 0 ? "\(h) h \(m) min" : "\(h) h"
    }

    /// Schätzung mit Ungefähr-Zeichen; ohne Zahl ein leerer Text
    static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return "≈ \(span(seconds))"
    }

    /// Restzeit: „noch ≈ 1:05“
    static func left(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return t("noch ≈ \(span(seconds))", "≈ \(span(seconds)) left")
    }

    /// Gigabyte im Zahlenformat der Sprache: „37,5 GB“
    static func gb(_ gb: Double) -> String {
        let text = gb >= 10 ? String(format: "%.1f", (gb * 10).rounded() / 10) : String(format: "%.2f", (gb * 100).rounded() / 100)
        let trimmed = text.contains(".") ? text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : text
        return (Lang.current == .de ? trimmed.replacingOccurrences(of: ".", with: ",") : trimmed) + " GB"
    }

    /// Ladezeit bei einer angenommenen Leitung (Vorgabe 100 MBit/s), in Sekunden
    static func downloadSeconds(_ gb: Double, mbit: Double = 100) -> Double { gb * 8000 / mbit }

    /// Woher eine Zahl kommt, für den Tooltip
    static func source(_ e: JobEstimate?) -> String {
        guard let e else { return "" }
        let base: String
        switch e.source {
        case "history": base = t("gemessen auf diesem Mac (\(e.runs) Läufe)", "measured on this Mac (\(e.runs) runs)")
        case "estimate": base = t("geschätzt aus Messungen auf einem Mac mini M1", "estimated from measurements on a Mac mini M1")
        case "rough": base = t("grob geschätzt", "rough estimate")
        default: base = t("keine Messung", "not measured")
        }
        guard let load = e.load, load >= 1 else { return base }
        return base + t("; dazu einmalig ≈ \(Int(load.rounded())) s zum Laden", "; plus ≈ \(Int(load.rounded())) s once to load")
    }
}
