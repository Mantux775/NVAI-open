import Foundation
import PhotoCraftKit

/// Verbindungseinstellungen – wie `settings.json` der Windows-Brücke, hier im Datenordner
/// `~/Library/Application Support/ArtCraft-LocalAI` (nur für den Nutzer lesbar, enthält den Token).
struct AppSettings: Codable, Equatable {
    /// Im Normalbetrieb läuft NV-AI auf demselben Mac (gleicher REST-Vertrag, API 1). Eine NV-AI auf
    /// einem anderen Rechner geht auch – dann mit deren Adresse und Token.
    var nvaiURL = "http://127.0.0.1:8100"
    var nvaiToken = ""
    var photocraftPort = 47821
    /// „auto“ (Systemsprache), „en“ oder „de“ – wie `language` in settings.json der Windows-Brücke.
    var language = "auto"

    enum CodingKeys: String, CodingKey {
        case nvaiURL = "nvai_url", nvaiToken = "nvai_token", photocraftPort = "photocraft_port", language
    }

    static var dataDirectory: URL { PhotoCraftLaunch.defaultDataDirectory() }
    static var file: URL { dataDirectory.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: file) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.dataDirectory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    /// Gültige Basis-URL (http/https mit Host) oder `nil`.
    var baseURL: URL? {
        var text = nvaiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    var token: String? {
        let value = nvaiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var port: UInt16 { UInt16(clamping: photocraftPort) }

    /// NV-AI auf diesem Mac?
    var isLocal: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL?.host?.lowercased() ?? "") }
}

extension AppSettings {
    // Fehlende Schlüssel (ältere oder von Hand geschriebene Datei) bekommen den Standardwert.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nvaiURL = try c.decodeIfPresent(String.self, forKey: .nvaiURL) ?? nvaiURL
        nvaiToken = try c.decodeIfPresent(String.self, forKey: .nvaiToken) ?? nvaiToken
        photocraftPort = try c.decodeIfPresent(Int.self, forKey: .photocraftPort) ?? photocraftPort
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
    }
}

/// Eingaben des Panels – bleiben über Neustarts erhalten (wie localStorage im Windows-Panel).
struct FormState: Codable, Equatable {
    var mode: Mode = .fill
    var prompt = ""
    var negative = ""
    /// Modus → Modell-ID; leer = automatisch (aktives bzw. bestes passendes Modell).
    var models: [String: String] = [:]
    var variants = 2
    var strength = 0.5
    var margin = 0.35
    var steps = ""
    var cfg = ""
    var seed = ""
    var native = false
    var hires = false
    var autoPlace = true
    var advanced = false
    var alwaysOnTop = true

    enum CodingKeys: String, CodingKey {
        case mode, prompt, negative, models, variants, strength, margin, steps, cfg, seed, native, hires,
             autoPlace, advanced, alwaysOnTop
    }

    private static let key = "panel-form"

    static func load() -> FormState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let form = try? JSONDecoder().decode(FormState.self, from: data) else { return FormState() }
        return form
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension FormState {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        mode = value(.mode, mode)
        prompt = value(.prompt, prompt)
        negative = value(.negative, negative)
        models = value(.models, models)
        variants = min(4, max(1, value(.variants, variants)))
        strength = value(.strength, strength)
        margin = value(.margin, margin)
        steps = value(.steps, steps)
        cfg = value(.cfg, cfg)
        seed = value(.seed, seed)
        native = value(.native, native)
        hires = value(.hires, hires)
        autoPlace = value(.autoPlace, autoPlace)
        advanced = value(.advanced, advanced)
        alwaysOnTop = value(.alwaysOnTop, alwaysOnTop)
    }
}

/// Die drei Modi des Panels (Texte wie panel/panel.js).
enum Mode: String, CaseIterable, Identifiable, Codable {
    case fill, generate, refine

    var id: String { rawValue }
    var label: String { Planning.modeLabel(rawValue) }

    var go: String {
        switch self {
        case .fill: return t("Auswahl füllen", "Fill selection")
        case .generate: return t("Bild generieren", "Generate image")
        case .refine: return t("Überarbeiten", "Refine")
        }
    }

    var hint: String {
        switch self {
        case .fill:
            return t("Füllt die Auswahl passend zur Umgebung. Ohne Prompt wird die Umgebung fortgesetzt, ohne Auswahl werden transparente Ränder gefüllt.",
                     "Fills the selection to match its surroundings. Without a prompt the surroundings continue; without a selection, transparent edges get filled.")
        case .generate:
            return t("Erzeugt ein neues Bild in der Auswahl – oder auf der ganzen Arbeitsfläche, wenn nichts ausgewählt ist.",
                     "Creates a new image in the selection – or on the whole canvas if nothing is selected.")
        case .refine:
            return t("Rechnet die Auswahl oder das ganze Bild neu. Die Stärke bestimmt, wie viel sich ändert.",
                     "Re-renders the selection or the whole image. The strength sets how much changes.")
        }
    }

    var placeholder: String {
        switch self {
        case .fill: return t("Was soll in der Auswahl entstehen? Leer lassen = Umgebung fortsetzen",
                             "What should appear in the selection? Leave empty = continue the surroundings")
        case .generate: return t("Beschreibe das Bild, z. B. „a red vintage car at sunset, cinematic photo“",
                                 "Describe the image, e.g. \"a red vintage car at sunset, cinematic photo\"")
        case .refine: return t("Wie soll sich der Bereich verändern? z. B. „as an oil painting with visible brush strokes“",
                               "How should the area change? e.g. \"as an oil painting with visible brush strokes\"")
        }
    }

    /// Modelle wie FLUX 3 bearbeiten mit dem Ausschnitt als Referenzbild statt per Bild-zu-Bild.
    static var editHint: String {
        t("Bearbeitet die Auswahl oder das ganze Bild mit dem Ausschnitt als Referenz: Beschreibe, was sich ändert – und was gleich bleibt.",
          "Edits the selection or the whole image using the area as a reference: describe what changes – and what stays the same.")
    }
    static var editPlaceholder: String {
        t("z. B. „Replace the rope handles with forged iron handles; keep everything else unchanged.“",
          "e.g. \"Replace the rope handles with forged iron handles; keep everything else unchanged.\"")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : self }
}
