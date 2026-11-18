import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Bereich „Ton-Forensik“ (seit 0.5.7, Stufe 1 ohne KI): Prüfpakete öffnen, die NVAI-open unter Windows exportiert hat,
/// alle Spuren und das Video abspielen, die Übersetzer-Spur prüfen und korrigieren, Notizen setzen und exportieren (WAV,
/// Video mit Ton, Untertitel, Text). Angezeigt wird dieselbe Prüf-App wie im Paket (NVAI-Pruefer.html aus dem Bundle),
/// über den eigenen Server auf 127.0.0.1 (`ReviewRoutes`); Ordner- und Speichern-Dialog kommen von der App
/// (`ReviewBridge`), weil WebKit kein File System Access hat. Spracherkennung und Übersetzung auf dem Mac folgen (Stufe 2).
struct ForensicView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.serverState {
        case .listening(let port):
            ReviewWebView(port: port)
        default:
            VStack(spacing: 10) {
                ProgressView()
                Text(state.serverDescription).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Der WKWebView bleibt über Reiterwechsel erhalten (ein geöffneter Fall soll nicht beim Wechsel ins Studio verloren gehen).
struct ReviewWebView: NSViewRepresentable {
    let port: UInt16

    func makeNSView(context: Context) -> WKWebView { ReviewBridge.shared.view(port: port) }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Startoptionen zum Prüfen ohne Maus (Claude hat am Mac keine Bedienungshilfen-Freigabe):
///
///     NVAI-open --snapshot <png> --tab forensic --review-package <paketordner> [--review-script <js>]
///               [--review-save-dir <ordner>] [--review-shot <png>] [--quit]
///
/// `--review-package` öffnet das Paket ohne Dialog (mit Schreiben nach „bearbeitung/“), `--review-script` führt nach dem
/// Laden eine async-Funktion in der Seite aus und schreibt ihr Ergebnis ins Protokoll („Review script: …“),
/// `--review-save-dir` legt Exporte ohne Speichern-Dialog in diesen Ordner, `--review-shot` fotografiert die Seite
/// (das Fensterfoto zeigt WebKit-Inhalte nicht).
enum ReviewTest {
    private static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return (args[i + 1] as NSString).expandingTildeInPath
    }

    static var package: String? { value("--review-package") }
    static var script: String? { value("--review-script") }
    static var saveDir: String? { value("--review-save-dir") }
    static var shot: String? { value("--review-shot") }
    static var active: Bool { package != nil }
    @MainActor static var finished = false
}

@MainActor
final class ReviewBridge: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let shared = ReviewBridge()

    private var webView: WKWebView?
    private var loadedPort: UInt16 = 0
    private var testRan = false

    func view(port: UInt16) -> WKWebView {
        let view = webView ?? makeView()
        if loadedPort != port {
            loadedPort = port
            load(view, port: port)
        }
        return view
    }

    private func makeView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "nvaiReview")
        ucc.add(self, name: "nvaiLog")
        ucc.addUserScript(WKUserScript(source: Self.startScript(lang: Lang.ui.rawValue), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = .windowBackgroundColor
        webView = view
        return view
    }

    /// Sprache wie die App; Fehler der Seite ins Protokoll der App (~/Library/Logs/NV-AI/nvai.log).
    private static func startScript(lang: String) -> String {
        """
        (() => {
          try { localStorage.setItem('nvai-lang', '\(lang)') } catch (e) {}
          const post = (level, args) => { try { window.webkit.messageHandlers.nvaiLog.postMessage(level + ': ' + args.map((a) => (a && a.message) || String(a)).join(' ').slice(0, 400)) } catch (e) {} }
          const err = console.error.bind(console)
          console.error = (...a) => { post('error', a); err(...a) }
          window.addEventListener('error', (ev) => post('error', [ev.message + ' @' + ev.lineno]))
          window.addEventListener('unhandledrejection', (ev) => post('error', ['unhandled: ' + ((ev.reason && ev.reason.message) || ev.reason)]))
        })()
        """
    }

    private func load(_ view: WKWebView, port: UInt16) {
        let base = "http://127.0.0.1:\(port)/review/app"
        guard let path = ReviewTest.package else {
            view.load(URLRequest(url: URL(string: base)!))
            return
        }
        Task { @MainActor in
            let token = await ReviewPackages.shared.register(URL(fileURLWithPath: path))
            view.load(URLRequest(url: URL(string: "\(base)?paket=/review/pkg/\(token)/&schreiben=1")!))
        }
    }

    // MARK: Nachrichten der Seite

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nvaiLog", let text = message.body as? String { AppLog.info("Review page: \(text)") }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        let window = message.webView?.window
        Task { @MainActor in
            let reply = await self.answer(body, window: window)
            replyHandler(reply, nil)
        }
    }

