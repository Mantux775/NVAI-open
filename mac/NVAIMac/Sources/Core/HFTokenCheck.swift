import Foundation

/// Prüft ein Hugging-Face-Token, bevor es gespeichert wird (seit 0.5.10; Nutzer 20.11.2026: „beim speichern soll es
/// überprüfen ob es passt, da soll auch ein check button sein“). Wie `huggingface_hub.whoami` unter Windows über
/// /api/whoami-v2, dazu wie `auth_check` über /api/models/<Repo>/auth-check, ob das Token das gesperrte LTX-2.5 lesen
/// darf (Lizenz angenommen, bei fein eingestellten Tokens auch das Recht auf gesperrte Repos). Das Token geht nur an
/// huggingface.co.
enum HFTokenCheck {
    static let gatedRepo = "Lightricks/LTX-2.5"

    enum Outcome: Sendable, Equatable {
        /// `gated`: Zugriff auf LTX-2.5; nil = nicht festzustellen
        case valid(name: String, role: String?, gated: Bool?)
        case rejected
        case unreachable(String)
    }

    static func check(_ token: String) async -> Outcome {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .rejected }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreachable("HTTP \(status)")
            }
            let name = json["name"] as? String ?? "?"
            let role = ((json["auth"] as? [String: Any])?["accessToken"] as? [String: Any])?["role"] as? String
            return .valid(name: name, role: role, gated: await gatedAccess(token))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// 200 = Zugriff, 401/403 = keiner (Lizenz nicht angenommen oder Recht fehlt), sonst nicht festzustellen.
    private static func gatedAccess(_ token: String) async -> Bool? {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(gatedRepo)/auth-check")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200 { return true }
        if status == 401 || status == 403 { return false }
        return nil
    }

    /// Ergebnis als Satz für Einstellungen und REST; `saving`: das Token sollte gespeichert werden (gültig = gespeichert).
    static func message(_ outcome: Outcome, saving: Bool) -> String {
        let notSaved = saving ? t(" Nicht gespeichert.", " Not saved.") : ""
        switch outcome {
        case .valid(let name, let role, let gated):
            let right: String
            switch role {
            case "read": right = t("Leserecht", "read access")
            case "write": right = t("Schreibrecht", "write access")
            case "fineGrained": right = t("fein eingestellte Rechte", "fine-grained permissions")
            default: right = role ?? t("unbekannte Rechte", "unknown permissions")
            }
            var text = t("Das Token gilt: Konto „\(name)“, \(right).", "The token is valid: account \"\(name)\", \(right).")
            switch gated {
            case true?:
                text += t(" Zugriff auf LTX-2.5: ja.", " Access to LTX-2.5: yes.")
            case false?:
                text += t(" Kein Zugriff auf LTX-2.5: auf huggingface.co/\(gatedRepo) die Lizenz annehmen (nur für Video mit LTX-2.5 nötig).",
                          " No access to LTX-2.5: accept the license at huggingface.co/\(gatedRepo) (only needed for video with LTX-2.5).")
            case nil:
                break
            }
            return text + (saving ? t(" Gespeichert.", " Saved.") : "")
        case .rejected:
            return t("Hugging Face lehnt das Token ab. Bitte neu kopieren (es beginnt mit „hf_“) oder ein neues mit Leserecht anlegen.",
                     "Hugging Face rejects the token. Please copy it again (it starts with \"hf_\") or create a new one with read access.")
                + notSaved
        case .unreachable(let why):
            return t("Hugging Face ist nicht erreichbar (\(why)), das Token ist nicht geprüft.",
                     "Hugging Face cannot be reached (\(why)); the token is not checked.") + notSaved
        }
    }
}
