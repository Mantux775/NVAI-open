import AVFoundation
import Foundation

/// Medieninfo für das Studio, wie probe() unter Windows: Art, Dauer in Ticks, Ton, Format. AVFoundation lädt
/// asynchron; deshalb liest StudioStore die Assets eines Befehls vorher (`prefetch`), und die synchronen Befehle
/// finden die Werte hier im Zwischenspeicher.
final class StudioMediaCache: @unchecked Sendable {
    static let shared = StudioMediaCache()
    private let lock = NSLock()
    private var byID: [String: StudioMedia] = [:]

    func get(_ id: String) -> StudioMedia? {
        lock.lock()
        defer { lock.unlock() }
        return byID[id]
    }

    func set(_ id: String, _ media: StudioMedia) {
        lock.lock()
        byID[id] = media
        lock.unlock()
    }
}

enum StudioMediaProbe {
    static let imageSuffixes: Set<String> = ["png", "jpg", "jpeg", "webp", "bmp", "heic", "tif", "tiff"]

    /// Umgebung der Studio-Befehle in der App: Medieninfo aus dem Zwischenspeicher, Assets aus dem AssetStore.
    static let environment = StudioEnvironment(
        probe: { id in
            if let m = StudioMediaCache.shared.get(id) { return m }
            guard AssetSnapshot.shared.get(id) != nil else {
                throw StudioError(t("Unbekanntes Asset: \(id)", "Unknown asset: \(id)"), notFound: true)
            }
            throw StudioError(t("Datei nicht lesbar: \(id)", "Cannot read file: \(id)"))
        },
        asset: { id in
            guard let r = AssetSnapshot.shared.get(id) else { return nil }
            return StudioAssetInfo(kind: r.kind, filename: r.filename, prompt: r.prompt, meta: r.meta)
        })

    /// Medieninfo der genannten Assets lesen, soweit noch nicht bekannt. Unbekannte oder unlesbare bleiben weg; der
    /// Befehl meldet sie dann selbst.
    static func prefetch(_ ids: [String]) async {
        for id in Set(ids) where StudioMediaCache.shared.get(id) == nil {
            guard let record = AssetSnapshot.shared.get(id) else { continue }
            if let m = try? await probe(record: record) { StudioMediaCache.shared.set(id, m) }
        }
    }

    static func probe(record r: AssetRecord) async throws -> StudioMedia {
        let url = AssetStore.shared.fileURL(r.filename)
        if r.kind == "image" || imageSuffixes.contains(url.pathExtension.lowercased()) {
            return StudioMedia(kind: "image", duration: nil)
        }
        return try await probe(url: url)
    }

    static func probe(url: URL) async throws -> StudioMedia {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        guard duration.seconds.isFinite, duration.seconds > 0, video != nil || audio != nil else {
            throw StudioError(t("Datei nicht lesbar: \(url.lastPathComponent)", "Cannot read file: \(url.lastPathComponent)"))
        }
        var m = StudioMedia(kind: video != nil ? "video" : "audio", duration: Studio.ticks(duration.seconds),
                            audio: audio != nil)
        if let video {
            let (size, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            m.width = Int(abs(shown.width).rounded())
            m.height = Int(abs(shown.height).rounded())
            m.fps = Double(fps)
        }
        return m
    }

    /// Asset-IDs, deren Medieninfo ein Befehl brauchen kann: asset_id und takes in den Parametern (auch in batch),
    /// dazu Takes der Szenen und Clips des Projekts (Übernehmen, Tempo, Trimmen).
    static func referencedAssets(_ params: StudioParams, _ p: StudioProject) -> [String] {
        var ids: [String] = []
        func walk(_ v: JSONValue, key: String?) {
            switch v {
            case .string(let s) where key == "asset_id": ids.append(s)
            case .array(let a): a.forEach { walk($0, key: key == "takes" ? "asset_id" : key) }
            case .object(let o): o.forEach { walk($0.value, key: $0.key) }
            default: break
            }
        }
        walk(.object(params), key: nil)
        ids += p.scenes.flatMap { $0.takes + ($0.take.map { [$0] } ?? []) }
        ids += p.clips.map(\.assetID)
        return ids
    }
}
