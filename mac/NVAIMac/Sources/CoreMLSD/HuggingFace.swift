import Foundation

/// Sucht Modelle auf Hugging Face und prüft, ob NVAI-open sie ausführen kann: Core-ML-Bildmodelle lassen sich laden,
/// MLX-Bildmodelle und Videomodelle werden eingeordnet (läuft als Katalogmodell, nicht eingebaut, zu groß).
///
/// Übernommen aus ios/NVAILocal (HuggingFace.swift).
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
        var pipelineTag = ""
        var tags: [String] = []
        /// Für Treffer ohne Core-ML-Pipeline: ob und wie das Modell auf diesem Mac läuft.
        var einordnung: Einordnung?
        var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        var autor: String { id.split(separator: "/").first.map(String.init) ?? "" }
        var istLora: Bool { tags.contains("lora") || id.lowercased().contains("lora") }

        func eingeordnet(video: Bool) -> Treffer {
            var kopie = self
            kopie.einordnung = HuggingFace.einordnung(id: id, tags: tags, video: video)
            return kopie
        }
    }

    /// Was die Suche zeigt (Nutzerwunsch 26.10.2026: „gezielt nach Video oder Bildern suchen“).
    enum Art: String, CaseIterable, Identifiable {
        case bild = "image", video = "video"
        var id: String { rawValue }
        var titel: String { self == .bild ? t("Bilder", "Images") : t("Videos", "Videos") }
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

    /// Bilder: ladbare Core-ML-Pipelines zuerst, danach MLX-Bildmodelle mit Einordnung. Videos: Text und Bild zu
    /// Video, jeweils mit Einordnung; was auf diesem Mac läuft, zuerst.
    static func suche(_ text: String, art: Art = .bild) async throws -> [Treffer] {
        let frage = text.trimmingCharacters(in: .whitespaces)
        let mitFrage: [URLQueryItem] = frage.isEmpty ? [] : [.init(name: "search", value: frage)]
        switch art {
        case .bild:
            // Drei Anfragen: Viele Pipelines (pcuenq, Guernika, …) tragen kein coreml-Tag, deshalb die freie Suche;
            // die getaggten gehen dort aber unter den 50 meistgeladenen Treffern eines Suchworts unter („realistic“
            // fand so nichts, mit Tag 11 Pipelines). Dazu MLX-Bildmodelle, damit „flux“ oder „z-image“ etwas zeigen.
            async let getaggt = suchanfrage(mitFrage + [.init(name: "filter", value: "coreml")])
            async let frei = suchanfrage([.init(name: "search", value: frage.isEmpty ? "coreml-stable-diffusion" : frage)])
            async let mlx = suchanfrage(mitFrage + [.init(name: "filter", value: "mlx"),
                                                    .init(name: "pipeline_tag", value: "text-to-image")])
            let a = try await getaggt
            let b = try await frei
            // Das coreml-Tag tragen auch Sprach- und Textmodelle mit ZIP-Paketen (Whisper stand ganz oben): nur Repos
            // ohne Pipeline-Angabe oder mit Bild-Pipeline.
            let coreml = vereint(a + b)
                .filter { !$0.angebote.isEmpty && ["", "text-to-image", "image-to-image"].contains($0.pipelineTag) }
                .sorted { $0.downloads > $1.downloads }
            let ids = Set(coreml.map(\.id))
            // Nur Zusatz: Scheitert diese Anfrage, bleiben die Core-ML-Treffer.
            let andere = vereint((try? await mlx) ?? []).filter { !ids.contains($0.id) && $0.angebote.isEmpty && !$0.istLora }
            return coreml + andere.map { $0.eingeordnet(video: false) }.sorted { $0.downloads > $1.downloads }
        case .video:
            async let t2v = suchanfrage(mitFrage + [.init(name: "pipeline_tag", value: "text-to-video")])
            async let i2v = suchanfrage(mitFrage + [.init(name: "pipeline_tag", value: "image-to-video")])
            let a = try await t2v
            let b = try await i2v
            // LoRAs lädt der Mac nicht; sie machten bei „wan“ und „ltx“ rund ein Drittel der Treffer aus.
            return vereint(a + b).filter { !$0.istLora }.map { $0.eingeordnet(video: true) }.sorted {
                ($0.einordnung?.rang ?? 9, -$0.downloads) < ($1.einordnung?.rang ?? 9, -$1.downloads)
            }
        }
    }

    /// Doppelte Treffer aus mehreren Anfragen: der erste bleibt.
    private static func vereint(_ treffer: [Treffer]) -> [Treffer] {
        var gesehen = Set<String>()
        return treffer.filter { gesehen.insert($0.id).inserted }
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
            .init(name: "expand[]", value: "pipeline_tag"),
            .init(name: "expand[]", value: "tags"),
        ]
        let (daten, antwort) = try await URLSession.shared.data(from: teile.url!)
        try pruefeAntwort(antwort)
        let roh = try JSONSerialization.jsonObject(with: daten) as? [[String: Any]] ?? []
        return roh.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            let pfade = (e["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String }
            return Treffer(id: id, downloads: e["downloads"] as? Int ?? 0, likes: e["likes"] as? Int ?? 0,
                           angebote: angebote(repo: id, pfade: pfade),
                           pipelineTag: e["pipeline_tag"] as? String ?? "", tags: e["tags"] as? [String] ?? [])
        }
    }

    // MARK: - Einordnen ohne Core-ML-Pipeline

    /// Was ein Treffer ohne Core-ML-Pipeline für diesen Mac bedeutet, wie die Hinweise der Windows-Suche: Die Familie
    /// läuft als Katalogmodell, ist (noch) nicht eingebaut oder braucht mehr Arbeitsspeicher. Nur nach Name und Tags
    /// (die Tags nennen auch das Basismodell, so werden Quantisierungen und Ableger erkannt).
    struct Einordnung: Hashable {
        /// katalog: genau das Repo, aus dem ein Katalogmodell lädt; familie: andere Fassung derselben Familie.
        enum Stand: Hashable { case katalog, familie, nicht, zuGross }
        let stand: Stand
        let text: String
        /// Sortierung: was hier läuft, zuerst; der Rest gemeinsam nach Downloads (sonst standen die LTX-2-Modelle
        /// bei „ltx-2“ hinter allem anderen).
        var rang: Int {
            switch stand {
            case .katalog: return 0
            case .familie: return 1
            case .nicht, .zuGross: return 2
            }
        }
    }

    /// Familie eines Katalogmodells: läuft, wenn es genau dessen Repo ist, sonst nur der Hinweis auf den Katalog.
    private static func katalogFamilie(_ id: String, name: String, wo: (de: String, en: String)) -> Einordnung {
        if ModelCatalog.sourceRepos.contains(id.lowercased()) {
            return Einordnung(stand: .katalog, text: t(
                "Läuft: Aus diesem Repo lädt NVAI-open \(name), unter „Modelle“\(wo.de).",
                "Runs: NVAI-open downloads \(name) from this repository, under \"Models\"\(wo.en)."))
        }
        return Einordnung(stand: .familie, text: t(
            "Gleiche Familie wie \(name) im Katalog (unter „Modelle“\(wo.de)). Diese Fassung (andere Version, "
                + "Quantisierung oder Ableger) lädt NVAI-open für Mac nicht.",
            "Same family as \(name) in the catalog (under \"Models\"\(wo.en)). NVAI-open for Mac does not load this "
                + "version (another release, quantization or derivative)."))
    }

    static func einordnung(id: String, tags: [String], video: Bool) -> Einordnung {
        let n = ([id] + tags).joined(separator: " ").lowercased()
        func hat(_ teile: String...) -> Bool { teile.contains { n.contains($0) } }
        // LoRAs zuerst (die Suche blendet sie aus; für die Schnittstelle bleibt die Einordnung): Ihre Tags nennen das
        // Basismodell, LTX-2.3-LoRAs liefen sonst unter LTX-Video.
        if tags.contains("lora") || id.lowercased().contains("lora") {
            return Einordnung(stand: .nicht, text: t(
                "LoRA (Zusatz zu einem Modell): lädt NVAI-open für Mac aus der Suche nicht.",
                "LoRA (an add-on for a model): NVAI-open for Mac does not load it from the search."))
        }
        if hat("ltx-2", "ltx2", "ltx_2") {
            return Einordnung(stand: SystemInfo.memoryGB >= 32 ? .nicht : .zuGross, text: t(
                "LTX-2 (2.3, 2.5) mit Ton braucht ab 32 GB Arbeitsspeicher und ist in NVAI-open für Mac noch nicht "
                    + "eingebaut. Die Windows-Fassung rechnet LTX-2.5.",
                "LTX-2 (2.3, 2.5) with sound needs 32 GB of memory or more and is not built into NVAI-open for Mac "
                    + "yet. The Windows version runs LTX-2.5."))
        }
        if hat("ltx-video", "ltxv", "ltx_video") {
            if hat("13b") {
                return Einordnung(stand: .nicht, text: t(
                    "LTX-Video 13B ist in NVAI-open für Mac noch nicht eingebaut. Auf dem Mac läuft LTX-Video 2B (Katalog).",
                    "LTX-Video 13B is not built into NVAI-open for Mac yet. On the Mac, LTX-Video 2B runs (catalog)."))
            }
            return katalogFamilie(id, name: "LTX-Video 2B (0.9.8 distilled)", wo: (" bei Video", " in Video"))
        }
        if hat("wan2", "wan-2", "wan_2") {
            return Einordnung(stand: .nicht, text: hat("1.3b", "1_3b")
                ? t("Wan 2.1 1.3B ist für NVAI-open für Mac geplant, aber noch nicht eingebaut.",
                    "Wan 2.1 1.3B is planned for NVAI-open for Mac but not built in yet.")
                : t("Wan (5B, 14B) ist in NVAI-open für Mac nicht eingebaut.",
                    "Wan (5B, 14B) is not built into NVAI-open for Mac."))
        }
        if hat("qwen-image", "qwen_image") {
            return Einordnung(stand: .nicht, text: t(
                "Qwen-Image (20 Mrd. Parameter) ist in NVAI-open für Mac nicht eingebaut.",
                "Qwen-Image (20 billion parameters) is not built into NVAI-open for Mac."))
        }
        if hat("flux.2-klein", "flux-2-klein", "flux2-klein") {
            if hat("9b") {
                return Einordnung(stand: .nicht, text: t(
                    "FLUX.2 Klein 9B ist nicht im Mac-Katalog; dort steht FLUX.2 Klein 4B.",
                    "FLUX.2 Klein 9B is not in the Mac catalog; it has FLUX.2 Klein 4B."))
            }
            return katalogFamilie(id, name: "FLUX.2 Klein 4B", wo: ("", ""))
        }
        if hat("z-image", "zimage", "z_image") {
            return katalogFamilie(id, name: "Z-Image Turbo", wo: ("", ""))
        }
        if hat("flux.1", "flux-1", "flux1") {
            return Einordnung(stand: .nicht, text: t(
                "FLUX.1 ist in NVAI-open für Mac nicht eingebaut; FLUX.2 Klein steht im Katalog.",
                "FLUX.1 is not built into NVAI-open for Mac; FLUX.2 Klein is in the catalog."))
        }
        return Einordnung(stand: .nicht, text: video
            ? t("Diese Videomodell-Familie ist in NVAI-open für Mac nicht eingebaut. Auf dem Mac läuft LTX-Video 2B (Katalog).",
                "This video model family is not built into NVAI-open for Mac. On the Mac, LTX-Video 2B runs (catalog).")
            : t("Dieses Format lädt NVAI-open für Mac nicht. Aus der Suche lassen sich Core-ML-Pipelines laden "
                    + "(Stable Diffusion 1.5, 2 und XL).",
                "NVAI-open for Mac cannot load this format. From the search it loads Core ML pipelines "
                    + "(Stable Diffusion 1.5, 2 and XL)."))
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
