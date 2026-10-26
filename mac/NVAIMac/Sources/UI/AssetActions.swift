import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Was man mit einem erzeugten oder hochgeladenen Asset überall tun kann (Nutzerwunsch 26.10.2026): den Speicherort im
/// Finder öffnen und die Datei mit der Standard-App des Systems öffnen (Vorschau, QuickTime Player, Musik).
/// Ein Doppelklick auf ein Asset öffnet es überall mit der Standard-App.
enum AssetActions {
    static func url(_ asset: AssetRecord) -> URL { AssetStore.shared.fileURL(asset.filename) }

    static func revealInFinder(_ asset: AssetRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([url(asset)])
    }

    static func openWithDefaultApp(_ asset: AssetRecord) {
        NSWorkspace.shared.open(url(asset))
    }

    /// Kurzhilfe für Kacheln, die per Klick etwas anderes tun (Vorschau, Auswahl, Abspielen).
    static func help(click: String) -> String {
        click + t(" · Doppelklick: mit der Standard-App öffnen · Rechtsklick: Speicherort öffnen",
                  " · Double-click: open with the default app · Right-click: show in Finder")
    }
}

/// Die zwei Einträge, die in jedem Kontextmenü eines Assets stehen.
struct AssetMenuItems: View {
    let asset: AssetRecord

    var body: some View {
        Button(t("Speicherort öffnen", "Show in Finder")) { AssetActions.revealInFinder(asset) }
        Button(t("Mit der Standard-App öffnen", "Open with the default app")) { AssetActions.openWithDefaultApp(asset) }
    }
}

/// AppKits AVPlayerView statt SwiftUIs VideoPlayer. Der kommt aus dem Überbau `_AVKit_SwiftUI`; mit dem macOS-27-SDK
/// gebaut, band die App AVKit selbst nicht ein, und auf macOS 26.6 brach der erste VideoPlayer mit
/// „getSuperclassMetadata“ ab (Absturz beim Anklicken eines Videos, 0.4.8 Build 13, 26.10.2026).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
