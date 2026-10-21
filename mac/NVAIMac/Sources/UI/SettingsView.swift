import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var portText = ""
    @State private var reportMessage: String?

    var body: some View {
        Form {
            Section(t("Sprache", "Language")) {
                Picker(t("Sprache der App", "App language"), selection: Binding(
                    get: { state.language },
                    set: { state.setLanguage($0) }
                )) {
                    Text(t("Automatisch (Systemsprache)", "Automatic (system language)")).tag("auto")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                Text(t("Die Menüleiste wechselt beim nächsten Start von NV-AI. Die Schnittstelle antwortet "
                       + "in der Sprache, die der Client schickt (Accept-Language).",
                       "The menu bar switches the next time NV-AI starts. The API answers in the language "
                       + "the client asks for (Accept-Language)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Lokaler Server", "Local server")) {
                Text(state.serverDescription)
                HStack {
                    TextField("Port", text: $portText).frame(width: 90)
                    Button(t("Übernehmen", "Apply")) {
                        if let p = UInt16(portText), p >= 1024 { state.changePort(p) }
                    }
                }
                Text(t("Die PhotoCraft-App und eigene Skripte sprechen NV-AI über diese Adresse an. "
                       + "Erreichbar nur von diesem Mac. Standard ist 8100, wie NV-AI unter Windows.",
                       "The PhotoCraft app and your own scripts talk to NV-AI at this address. "
                       + "Reachable from this Mac only. The default is 8100, as in NV-AI for Windows."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(t("Protokoll: ", "Log: ") + AppLog.file.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section(t("Modelle", "Models")) {
                Text(state.modelsDirectory.path).textSelection(.enabled)
                HStack {
                    Button(t("Ordner wählen …", "Choose folder …")) {
                        if let url = Panels.chooseFolder(t("Ordner für die Modelle wählen", "Choose a folder for the models")) {
                            Task { await state.changeModelsDirectory(url) }
                        }
                    }
                    Button(t("Im Finder zeigen", "Show in Finder")) { NSWorkspace.shared.open(state.modelsDirectory) }
                }
                Text(t("Modelle sind je 5 bis 11 GB groß. Ein externer Datenträger geht auch; der Ordner heißt dann „models“.",
                       "Each model is 5 to 11 GB. An external drive works too; the folder is then called \"models\"."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Messbericht für Tester", "Test report")) {
                Button(t("Messbericht speichern …", "Save test report …")) { saveReport() }
                if let reportMessage { Text(reportMessage).font(.caption) }
                Text(t("Enthält Mac, Arbeitsspeicher, macOS und je Bild Größe, Schritte, Dauer und Speicherspitze. "
                       + "Keine Prompts, keine Bilder.",
                       "Contains the Mac, memory, macOS and, per image, size, steps, duration and peak memory. "
                       + "No prompts, no images."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Dieser Mac", "This Mac")) {
                Text(t("\(SystemInfo.chip), \(SystemInfo.memoryGB) GB Arbeitsspeicher", "\(SystemInfo.chip), \(SystemInfo.memoryGB) GB memory"))
                Text("macOS \(SystemInfo.macOS)")
                Text("NV-AI \(SystemInfo.appVersion) (\(SystemInfo.build))")
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(state.port) }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.title = t("Messbericht speichern", "Save test report")
        panel.nameFieldStringValue = t("NV-AI-Messbericht", "NV-AI-Test-Report") + "-\(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Report.markdown(images: state.images, jobs: state.jobs)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            reportMessage = t("Gespeichert: ", "Saved: ") + url.lastPathComponent
        } catch {
            reportMessage = t("Nicht gespeichert: ", "Not saved: ") + error.localizedDescription
        }
    }
}

/// Der Messbericht: das, was Tester zurückschicken sollen.
enum Report {
    static func markdown(images: [AssetRecord], jobs: [JobRecord]) -> String {
        var lines: [String] = [
            t("# NV-AI für Mac: Messbericht", "# NV-AI for Mac: test report"),
            "",
            "- App: \(SystemInfo.appVersion) (\(SystemInfo.build))",
            t("- Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB Arbeitsspeicher", "- Mac: \(SystemInfo.chip), \(SystemInfo.memoryGB) GB memory"),
            "- macOS: \(SystemInfo.macOS)",
            t("- Aktives Modell: ", "- Active model: ") + Models.active.name,
            t("- Erstellt: ", "- Created: ") + Date().formatted(date: .numeric, time: .shortened),
            "",
            t("## Bilder", "## Images"),
            "",
            t("| Zeit | Modell | Art | Größe | Schritte | Laden s | Rechnen s | Speicherspitze MB |",
              "| Time | Model | Mode | Size | Steps | Load s | Generate s | Peak memory MB |"),
            "|---|---|---|---|---|---|---|---|",
        ]
        for asset in images.sorted(by: { $0.createdAt < $1.createdAt }) {
            let m = asset.meta
            let time = Date(timeIntervalSince1970: asset.createdAt).formatted(date: .numeric, time: .standard)
            let size = "\(m["width"]?.intValue ?? 0) × \(m["height"]?.intValue ?? 0)"
            let load = m["load_s"]?.doubleValue.map { String(format: "%.1f", $0) } ?? ""
            let run = m["duration_s"]?.doubleValue.map { String(format: "%.1f", $0) } ?? ""
            let model = Models.find(asset.modelID)?.name ?? m["model_name"]?.stringValue ?? asset.modelID
            lines.append("| \(time) | \(model) | \(m["mode"]?.stringValue ?? "") "
                + "| \(size) | \(m["steps"]?.intValue ?? 0) | \(load) | \(run) | \(m["peak_memory_mb"]?.intValue ?? 0) |")
        }
        let failed = jobs.filter { $0.status == "error" }
        if !failed.isEmpty {
            lines += ["", t("## Fehler", "## Errors"), ""]
            for job in failed { lines.append("- \(job.kind): \(job.error ?? t("ohne Meldung", "no message"))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