    private func answer(_ body: [String: Any], window: NSWindow?) async -> [String: Any] {
        switch body["op"] as? String {
        case "open": return await openPackage(window: window)
        case "save": return await saveTarget(name: body["name"] as? String ?? "export", ext: body["ext"] as? String ?? "", window: window)
        default: return ["error": "unknown op"]
        }
    }

    private func runPanel(_ panel: NSSavePanel, window: NSWindow?) async -> Bool {
        await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
            } else {
                continuation.resume(returning: panel.runModal() == .OK)
            }
        }
    }

    private func openPackage(window: NSWindow?) async -> [String: Any] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = t("Ordner des Prüfpakets wählen (der Ordner, in dem NVAI-Pruefer.html liegt).",
                          "Choose the folder of the review package (the folder that contains NVAI-Pruefer.html).")
        panel.prompt = t("Öffnen", "Open")
        guard await runPanel(panel, window: window), var url = panel.url else { return [:] }
        // auch den Unterordner „fall“ annehmen
        if !ReviewPackages.isPackage(url), url.lastPathComponent == "fall", ReviewPackages.isPackage(url.deletingLastPathComponent()) {
            url = url.deletingLastPathComponent()
        }
        guard ReviewPackages.isPackage(url) else {
            return ["error": t("Das ist kein Prüfpaket von NVAI-open (fall/manifest.json fehlt). Bitte den Ordner wählen, in dem NVAI-Pruefer.html liegt.",
                               "This is not an NVAI-open review package (fall/manifest.json missing). Please choose the folder that contains NVAI-Pruefer.html.")]
        }
        let token = await ReviewPackages.shared.register(url)
        return ["base": "/review/pkg/\(token)/"]
    }

    private func saveTarget(name: String, ext: String, window: NSWindow?) async -> [String: Any] {
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let url: URL
        if let dir = ReviewTest.saveDir {
            url = URL(fileURLWithPath: dir).appendingPathComponent(clean)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = clean
            panel.canCreateDirectories = true
            let bare = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !bare.isEmpty, let type = UTType(filenameExtension: bare) { panel.allowedContentTypes = [type] }
            guard await runPanel(panel, window: window), let chosen = panel.url else { return [:] }
            url = chosen
        }
        do {
            let token = try await ReviewExports.shared.register(url)
            return ["url": "/review/out/\(token)", "name": url.lastPathComponent]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: Navigation und Dialoge der Seite

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if ["blob", "about", "data"].contains(url.scheme ?? "") { return .allow }
        if url.host == "127.0.0.1", url.path.hasPrefix("/review/") { return .allow }
        // Verweise nach draußen (Lizenztexte) im Browser, nie in diesem Fenster
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard ReviewTest.active, !testRan else { return }
        testRan = true
        Task { @MainActor in await self.runTest(webView) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        _ = await sheet(alert, window: webView.window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        return await sheet(alert, window: webView.window) == .alertFirstButtonReturn
    }

    private func sheet(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: alert.runModal())
            }
        }
    }

    // MARK: Prüfstand

    private func runTest(_ webView: WKWebView) async {
        try? await Task.sleep(nanoseconds: 8_000_000_000)   // Paket laden, Arbeitsfläche aufbauen
        if let path = ReviewTest.script, let source = try? String(contentsOfFile: path, encoding: .utf8) {
            do {
                let result = try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
                AppLog.info("Review script: \(String(describing: result ?? "nil"))")
            } catch {
                AppLog.error("Review script failed: \(error.localizedDescription)")
            }
        }
        if let shot = ReviewTest.shot {
            let image: NSImage? = await withCheckedContinuation { continuation in
                webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in continuation.resume(returning: image) }
            }
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: shot))
                    AppLog.info("Review shot written: \(shot)")
                } catch {
                    AppLog.error("Review shot not written: \(error.localizedDescription)")
                }
            }
        }
        ReviewTest.finished = true
    }
}
