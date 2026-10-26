import AppKit
import SwiftUI

/// Startet Server und Dienste beim Programmstart – unabhängig davon, ob ein Fenster erscheint.
/// Die PhotoCraft-App öffnet NVAI-open im Hintergrund (activates=false) und wartet auf /api/version.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("Start NVAI-open \(SystemInfo.appVersion) (\(SystemInfo.build)), \(SystemInfo.chip), "
            + "\(SystemInfo.memoryGB) GB, macOS \(SystemInfo.macOS), port \(Settings.serverPort), "
            + "models \(Settings.modelsDirectory.path), language \(Lang.ui.rawValue)")
        Lang.applyToMenus()   // Einstellungen aus 0.3 übernehmen; wirkt ab dem nächsten Start
        MetalRetainFix.apply()   // vor der ersten MLX-Rechnung (MLX-Fehler #3689)
        AppState.shared.ensureServer()
        Task { @MainActor in
            await AppState.shared.start()
            await LaunchOptions.runTasks()
        }
    }

    /// Fenster zu heißt nicht Programm aus: der Server bleibt für die PhotoCraft-App erreichbar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("Quit NVAI-open")
    }
}

/// Startoptionen für Tests ohne Bildschirm (wie bei der PhotoCraft-App):
///
///     NVAI-open --snapshot <png> [--tab generate|restore|audio|history|models|search|settings] [--report <md>] [--quit]
///     NVAI-open --restore-kind <ordner> --kind-out <json> [--quit]
///     NVAI-open --sharpen <bild> --sharpen-out <png> [--sharpen-scale 2] [--quit]
///     NVAI-open --audio-test <prompt> --audio-out <wav> [--audio-seconds 10] [--quit]
///
/// `--snapshot` fotografiert das eigene Fenster (cacheDisplay, keine Bildschirmfreigabe nötig),
/// `--tab search` öffnet dazu die Modellsuche, `--tab restore` „Generieren“ mit „Foto restaurieren“;
/// `--report` schreibt den Messbericht. `--restore-kind` stellt jedem Foto (JPEG/PNG, auch in Unterordnern) die Frage
/// von „Automatisch“ beim Restaurieren (`VisionEngine`) und schreibt Antwort, Wahl und Sekunden nach `--kind-out`.
/// `--sharpen` schärft ein Bild mit SeedVR2 (`SeedVR2Engine`) und schreibt Zeit und Speicherspitze ins Protokoll.
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
        let kindDir = value("--restore-kind")
        let sharpen = value("--sharpen")
        let audio = args.firstIndex(of: "--audio-test").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard snapshot != nil || report != nil || problem != nil || kindDir != nil || sharpen != nil || audio != nil else { return }

        if let audio, let out = value("--audio-out") {
            await audioTest(audio, out: out, seconds: Double(value("--audio-seconds") ?? "") ?? 10)
        }

        if let sharpen, let out = value("--sharpen-out") {
            await sharpenTest(sharpen, out: out, scale: Double(value("--sharpen-scale") ?? "") ?? 2)
        }

        if let kindDir, let out = value("--kind-out") { await restoreKinds(kindDir, out: out) }

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
            AppState.shared.selectedTab = tab == "search" ? "models" : (tab == "restore" || tab == "audio") ? "generate" : tab
            if tab == "search" { AppState.shared.showSearch = true }
            if tab == "restore" { AppState.shared.showRestore = true }
            if tab == "audio" { AppState.shared.showAudio = true }
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

    /// Prüfstand für „Automatisch“: alle Fotos eines Ordners, das Modell bleibt dafür geladen.
    private static func restoreKinds(_ dir: String, out: String) async {
        let root = URL(fileURLWithPath: dir)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        var results: [String: Any] = [:]
        let sampler = PeakMemorySampler()
        sampler.start()
        let started = Date()
        for file in files {
            let rel = String(file.path.dropFirst(root.path.count + 1))
            do {
                let image = try ImageFiles.load(file)
                var entry: [String: Any] = [:]
                // Log-Odds je Frage, einmal in der Größe des Modells (bis 1 MP), einmal auf 0,35 MP verkleinert.
                let small = ImageFiles.resized(image, width: Int(Double(image.width) * (0.35e6 / Double(image.width * image.height)).squareRoot()),
                                               height: Int(Double(image.height) * (0.35e6 / Double(image.width * image.height)).squareRoot()))
                for (label, picture) in [("full", image), ("small", small)] {
                    let t0 = Date()
                    let odds = try await VisionEngine.shared.logOdds(picture, questions: VisionEngine.probeQuestions)
                    entry[label] = odds.map { ($0 * 100).rounded() / 100 }
                    entry["\(label)_seconds"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10
                }
                results[rel] = entry
                AppLog.info("Restore kind \(rel): \(entry)")
            } catch {
                results[rel] = ["error": (error as? LocalizedError)?.errorDescription ?? String(describing: error)]
            }
        }
        await VisionEngine.shared.unload()
        results["_total_seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        results["_peak_memory_mb"] = Int(sampler.stop())
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
        }
    }

    /// Prüfstand für Stable Audio 3: ein Prompt, Laden und Rechnen getrennt gemessen.
    private static func audioTest(_ prompt: String, out: String, seconds: Double) async {
        do {
            let sampler = PeakMemorySampler()
            sampler.start()
            let t0 = Date()
            try await AudioEngine.shared.load()
            let loaded = Date().timeIntervalSince(t0)
            MemoryLog.line("Stable Audio 3 loaded")
            let t1 = Date()
            let wav = try await AudioEngine.shared.generate(prompt: prompt, seconds: seconds, steps: 8, cfg: 1, seed: 42)
            let took = Date().timeIntervalSince(t1)
            try wav.write(to: URL(fileURLWithPath: out))
            await AudioEngine.shared.unload()
            AppLog.info(String(format: "Audio test: %.0f s audio, load %.1f s, generate %.1f s, peak %d MB, %d bytes",
                               seconds, loaded, took, Int(sampler.stop()), wav.count))
        } catch {
            AppLog.error("Audio test failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
    }

    /// Prüfstand fürs Schärfen: ein Bild, Laden und Rechnen getrennt gemessen.
    private static func sharpenTest(_ path: String, out: String, scale: Double) async {
        guard let dir = HelperModel.sharpen.localPath else {
            AppLog.error("Sharpen test: SeedVR2 3B not downloaded")
            return
        }
        do {
            let image = try ImageFiles.load(URL(fileURLWithPath: path))
            let sampler = PeakMemorySampler()
            sampler.start()
            let t0 = Date()
            try await SeedVR2Engine.shared.load(dir)
            let loaded = Date().timeIntervalSince(t0)
            let t1 = Date()
            let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
            let result = try await SeedVR2Engine.shared.upscale(image, width: w, height: h, seed: 42) { done, total in
                AppLog.info("Sharpen test: tile \(done) of \(total)")
            }
            let seconds = Date().timeIntervalSince(t1)
            try ImageFiles.pngData(result).write(to: URL(fileURLWithPath: out))
            await SeedVR2Engine.shared.unload()
            AppLog.info(String(format: "Sharpen test: %d×%d → %d×%d, tile %d, load %.1f s, sharpen %.1f s, peak %d MB",
                               image.width, image.height, w, h, SeedVR2Engine.tile, loaded, seconds, Int(sampler.stop())))
        } catch {
            AppLog.error("Sharpen test failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
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
