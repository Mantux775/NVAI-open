import Foundation

/// LoRAs für FLUX.2 Klein 4B (seit 0.4.7): kleine Zusatzgewichte für einen Stil oder eine Aufgabe, wie unter
/// Windows über `loras=[{"model_id": …, "strength": …}]` beim Generieren. Das Paket flux-2-swift-mlx verrechnet
/// sie beim Laden mit dem Transformer (auch in 4 Bit: entquantisieren, addieren, neu quantisieren); eine andere
/// Auswahl lädt den Transformer deshalb neu. Die Auslösewörter gehören in den Prompt.
///
/// Der feste Katalog ist nach Downloads auf Hugging Face ausgewählt (Stand 25.10.2026), alle Apache-2.0 und für
/// FLUX.2 Klein 4B trainiert. Seit 0.5.5 kommen eigene Dateien dazu (`uploaded`, etwa selbst trainiert), abgelegt
/// direkt im Ordner loras/ und eingetragen in `UserLoRACatalog`.
struct LoRAModel: Identifiable, Sendable, Equatable {
    let id: String
    let nameDE: String
    let nameEN: String
    let repo: String
    let file: String
    let bytes: Int64
    let trigger: String
    let strength: Double
    /// "style": wirkt beim Erzeugen; "edit": braucht ein Bild als Referenz (Bearbeiten).
    let use: String
    let descriptionDE: String
    let descriptionEN: String
    /// LoRA-Basis (`family` im Vertrag): unter welchen Modellen sie erscheint. Der feste Katalog ist ganz FLUX.2 Klein 4B.
    var base: String = LoRAModel.family
    /// Vom Rechner hinzugefügt (seit 0.5.5): liegt als loras/<file>, lässt sich nicht herunterladen.
    var uploaded = false
    var sha256 = ""
    var added = ""

    static let family = "flux2-klein-4b"

    var name: String { t(nameDE, nameEN) }
    var description: String {
        guard uploaded else { return t(descriptionDE, descriptionEN) }
        return t("Vom Rechner hinzugefügt: \(file). Für Ergebnisse gilt die Lizenz des Grundmodells; stammt die Datei aus "
                 + "dem Netz, auch die Lizenz von dort.",
                 "Added from this computer: \(file). Results fall under the license of the base model; if the file comes "
                 + "from the web, also under its license there.")
    }
    var license: String { uploaded ? t("eigene Datei", "own file") : "Apache-2.0" }
    var sizeMB: Double { Double(bytes) / 1_000_000 }
    var baseLabel: String { LoRAFiles.label(base) }

    var localURL: URL {
        let folder = LoRAFiles.directory
        return uploaded ? folder.appendingPathComponent(file) : folder.appendingPathComponent(repo).appendingPathComponent(file)
    }

    var installed: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? Int64 ?? 0
        return uploaded ? size == bytes : Double(size) >= Double(bytes) * 0.95
    }

    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !uploaded else { throw LoRAUploads.notDownloadable() }
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = try await Downloader().lade(url) { stand in
            progress(stand.anteil, t("lädt \(file)", "downloading \(file)"))
        }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tmp, to: localURL)
    }

    /// Datei löschen; eine eigene LoRA verschwindet dabei ganz aus der Liste (neu laden lässt sie sich nicht).
    func delete() {
        try? FileManager.default.removeItem(at: localURL)
        if uploaded { UserLoRACatalog.remove(id) }
    }

    /// Wie `ModelInfo` einer LoRA unter Windows (Art „lora“, Basis in `family`, Auslöser in `trigger`; seit 0.5.5
    /// `custom`, `uploaded` und `expert` wie unter Windows 0.5.24).
    var info: [String: Any] {
        let ok = installed
        let gb = (sizeMB / 10).rounded() / 100
        var out: [String: Any] = [
            "id": id, "name": name, "kind": "lora", "family": base, "workflow": "",
            "files": [["repo": uploaded ? LoRAUploads.uploadRepo : repo, "file": file, "target": "loras", "installed": ok,
                       "local_path": localURL.path, "size_gb": gb]],
            "size_gb": gb, "vram_gb": 0, "license": license, "commercial_ok": true,
            "warning": "", "best_for": description, "description": description, "pros": [String](), "cons": [String](),
            "installed": ok, "partially_installed": false, "disk_gb": ok ? gb : 0,
            "runnable": ok, "favorite": false, "fits_vram": "ja", "engine": "mlx", "trigger": trigger,
            "features": ["strength": strength, "use": use, "recommended_for": [base]] as [String: Any],
            "custom": uploaded, "uploaded": uploaded, "expert": "", "source_url": "",
        ]
        if uploaded {
            out["best_for"] = t("Eigene LoRA für \(baseLabel)", "Own LoRA for \(baseLabel)")
            out["cons"] = [t("Nicht von NVAI-open getestet", "Not tested by NVAI-open")]
            out["features"] = ["strength": strength, "use": use] as [String: Any]
        }
        return out
    }
}

