import AVFoundation
import ImageIO
import SwiftUI

/// Vorschaubilder für Material und Clips (wie die Medienliste und die Clips unter Windows): Bilder über ImageIO
/// verkleinert, Videos ihr Bild bei 0,5 s. Im Speicher gehalten; erzeugt im Hintergrund, die Ansicht lädt nach.
@MainActor
final class StudioThumbnails: ObservableObject {
    static let shared = StudioThumbnails()
    @Published private(set) var images: [String: CGImage] = [:]
    private var pending: Set<String> = []

    func image(_ assetID: String) -> CGImage? {
        if let img = images[assetID] { return img }
        load(assetID)
        return nil
    }

    private func load(_ assetID: String) {
        guard !pending.contains(assetID), let record = AssetSnapshot.shared.get(assetID) else { return }
        pending.insert(assetID)
        let url = AssetStore.shared.fileURL(record.filename)
        let ext = url.pathExtension.lowercased()
        Task.detached(priority: .utility) {
            var img: CGImage?
            if StudioMediaProbe.imageSuffixes.contains(ext) {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    img = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }
            } else if ["mp4", "mov", "m4v"].contains(ext) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 240)
                img = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            }
            await MainActor.run {
                if let img { StudioThumbnails.shared.images[assetID] = img }
            }
        }
    }
}

/// Ein Vorschaubild oder, solange es fehlt (Ton, noch nicht geladen), ein Symbol.
struct StudioThumb: View {
    let assetID: String
    var symbol = "film"
    @ObservedObject private var thumbs = StudioThumbnails.shared

    var body: some View {
        if let img = thumbs.image(assetID) {
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
    }
}
