import Foundation
import ZIPFoundation

/// Lädt ein Core-ML-Modell herunter, entpackt es und prüft es – wie ModelStore in NVAILocal.
///
/// Geladen wird in einen Arbeitsordner `<id>.laden`, der erst nach bestandener Prüfung an
/// seinen Platz rückt. Ein abgebrochener Download kann so nie als „installiert“ erscheinen.
enum CoreMLInstaller {
    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static func install(_ model: CoreMLModel, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let fm = FileManager.default
        let ziel = CoreMLCatalog.location(model)
        let arbeit = CoreMLCatalog.root.appendingPathComponent(model.id + ".laden", isDirectory: true)
        try? fm.removeItem(at: arbeit)
        try fm.createDirectory(at: arbeit, withIntermediateDirectories: true)
        do {
            switch model.quelle {
            case .zip(let url):
                progress(0, t("verbindet", "connecting"))
                let zip = try await Downloader().lade(url) { stand in
                    progress(stand.anteil * 0.85, text(stand.geladen, stand.gesamt))
                }
                progress(0.86, t("entpackt", "unpacking"))
                defer { try? fm.removeItem(at: zip) }
                try fm.unzipItem(at: zip, to: arbeit)
            case .ordner(let repo, let pfad):
                progress(0, t("liest Dateiliste", "reading file list"))
                let baum = try await HuggingFace.dateien(in: repo, unter: pfad)
                let liste = HuggingFace.ladeliste(baum, ordner: pfad)
                guard !liste.isEmpty else {
                    throw Fehler(text: t("Im Repo liegen keine passenden Dateien mehr.", "The repository no longer contains matching files."))
                }
                let gesamt = max(1, liste.reduce(Int64(0)) { $0 + $1.bytes })
                var fertig: Int64 = 0
                let eltern = (pfad as NSString).deletingLastPathComponent
                for (nr, d) in liste.enumerated() {
                    try Task.checkCancellation()
                    let rel = eltern.isEmpty ? d.pfad : String(d.pfad.dropFirst(eltern.count + 1))
                    let zielDatei = arbeit.appendingPathComponent(rel)
                    try fm.createDirectory(at: zielDatei.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let basis = fertig
                    let tmp = try await Downloader().lade(HuggingFace.dateiURL(repo, d.pfad)) { stand in
                        let jetzt = basis + stand.geladen
                        progress(0.9 * Double(jetzt) / Double(gesamt),
                                 text(jetzt, gesamt) + t(" · Datei \(nr + 1) von \(liste.count)", " · file \(nr + 1) of \(liste.count)"))
                    }
                    try? fm.removeItem(at: zielDatei)
                    try fm.moveItem(at: tmp, to: zielDatei)
                    fertig += d.bytes
                }
            }
            try? fm.removeItem(at: arbeit.appendingPathComponent("__MACOSX"))
            progress(0.97, t("prüft", "checking"))
            var pfade: [String] = []
            if let e = fm.enumerator(at: arbeit, includingPropertiesForKeys: nil) {
                for case let url as URL in e { pfade.append(String(url.path.dropFirst(arbeit.path.count))) }
            }
            let befund = Modellpruefung.pipeline(aus: pfade)
            guard befund.vollstaendig else {
                throw Fehler(text: t("Paket unvollständig, es fehlt: ", "Incomplete package, missing: ")
                                 + befund.fehlend.joined(separator: ", ") + ".")
            }
            try JSONEncoder().encode(["id": model.id, "version": "1"])
                .write(to: arbeit.appendingPathComponent(CoreMLCatalog.marker))
            try? fm.removeItem(at: ziel)
            try fm.moveItem(at: arbeit, to: ziel)
            progress(1, t("fertig", "done"))
        } catch {
            try? fm.removeItem(at: arbeit)
            throw error
        }
    }

    static func remove(_ model: CoreMLModel) {
        try? FileManager.default.removeItem(at: CoreMLCatalog.location(model))
    }

    private static func text(_ geladen: Int64, _ gesamt: Int64) -> String {
        let gb = Double(geladen) / 1_073_741_824
        return gesamt > 0 ? String(format: "%.2f / %.2f GB", gb, Double(gesamt) / 1_073_741_824)
                          : String(format: "%.2f GB", gb)
    }
}
