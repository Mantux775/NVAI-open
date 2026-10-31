import AppKit
import SwiftUI

@main
struct NVAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("NVAI-open") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 660)
                .task { await state.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                LicensesMenuItem()
            }
        }

        Window(t("Lizenzen", "Licenses"), id: "licenses") {
            LicensesView()
                .environmentObject(state)
                .frame(minWidth: 640, minHeight: 520)
        }
    }
}

/// „Über NVAI-open → Lizenzen …“ im App-Menü.
struct LicensesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(t("Lizenzen …", "Licenses …")) { openWindow(id: "licenses") }
    }
}

/// Zeigt Third-Party-Notices.txt aus dem App-Bundle: Name, Lizenz und vollen Text jeder Abhängigkeit.
struct LicensesView: View {
    @EnvironmentObject var state: AppState

    private var text: String {
        guard let url = Bundle.main.url(forResource: "Third-Party-Notices", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return t("Third-Party-Notices.txt fehlt im App-Bundle.", "Third-Party-Notices.txt is missing from the app bundle.")
        }
        return content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("NVAI-open steht unter der MIT-Lizenz. Es nutzt die folgenden Open-Source-Komponenten. "
                   + "Modelle gehören nicht zur App; ihre Lizenz steht in der Modellliste.",
                   "NVAI-open is released under the MIT License. It uses the following open-source components. "
                   + "Models are not part of the app; the model list shows their license."))
                .font(.callout)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(.quaternary)
        }
        .padding(14)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $state.selectedTab) {
                // Wie unter Windows: das Studio zuerst und beim Start offen
                StudioView().tabItem { Text("Studio") }.tag("studio")
                GenerateView().tabItem { Text(t("Generieren", "Generate")) }.tag("generate")
                HistoryView().tabItem { Text(t("Verlauf", "History")) }.tag("history")
                ModelsView().tabItem { Text(t("Modelle", "Models")) }.tag("models")
                SettingsView().tabItem { Text(t("Einstellungen", "Settings")) }.tag("settings")
            }
            .padding(.top, 6)
            StatusBar()
        }
    }
}

/// Fußzeile: Server, Modell, laufender Auftrag – damit man immer sieht, was gerade passiert.
struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(serverColor)
                .frame(width: 8, height: 8)
            Text(state.serverDescription)
            Divider().frame(height: 12)
            Text(t("Modell: ", "Model: ") + (Models.find(state.activeModelID)?.name ?? state.activeModelID))
            Spacer()
            if let job = state.runningJob {
                ProgressView(value: job.progress).frame(width: 120)
                Text(job.stage).lineLimit(1)
            } else {
                Text("\(SystemInfo.chip), \(SystemInfo.memoryGB) GB").foregroundStyle(.secondary)
            }
            // Versionsnummer wie in der Weboberfläche unter Windows (Nutzerwunsch 26.10.2026).
            Divider().frame(height: 12)
            Text("NVAI-open \(SystemInfo.appVersion)").foregroundStyle(.secondary)
                .help("NVAI-open \(SystemInfo.appVersion) (Build \(SystemInfo.build))")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var serverColor: Color {
        switch state.serverState {
        case .listening: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}
