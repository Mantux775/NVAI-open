import AppKit
import Foundation

/// PhotoCraft mit Steuerkanal starten (docs/mac-port.md, Abschnitt 1).
public struct PhotoCraftLaunch: Equatable, Sendable {
    public var appURL: URL
    public var port: UInt16
    public var tokenFile: URL
    public var exchange: URL
    /// Nur für Testinstanzen: eigener Einstellungsordner (`PHOTOCRAFT_CONFIG_DIR`).
    public var configDirectory: URL?

    public init(appURL: URL = URL(fileURLWithPath: "/Applications/PhotoCraft.app"), port: UInt16 = 47821,
                tokenFile: URL, exchange: URL, configDirectory: URL? = nil) {
        self.appURL = appURL
        self.port = port
        self.tokenFile = tokenFile
        self.exchange = exchange
        self.configDirectory = configDirectory
    }

    /// Nutzerbezogener Datenordner: `~/Library/Application Support/ArtCraft-LocalAI`.
    public static func defaultDataDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtCraft-LocalAI", isDirectory: true)
    }

    public static func standard(port: UInt16 = 47821) -> PhotoCraftLaunch {
        let data = defaultDataDirectory()
        return PhotoCraftLaunch(port: port, tokenFile: data.appendingPathComponent("photocraft-control.token"),
                                exchange: data.appendingPathComponent("exchange", isDirectory: true))
    }

    /// Startparameter für PhotoCraft.
    public var arguments: [String] {
        ["--control", String(port), "--control-token-file", tokenFile.path,
         "--automation-read-root", exchange.path, "--automation-write-root", exchange.path]
    }

    public var environment: [String: String] {
        configDirectory.map { ["PHOTOCRAFT_CONFIG_DIR": $0.path] } ?? [:]
    }

    /// Gleichwertiger Aufruf von `open` (für Skripte und die Fehlersuche).
    public var openCommand: [String] {
        var cmd = ["open", "-n", "-a", appURL.path]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(key)=\(value)"] }
        return cmd + ["--args"] + arguments
    }

    // MARK: PhotoCraft finden

    public static let bundleIdentifier = "ai.storyteller.photocraft"
    /// Neueste Veröffentlichung. Die Seite getartcraft.com/apps/photocraft verlinkte im Oktober 2026
    /// noch 0.7.0, während 0.10.0 aktuell war.
    public static let downloadURL = URL(string: "https://github.com/storytold/photocraft/releases/latest")!
    /// Mit dieser Version ist der Steuerkanal vermessen; ältere bekommen einen Hinweis.
    public static let testedVersion = "0.10.0"

    /// Installiertes PhotoCraft – über die Bundle-ID (Launch Services, egal in welchem Ordner),
    /// sonst `/Applications/PhotoCraft.app`. `nil`, wenn es keines gibt.
    public static func installedApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) { return url }
        let fallback = URL(fileURLWithPath: "/Applications/PhotoCraft.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// `CFBundleShortVersionString` aus der Info.plist – frisch gelesen, denn `Bundle` merkt sich
    /// den Stand und sähe ein Update nicht.
    public static func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// „0.7.0“ ist älter als „0.10.0“: Stellen als Zahlen vergleichen, fehlende zählen als 0
    /// (wie `config.version_older` der Brücke). Ohne Zahlen kein Urteil.
    public static func isVersion(_ version: String, olderThan reference: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            Array(text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }.prefix(3))
        }
        let a = parts(version), b = parts(reference)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Datenordner anlegen (Token-Ordner nur für den Nutzer) und PhotoCraft als neue Instanz starten.
    @MainActor
    public func launch() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: exchange.appendingPathComponent("jobs", isDirectory: true), withIntermediateDirectories: true)
        let tokenDir = tokenFile.deletingLastPathComponent()
        try fm.createDirectory(at: tokenDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tokenDir.path)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = arguments
        if !environment.isEmpty { config.environment = environment }
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
}
