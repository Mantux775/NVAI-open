import AppKit
import PhotoCraftKit
import SwiftUI

/// „NVAI-open für PhotoCraft“ – ein schwebendes Panel neben PhotoCraft (Einstieg: main.swift).
struct NVAIPhotoCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // Nach einem Sprachwechsel baut .id die Oberfläche neu auf – t() selbst ist nicht beobachtbar.
        Window(t("NVAI-open für PhotoCraft", "NVAI-open for PhotoCraft"), id: "panel") {
            PanelView()
                .environment(model)
                .id(model.settings.language)
        }
        .defaultSize(width: 390, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
                .id(model.settings.language)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Fehlersuche ohne Bildschirmfreigabe (etwa per ssh):
    /// `--snapshot <datei.png> [--start-nvai] [--run <prompt>] [--quit]` speichert nach 5 s ein Bild des
    /// Panels – die App zeichnet dafür nur ihr eigenes Fenster. Mit `--start-nvai` drückt sie vorher
    /// „NVAI-open starten“ und wartet, bis NVAI-open antwortet; mit `--run` startet sie „Generieren“ (eine
    /// Variante) und wartet auf das Ergebnis. Den Verlauf schreibt sie ins Log.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let quit = args.contains("--quit")
        let startNVAI = args.contains("--start-nvai")
        let prompt = args.firstIndex(of: "--run").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Task { @MainActor in
            if startNVAI, let model = AppModel.shared {
                await model.diagnosticStartNVAI()
            }
            if let prompt, let model = AppModel.shared {
                await model.diagnosticRun(prompt: prompt)
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            Self.snapshot(to: url)
            if quit { NSApp.terminate(nil) }
        }
    }

    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.write("Bild des Panels: \(url.path)")
    }
}
