import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Vorschaubilder aus den Asset-Dateien, zwischengespeichert.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for asset: AssetRecord, maxSide: Int = 320) -> NSImage? {
        let key = "\(asset.filename)#\(maxSide)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cg = ImageFiles.thumbnail(AssetStore.shared.fileURL(asset.filename), maxSide: maxSide) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }

    static func image(at url: URL, maxSide: Int = 160) -> NSImage? {
        let key = "\(url.path)#\(maxSide)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cg = ImageFiles.thumbnail(url, maxSide: maxSide) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AssetThumbnail: View {
    let asset: AssetRecord
    var maxSide = 320

    var body: some View {
        Group {
            if let image = Thumbnails.image(for: asset, maxSide: maxSide) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary).overlay(Text("?").foregroundStyle(.secondary))
            }
        }
    }
}

enum Panels {
    @MainActor
    static func chooseImage(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Ein oder mehrere Bilder zum Hochladen (Referenzen nehmen mehrere auf einmal).
    @MainActor
    static func chooseImages(_ title: String, multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func chooseFolder(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
