import AppKit
import AVFoundation
import SwiftUI

/// Spielt erzeugte Klänge ab (seit 0.4.7); immer nur einer zur Zeit.
@MainActor
final class AudioPlayback: ObservableObject {
    static let shared = AudioPlayback()

    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ asset: AssetRecord) {
        if playingID == asset.id {
            stop()
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: AssetStore.shared.fileURL(asset.filename)) else { return }
        player = p
        p.play()
        playingID = asset.id
        // Ende erkennen ohne Delegate: einmal pro halbe Sekunde nachsehen.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if !player.isPlaying { self.stop() }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingID = nil
    }
}

/// Eine Zeile mit Abspielknopf, Prompt und Angaben zu einem Klang.
struct AudioRow: View {
    let asset: AssetRecord
    @ObservedObject private var playback = AudioPlayback.shared

    private var details: String {
        let m = asset.meta
        var parts: [String] = []
        if let s = m["seconds"]?.doubleValue { parts.append("\(Int(s)) s") }
        if let d = m["duration_s"]?.doubleValue { parts.append(t("gerechnet \(Int(d)) s", "took \(Int(d)) s")) }
        if let seed = m["seed"]?.intValue { parts.append("Seed \(seed)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                playback.toggle(asset)
            } label: {
                Image(systemName: playback.playingID == asset.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .help(playback.playingID == asset.id ? t("Anhalten", "Stop") : t("Abspielen", "Play"))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.prompt).lineLimit(2).font(.callout)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .contextMenu {
            Button(t("Im Finder zeigen", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(asset.filename)])
            }
        }
    }
}

/// Stable Audio 3 unter „Modelle“: laden, Fortschritt, löschen.
struct AudioModelCard: View {
    @EnvironmentObject var state: AppState

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == AudioCatalog.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == AudioCatalog.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(AudioCatalog.name).font(.headline)
                    Spacer()
                    Text(state.audioInstalled ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                        .foregroundStyle(state.audioInstalled ? .green : .secondary)
                }
                Text(AudioCatalog.description).font(.callout)
                Text(String(format: t("Download %.1f GB · bis %d s je Klang auf diesem Mac", "Download %.1f GB · up to %d s per clip on this Mac"),
                            AudioCatalog.downloadGB, Int(AudioCatalog.maxSeconds)))
                    .font(.caption).foregroundStyle(.secondary)
                if let download {
                    ProgressView(value: download.progress)
                    Text(download.stage).font(.caption).foregroundStyle(.secondary)
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if !state.audioInstalled {
                        Button(t("Herunterladen", "Download")) {
                            Task { _ = await JobQueue.shared.submitAudioDownload() }
                        }
                        .disabled(download != nil)
                    } else {
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            Task {
                                await AudioEngine.shared.unload()
                                AudioCatalog.delete()
                                state.refreshModels()
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
