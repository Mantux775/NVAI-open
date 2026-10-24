import AppKit
import PhotoCraftKit

/// `--selftest`: prüft ohne Fenster, was die App braucht, und schreibt es lesbar auf stdout (auf
/// Englisch, es ist ein Werkzeug für die Fehlersuche). Ergebnis „gut“, wenn NVAI-open nutzbar ist;
/// PhotoCraft darf fehlen (startet die App selbst).
enum SelfTest {
    static func run() async -> Bool {
        Localization.choice = "en"
        let settings = AppSettings.load()
        let exists = FileManager.default.fileExists(atPath: AppSettings.file.path)
        print("NVAI-open for PhotoCraft – self-test")
        print("Settings: \(AppSettings.file.path)\(exists ? "" : " (missing – defaults)")")
        print("NVAI-open address: \(settings.nvaiURL), token: \(settings.token == nil ? "none" : "set"), language: \(settings.language)")

        if let app = PhotoCraftLaunch.installedApp() {
            let version = PhotoCraftLaunch.version(of: app) ?? "?"
            let old = PhotoCraftLaunch.isVersion(version, olderThan: PhotoCraftLaunch.testedVersion)
                ? " – older than the tested \(PhotoCraftLaunch.testedVersion)" : ""
            print("PhotoCraft installed: \(app.path) (\(version))\(old)")
        } else {
            print("PhotoCraft: not installed – download: \(PhotoCraftLaunch.downloadURL.absoluteString)")
        }
        let nvaiApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppModel.nvaiMacBundleID)
        print("NVAI-open for Mac: \(nvaiApp?.path ?? "not installed (\(AppModel.nvaiMacBundleID))")")
        let launch = PhotoCraftLaunch.standard(port: settings.port)
        let control = ControlClient(port: settings.port, tokenURL: launch.tokenFile)
        do {
            let ui = try await control.inspect()
            let docs = ui["session"]?["documents"]?.arrayValue?.count ?? 0
            let name = ui["document"]?["name"]?.stringValue ?? "–"
            print("PhotoCraft: connected (port \(settings.port)), \(docs) document(s), active: \(name)")
        } catch {
            print("PhotoCraft: \(error.localizedDescription)")
        }
        await control.close()

        guard let url = settings.baseURL else {
            print("NVAI-open: invalid address")
            return false
        }
        let nvai = NVAIClient(baseURL: url, token: settings.token)
        do {
            let health = try await nvai.health()
            print("NVAI-open: reachable, active image model: \(health["active_models"]?["image"]?.stringValue ?? "–")")
            if let info = try await nvai.version() {
                print("Version \(info.version), API \(info.api), auth \(info.auth ?? "?"), access \(info.authorized ? "allowed" : "refused"), features: \(info.features.joined(separator: ", "))")
            } else {
                print("Version: before 0.2.0 (no /api/version)")
            }
            try await nvai.checkCompatible()
            let masks = try await nvai.supportsMasks()
            let models = try await nvai.imageModels().filter { $0["runnable"]?.truthy ?? false }
            print("Masks: \(masks ? "yes" : "no"), image models: \(models.compactMap { $0["id"]?.stringValue }.joined(separator: ", "))")
            return true
        } catch {
            print("NVAI-open: \(error.localizedDescription)")
            return false
        }
    }
}
