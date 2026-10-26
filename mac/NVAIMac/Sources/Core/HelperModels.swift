import Foundation
import FluxTextEncoders

/// Zusatzmodelle (seit 0.4.7): keine Bildmodelle, sondern Werkzeuge beim Restaurieren. Sie stehen unter
/// „Modelle“ in einem eigenen Abschnitt und in `GET /api/models` mit eigener Art (SeedVR2 wie unter Windows als
/// „upscale“).
enum HelperModel: String, CaseIterable, Identifiable, Sendable {
    /// Qwen3.5 4B (Alibaba, Apache-2.0) als Bild-Sprachmodell: entscheidet bei „Automatisch“, ob gründlich oder
    /// schonend restauriert wird – dieselbe Modellfamilie wie der Upsampler von FLUX 3 unter Windows (9B).
    case vision = "qwen3.5-4b-vlm"
    /// SeedVR2 3B (ByteDance, Apache-2.0) in 8 Bit: Schärfen und Vergrößern, die kleine Fassung des Windows-Modells.
    case sharpen = "seedvr2-3b-int8"

    /// Dateien von SeedVR2 (mlx-community/SeedVR2-3B-mlx-int8) mit Größe in Bytes laut Hugging Face.
    static let seedvr2Files: [(name: String, bytes: Int64)] = [
        ("config.json", 247), ("pos_emb.safetensors", 594_008), ("vae.safetensors", 501_000_000),
        ("transformer.safetensors", 4_220_000_000),
    ]

    var id: String { rawValue }

    var kind: String {
        switch self {
        case .vision: return "vlm"
        case .sharpen: return "upscale"
        }
    }

    var name: String {
        switch self {
        case .vision: return t("Qwen3.5 4B (Bild-Sprachmodell, 4 Bit)", "Qwen3.5 4B (vision language model, 4-bit)")
        case .sharpen: return t("SeedVR2 3B (8 Bit, Schärfen und Vergrößern)", "SeedVR2 3B (8-bit, sharpen and enlarge)")
        }
    }

    var repo: String {
        switch self {
        case .vision: return Qwen35Variant.qwen35_4B_4bit.repoId
        case .sharpen: return "mlx-community/SeedVR2-3B-mlx-int8"
        }
    }

    /// Download laut Hugging Face (model.safetensors 3,03 GB, Tokenizer 0,03 GB).
    var sizeGB: Double {
        switch self {
        case .vision: return 3.06
        case .sharpen: return 4.72
        }
    }

    var license: String { "Apache-2.0" }

    var family: String {
        switch self {
        case .vision: return "qwen3.5"
        case .sharpen: return "seedvr2"
        }
    }

    var bestFor: String {
        switch self {
        case .vision: return t("Foto restaurieren, „Automatisch“: wählt gründlich oder schonend",
                               "Restore photo, \"Automatic\": picks thorough or gentle")
        case .sharpen: return t("Foto restaurieren: alte Fotos schärfen, entrauschen und vergrößern",
                                "Restore photo: sharpen, denoise and enlarge old photos")
        }
    }

    var description: String {
        switch self {
        case .vision:
            return t("Qwen3.5 4B von Alibaba (Apache-2.0), ein Sprachmodell, das Bilder sieht. Beim Restaurieren mit "
                     + "„Automatisch“ fragt NVAI-open es vorher, ob das Foto über das ganze Bild beschädigt ist: dann "
                     + "gründlich, sonst schonend (bei 20 von 21 Testfotos die bessere Wahl, rund 20 s auf einem M1). Unter "
                     + "Windows entscheidet der Upsampler von FLUX 3 (Qwen3.5 9B). Ohne dieses Modell rechnet „Automatisch“ "
                     + "gründlich.",
                     "Qwen3.5 4B by Alibaba (Apache-2.0), a language model that sees images. When restoring with "
                     + "\"Automatic\", NVAI-open first asks it whether the damage covers the whole picture: then thorough, "
                     + "otherwise gentle (the better choice on 20 of 21 test photos, about 20 s on an M1). On Windows the "
                     + "FLUX 3 upsampler (Qwen3.5 9B) decides. Without this model, \"Automatic\" restores thoroughly.")
        case .sharpen:
            return t("SeedVR2 3B von ByteDance (Apache-2.0) in 8 Bit, die kleine Fassung des Modells, das unter Windows "
                     + "schärft (7B). Es nimmt Rauschen, Korn und Unschärfe heraus und vergrößert dabei in einem einzigen "
                     + "Schritt, ohne den Bildinhalt neu zu erfinden. Letzter Schritt von „Foto restaurieren“, geht auch "
                     + "allein. Repariert keine Kratzer oder Risse, das macht „Schäden entfernen“.",
                     "SeedVR2 3B by ByteDance (Apache-2.0) in 8-bit, the small version of the model that sharpens on "
                     + "Windows (7B). It removes noise, grain and blur and enlarges in a single step without reinventing "
                     + "the picture. Last step of \"Restore photo\", also works on its own. It does not repair "
                     + "scratches or tears, that is what \"Remove damage\" does.")
        }
    }

