import AppKit
import SwiftUI

/// Startet Server und Dienste beim Programmstart – unabhängig davon, ob ein Fenster erscheint.
/// Die PhotoCraft-App öffnet NV-AI im Hintergrund (activates=false) und wartet auf /api/version.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("Start NV-AI \(SystemInfo.appVersion) (\(SystemInfo.build)), \(SystemInfo.chip), "
            + "\(SystemInfo.memoryGB) GB, macOS \(SystemInfo.macOS), port \(Settings.serverPort), "
            + "models \(Settings.modelsDirectory.path), language \(Lang.ui.rawValue)")
        Lang.applyToMenus()   // Einstellungen aus 0.3 übernehmen; wirkt ab dem nächsten Start
        AppState.shared.ensureServer()
        Task { @MainActor in
            await AppState.shared.start()
            await LaunchOptions.runTasks()
        }
    }

    /// Fenster zu heißt nicht Programm aus: der Server bleibt für die PhotoCraft-App erreichbar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("Quit NV-AI")
    }
}

/// Startoptionen für Tests ohne Bildschirm (wie bei der PhotoCraft-App):
///
///     NV-AI --snapshot <png> [--tab generate|history|models|search|settings] [--report <md>] [--quit]
///
/// `--snapshot` fotografiert das eigene Fenster (cacheDisplay, keine Bildschirmfreigabe nötig),
/// `--tab search` öffnet dazu die Modellsuche; `--report` schreibt den Messbericht.
@MainActor
enum LaunchOptions {
    private static var args: [String] { CommandLine.arguments }

    private static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    static func runTasks() async {
        let snapshot = value("--snapshot")
        let report = value("--report")
        let problem = value("--problem-report")
        let quit = args.contains("--quit")
        guard snapshot != nil || report != nil || problem != nil else { return }

        // Anonymisierter Fehlerbericht ohne Dialog (zum Prüfen der Anonymisierung).
        if let problem {
            let text = ProblemReport.build(description: value("--description") ?? "", jobs: AppState.shared.jobs).text
            do {
                try text.write(toFile: problem, atomically: true, encoding: .utf8)
                AppLog.info("Problem report written")
            } catch {
                AppLog.error("Problem report not written: \(error.localizedDescription)")
            }
        }

        if let report {
            let text = Report.markdown(images: AppState.shared.images, jobs: AppState.shared.jobs)
            do {
                try text.write(toFile: report, atomically: true, encoding: .utf8)
                AppLog.info("Test report written: \(report)")
            } catch {
                AppLog.error("Test report not written: \(error.localizedDescription)")
            }
        }
        if let snapshot {
            let tab = value("--tab") ?? "generate"
            AppState.shared.selectedTab = tab == "search" ? "models" : tab
            if tab == "search" { AppState.shared.showSearch = true }
            // Rendern und – bei der Suche – die Trefferliste von Hugging Face abwarten.
            try? await Task.sleep(nanoseconds: tab == "search" ? 9_000_000_000 : 2_500_000_000)
            write(snapshot, sheet: tab == "search")
        }
        if quit {
            // Mit offenem Blatt (Modellsuche) beendete terminate die App nicht (gemessen):
            // Blatt schließen, dann beenden, und notfalls hart nach 3 s.
            AppState.shared.showSearch = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
    }

    private static func write(_ path: String, sheet: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 && $0.sheetParent == nil })
        else {
            AppLog.error("Snapshot: no window found")
            return
        }
        let target = sheet ? (window.attachedSheet ?? window) : window
        // Der Rahmen samt Titelleiste ist die Oberansicht der contentView.
        guard let view = target.contentView?.superview ?? target.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            AppLog.error("Snapshot: window could not be rendered")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            AppLog.info("Snapshot written: \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            AppLog.error("Snapshot not written: \(error.localizedDescription)")
        }
    }
}
