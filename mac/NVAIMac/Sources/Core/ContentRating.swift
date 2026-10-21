import Foundation

/// Zensiert oder unzensiert, wie `server/nvai/content.py` unter Windows: Einstufung mit Beleg
/// und Quelle. Ohne Eintrag gilt „unbekannt“ – lieber das als eine geratene Angabe.
enum ContentRating {
    struct Entry {
        let level: String          // uncensored | partial | censored
        let de: String
        let en: String
        let source: String
    }

    /// Stand der Recherche: 2026-10-21. Mit der Suche hinzugefügte Core-ML-Modelle bleiben „unbekannt“.
    static let table: [String: Entry] = {
        let flux2 = Entry(level: "censored",
                          de: "Laut Modellkarte sind die Trainingsdaten auf NSFW gefiltert, das Feintuning unterdrückt bestimmte Inhalte.",
                          en: "According to the model card, training data was filtered for NSFW and fine-tuning suppresses certain content.",
                          source: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")
        return [
            "flux2-klein-4b": flux2,
            "flux2-klein-4b-q8": flux2,
            "coreml-sd21-base": Entry(
                level: "partial",
                de: "SD 2.0 war streng gefiltert, 2.1 wurde mit gelockertem Filter nachtrainiert; etwas Nacktheit ist möglich. Apples Paket bringt keinen Safety Checker mit.",
                en: "SD 2.0 was strictly filtered, 2.1 was fine-tuned with a looser filter; some nudity is possible. Apple's package ships no safety checker.",
                source: "https://huggingface.co/stabilityai/stable-diffusion-2-1"),
            "coreml-sd15": Entry(
                level: "partial",
                de: "Trainingsdaten ohne NSFW-Filter. Ob Apples Paket einen Safety Checker mitbringt, ist nicht geprüft; dann kommen beanstandete Bilder leer zurück.",
                en: "Training data without an NSFW filter. Whether Apple's package ships a safety checker is not verified; if it does, flagged images come back empty.",
                source: "https://github.com/apple/ml-stable-diffusion"),
            "coreml-sdxl-mixed-bit": Entry(
                level: "partial",
                de: "Stability nutzt eine gefilterte Teilmenge von LAION-5B; schwache Nacktheit ist möglich. Apples SDXL-Paket hat keinen Safety Checker.",
                en: "Stability uses a filtered subset of LAION-5B; weak nudity is possible. Apple's SDXL package has no safety checker.",
                source: "https://github.com/apple/ml-stable-diffusion"),
        ]
    }()

    static func entry(_ id: String) -> Entry? { table[id] }

    static func label(_ id: String) -> String {
        switch table[id]?.level {
        case "uncensored": return t("unzensiert", "uncensored")
        case "partial": return t("teilweise zensiert", "partly censored")
        case "censored": return t("zensiert", "censored")
        default: return t("Zensur unbekannt", "filtering unknown")
        }
    }

    static func help(_ id: String) -> String {
        guard let e = table[id] else {
            return t("Keine verlässliche Angabe des Herstellers gefunden.", "No reliable statement from the maker found.")
        }
        return t(e.de, e.en) + "\n" + t("Quelle: ", "Source: ") + e.source
    }

    /// Felder für /api/models, wie unter Windows.
    static func apiFields(_ id: String) -> [String: Any] {
        guard let e = table[id] else { return ["content": NSNull(), "content_note": "", "content_source": ""] }
        return ["content": e.level, "content_note": t(e.de, e.en), "content_source": e.source]
    }
}
