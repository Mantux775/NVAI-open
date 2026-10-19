import Foundation

/// Sucht Core-ML-Bildmodelle auf Hugging Face und prüft, ob NV-AI sie ausführen kann.
///
/// Übernommen aus ios/NVAILocal (HuggingFace.swift), auf Bildmodelle beschränkt.
/// Die API ist öffentlich: `/api/models` sucht (mit `expand[]=siblings` samt Dateiliste),
/// `/api/models/<id>/tree` listet die Dateien mit Größe. Repos liegen als ZIP mit der
/// kompilierten Pipeline oder als loser `compiled`-Ordner vor – beides funktioniert.
enum HuggingFace {

    struct Datei: Hashable, Codable {
        let pfad: String
        let bytes: Int64
    }

    struct Treffer: Identifiable, Hashable {
        let id: String                 // z. B. "apple/coreml-stable-diffusion-v1-5-palettized"
        let downloads: Int
        let likes: Int
        /// Grobe Einordnung allein aus den Dateinamen. Genau geprüft wird beim Öffnen.
        let angebote: [Angebot]
        var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        var autor: String { id.split(separator: "/").first.map(String.init) ?? "" }
    }

    /// Eine Einheit, die sich als Modell laden lässt.
    struct Angebot: Identifiable, Hashable {
        enum Form: Hashable {
            case zip(String)            // Pfad des Archivs
            case ordner(String)         // loser compiled-Ordner einer Pipeline
        }
        enum Stand: Hashable {
            case ungeprueft
            case lauffaehig(String)
            case nicht(String)
        }

        let repo: String
        let form: Form
        var isXL = false
        var dateien: [Datei] = []      // was tatsächlich geladen wird
        var stand: Stand = .ungeprueft
        /// Auflösung aus dem Namen (512, 768, 1024), sonst geschätzt.
        var aufloesung: Int {
            let n = (repo + "/" + ordner).lowercased()
            if n.contains("768") { return 768 }
            if isXL || n.contains("xl") || n.contains("1024") { return 1024 }
            return 512
        }

        var id: String { repo + "|" + ordner }

        var ordner: String {
            switch form {
            case .zip(let p): return p
            case .ordner(let p): return p
            }
        }

        var titel: String {
            switch form {
            case .zip(let p):
                return (p as NSString).lastPathComponent
                    .replacingOccurrences(of: ".zip", with: "", options: .caseInsensitive)
            case .ordner(let p):
                return p.isEmpty ? t("Hauptordner", "root folder") : p
            }
        }

        var groesseBytes: Int64 { dateien.reduce(0) { $0 + $1.bytes } }
        var groesseGb: Double { (Double(groesseBytes) / 1_073_741_824 * 100).rounded() / 100 }

        /// Faustregel: geladen braucht eine Pipeline knapp das Doppelte des Pakets.
        var bedarfGb: Double { max(0.5, (groesseGb * 1.8 * 10).rounded() / 10) }

        /// `split_einsum` rechnet auf der Neural Engine, `original` auf der GPU.
        var nutztGPU: Bool {
            let n = (repo + "/" + ordner).lowercased()
            if n.contains("split_einsum") || n.contains("split-einsum") || n.contains("-ios") || n.contains("_ios") {
                return false
            }
            return n.contains("original") || isXL
        }

        var istLauffaehig: Bool {
            if case .lauffaehig = stand { return true }
            return false
        }
    }

    // MARK: - Suche

    static func suche(_ text: String) async throws -> [Treffer] {
        let frage = text.trimmingCharacters(in: .whitespaces)
        // Bewusst ohne Tag-Filter: viele Pipelines (pcuenq, Guernika, …) tragen kein coreml-Tag.
        // Ob etwas ladbar ist, entscheiden die Dateien.
        var q: [URLQueryItem] = [.init(name: "search", value: frage.isEmpty ? "coreml-stable-diffusion" : frage)]
        if !frage.isEmpty && !frage.lowercased().contains("coreml") {
            q = [.init(name: "search", value: frage)]
        }
        let treffer = try await suchanfrage(q)
        return treffer.filter { !$0.angebote.isEmpty }.sorted { $0.downloads > $1.downloads }
    }

