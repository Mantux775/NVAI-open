import AppKit
import AVFoundation
import SwiftUI

/// Erstes Bild eines Videos als Vorschau (seit 0.4.8).
struct VideoThumbnail: View {
    let url: URL
    var maxSide: CGFloat = 480
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(1.5, contentMode: .fit)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 3)
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            if let frame = try? await generator.image(at: .zero) {
                image = NSImage(cgImage: frame.image, size: .zero)
            }
        }
    }
}

/// Spielt ein Video in Schleife ab.
struct VideoPlayerSheet: View {
    let asset: AssetRecord
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerView(player: player)
                .frame(minWidth: 640, minHeight: 400)
            Text(asset.prompt).font(.callout).lineLimit(3)
            HStack {
                Button(t("Speicherort öffnen", "Show in Finder")) { AssetActions.revealInFinder(asset) }
                Button(t("Mit der Standard-App öffnen", "Open with the default app")) {
                    AssetActions.openWithDefaultApp(asset)
                }
                Spacer()
                Button(t("Schließen", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .onAppear {
            let item = AVPlayerItem(url: AssetStore.shared.fileURL(asset.filename))
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        }
        .onDisappear { player.pause() }
    }
}

/// Ein Video mit Vorschaubild, Prompt und Angaben; Klick spielt es ab.
struct VideoRow: View {
    let asset: AssetRecord
    @State private var playing = false

    private var details: String {
        let m = asset.meta
        var parts: [String] = []
        if let w = m["width"]?.intValue, let h = m["height"]?.intValue { parts.append("\(w) × \(h)") }
        if let s = m["seconds"]?.doubleValue { parts.append(String(format: "%.1f s", s)) }
        if m["image_asset_id"]?.stringValue != nil { parts.append(t("mit Startbild", "with start image")) }
        if let d = m["duration_s"]?.doubleValue { parts.append(t("gerechnet \(Int(d)) s", "took \(Int(d)) s")) }
        if let seed = m["seed"]?.intValue { parts.append("Seed \(seed)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: AssetStore.shared.fileURL(asset.filename))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { AssetActions.openWithDefaultApp(asset) }
                .onTapGesture { playing = true }
                .help(AssetActions.help(click: t("Klick: abspielen", "Click: play")))
            Text(asset.prompt).lineLimit(2).font(.callout)
            Text(details).font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(t("Abspielen", "Play")) { playing = true }
            AssetMenuItems(asset: asset)
        }
        .sheet(isPresented: $playing) { VideoPlayerSheet(asset: asset) }
    }
}

/// LTX-Video 2B unter „Modelle“: laden, Fortschritt, löschen.
struct VideoModelCard: View {
    @EnvironmentObject var state: AppState

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == VideoCatalog.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == VideoCatalog.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(VideoCatalog.name).font(.headline)
                    Text(ContentRating.label(VideoCatalog.id)).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(.secondary.opacity(0.5)))
                        .foregroundStyle(.secondary)
                        .help(ContentRating.help(VideoCatalog.id))
                    FitBadges(fit: MacFit.of(needGB: MacFit.videoNeedGB),
                              recommended: MacRecommendations.isRecommended(VideoCatalog.id))
                    Spacer()
                    Text(state.videoInstalled ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                        .foregroundStyle(state.videoInstalled ? .green : .secondary)
                }
                Text(VideoCatalog.description).font(.callout)
                Text(String(format: t("Download %.1f GB · ab 8 GB Arbeitsspeicher · LTX-Video Open Weights License",
                                      "Download %.1f GB · from 8 GB of memory · LTX-Video Open Weights License"),
                            VideoCatalog.downloadGB))
                    .font(.caption).foregroundStyle(.secondary)
                if state.videoInstalled {
                    // Wer das Modell vor dem Startbild geladen hat (bis Build 14), holt den Encoder hier nach.
                    Text(state.videoEncoderInstalled
                         ? t("Startbild: bereit (Bild-Encoder geladen).", "Start image: ready (image encoder downloaded).")
                         : t("Startbild: braucht den Bild-Encoder, 1,4 GB Download.", "Start image: needs the image encoder, 1.4 GB download."))
                        .font(.caption).foregroundStyle(state.videoEncoderInstalled ? .green : .orange)
                }
                if let download {
                    ProgressView(value: download.progress)
                    Text(download.stage).font(.caption).foregroundStyle(.secondary)
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if !state.videoInstalled {
                        Button(t("Herunterladen", "Download")) {
                            Task { _ = await JobQueue.shared.submitVideoDownload() }
                        }
                        .disabled(download != nil)
                    } else {
                        if !state.videoEncoderInstalled {
                            Button(t("Startbild nachrüsten", "Add start image")) {
                                Task { _ = await JobQueue.shared.submitVideoDownload() }
                            }
                            .disabled(download != nil)
                        }
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            Task {
                                await VideoEngine.shared.unload()
                                VideoCatalog.delete()
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
