import AppKit
import Observation
import PhotoCraftKit

/// Stand von PhotoCraft (aus `ui.inspect`).
struct PhotoCraftState: Equatable {
    var connected = false
    var error: String?
    /// PhotoCraft läuft, aber ohne Steuerkanal (normal gestartet).
    var uncontrolledRunning = false
    var documents = 0
    var dialogOpen = false
    var document: DocumentInfo?
    /// Installiert (per Bundle-ID gefunden) und in welcher Version.
    var installed = true
    var version: String?

    /// Älter als die Version, mit der der Steuerkanal vermessen ist.
    var outdated: Bool {
        version.map { PhotoCraftLaunch.isVersion($0, olderThan: PhotoCraftLaunch.testedVersion) } ?? false
    }
}

struct DocumentInfo: Equatable {
    var name: String
    var width: Int
    var height: Int
    var colorMode: String
    var depth: Int
    var selection: Rect?

    private static var colorModes: [String: String] {
        ["Rgb": "RGB", "Cmyk": "CMYK", "Gray": t("Graustufen", "Grayscale"), "Grayscale": t("Graustufen", "Grayscale"), "Lab": "Lab"]
    }

    var meta: String {
        "\(width) × \(height) px · \(Self.colorModes[colorMode] ?? colorMode) \(depth) " + t("Bit", "bit")
    }
}

/// Stand von NVAI-open (aus `/api/health` und `/api/version`).
struct NVAIState: Equatable {
    var connected = false
    var error: String?
    var version: String?
    var authorized = true
    /// Erreichbar, aber nicht nutzbar: andere Vertragsversion oder Zugriff verweigert.
    var problem: String?
    var masks = false
    /// „Prompt ausbauen“ (`POST /api/prompt/expand`): NVAI-open ab 0.4.
    var expand = false
    /// Erweitern (`outpaint`): NVAI-open für Windows ab 0.5.4, für Mac ab 0.4.3.
    var outpaint = false
    /// Restaurieren (`POST /api/image/restore`): NVAI-open für Windows ab 0.5.11, für Mac ab 0.4.6.
    var restore = false
    /// Arten des Entfernens, die der Server kennt (Windows: auto, thorough, gentle; Mac: thorough).
    var restoreModes: [String] = []
    /// Schärfen mit SeedVR2 ist installiert (nur NVAI-open für Windows).
    var sharpen = false
    /// NVAI-open für Mac (rechnet auf Apple Silicon, deutlich langsamer als eine RTX-Karte).
    var mac = false
    /// Laufende und wartende Modell-Downloads von NVAI-open.
    var downloads: [NVAIClient.Download] = []
    var busy = false
    var activeModel: String?
    var loaded: [String] = []
    var gpu: String?

    var usable: Bool { connected && problem == nil }
}

/// Ein Bildmodell aus NVAI-open mit dem, was es in den drei Modi kann (wie `/api/models` der Brücke).
struct ModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let workflow: String?
    let commercialOK: Bool?
    let warning: String
    let bestFor: String
    let img2img: Bool
    let refine: Bool
    let mask: Bool
    /// Überarbeiten per Referenzbild (FLUX 3) statt per Bild-zu-Bild.
    let referenceEdit: Bool
    /// Schnelle Modelle (cfg 1) folgen beim Füllen dem Prompt kaum.
    let weakPrompt: Bool
    let negativePrompt: Bool
    let hires: Bool
    let promptHint: String
    let placeholder: String
    /// Wie das Modell erweitert: "reference" (nahtlos), "mask" (oft harte Kante) oder nil.
    let outpaint: String?
    /// Bearbeitet Fotos per Referenzbild (FLUX 3, FLUX.2 Klein): taugt zum Restaurieren und Einfärben.
    let restore: Bool

    init(_ m: JSONValue, masks: Bool) {
        let features = m["features"] ?? [:]
        id = m["id"]?.stringValue ?? ""
        name = m["name"]?.stringValue ?? id
        workflow = m["workflow"]?.stringValue
        commercialOK = m["commercial_ok"]?.boolValue
        warning = m["warning"]?.stringValue ?? ""
        bestFor = m["best_for"]?.stringValue ?? ""
        img2img = Planning.capable(m, "img2img", masksSupported: masks)
        refine = Planning.capable(m, "refine", masksSupported: masks)
        mask = Planning.capable(m, "mask", masksSupported: masks)
        referenceEdit = refine && !img2img
        weakPrompt = workflow.map { Planning.weakPromptWorkflows.contains($0) } ?? false
        negativePrompt = features["negative_prompt"]?.boolValue ?? true
        hires = features["hires"]?.boolValue ?? true
        promptHint = features["prompt_hint"]?.stringValue ?? ""
        placeholder = features["placeholder"]?.stringValue ?? ""
        outpaint = features["outpaint"]?.stringValue
        restore = Planning.restoreCapable(m)
    }

    func suits(_ mode: Mode) -> Bool {
        switch mode {
        case .fill, .extend: return mask
        case .refine: return refine
        case .generate: return true
        case .restore: return restore
        }
    }
}

/// Ein Auftrag im Panel: der `GenerationTask` aus PhotoCraftKit plus Anzeigezustand.
@Observable
final class TaskItem: Identifiable {
    enum Status { case running, done, error, cancelled }

    let task: GenerationTask
    let id: String
    let created = Date()
    var status = Status.running
    var progress = 0.0
    var stage = t("startet", "starting")
    var error: String?
    var placedVariant: Int?
    var images: [NSImage] = []
    var finished: Date?

    init(task: GenerationTask) {
        self.task = task
        id = task.id
    }

    var mode: Mode { Mode(rawValue: task.mode) ?? .generate }

    var title: String {
        let prompt = task.prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !prompt.isEmpty { return prompt }
        if mode == .restore {
            let p = task.params
            return [(p["repair"]?.truthy ?? true) ? t("Schäden", "damage") : nil,
                    (p["colorize"]?.truthy ?? false) ? t("Farbe", "color") : nil,
                    (p["sharpen"]?.truthy ?? false) ? t("Schärfe", "sharpness") : nil].compactMap { $0 }.joined(separator: ", ")
        }
        return t("(ohne Prompt)", "(no prompt)")
    }

    var duration: String? {
        guard let finished else { return nil }
        return "\(Int(finished.timeIntervalSince(created).rounded())) s"
    }

    func loadImages(exchange: URL) {
        images = task.variants.map { NSImage(contentsOf: exchange.appendingPathComponent($0.file)) ?? NSImage() }
    }
}

/// Ergebnis von „Verbindung prüfen“.
struct ProbeResult: Equatable {
    var ok: Bool
    var message: String
}
