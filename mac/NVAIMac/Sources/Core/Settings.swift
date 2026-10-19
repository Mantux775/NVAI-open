import Foundation

/// Einstellungen in den UserDefaults. Jeder Wert lässt sich beim Start überschreiben,
/// etwa für Tests: `open -n NV-AI.app --args -serverPort 8110 -modelsDirectory ~/…/models`.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    /// ~/Library/Application Support/NV-AI
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NV-AI", isDirectory: true)
    }

    static var assetsDirectory: URL { appSupport.appendingPathComponent("assets", isDirectory: true) }

    /// Wo die Modelle liegen. Der Ordner muss „models“ heißen: swift-transformers legt den
    /// Text-Encoder unter <Basis>/models/<Repo> ab und nimmt dafür den Elternordner als Basis.
    static var modelsDirectory: URL {
        get {
            if let path = defaults.string(forKey: "modelsDirectory"), !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                return normalizedModelsDirectory(url)
            }
            return appSupport.appendingPathComponent("models", isDirectory: true)
        }
        set { defaults.set(normalizedModelsDirectory(newValue).path, forKey: "modelsDirectory") }
    }

    static func normalizedModelsDirectory(_ url: URL) -> URL {
        url.lastPathComponent == "models" ? url : url.appendingPathComponent("models", isDirectory: true)
    }

    /// Port des lokalen Servers. 8100 wie NV-AI unter Windows – die PhotoCraft-App sucht dort.
    static var serverPort: UInt16 {
        get {
            let value = defaults.integer(forKey: "serverPort")
            return (1024...65535).contains(value) ? UInt16(value) : 8100
        }
        set { defaults.set(Int(newValue), forKey: "serverPort") }
    }

    static var activeModelID: String? {
        get { defaults.string(forKey: "activeModelID") }
        set { defaults.set(newValue, forKey: "activeModelID") }
    }

    /// Hugging-Face-Token für gesperrte Repos (nur für die Suche, FLUX.2 Klein braucht keinen).
    static var hfToken: String? {
        get { defaults.string(forKey: "hfToken").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "hfToken") }
    }
}