/// Eine gewählte LoRA mit Stärke (aus `loras` im Auftrag).
struct LoRAChoice: Sendable, Equatable, Hashable {
    var id: String
    var strength: Double
}

enum LoRACatalog {
    static let fixed: [LoRAModel] = [
        LoRAModel(
            id: "lora-flux2k-pixel-art", nameDE: "Pixel-Art (Limbicnation)", nameEN: "Pixel art (Limbicnation)",
            repo: "Limbicnation/pixel-art-lora", file: "pytorch_lora_weights.safetensors", bytes: 325_300_000,
            trigger: "pixel art sprite", strength: 1.0, use: "style",
            descriptionDE: "Pixel-Art-Sprites für Spiele: klare Pixel, begrenzte Farben. Prompt mit „pixel art sprite“ beginnen.",
            descriptionEN: "Pixel art sprites for games: crisp pixels, limited colors. Start the prompt with \"pixel art sprite\"."),
        LoRAModel(
            id: "lora-flux2k-spritesheet", nameDE: "Sprite-Sheet 2 × 2 (xocialize)", nameEN: "Sprite sheet 2 × 2 (xocialize)",
            repo: "xocialize/spritesheet-FLUX.2-klein-4B-lora", file: "flux-spritesheet-lora.safetensors", bytes: 76_000_000,
            trigger: "2x2 sprite sheet", strength: 1.0, use: "style",
            descriptionDE: "Vier Ansichten oder Posen einer Figur in einem 2 × 2-Raster, etwa für Animationen. Auslöser „2x2 sprite sheet“.",
            descriptionEN: "Four views or poses of one character in a 2 × 2 grid, e.g. for animation. Trigger \"2x2 sprite sheet\"."),
        LoRAModel(
            id: "lora-flux2k-background-remove", nameDE: "Hintergrund entfernen (xocialize)",
            nameEN: "Remove background (xocialize)",
            repo: "xocialize/background-remove-FLUX.2-klein-4B-lora", file: "flux-background-remove-lora.safetensors",
            bytes: 76_000_000, trigger: "Remove the background from the image", strength: 1.0, use: "edit",
            descriptionDE: "Bearbeiten: stellt das Motiv eines Referenzbildes frei. Bild als Referenz wählen, Prompt „Remove the "
                + "background from the image“.",
            descriptionEN: "Editing: cuts out the subject of a reference image. Pick the image as a reference, prompt \"Remove "
                + "the background from the image\"."),
        LoRAModel(
            id: "lora-flux2k-anime", nameDE: "Anime-Stil (Sawata97)", nameEN: "Anime style (Sawata97)",
            repo: "Sawata97/flux2_4b_koni_animestyle", file: "Flux_klein_4b_anime_Koni.safetensors", bytes: 184_800_000,
            trigger: "anime_style", strength: 1.0, use: "style",
            descriptionDE: "Anime-Zeichenstil für Figuren und Szenen. Auslöser „anime_style“.",
            descriptionEN: "Anime drawing style for characters and scenes. Trigger \"anime_style\"."),
        LoRAModel(
            id: "lora-flux2k-consistent-edit", nameDE: "Gleichbleibend bearbeiten (xocialize)",
            nameEN: "Consistent editing (xocialize)",
            repo: "xocialize/consistence-edit-FLUX.2-klein-4B-lora", file: "f2k_4B_consist_20260314.safetensors",
            bytes: 385_400_000, trigger: "", strength: 1.0, use: "edit",
            descriptionDE: "Bearbeiten mit Referenzbild: hält Gesicht, Kleidung und Aufbau näher am Vorbild, wenn sich nur ein Teil ändern soll.",
            descriptionEN: "Editing with a reference image: keeps face, clothing and layout closer to the source when only one part should change."),
    ]

    /// Fester Katalog und eigene Dateien (seit 0.5.5).
    static var all: [LoRAModel] { fixed + UserLoRACatalog.models }

    static func find(_ id: String?) -> LoRAModel? { all.first { $0.id == id } }
    static var installed: [LoRAModel] { all.filter(\.installed) }
    static func isFixed(_ id: String) -> Bool { fixed.contains { $0.id == id } }
}
