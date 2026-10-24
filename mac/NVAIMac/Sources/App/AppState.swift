import Foundation
import SwiftUI

/// Verbindet Oberfläche, Server und Warteschlange. Alles Sichtbare läuft auf dem Main Actor;
/// Server und Aufträge melden Änderungen, die Oberfläche holt sich dann den neuen Stand.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var serverState: HTTPServer.State = .stopped
    @Published var jobs: [JobRecord] = []
    @Published var images: [AssetRecord] = []
    @Published var models: [ModelRow] = []
    @Published var activeModelID: String = Models.active.id
    @Published var modelsDirectory: URL = Settings.modelsDirectory
    @Published var port: UInt16 = Settings.serverPort
    /// Gewählter Reiter (generate, history, models, settings) – auch für `--snapshot --tab`.
    @Published var selectedTab = "generate"
    @Published var showSearch = false
    /// "auto", "en" oder "de"; die Texte liefert t() aus Lang.ui.
    @Published var language: String = Lang.setting

    struct ModelRow: Identifiable, Equatable {
        let model: AnyModel
        let installed: Bool
        let partial: Bool
        var id: String { model.id }
    }

    private var server: HTTPServer?
    private var started = false
    private var startTask: Task<Void, Never>?
    private var refreshScheduled = false

    /// Startet alles, was ohne Fenster laufen muss – aufgerufen vom AppDelegate beim Programmstart,
    /// nicht erst vom Fenster: Die PhotoCraft-App öffnet NVAI-open im Hintergrund.
    func start() async {
        // Fenster (.task) und AppDelegate rufen beide; der zweite wartet auf den ersten,
        // damit z. B. --report erst nach dem Laden der Bilder schreibt.
        if let running = startTask {
            await running.value
            return
        }
        let task = Task { @MainActor in await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        guard !started else { return }
        started = true
        // Der Server zuerst: Clients warten auf /api/version, alles andere kann nachkommen.
        ensureServer()
        Flux2Engine.configureModelsDirectory(modelsDirectory)
        await AssetStore.shared.load()
        let notify: @Sendable () -> Void = { Task { @MainActor in AppState.shared.scheduleRefresh() } }
        await AssetStore.shared.setOnChange(notify)
        await JobQueue.shared.setOnChange(notify)
        refreshModels()
        await refresh()
        AppLog.info("Ready: \(Models.all.filter(\.installed).count) model(s) installed, active \(Models.active.id)")
    }

    /// Startet den Server einmal. SwiftUI legt das Fenster (und dessen .task) mitunter vor
    /// applicationDidFinishLaunching an – zwei Starts hätten den Listener neu aufgesetzt (gemessen).
    func ensureServer() {
        if server == nil { startServer() }
    }

    func startServer() {
        let server = self.server ?? HTTPServer { request in await APIRouter.handle(request) }
        server.onStateChange = { state in Task { @MainActor in AppState.shared.serverState = state } }
        self.server = server
        server.start(port: port)
    }

    func changePort(_ newPort: UInt16) {
        port = newPort
        Settings.serverPort = newPort
        startServer()
    }

    func changeModelsDirectory(_ url: URL) async {
        let normalized = Settings.normalizedModelsDirectory(url)
        Settings.modelsDirectory = normalized
        modelsDirectory = normalized
        await Flux2Engine.shared.unload()
        Flux2Engine.configureModelsDirectory(normalized)
        refreshModels()
    }

    /// Sprache umstellen: alle Ansichten beobachten AppState und zeichnen sich neu.
    func setLanguage(_ value: String) {
        Lang.setting = value
        Lang.applyToMenus()
        language = value
        AppLog.info("Language set to \(value) (\(Lang.ui.rawValue))")
        refreshModels()
    }

    func setActiveModel(_ id: String) {
        Settings.activeModelID = id
        activeModelID = id
    }

    /// Bündelt viele Fortschrittsmeldungen zu höchstens vier Aktualisierungen pro Sekunde.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            refreshScheduled = false
            await refresh()
        }
    }

    func refresh() async {
        jobs = await JobQueue.shared.list(limit: 200)
        images = await AssetStore.shared.list(kind: "image", limit: 1000)
        // Ein beendeter Download ändert den Modellstatus.
        refreshModels()
    }

    func refreshModels() {
        let rows = Models.all.map { ModelRow(model: $0, installed: $0.installed, partial: $0.partiallyInstalled) }
        if rows != models { models = rows }
        activeModelID = Models.active.id
    }

    var serverDescription: String {
        switch serverState {
        case .stopped: return t("Server aus", "Server stopped")
        case .starting: return t("Server startet …", "Server starting …")
        case .listening(let p): return t("Server läuft: http://127.0.0.1:\(p)", "Server running: http://127.0.0.1:\(p)")
        case .failed(let message): return t("Server-Fehler: \(message)", "Server error: \(message)")
        }
    }

    var runningJob: JobRecord? { jobs.first { $0.status == "running" } }
}
