import PhotoCraftKit
import SwiftUI

/// Einstellungen (⌘,): NV-AI-Adresse und Token, PhotoCraft-Steuerport, Sprache.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var result: ProbeResult?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                TextField(t("Adresse", "Address"), text: $draft.nvaiURL, prompt: Text(verbatim: "http://127.0.0.1:8100"))
                SecureField("Token", text: $draft.nvaiToken,
                            prompt: Text(t("nur für NV-AI auf einem anderen Rechner", "only for NV-AI on another computer")))
            } header: {
                Text(verbatim: "NV-AI")
            } footer: {
                Text(t("Normalerweise läuft NV-AI auf diesem Mac (http://127.0.0.1:8100, ohne Token). Eine NV-AI auf einem anderen Rechner braucht deren Adresse und Token.",
                       "Normally NV-AI runs on this Mac (http://127.0.0.1:8100, no token). An NV-AI on another computer needs its address and token."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField(t("Steuer-Port", "Control port"), value: $draft.photocraftPort, format: .number.grouping(.never))
                LabeledContent(t("Datenordner", "Data folder")) {
                    Text(AppSettings.dataDirectory.path).font(.caption).textSelection(.enabled)
                }
            } header: {
                Text(verbatim: "PhotoCraft")
            }
            Section {
                Picker(t("Sprache", "Language"), selection: $draft.language) {
                    Text(t("Automatisch (Systemsprache)", "Automatic (system language)")).tag("auto")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Deutsch").tag("de")
                }
            } footer: {
                Text(t("Menüs von macOS folgen der Wahl nach einem Neustart der App.",
                       "macOS menus follow the choice after the app is restarted."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(alignment: .firstTextBaseline) {
                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                            .font(.callout)
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(checking ? t("Prüft …", "Checking …") : t("Verbindung prüfen", "Check connection")) { Task { await check() } }
                        .disabled(checking)
                    Button(t("Sichern", "Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft == model.settings)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            draft = model.settings
            result = nil
        }
    }

    private func check() async {
        checking = true
        result = await model.probe(draft)
        checking = false
    }

    private func save() {
        do {
            try model.apply(draft)
            result = ProbeResult(ok: true, message: t("Gesichert.", "Saved."))
        } catch {
            result = ProbeResult(ok: false, message: error.localizedDescription)
        }
    }
}
