import SwiftUI

/// Wie unter Windows (Nutzerwunsch 26.10.2026): Welche Modelle für diesen Mac empfohlen sind und ob ein Modell in
/// seinen Arbeitsspeicher passt. „ja“, „knapp“ und „nein“ wie `ModelCatalog.fits` und `CoreMLCatalog.fits`.
enum MacFit {
    /// Für Modelle, deren Bedarf als gemessene Speicherspitze bekannt ist: Passt mit 2 GB Luft für macOS und andere
    /// Programme → ja; passt nur ohne Luft → knapp; sonst nein.
    static func of(needGB: Double) -> String {
        let ram = Double(SystemInfo.memoryGB)
        if needGB <= ram - 2 { return "ja" }
        if needGB <= ram { return "knapp" }
        return "nein"
    }

    /// Gemessene Spitzen am Mac mini M1 mit 8 GB (siehe CLAUDE.md): LTX-Video 2B 6,2 GB bei 768 × 512 × 97,
    /// SeedVR2 3B 6,5 GB, Qwen3.5 4B rund 3 GB; Stable Audio 3 laut Katalog 5 GB.
    static let videoNeedGB = 6.2
    static let audioNeedGB = 5.0

    static func helperNeedGB(_ helper: HelperModel) -> Double {
        switch helper {
        case .vision: return 3.5
        case .sharpen: return 6.5
        }
    }
}

enum MacRecommendations {
    /// Die Empfehlung je Bereich für diesen Mac: das FLUX.2-Klein-Modell zur Speichergröße, Z-Image Turbo, wenn es
    /// ohne Nachladen passt, Video, Musik und die Zusätze, wenn sie passen.
    static func isRecommended(_ id: String) -> Bool {
        if id == ModelCatalog.recommended.id { return true }
        if let z = ZImageCatalog.model(id) { return ZImageCatalog.fits(z) == "ja" }
        if VideoCatalog.model(id) != nil { return VideoCatalog.recommended.id == id }  // eines je Speichergröße
        if id == AudioCatalog.id { return MacFit.of(needGB: MacFit.audioNeedGB) != "nein" }
        if let helper = HelperModel(rawValue: id) { return MacFit.of(needGB: MacFit.helperNeedGB(helper)) != "nein" }
        return false
    }
}

/// „empfohlen“ und „passt in 8 GB“ / „knapp für diesen Mac“ / „zu groß für diesen Mac“ als Abzeichen.
struct FitBadges: View {
    let fit: String
    let recommended: Bool

    var body: some View {
        HStack(spacing: 6) {
            if recommended {
                Text(t("empfohlen", "recommended")).font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.8)))
                    .foregroundStyle(.white)
                    .help(t("Empfehlung für diesen Mac (\(SystemInfo.chip), \(SystemInfo.memoryGB) GB)",
                            "Recommended for this Mac (\(SystemInfo.chip), \(SystemInfo.memoryGB) GB)"))
            }
            switch fit {
            case "ja":
                badge(t("passt in \(SystemInfo.memoryGB) GB", "fits into \(SystemInfo.memoryGB) GB"), .green,
                      t("Läuft mit dem Arbeitsspeicher dieses Macs, mit Luft für andere Programme.",
                        "Runs with this Mac's memory, with room for other apps."))
            case "knapp":
                badge(t("knapp für diesen Mac", "tight for this Mac"), .orange,
                      t("Läuft, braucht aber fast den ganzen Arbeitsspeicher: andere Programme schließen, kleine Formate.",
                        "Runs, but needs almost all of the memory: quit other apps, choose small sizes."))
            default:
                badge(t("zu groß für diesen Mac", "too big for this Mac"), .red,
                      t("Braucht mehr Arbeitsspeicher, als dieser Mac hat.", "Needs more memory than this Mac has."))
            }
        }
    }

    private func badge(_ text: String, _ color: Color, _ help: String) -> some View {
        Text(text).font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.8)))
            .foregroundStyle(color)
            .help(help)
    }
}