    var installed: Bool {
        switch self {
        case .vision: return TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: .qwen35_4B_4bit)
        case .sharpen: return localPath != nil
        }
    }

    /// Ordner von SeedVR2 im Modellordner (wie die Hugging-Face-Ablage: Organisation/Repo).
    static var seedvr2Directory: URL { Settings.modelsDirectory.appendingPathComponent("mlx-community/SeedVR2-3B-mlx-int8") }

    var localPath: URL? {
        switch self {
        case .vision: return TextEncoderModelDownloader.findQwen35ModelPath(for: .qwen35_4B_4bit)
        case .sharpen:
            let dir = Self.seedvr2Directory
            // Vollständig, wenn jede Datei da ist und mindestens 95 % der erwarteten Größe hat.
            let complete = Self.seedvr2Files.allSatisfy { file in
                let path = dir.appendingPathComponent(file.name).path
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
                return Double(size) >= Double(file.bytes) * 0.95
            }
            return complete ? dir : nil
        }
    }

    static func find(_ id: String?) -> HelperModel? { id.flatMap { HelperModel(rawValue: $0) } }

    /// Lädt fehlende Dateien von Hugging Face (in den Modellordner der App).
    func download(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        switch self {
        case .vision:
            _ = try await TextEncoderModelDownloader(hfToken: Settings.hfToken)
                .downloadQwen35(variant: .qwen35_4B_4bit) { fraction, message in progress(fraction, message) }
        case .sharpen:
            let dir = Self.seedvr2Directory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let total = Self.seedvr2Files.reduce(Int64(0)) { $0 + $1.bytes }
            var before: Int64 = 0
            for file in Self.seedvr2Files {
                let target = dir.appendingPathComponent(file.name)
                let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? 0
                if Double(size) < Double(file.bytes) * 0.95 {
                    let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file.name)")!
                    let offset = before
                    let tmp = try await Downloader().lade(url) { stand in
                        progress(Double(offset + stand.geladen) / Double(total),
                                 t("lädt \(file.name)", "downloading \(file.name)"))
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: tmp, to: target)
                }
                before += file.bytes
            }
            progress(1, t("fertig", "done"))
        }
    }

    func delete() throws {
        switch self {
        case .vision: if let path = localPath { try FileManager.default.removeItem(at: path) }
        case .sharpen: try? FileManager.default.removeItem(at: Self.seedvr2Directory)
        }
    }

    /// Wie `features` von SeedVR2 unter Windows: Maßstäbe, Vorgabe, Obergrenze in Pixeln.
    var features: [String: Any] {
        switch self {
        case .vision: return [:]
        case .sharpen: return ["scales": [1, 2, 4], "scale": 2, "max_pixels": Self.sharpenMaxPixels]
        }
    }

    /// Obergrenze fürs Schärfen: auf kleinen Macs kleiner, dort rechnet jede Kachel lange.
    static var sharpenMaxPixels: Int { SystemInfo.memoryGB <= 16 ? 8_000_000 : 16_000_000 }

    /// Wie `ModelInfo` im Vertrag.
    var info: [String: Any] {
        let ok = installed
        return [
            "id": id, "name": name, "kind": kind, "family": family, "workflow": self == .vision ? "qwen35_vlm" : "seedvr2",
            "files": [["repo": repo, "file": "model.safetensors", "target": kind, "installed": ok,
                       "local_path": localPath?.path ?? "", "size_gb": sizeGB]],
            "size_gb": sizeGB, "vram_gb": 4, "license": license, "commercial_ok": true,
            "warning": "", "best_for": bestFor, "description": description, "pros": [String](), "cons": [String](),
            "installed": ok, "partially_installed": false, "disk_gb": ok ? sizeGB : 0,
            "runnable": ok, "favorite": false, "fits_vram": "ja", "features": features, "engine": "mlx",
        ]
    }
}