    private static func suchanfrage(_ zusatz: [URLQueryItem]) async throws -> [Treffer] {
        var teile = URLComponents(string: "https://huggingface.co/api/models")!
        teile.queryItems = zusatz + [
            .init(name: "limit", value: "50"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "expand[]", value: "siblings"),
            .init(name: "expand[]", value: "downloads"),
            .init(name: "expand[]", value: "likes"),
        ]
        let (daten, antwort) = try await URLSession.shared.data(from: teile.url!)
        try pruefeAntwort(antwort)
        let roh = try JSONSerialization.jsonObject(with: daten) as? [[String: Any]] ?? []
        return roh.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            let pfade = (e["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String }
            return Treffer(id: id, downloads: e["downloads"] as? Int ?? 0, likes: e["likes"] as? Int ?? 0,
                           angebote: angebote(repo: id, pfade: pfade))
        }
    }

    // MARK: - Dateien eines Repos

    /// Alle Dateien eines Repos oder Unterordners, mit Größe. Lange Listen kommen seitenweise.
    static func dateien(in repo: String, unter ordner: String = "") async throws -> [Datei] {
        var pfad = "https://huggingface.co/api/models/\(repo)/tree/main"
        if !ordner.isEmpty { pfad += "/" + kodiere(ordner) }
        var naechste: URL? = URL(string: pfad + "?recursive=true")
        var ergebnis: [Datei] = []
        while let url = naechste {
            let (daten, antwort) = try await URLSession.shared.data(from: url)
            try pruefeAntwort(antwort)
            let roh = try JSONSerialization.jsonObject(with: daten) as? [[String: Any]] ?? []
            for e in roh where e["type"] as? String == "file" {
                guard let p = e["path"] as? String else { continue }
                let lfs = e["lfs"] as? [String: Any]
                let bytes = (lfs?["size"] as? NSNumber)?.int64Value ?? (e["size"] as? NSNumber)?.int64Value ?? 0
                ergebnis.append(Datei(pfad: p, bytes: bytes))
            }
            naechste = nil
            if let link = (antwort as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"),
               link.contains("rel=\"next\""),
               let a = link.firstIndex(of: "<"), let b = link.firstIndex(of: ">"), a < b {
                naechste = URL(string: String(link[link.index(after: a) ..< b]))
            }
        }
        return ergebnis
    }

    static func dateiURL(_ repo: String, _ pfad: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(kodiere(pfad))")!
    }

    /// Pfade können Leerzeichen enthalten. Jede Komponente einzeln kodieren.
    private static func kodiere(_ pfad: String) -> String {
        pfad.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed
                .subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
        }.joined(separator: "/")
    }

    private static func pruefeAntwort(_ a: URLResponse) throws {
        guard let h = a as? HTTPURLResponse else { return }
        guard (200..<300).contains(h.statusCode) else {
            throw Fehler(text: h.statusCode == 429
                         ? t("Hugging Face drosselt gerade die Anfragen. Bitte kurz warten.",
                             "Hugging Face is rate-limiting requests. Please wait a moment.")
                         : t("Hugging Face antwortet mit Fehler \(h.statusCode).",
                             "Hugging Face answered with error \(h.statusCode)."))
        }
    }

    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // MARK: - Einordnen

    /// Was in einem Repo als Bildmodell infrage kommt – nur nach Dateinamen.
    static func angebote(repo: String, pfade: [String]) -> [Angebot] {
        var ergebnis: [Angebot] = []
        // 1. Archive mit fertiger Pipeline, auch in Unterordnern.
        for p in pfade where p.lowercased().hasSuffix(".zip") && !Modellpruefung.keineBildPipeline(p) {
            ergebnis.append(Angebot(repo: repo, form: .zip(p)))
        }
        // 2. Lose compiled-Ordner: ein Verzeichnis mit allen Teilen einer Pipeline.
        var ordner: [String: [String]] = [:]
        for p in pfade {
            let teil: String
            if let r = p.range(of: ".mlmodelc/") {
                teil = String(p[..<r.lowerBound]) + ".mlmodelc"
            } else if p.hasSuffix("vocab.json") || p.hasSuffix("merges.txt") {
                teil = p
            } else {
                continue
            }
            ordner[(teil as NSString).deletingLastPathComponent, default: []].append(teil)
        }
        for (dir, teile) in ordner.sorted(by: { $0.key < $1.key }) where !Modellpruefung.keineBildPipeline(dir) {
            let befund = Modellpruefung.pipeline(aus: teile)
            guard befund.vollstaendig else { continue }
            var a = Angebot(repo: repo, form: .ordner(dir))
            a.isXL = befund.isXL
            ergebnis.append(a)
        }
        return ergebnis
    }

    // MARK: - Prüfen

    /// Prüft ein Angebot gegen die echten Dateien: bei Archiven das Inhaltsverzeichnis
    /// (per Range-Anfrage, ohne Download), bei Ordnern die Dateiliste.
    static func pruefe(_ roh: Angebot, baum: [Datei]?) async -> Angebot {
        var a = roh
        do {
            switch a.form {
            case .zip(let p):
                if let baum {
                    guard let datei = baum.first(where: { $0.pfad == p }) else {
                        a.stand = .nicht(t("Archiv nicht mehr vorhanden.", "The archive is no longer available."))
                        return a
                    }
                    a.dateien = [datei]
                }
                let namen = try await ZipInhalt.namen(von: dateiURL(a.repo, p))
                if namen.contains(where: { $0.contains(".mlpackage/") }) && !namen.contains(where: { $0.contains(".mlmodelc/") }) {
                    a.stand = .nicht(t("Enthält unkompilierte Core-ML-Pakete statt einer Bild-Pipeline.",
                                       "Contains uncompiled Core ML packages instead of an image pipeline."))
                    return a
                }
                let befund = Modellpruefung.pipeline(aus: namen)
                a.isXL = befund.isXL
                a.stand = befund.vollstaendig
                    ? .lauffaehig(pipelineText(befund))
                    : .nicht(t("Im Archiv fehlt: ", "Missing in the archive: ") + befund.fehlend.joined(separator: ", ") + ".")
            case .ordner(let dir):
                guard let baum else {
                    a.stand = .lauffaehig(t("SD-Pipeline · vollständig", "SD pipeline · complete"))
                    return a
                }
                a.dateien = ladeliste(baum, ordner: dir)
                let befund = Modellpruefung.pipeline(aus: a.dateien.map(\.pfad))
                a.isXL = befund.isXL
                a.stand = befund.vollstaendig
                    ? .lauffaehig(pipelineText(befund) + t(" · \(a.dateien.count) Dateien", " · \(a.dateien.count) files"))
                    : .nicht(t("Es fehlt: ", "Missing: ") + befund.fehlend.joined(separator: ", ") + ".")
            }
        } catch {
            a.stand = .nicht(t("Prüfung fehlgeschlagen: ", "Check failed: ") + error.localizedDescription)
        }
        return a
    }

    private static func pipelineText(_ b: Modellpruefung.Pipeline) -> String {
        var teile = [b.isXL ? t("SDXL-Pipeline", "SDXL pipeline") : t("SD-Pipeline", "SD pipeline"),
                     t("vollständig", "complete")]
        if b.inTeilen { teile.append(t("Unet geteilt", "split Unet")) }
        return teile.joined(separator: " · ")
    }

    /// Welche Dateien eines Ordners tatsächlich geladen werden. Apples Ordner enthalten die
    /// Unet doppelt (ganz und in zwei Teilen); die Pipeline nimmt die Teile, sobald es sie gibt.
    /// Anders als auf dem iPhone bleibt der VAE-Encoder dabei: der Mac braucht ihn für Bild-zu-Bild.
    static func ladeliste(_ baum: [Datei], ordner dir: String) -> [Datei] {
        let praefix = dir.isEmpty ? "" : dir + "/"
        let imOrdner = baum.filter { d in
            d.pfad.hasPrefix(praefix) && !d.pfad.contains("__MACOSX")
                && !(d.pfad as NSString).lastPathComponent.hasPrefix("._")
        }
        func erste(_ d: Datei) -> String {
            let rel = d.pfad.dropFirst(praefix.count)
            return rel.split(separator: "/").first.map(String.init) ?? String(rel)
        }
        let teile = Set(imOrdner.map(erste))
        let geteilt = teile.contains("UnetChunk1.mlmodelc") && teile.contains("UnetChunk2.mlmodelc")
        let weg: Set<String> = ["UnetRefiner.mlmodelc", "ControlledUnet.mlmodelc"]
        return imOrdner.filter { d in
            let e = erste(d)
            guard e.hasSuffix(".mlmodelc") || e == "vocab.json" || e == "merges.txt" else { return false }
            if geteilt && e == "Unet.mlmodelc" { return false }
            return !weg.contains(e)
        }
    }
}
