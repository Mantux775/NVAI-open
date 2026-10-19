import Foundation

/// Woher die Dateien eines Core-ML-Modells kommen.
enum CoreMLQuelle: Hashable, Codable {
    /// Ein ZIP mit fertig kompilierten Ressourcen.
    case zip(URL)
    /// Lose Dateien eines Hugging-Face-Repos: alles unterhalb dieses Ordners.
    case ordner(repo: String, pfad: String)

    var schluessel: String {
        switch self {
        case .zip(let url): return url.absoluteString
        case .ordner(let repo, let pfad): return repo + ":" + pfad
        }
    }
}

/// Ein Stable-Diffusion-Modell als fertig konvertierte Core-ML-Pipeline (wie in NVAILocal).
/// Läuft auch auf Macs mit 8 GB; die Bilder bleiben unter FLUX.2 Klein.
struct CoreMLModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let quelle: CoreMLQuelle
    /// Downloadgröße in GB.
    let sizeGb: Double
    /// Speicher, den die geladene Pipeline braucht.
    let needGb: Double
    /// Kantenlänge, auf die die Pipeline kompiliert ist (512, 768 oder 1024).
    let resolution: Int
    let isXL: Bool
    let note: String
    var license: String = "siehe Repo"
    var custom: Bool = false
    /// Englische Beschreibung (fehlt bei älteren gespeicherten Einträgen).
    var noteEN: String? = nil

    var noteText: String { Lang.current == .de ? note : (noteEN ?? note) }
    var licenseText: String { license == "siehe Repo" || license.isEmpty ? t("siehe Repo", "see repository") : license }

    var workflow: String { isXL ? "coreml_sdxl" : "coreml_sd" }

    /// `original` rechnet auf der GPU, `split_einsum` auf der Neural Engine.
    var nutztGPU: Bool {
        let n = quelle.schluessel.lowercased()
        if n.contains("split_einsum") || n.contains("split-einsum") || n.contains("split%20einsum")
            || n.contains("_ios") || n.contains("-ios") { return false }
        return n.contains("original") || isXL
    }
}

