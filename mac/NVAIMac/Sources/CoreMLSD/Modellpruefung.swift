import Foundation

/// Entscheidet, ob die App ein Paket ausfuehren kann (kopiert aus NVAILocal, nur der Bild-Teil).
///
/// Dieselben Regeln gelten an drei Stellen: in der Suche (an den Dateinamen
/// bzw. der Schnittstelle, vor dem Download), nach dem Download (am echten
/// Ordner) und beim Rechnen (an der geladenen Schnittstelle). So kann die
/// Suche nichts anbieten, woran die App spaeter scheitert.
enum Modellpruefung {

    // MARK: - Bild-Pipelines

    struct Pipeline: Hashable {
        let fehlend: [String]
        let isXL: Bool
        /// Unet in zwei Teilen -- die Fassung, die Apple fuer iOS empfiehlt.
        let inTeilen: Bool
        var vollstaendig: Bool { fehlend.isEmpty }
    }

    /// Wertet die Pfade eines Ordners oder Archivs aus. `__MACOSX` und
    /// AppleDouble-Dateien (`._Name`) zaehlen nicht: das sind Finder-Reste,
    /// die beim Packen auf einem Mac mitrutschen.
    static func pipeline(aus pfade: [String]) -> Pipeline {
        var teile = Set<String>()
        for p in pfade {
            let komponenten = p.split(separator: "/").map(String.init)
            if komponenten.contains("__MACOSX") { continue }
            for k in komponenten {
                if k.hasPrefix("._") { break }
                if k.hasSuffix(".mlmodelc") || k == "vocab.json" || k == "merges.txt" {
                    teile.insert(k)
                }
            }
        }
        var fehlend: [String] = []
        if !teile.contains("TextEncoder.mlmodelc") { fehlend.append("TextEncoder") }
        let ganz = teile.contains("Unet.mlmodelc")
        let geteilt = teile.contains("UnetChunk1.mlmodelc") && teile.contains("UnetChunk2.mlmodelc")
        if !ganz && !geteilt { fehlend.append("Unet") }
        if !teile.contains("VAEDecoder.mlmodelc") { fehlend.append("VAEDecoder") }
        if !teile.contains("vocab.json") || !teile.contains("merges.txt") {
            fehlend.append("Tokenizer")
        }
        return Pipeline(fehlend: fehlend, isXL: teile.contains("TextEncoder2.mlmodelc"),
                        inTeilen: geteilt)
    }

    /// Namen, an denen man Pakete erkennt, die die Text-zu-Bild-Pipeline nicht
    /// ausfuehren kann: Zusatznetze, Inpainting (braucht Maske und Startbild),
    /// InstructPix2Pix (braucht ein Startbild), einzeln gepackte Bausteine
    /// (`Unet.mlmodelc.zip`) und gezippte `.mlpackage`/`.mlperf`-Dateien.
    static func keineBildPipeline(_ pfad: String) -> Bool {
        let n = pfad.lowercased()
        return ["controlnet", "safetychecker", "safety_checker", "inpaint", "pix2pix",
                "scripts.zip", ".mlmodelc.zip", ".mlpackage", ".mlperf"].contains { n.contains($0) }
    }
}
