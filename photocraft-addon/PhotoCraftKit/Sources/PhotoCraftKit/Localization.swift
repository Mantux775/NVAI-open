import Foundation
import os

/// Sprache von Texten und Meldungen: Englisch ist Standard, Deutsch die Option – wie
/// `bridge/i18n.py`. Jeder sichtbare Text steht als `t("Deutsch", "English")` im Code.
public enum Localization {
    /// Wahl: „auto“ (Systemsprache), „en“ oder „de“; daneben die wirksame Sprache.
    private static let state = OSAllocatedUnfairLock(initialState: (choice: "auto", language: systemLanguage()))

    public static let choices = ["auto", "en", "de"]

    /// Deutsch nur, wenn die bevorzugte Systemsprache Deutsch ist, sonst Englisch.
    public static func systemLanguage() -> String {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("de") ? "de" : "en"
    }

    public static var choice: String {
        get { state.withLock { $0.choice } }
        set {
            let value = choices.contains(newValue) ? newValue : "auto"
            let language = value == "auto" ? systemLanguage() : value
            state.withLock { $0 = (value, language) }
        }
    }

    /// Wirksame Sprache, „de“ oder „en“ – auch als `Accept-Language` für NVAI-open.
    public static var language: String { state.withLock { $0.language } }
}

/// Den Text in der gewählten Sprache: `t("Deutsch", "English")`.
public func t(_ de: String, _ en: String) -> String {
    Localization.language == "de" ? de : en
}