enum CoreMLCatalog {
    /// Mitgelieferte Auswahl, wie in NVAILocal (Apples Konvertierungen auf Hugging Face).
    static let builtIn: [CoreMLModel] = [
        CoreMLModel(
            id: "coreml-sd21-base", name: "Stable Diffusion 2.1 Base (Core ML)",
            quelle: .zip(URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip")!),
            sizeGb: 1.06, needGb: 2.2, resolution: 512, isXL: false,
            note: "Kleinstes Paket, läuft auf jedem Mac. Für Skizzen und Tests.",
            license: "CreativeML Open RAIL++-M",
            noteEN: "Smallest package, runs on every Mac. For sketches and tests."),
        CoreMLModel(
            id: "coreml-sd15", name: "Stable Diffusion 1.5 (Core ML)",
            quelle: .zip(URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized/resolve/main/coreml-stable-diffusion-v1-5-palettized_split_einsum_v2_compiled.zip")!),
            sizeGb: 1.46, needGb: 2.6, resolution: 512, isXL: false,
            note: "Größtes Ökosystem an Prompt-Wissen und Stilen.",
            license: "CreativeML Open RAIL-M",
            noteEN: "Largest ecosystem of prompt know-how and styles."),
        CoreMLModel(
            id: "coreml-sdxl-mixed-bit", name: "SDXL Base (Core ML, mixed-bit)",
            quelle: .zip(URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization/resolve/main/coreml-stable-diffusion-mixed-bit-palettization_original_compiled.zip")!),
            sizeGb: 6.25, needGb: 9.0, resolution: 1024, isXL: true,
            note: "SDXL für die GPU des Macs, fein quantisiert (4,5 Bit). Ab 16 GB.",
            license: "CreativeML Open RAIL++-M",
            noteEN: "SDXL for the Mac GPU, finely quantized (4.5-bit). 16 GB or more."),
    ]

    static var all: [CoreMLModel] { builtIn + UserCoreMLCatalog.load() }

    static func model(_ id: String?) -> CoreMLModel? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // MARK: Ablage

    /// <Modellordner>/coreml/<id> – neben den FLUX.2-Dateien, die unter <Organisation>/<Repo> liegen.
    static var root: URL {
        Settings.modelsDirectory.appendingPathComponent("coreml", isDirectory: true)
    }

    static func location(_ m: CoreMLModel) -> URL { root.appendingPathComponent(m.id, isDirectory: true) }

    /// Merkzettel im fertigen Ordner: hier ist eine Installation vollständig.
    static let marker = "nvai-fertig.json"

    static func isInstalled(_ m: CoreMLModel) -> Bool {
        FileManager.default.fileExists(atPath: location(m).appendingPathComponent(marker).path)
    }

    /// Wo die Pipeline ihre Ressourcen erwartet: das Verzeichnis mit der Unet.
    static func resources(_ m: CoreMLModel) -> URL? { ressourcen(in: location(m)) }

    static func ressourcen(in base: URL) -> URL? {
        guard let alle = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in alle {
            let name = url.lastPathComponent
            if name == "__MACOSX" { alle.skipDescendants(); continue }
            if name == "Unet.mlmodelc" || name == "UnetChunk1.mlmodelc" { return url.deletingLastPathComponent() }
            if name.hasSuffix(".mlmodelc") { alle.skipDescendants() }
        }
        return nil
    }

    /// Bild-zu-Bild braucht den VAE-Encoder; nicht jedes Paket bringt ihn mit.
    static func hasEncoder(_ m: CoreMLModel) -> Bool {
        guard let dir = resources(m) else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("VAEEncoder.mlmodelc").path)
    }

    static func fits(_ m: CoreMLModel) -> String {
        let budget = Double(SystemInfo.memoryGB) - 3
        if m.needGb <= budget - 1 { return "ja" }
        if m.needGb <= budget { return "knapp" }
        return "nein"
    }

    // MARK: Vertrag

    static var promptHint: String {
        t("Stichworte und kurze Wendungen, durch Kommas getrennt, wichtigstes zuerst (Stable Diffusion liest "
            + "nur die ersten 77 Tokens). Der negative Prompt wirkt. Das Format ist fest: das Bild entsteht "
            + "quadratisch und wird auf die gewünschte Größe gebracht.",
          "Keywords and short phrases, separated by commas, most important first (Stable Diffusion only reads "
            + "the first 77 tokens). The negative prompt works. The size is fixed: the image is rendered square "
            + "and then scaled to the requested size.")
    }

    static func features(_ m: CoreMLModel) -> [String: Any] {
        let steps = m.isXL ? 30 : 25
        return [
            "steps": steps, "cfg": m.isXL ? 6.0 : 7.5,
            "negative_prompt": true,
            "default_negative": "blurry, low quality, watermark, text",
            "upsampler": false, "references": 0, "bbox": false,
            "img2img": isInstalled(m) ? hasEncoder(m) : true,
            "mask": false, "hires": false, "text_rendering": false,
            "sizes": [["label": t("\(m.resolution) × \(m.resolution): natives Format", "\(m.resolution) × \(m.resolution): native size"),
                       "w": m.resolution, "h": m.resolution]],
            "fixed_size": m.resolution,
            "prompt_hint": promptHint,
            "placeholder": "weathered wooden ammunition crate, stenciled letters, rope handles, studio photo, plain grey background",
        ]
    }

    static func info(_ m: CoreMLModel) -> [String: Any] {
        let installed = isInstalled(m)
        let file: [String: Any]
        switch m.quelle {
        case .zip(let url):
            file = ["repo": url.pathComponents.dropFirst().prefix(2).joined(separator: "/"),
                    "file": url.lastPathComponent, "target": "coreml", "installed": installed,
                    "local_path": location(m).path, "size_gb": m.sizeGb]
        case .ordner(let repo, let pfad):
            file = ["repo": repo, "file": pfad.isEmpty ? t("(Hauptordner)", "(root folder)") : pfad, "target": "coreml",
                    "installed": installed, "local_path": location(m).path, "size_gb": m.sizeGb]
        }
        let warning = fits(m) == "nein"
            ? t("Braucht rund \(Int(m.needGb.rounded())) GB Arbeitsspeicher, dieser Mac hat \(SystemInfo.memoryGB) GB.",
                "Needs about \(Int(m.needGb.rounded())) GB of memory; this Mac has \(SystemInfo.memoryGB) GB.") : ""
        return [
            "id": m.id, "name": m.name, "kind": "image", "family": m.isXL ? "sdxl" : "sd", "workflow": m.workflow,
            "files": [file], "size_gb": m.sizeGb, "vram_gb": m.needGb,
            "license": m.licenseText, "commercial_ok": !m.custom,
            "warning": warning,
            "best_for": m.isXL ? t("SDXL-Stile, mittlere Macs", "SDXL styles, mid-size Macs")
                               : t("kleine Macs, schnelle Entwürfe", "small Macs, quick drafts"),
            "description": m.noteText, "pros": [String](),
            "cons": [t("Festes Format \(m.resolution) × \(m.resolution)", "Fixed size \(m.resolution) × \(m.resolution)"),
                     t("Keine Masken", "No masks")],
            "installed": installed, "partially_installed": false, "disk_gb": installed ? m.sizeGb : 0,
            "runnable": installed, "favorite": false, "fits_vram": fits(m),
            "features": features(m), "engine": "coreml", "custom": m.custom,
        ]
    }
}

/// Selbst hinzugefügte Core-ML-Modelle (aus der Suche), als JSON neben den Einstellungen.
enum UserCoreMLCatalog {
    private static var file: URL { Settings.appSupport.appendingPathComponent("coreml-modelle.json") }
    private static let lock = NSLock()

    static func load() -> [CoreMLModel] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([CoreMLModel].self, from: data)) ?? []
    }

    static func add(_ m: CoreMLModel) {
        var list = load().filter { $0.id != m.id }
        list.append(m)
        save(list)
    }

    static func remove(_ id: String) {
        save(load().filter { $0.id != id })
    }

    private static func save(_ list: [CoreMLModel]) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: Settings.appSupport, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }

    /// Aus einem geprüften Treffer der Suche.
    static func model(from a: HuggingFace.Angebot) -> CoreMLModel {
        let slug = (a.repo + "-" + a.titel).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let id = "coreml-" + String(slug).split(separator: "-").joined(separator: "-").prefix(60)
        let quelle: CoreMLQuelle
        switch a.form {
        case .zip(let p): quelle = .zip(HuggingFace.dateiURL(a.repo, p))
        case .ordner(let p): quelle = .ordner(repo: a.repo, pfad: p)
        }
        return CoreMLModel(id: id, name: "\(a.repo.split(separator: "/").last.map(String.init) ?? a.repo) · \(a.titel)",
                           quelle: quelle, sizeGb: a.groesseGb, needGb: a.bedarfGb, resolution: a.aufloesung,
                           isXL: a.isXL, note: "Aus der Suche hinzugefügt: \(a.repo). Lizenz im Repo prüfen.",
                           license: "siehe Repo", custom: true,
                           noteEN: "Added from search: \(a.repo). Check the license in the repository.")
    }
}
