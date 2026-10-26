import Foundation

/// LoRAs für FLUX.2 Klein 4B (seit 0.4.7): kleine Zusatzgewichte für einen Stil oder eine Aufgabe, wie unter
/// Windows über `loras=[{"model_id": …, "strength": …}]` beim Generieren. Das Paket flux-2-swift-mlx verrechnet
/// sie beim Laden mit dem Transformer (auch in 4 Bit: entquantisieren, addieren, neu quantisieren); eine andere
/// Auswahl lädt den Transformer deshalb neu. Die Auslösewörter gehören in den Prompt.
///
/// Ausgewählt nach Downloads auf Hugging Face (Stand 25.10.2026), alle Apache-2.0 und für FLUX.2 Klein 4B
/// trainiert.
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

    static let family = "flux2-klein-4b"

    var name: String { t(nameDE, nameEN) }
    var description: String { t(descriptionDE, descriptionEN) }
    var license: String { "Apache-2.0" }
    var sizeMB: Double { Double(bytes) / 1_000_000 }

    var localURL: URL {
        Settings.modelsDirectory.appendingPathComponent("loras").appendingPathComponent(repo).appendingPathComponent(file)
    }

    var installed: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? Int64 ?? 0
        return Double(size) >= Double(bytes) * 0.95
    }

    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = try await Downloader().lade(url) { stand in
            progress(stand.anteil, t("lädt \(file)", "downloading \(file)"))
        }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tmp, to: localURL)
    }

    func delete() {
        try? FileManager.default.removeItem(at: localURL)
    }

    /// Wie `ModelInfo` einer LoRA unter Windows (Art „lora“, Basis in `family`, Auslöser in `trigger`).
    var info: [String: Any] {
        let ok = installed
        return [
            "id": id, "name": name, "kind": "lora", "family": Self.family, "workflow": "",
            "files": [["repo": repo, "file": file, "target": "loras", "installed": ok, "local_path": localURL.path,
                       "size_gb": (sizeMB / 10).rounded() / 100]],
            "size_gb": (sizeMB / 10).rounded() / 100, "vram_gb": 0, "license": license, "commercial_ok": true,
            "warning": "", "best_for": description, "description": description, "pros": [String](), "cons": [String](),
            "installed": ok, "partially_installed": false, "disk_gb": ok ? (sizeMB / 10).rounded() / 100 : 0,
            "runnable": ok, "favorite": false, "fits_vram": "ja", "engine": "mlx", "trigger": trigger,
            "features": ["strength": strength, "use": use, "recommended_for": [Self.family]] as [String: Any],
        ]
    }
}

/// Eine gewählte LoRA mit Stärke (aus `loras` im Auftrag).
struct LoRAChoice: Sendable, Equatable, Hashable {
    var id: String
    var strength: Double
}

enum LoRACatalog {
    static let all: [LoRAModel] = [
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

    static func find(_ id: String?) -> LoRAModel? { all.first { $0.id == id } }
    static var installed: [LoRAModel] { all.filter(\.installed) }
}
