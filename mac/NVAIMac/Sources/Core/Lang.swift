import Foundation

/// Language of visible texts. English is the default; German is an option.
///
/// The app UI follows the setting (Automatic = system language; anything but German means
/// English). The REST API answers in the language the client asks for via `Accept-Language`
/// (de → German, otherwise English); `APIRouter` sets `Lang.request` for the whole request.
enum Lang: String, Sendable {
    case de, en

    /// Set per request (and per job) by the server; nil in the app UI.
    @TaskLocal static var request: Lang?

    /// Setting value: "auto", "en" or "de".
    static var setting: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    static var systemIsGerman: Bool {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("de")
    }

    static var ui: Lang {
        switch setting {
        case "de": return .de
        case "en": return .en
        default: return systemIsGerman ? .de : .en
        }
    }

    static var current: Lang { request ?? ui }

    /// Menüleiste und Systemdialoge folgen der Spracheinstellung der App (ab dem nächsten Start):
    /// "de"/"en" setzt AppleLanguages nur für diese App, "auto" nimmt die Systemsprache.
    /// Dazu nennt Info.plist CFBundleLocalizations (en, de).
    static func applyToMenus() {
        switch setting {
        case "de", "en": UserDefaults.standard.set([setting], forKey: "AppleLanguages")
        default: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// "de-DE,de;q=0.9,en;q=0.8" → .de. Without a header: English.
    static func from(acceptLanguage header: String?) -> Lang {
        guard let header, !header.isEmpty else { return .en }
        let languages = header.split(separator: ",").map { part -> (String, Double) in
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let tag = pieces.first?.lowercased() ?? ""
            let q = pieces.dropFirst().first { $0.hasPrefix("q=") }.flatMap { Double($0.dropFirst(2)) } ?? 1.0
            return (tag, q)
        }
        let best = languages.max { $0.1 < $1.1 }?.0 ?? ""
        return best.hasPrefix("de") ? .de : .en
    }
}

/// Text in the current language: `t("Deutsch", "English")`.
func t(_ de: String, _ en: String) -> String {
    Lang.current == .de ? de : en
}
