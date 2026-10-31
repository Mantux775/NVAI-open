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
    /// Hochgeladene Bilder (Startbild, Maske, Referenz, altes Foto), neueste zuerst.
    @Published var uploads: [AssetRecord] = []
    /// Video- und Ton-Uploads (Studio).
    @Published var mediaUploads: [AssetRecord] = []
    /// Erzeugte Musik und Klänge (seit 0.4.7), neueste zuerst.
    @Published var audios: [AssetRecord] = []
    /// Stable Audio 3 geladen?
    @Published var audioInstalled = AudioCatalog.installed
    /// Videos (seit 0.4.8, LTX-Video 2B) und ob das Modell geladen ist; dazu der Bild-Encoder fürs Startbild.
    @Published var videos: [AssetRecord] = []
    @Published var videoInstalled = VideoCatalog.installed
    @Published var videoEncoderInstalled = VideoCatalog.encoderInstalled
    @Published var models: [ModelRow] = []
    @Published var activeModelID: String = Models.active.id
    @Published var modelsDirectory: URL = Settings.modelsDirectory
    /// Ablage der erzeugten Dateien (seit 0.4.8 wählbar).
    @Published var assetsDirectory: URL = Settings.assetsDirectory
    @Published var port: UInt16 = Settings.serverPort
    /// Gewählter Reiter (generate, history, models, settings) – auch für `--snapshot --tab`.
    @Published var selectedTab = "studio"
    @Published var showSearch = false
    /// `--snapshot --tab search --search-kind video --search-query ltx`: so öffnet sich die Modellsuche.
    var searchPreset: (art: HuggingFace.Art, query: String)?
    /// „Generieren“ mit „Foto restaurieren“ öffnen (`--snapshot --tab restore`).
    @Published var showRestore = false
    /// „Generieren“ mit „Musik und Klänge“ öffnen (`--snapshot --tab audio`).
    @Published var showAudio = false
    /// „Generieren“ mit „Video“ öffnen (`--snapshot --tab video`).
    @Published var showVideo = false
    /// `--snapshot --tab player`: Verlauf öffnen und dieses Video abspielen (Prüfung des Players ohne Klick).
    @Published var snapshotPlayVideo: AssetRecord?
    /// "auto", "en" oder "de"; die Texte liefert t() aus Lang.ui.
    @Published var language: String = Lang.setting

    /// Zusatzmodelle (Qwen3.5 4B für „Automatisch“ beim Restaurieren) mit Ladestand.
    @Published var helpers: [HelperRow] = []
    /// LoRAs für FLUX.2 Klein mit Ladestand.
    @Published var loras: [LoRARow] = []

    struct LoRARow: Identifiable, Equatable {
        let model: LoRAModel
        let installed: Bool
        var id: String { model.id }
    }

    struct HelperRow: Identifiable, Equatable {
        let model: HelperModel
        let installed: Bool
        var id: String { model.id }
    }

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

    /// Ablage wechseln (seit 0.4.8). Gibt die Meldung für die Einstellungen zurück.
    func changeAssetsDirectory(_ url: URL, move: Bool) async -> String {
        do {
            let result = try await AssetStore.shared.relocate(to: url, move: move)
            assetsDirectory = Settings.assetsDirectory
            Thumbnails.clear()
            await refresh()
            AppLog.info("Assets folder changed (move \(move)): \(result.moved) moved, \(result.failed) stayed, "
                        + "\(result.merged) already there")
            var text = move
                ? t("Umgezogen: \(result.moved) Dateien.", "Moved: \(result.moved) files.")
                : t("Neue Dateien landen jetzt hier; die bisherigen bleiben im alten Ordner.",
                    "New files go here now; the previous ones stay in the old folder.")
            if result.failed > 0 {
                text += t(" \(result.failed) blieben im alten Ordner (Name schon vergeben oder nicht verschiebbar).",
                          " \(result.failed) stayed in the old folder (name already taken or not movable).")
            }
            if result.merged > 0 {
                text += t(" Im neuen Ordner lagen schon \(result.merged) Dateien von NVAI-open; der Verlauf zeigt beide.",
                          " The new folder already held \(result.merged) NVAI-open files; the history shows both.")
            }
            return text
        } catch {
            return t("Nicht gewechselt: ", "Not changed: ") + error.localizedDescription
        }
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
        // Bild-Uploads für die Bildauswahl; Video und Ton aus dem Studio getrennt (sie sind keine Ausgangsbilder)
        let allUploads = await AssetStore.shared.list(kind: "upload", limit: 1000)
        uploads = allUploads.filter { !AssetStore.mediaSuffixes.contains(($0.filename as NSString).pathExtension.lowercased()) }
        mediaUploads = allUploads.filter { AssetStore.mediaSuffixes.contains(($0.filename as NSString).pathExtension.lowercased()) }
        audios = await AssetStore.shared.list(kind: "audio", limit: 500)
        videos = await AssetStore.shared.list(kind: "video", limit: 500)
        // Ein beendeter Download ändert den Modellstatus.
        refreshModels()
    }

    func refreshModels() {
        let rows = Models.all.map { ModelRow(model: $0, installed: $0.installed, partial: $0.partiallyInstalled) }
        if rows != models { models = rows }
        let helperRows = HelperModel.allCases.map { HelperRow(model: $0, installed: $0.installed) }
        if helperRows != helpers { helpers = helperRows }
        let loraRows = LoRACatalog.all.map { LoRARow(model: $0, installed: $0.installed) }
        if loraRows != loras { loras = loraRows }
        let audioOK = AudioCatalog.installed
        if audioOK != audioInstalled { audioInstalled = audioOK }
        let videoOK = VideoCatalog.installed
        if videoOK != videoInstalled { videoInstalled = videoOK }
        let encoderOK = VideoCatalog.encoderInstalled
        if encoderOK != videoEncoderInstalled { videoEncoderInstalled = encoderOK }
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
