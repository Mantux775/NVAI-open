import AVFoundation
import CoreImage
import Foundation

/// Export des Schnitts, nach server/nvai/studio_render.py (Windows): Bild für Bild aus den Clips zusammengesetzt
/// (V1 unten, darüber V2 …), mit Übergängen und Skalieren; Ton gemischt, auf −14 LUFS gebracht und begrenzt; kodiert
/// über AVAssetWriter (VideoToolbox). Core Image mischt im sRGB-Raum, nicht linear, damit Überblendungen wie unter
/// Windows aussehen.
/// Auftrag „Studio exportieren“ in der JobQueue.
struct StudioExportRequest: Sendable {
    var projectID: String
    var preset: String
    var lang: Lang = Lang.current
}

enum StudioRender {
    struct Preset: Sendable {
        var id: String
        var label: (de: String, en: String)
        var codec: AVVideoCodecType
        var width: Int?
        var height: Int?
        var bitrate: Int?
        var ext: String
    }

    /// Vorlagen wie unter Windows, soweit macOS sie schreibt: AV1 kodiert VideoToolbox nicht, FFV1/MKV gibt es nicht
    /// (dafür ProRes 4444 als Weg ohne sichtbare Verluste).
    static let presets: [Preset] = [
        Preset(id: "youtube-1080p", label: ("YouTube 1080p (H.264)", "YouTube 1080p (H.264)"), codec: .h264,
               width: 1920, height: 1080, bitrate: 24_000_000, ext: "mp4"),
        Preset(id: "youtube-2160p", label: ("YouTube 4K (H.265)", "YouTube 4K (H.265)"), codec: .hevc,
               width: 3840, height: 2160, bitrate: 40_000_000, ext: "mp4"),
        Preset(id: "shorts-1080x1920", label: ("Hochformat 1080 × 1920 (Shorts)", "Vertical 1080 × 1920 (Shorts)"),
               codec: .h264, width: 1080, height: 1920, bitrate: 10_000_000, ext: "mp4"),
        Preset(id: "project", label: ("Projektformat (H.264)", "Project format (H.264)"), codec: .h264,
               width: nil, height: nil, bitrate: nil, ext: "mp4"),
        Preset(id: "prores", label: ("ProRes 4444 (MOV, für Schnittprogramme)", "ProRes 4444 (MOV, for editing software)"),
               codec: .proRes4444, width: nil, height: nil, bitrate: nil, ext: "mov"),
    ]

    static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

    // MARK: Plan

    struct Clip: Sendable {
        var track: String
        var url: URL
        var media: String  // video | image | audio
        var audio: Bool
        var start: Double
        var inPoint: Double
        var outPoint: Double
        var speed: Double
        var gainDB: Double
        var scale: Double
        var anchor: [Double]
        var scaleKeys: [(t: Double, v: Double)]
        var muted: Bool
        var transition: (kind: String, seconds: Double)?

        var length: Double { (outPoint - inPoint) / speed }
        var end: Double { start + length }

        /// Skalierung zur Medienzeit (Sekunden), wie scale_of unter Windows.
        func scale(at mediaT: Double) -> Double {
            guard let first = scaleKeys.first, let last = scaleKeys.last else { return scale }
            if mediaT <= first.t { return first.v }
            for (a, b) in zip(scaleKeys, scaleKeys.dropFirst()) where mediaT <= b.t {
                return a.v + (b.v - a.v) * (mediaT - a.t) / max(1e-9, b.t - a.t)
            }
            return last.v
        }
    }

    struct Plan: Sendable {
        var width: Int
        var height: Int
        var fps: (num: Int, den: Int)
        var sampleRate: Int
        var preset: Preset
        var duration: Double
        var tracks: [String]  // sichtbare Spuren
        var clips: [Clip]
        var loudness = -14.0
        var ceilingDB: Double
    }

    /// Was der Export braucht: Dateien, Clips in Sekunden, Ausgabeformat (wie render_plan unter Windows).
    static func plan(_ p: StudioProject, preset id: String) throws -> Plan {
        guard let pr = preset(id) else {
            throw StudioError(t("Unbekannte Vorlage: \(id)", "Unknown preset: \(id)"))
        }
        guard !p.clips.isEmpty else {
            throw StudioError(t("Der Schnitt ist leer: erst Szenen übernehmen oder Clips anlegen.",
                                "The edit is empty: conform scenes or add clips first."))
        }
        let tracks = Dictionary(p.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var clips: [Clip] = []
        for c in p.clips {
            guard let record = AssetSnapshot.shared.get(c.assetID),
                  FileManager.default.fileExists(atPath: AssetStore.shared.fileURL(record.filename).path) else {
                throw StudioError(t("Datei fehlt: \(c.assetID)", "File missing: \(c.assetID)"))
            }
            let media = p.media[c.assetID] ?? StudioMediaCache.shared.get(c.assetID)
                ?? StudioMedia(kind: record.kind == "audio" ? "audio" : "video", duration: nil, audio: true)
            clips.append(Clip(track: c.track, url: AssetStore.shared.fileURL(record.filename), media: media.kind,
                              audio: media.audio ?? false, start: Studio.seconds(c.start),
                              inPoint: Studio.seconds(c.inPoint), outPoint: Studio.seconds(c.outPoint), speed: c.speed,
                              gainDB: c.gainDB, scale: c.scale ?? 1, anchor: c.anchor ?? [0.5, 0.5],
                              scaleKeys: (c.scaleKeys ?? []).map { (Studio.seconds($0.at), $0.value) },
                              // stumm geschaltete Spur: ihr Ton fehlt, auch der Ton von Videoclips
                              muted: c.muted || (tracks[c.track]?.isMuted ?? false),
                              transition: c.transition.map { ($0.kind, Studio.seconds($0.duration)) }))
        }
        let lossless = pr.codec == .proRes4444  // PCM schwingt nicht über wie AAC
        return Plan(width: (pr.width ?? p.settings.width) / 2 * 2, height: (pr.height ?? p.settings.height) / 2 * 2,
                    fps: (p.settings.fps[0], p.settings.fps[1]), sampleRate: 48000, preset: pr,
                    duration: Studio.seconds(p.editDuration),
                    // ausgeblendete Videospuren fehlen im Bild (ihr Ton bleibt, solange die Spur nicht stumm ist)
                    tracks: p.tracks.filter { !$0.isHidden }.map(\.id), clips: clips, ceilingDB: lossless ? -1 : -2.5)
    }

    // MARK: Bildquellen

    static let coverTolerance = 0.05
    static let timeSlack = 0.001  // s; kürzer als jedes Bild (120 fps: 8,3 ms)

    /// Ins Ausgabeformat bringen: füllend bei fast gleichem Seitenverhältnis (5 %), sonst einpassen mit Rändern.
    static func fit(_ img: CIImage, width: Int, height: Int) -> CIImage {
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return img }
        let cover = abs((w / h) / (CGFloat(width) / CGFloat(height)) - 1) <= coverTolerance
        let s = cover ? max(CGFloat(width) / w, CGFloat(height) / h) : min(CGFloat(width) / w, CGFloat(height) / h)
        let nw = (w * s).rounded(), nh = (h * s).rounded()
        let scaled = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: nw / w, y: nh / h))
        let x = ((CGFloat(width) - nw) / 2).rounded(.down), y = ((CGFloat(height) - nh) / 2).rounded(.down)
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y)).cropped(to: frame)
            .composited(over: CIImage(color: .black).cropped(to: frame))
    }

    /// Meldung für ein Video, das AVFoundation nicht dekodiert (außerhalb von VideoSource: dort heißt die Zeit `t`).
    static func unreadable(_ url: URL) -> StudioError {
        StudioError(t("Video nicht lesbar: \(url.lastPathComponent)", "Cannot read the video: \(url.lastPathComponent)"))
    }

    /// Liest ein Video vorwärts und liefert zu einer Medienzeit das zuletzt fällige Bild, schon eingepasst.
    final class VideoSource {
        let asset: AVURLAsset
        let width: Int, height: Int
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var position: Double?
        var current: CIImage?
        var pending: (t: Double, buffer: CMSampleBuffer)?
        let track: AVAssetTrack?
        /// Lage laut preferredTransform: Der Leser liefert die Pixel ungedreht (Handyvideos im Hochformat lägen quer).
        let orientation: CGImagePropertyOrientation

        init(url: URL, width: Int, height: Int) async throws {
            asset = AVURLAsset(url: url)
            self.width = width
            self.height = height
            track = try await asset.loadTracks(withMediaType: .video).first
            let t = try await track?.load(.preferredTransform) ?? .identity
            switch (t.a, t.b, t.c, t.d) {
            case (0, 1, -1, 0): orientation = .right
            case (0, -1, 1, 0): orientation = .left
            case (-1, 0, 0, -1): orientation = .down
            default: orientation = .up
            }
        }

        private func start(_ t: Double) throws {
            reader?.cancelReading()
            guard let track else { return }
            let r = try AVAssetReader(asset: asset)
            let from = CMTime(seconds: max(0, t - 0.5), preferredTimescale: 600_000)
            r.timeRange = CMTimeRange(start: from, duration: .positiveInfinity)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            r.add(out)
            guard r.startReading() else {  // etwa ein Codec, den dieser Mac nicht dekodiert: melden statt schwarz
                throw r.error ?? StudioRender.unreadable(asset.url)
            }
            reader = r
            output = out
            pending = nil
            current = nil
        }

        func frame(at t: Double) throws -> CIImage? {
            if reader == nil || position == nil || t < position! - 1e-6 || t > position! + 2 { try start(t) }
            position = t
            var raw: CMSampleBuffer?
            while true {
                if pending == nil {
                    guard let buffer = output?.copyNextSampleBuffer() else {
                        if let reader, reader.status == .failed {  // Lesefehler, nicht das Ende der Datei
                            throw reader.error ?? StudioRender.unreadable(asset.url)
                        }
                        break  // Ende: letztes Bild steht
                    }
                    pending = (CMSampleBufferGetPresentationTimeStamp(buffer).seconds, buffer)
                }
                guard let next = pending else { break }
                if next.t <= t + StudioRender.timeSlack {
                    raw = next.buffer
                    pending = nil
                    continue
                }
                if raw == nil && current == nil { raw = next.buffer }  // erstes Bild liegt hinter t
                break
            }
            if let raw, let pixels = CMSampleBufferGetImageBuffer(raw) {
                current = StudioRender.fit(CIImage(cvPixelBuffer: pixels).oriented(orientation), width: width, height: height)
            }
            return current
        }

        func close() { reader?.cancelReading() }
    }

    // MARK: Zusammensetzen

    static let wipeEdge = 0.04  // weiche Kante der Wischblende, Anteil der Bildbreite

    /// Skalieren um den Fokuspunkt wie transform-origin: Der Punkt (ax, ay; y von oben) bleibt an seiner Stelle.
    /// Über 1 ein vergrößerter Ausschnitt, unter 1 das verkleinerte Bild über dem darunter (Bild im Bild).
    static func place(_ img: CIImage, _ s: Double, anchor: [Double], under: CIImage, width: Int, height: Int) -> CIImage {
        guard abs(s - 1) >= 1e-4 else { return img }
        let w = CGFloat(width), h = CGFloat(height)
        let px = CGFloat(anchor[0]) * w, py = (1 - CGFloat(anchor[1])) * h  // Core Image zählt y von unten
        let t = CGAffineTransform(translationX: px, y: py).scaledBy(x: CGFloat(s), y: CGFloat(s)).translatedBy(x: -px, y: -py)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let moved = img.transformed(by: t, highQualityDownsample: true)
        return s > 1 ? moved.cropped(to: frame) : moved.composited(over: under).cropped(to: frame)
    }

    /// Übergang bei Fortschritt a (0 → 1) von `base` (voriger Clip, Bild darunter oder Schwarz) zu `img`.
    static func blend(_ base: CIImage, _ img: CIImage, _ a: Double, kind: String, width: Int, height: Int) -> CIImage {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        func dissolve(_ from: CIImage, _ to: CIImage, _ x: Double) -> CIImage {
            to.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputImageKey: from, kCIInputTargetImageKey: to, kCIInputTimeKey: x]).cropped(to: frame)
        }
        switch kind {
        case "dip_black", "dip_white":
            let color = CIImage(color: kind == "dip_black" ? .black : .white).cropped(to: frame)
            return a < 0.5 ? dissolve(base, color, 2 * a) : dissolve(color, img, 2 * a - 1)
        case "wipe":
            let edge = wipeEdge * Double(width)
            let x1 = a * (1 + wipeEdge) * Double(width)  // dahinter noch der alte Clip
            let mask = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: CGFloat(x1 - edge), y: 0), "inputPoint1": CIVector(x: CGFloat(x1), y: 0),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: frame)
            return img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask]).cropped(to: frame)
        default:
            return dissolve(base, img, a)
        }
    }

    /// Setzt die Bilder des Schnitts zusammen (V1 unten, darüber V2 …, Übergänge, Skalieren), für den Export und,
    /// in kleinerem Format, für den Monitor. Liest Videos vorwärts; ein Sprung zurück liest neu ab dort.
    final class Compositor {
        let plan: Plan
        let width: Int, height: Int
        let black: CIImage
        private let videoTracks: [String]
        private var sources: [Int: VideoSource] = [:]
        private var stills: [Int: CIImage] = [:]

        init(plan: Plan) {
            self.plan = plan
            width = plan.width
            height = plan.height
            black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
            videoTracks = plan.tracks.filter { $0.hasPrefix("V") }.sorted { StudioTrack.number($0) < StudioTrack.number($1) }
        }

        private func image(_ i: Int, at mediaT: Double) async throws -> CIImage? {
            let c = plan.clips[i]
            if c.media == "image" {
                if stills[i] == nil, let img = CIImage(contentsOf: c.url, options: [.applyOrientationProperty: true]) {
                    stills[i] = StudioRender.fit(img, width: width, height: height)
                }
                return stills[i]
            }
            if c.media == "audio" { return nil }
            if sources[i] == nil { sources[i] = try await VideoSource(url: c.url, width: width, height: height) }
            return try sources[i]!.frame(at: mediaT)
        }

        /// Das Bild zur Zeit `time` (Sekunden auf der Zeitleiste).
        func frame(at time: Double) async throws -> CIImage {
            var canvas: CIImage?
            for track in videoTracks {
                guard let i = plan.clips.indices.first(where: {
                    plan.clips[$0].track == track && plan.clips[$0].start <= time && time < plan.clips[$0].end - 1e-9
                }) else { continue }
                let c = plan.clips[i]
                let local = time - c.start
                let mediaT = c.inPoint + local * c.speed
                guard var img = try await image(i, at: mediaT) else { continue }
                let under = canvas ?? black
                img = StudioRender.place(img, c.scale(at: mediaT), anchor: c.anchor, under: under, width: width, height: height)
                if let tr = c.transition, tr.seconds > 0, local < tr.seconds {
                    var base = under
                    if let j = plan.clips.indices.first(where: {
                        plan.clips[$0].track == c.track && $0 != i && abs(plan.clips[$0].end - c.start) < 1e-3
                    }) {
                        let prev = plan.clips[j]
                        let prevT = prev.outPoint + local * prev.speed
                        if let before = try await image(j, at: prevT) {
                            base = StudioRender.place(before, prev.scale(at: prevT), anchor: prev.anchor, under: under,
                                                      width: width, height: height)
                        }
                    }
                    img = StudioRender.blend(base, img, local / tr.seconds, kind: tr.kind, width: width, height: height)
                }
                canvas = img
            }
            return canvas ?? black
        }

        func close() { sources.values.forEach { $0.close() } }

        /// Quellen schließen, die nicht mehr gebraucht werden: Clip samt Übergang des folgenden liegt vor `time`.
        /// Für den Export (liest nur vorwärts); sonst blieben bei langen Schnitten Dutzende Leser offen.
        func dropFinished(before time: Double) {
            let tail = plan.clips.compactMap { $0.transition?.seconds }.max() ?? 0
            for (i, source) in sources where plan.clips[i].end + tail + 0.1 < time {
                source.close()
                sources[i] = nil
            }
            for i in stills.keys where plan.clips[i].end + tail + 0.1 < time { stills[i] = nil }
        }
    }

    // MARK: Ton

    /// Ton eines Clips von `from` bis `to` (Medienzeit), auf `length` Proben gestreckt (Tonhöhe bleibt), als
    /// Stereo-Float bei `rate`. AVFoundation streckt über eine skalierte Komposition (spektral, wie atempo).
    static func readAudio(_ url: URL, from: Double, to: Double, speed: Double, length: Int, rate: Int) async throws -> [[Float]] {
        var out: [[Float]] = [[Float](repeating: 0, count: length), [Float](repeating: 0, count: length)]
        guard length > 0, to > from else { return out }
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else { return out }
        let duration = try await asset.load(.duration).seconds
        let start = max(0, from), end = min(to, duration)
        guard end > start else { return out }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return out }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                end: CMTime(seconds: end, preferredTimescale: 600_000))
        try track.insertTimeRange(range, of: source, at: .zero)
        if abs(speed - 1) > 1e-6 {
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                 toDuration: CMTime(seconds: (end - start) / speed, preferredTimescale: 600_000))
        }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        reader.startReading()
        // Material beginnt später als `from`: vorne Stille
        var at = Int(((start - from) / speed * Double(rate)).rounded())
        while let buffer = output.copyNextSampleBuffer(), at < length {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var total = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let frames = total / 8
            pointer.withMemoryRebound(to: Float.self, capacity: frames * 2) { f in
                for i in 0..<frames where at + i < length {
                    out[0][at + i] = f[2 * i]
                    out[1][at + i] = f[2 * i + 1]
                }
            }
            at += frames
        }
        reader.cancelReading()
        return out
    }

    /// Alle Tonspuren und den Ton der Videoclips mischen, mit Lautstärke und Ein-/Ausblenden an Übergängen.
    static func mixAudio(_ plan: Plan, rate: Int, progress: (Double) -> Void) async throws -> [[Float]] {
        let total = Int((plan.duration * Double(rate)).rounded(.up)) + 1
        var mix: [[Float]] = [[Float](repeating: 0, count: total), [Float](repeating: 0, count: total)]
        func add(_ part: [[Float]], at: Int) {
            let end = min(total, at + part[0].count)
            guard end > at, at >= 0 else { return }
            for ch in 0..<2 { for i in at..<end { mix[ch][i] += part[ch][i - at] } }
        }
        let clips = plan.clips.filter { !$0.muted && ($0.media == "audio" || $0.audio) }
        for (n, c) in clips.enumerated() {
            progress(Double(n) / Double(max(1, clips.count)))
            let length = Int((c.length * Double(rate)).rounded())
            var audio = try await readAudio(c.url, from: c.inPoint, to: c.outPoint, speed: c.speed, length: length, rate: rate)
            let gain = Float(pow(10, c.gainDB / 20))
            for ch in 0..<2 { for i in 0..<length { audio[ch][i] *= gain } }
            if let tr = c.transition, tr.seconds > 0 {  // einblenden
                let k = min(length, Int(tr.seconds * Double(rate)))
                for ch in 0..<2 { for i in 0..<k { audio[ch][i] *= Float(i) / Float(max(1, k - 1)) } }
                // der vorherige Clip derselben Spur läuft über sein Ende hinaus aus
                if let prev = previous(plan, c), prev.media == "audio" || prev.audio, !prev.muted {
                    let m = Int((tr.seconds * Double(rate)).rounded())
                    var tail = try await readAudio(prev.url, from: prev.outPoint, to: prev.outPoint + tr.seconds * prev.speed,
                                                   speed: prev.speed, length: m, rate: rate)
                    let g = Float(pow(10, prev.gainDB / 20))
                    for ch in 0..<2 { for i in 0..<m { tail[ch][i] *= g * (1 - Float(i) / Float(max(1, m - 1))) } }
                    add(tail, at: Int((c.start * Double(rate)).rounded()))
                }
            }
            add(audio, at: Int((c.start * Double(rate)).rounded()))
        }
        return mix
    }

    /// Der Clip derselben Spur, der genau dort endet, wo `clip` beginnt (ihm gehört das Auslaufen im Übergang).
    static func previous(_ plan: Plan, _ clip: Clip) -> Clip? {
        plan.clips.first { $0.track == clip.track && abs($0.end - clip.start) < 1e-3 && $0.start < clip.start }
    }

    /// Integrierte Lautheit nach ITU-R BS.1770-4 (K-Filter für 48 kHz, 400-ms-Blöcke, Gates −70 LUFS und −10 LU).
    static func loudness(_ x: [[Float]], rate: Int) -> Double {
        func biquad(_ s: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: s.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<s.count {
                let v = b[0] * s[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                x2 = x1; x1 = s[i]; y2 = y1; y1 = v
                y[i] = v
            }
            return y
        }
        let block = Int(0.4 * Double(rate)), step = Int(0.1 * Double(rate))
        guard rate == 48000, x[0].count >= block else { return -70 }
        var cumulative: [[Double]] = []
        for ch in x {
            var y = biquad(ch.map(Double.init), [1.53512485958697, -2.69169618940638, 1.19839281085285],
                           [1.0, -1.69065929318241, 0.73248077421585])
            y = biquad(y, [1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])
            var sum = [Double](repeating: 0, count: y.count + 1)
            for i in 0..<y.count { sum[i + 1] = sum[i] + y[i] * y[i] }
            cumulative.append(sum)
        }
        var power: [Double] = []
        for s in stride(from: 0, through: x[0].count - block, by: step) {
            power.append(cumulative.reduce(0) { $0 + ($1[s + block] - $1[s]) / Double(block) })
        }
        let lk = power.map { -0.691 + 10 * log10(max($0, 1e-12)) }
        let gated = zip(power, lk).filter { $0.1 > -70 }.map(\.0)
        guard !gated.isEmpty else { return -70 }
        let relative = -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count)) - 10
        let final = zip(power, lk).filter { $0.1 > -70 && $0.1 > relative }.map(\.0)
        return final.isEmpty ? -70 : -0.691 + 10 * log10(final.reduce(0, +) / Double(final.count))
    }

    // MARK: Ablauf

    struct Result: Sendable {
        var url: URL
        var encoder: String
        var frames: Int
        var renderSeconds: Double
        var loudnessBefore: Double
        var gainDB: Double
        var peakDBFS: Double
    }

    /// Rendert den Plan nach `url`. `progress`: Anteil 0 … 1 und Stufe.
    static func render(_ plan: Plan, to url: URL, progress: @escaping (Double, String) -> Void) async throws -> Result {
        let started = Date()
        let width = plan.width, height = plan.height, rate = plan.sampleRate
        let fps = Double(plan.fps.num) / Double(plan.fps.den)
        let frames = max(1, Int((plan.duration * fps - 1e-9).rounded(.up)))

        progress(0, t("Ton mischen", "Mixing sound"))
        var audio = try await mixAudio(plan, rate: rate) { progress(0.02 * $0, t("Ton mischen", "Mixing sound")) }
        let measured = loudness(audio, rate: rate)
        var gainDB = 0.0
        if measured > -70 {
            gainDB = plan.loudness - measured
            let g = Float(pow(10, gainDB / 20))
            for ch in 0..<2 { for i in audio[ch].indices { audio[ch][i] *= g } }
        }
        var left = audio[0], right = audio[1]
        AudioEngine.limit(&left, &right, sampleRate: rate, ceilingDB: Float(plan.ceilingDB))
        audio = [left, right]
        var loudest: Float = 0
        for ch in audio { for v in ch where abs(v) > loudest { loudest = abs(v) } }
        let peak = 20 * log10(max(1e-9, Double(loudest)))

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: plan.preset.ext == "mov" ? .mov : .mp4)
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2]
        if let bitrate = plan.preset.bitrate {
            compression[AVVideoAverageBitRateKey] = bitrate
        } else if plan.preset.codec != .proRes4444 {
            compression[AVVideoAverageBitRateKey] = max(8_000_000, Int(Double(width * height) * fps * 0.18))
        }
        if plan.preset.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if plan.preset.codec == .proRes4444 { compression = [:] }
        var settings: [String: Any] = [
            AVVideoCodecKey: plan.preset.codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        let audioSettings: [String: Any] = plan.preset.codec == .proRes4444
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
               AVEncoderBitRateKey: 256_000]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw StudioError(t("Das Ausgabeformat lässt sich nicht schreiben.", "Cannot write this output format."))
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw StudioError(writer.error?.localizedDescription ?? t("Export fehlgeschlagen.", "Export failed."))
        }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer {
            if !finished {  // Abbruch oder Fehler: keine halbe Datei liegen lassen (ProRes wären Gigabytes)
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }

        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
        let black = CIImage(color: .black).cropped(to: frameRect)
        let compositor = Compositor(plan: plan)
        defer { compositor.close() }

        var audioSent = 0
        let audioTotal = min(audio[0].count, Int((Double(frames) / fps * Double(rate)).rounded()))
        /// Ein Stück Ton von `audioSent` bis `sample` anhängen (der Eingang nimmt gerade an).
        func appendAudio(upTo sample: Int) throws {
            let end = min(sample, audioTotal)
            guard end > audioSent else { return }
            let count = end - audioSent
            var interleaved = [Float](repeating: 0, count: count * 2)
            for i in 0..<count {
                interleaved[2 * i] = audio[0][audioSent + i]
                interleaved[2 * i + 1] = audio[1][audioSent + i]
            }
            var format = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                     mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                     mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            var block: CMBlockBuffer?
            let bytes = count * 8
            // kCMBlockBufferAssureMemoryNowFlag: ohne den Speicher scheiterte das Füllen still, der Schreiber bekam keinen
            // Ton und nahm nach 2 s kein Bild mehr an (gemessen 30.10.2026, der Export stand bei 24 %)
            let made = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                          customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                          flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            // OSStatus 0: ohne Fehler
            guard made == 0, let block, let description else {
                throw StudioError(t("Ton für den Export nicht anlegbar (\(made)).", "Cannot create the export sound (\(made))."))
            }
            let copied = interleaved.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            let created = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(audioSent), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            guard copied == 0, created == 0, let sample else {
                throw StudioError(t("Ton für den Export nicht anlegbar (\(copied), \(created)).", "Cannot create the export sound (\(copied), \(created))."))
            }
            guard audioInput.append(sample) else {
                throw StudioError(writer.error?.localizedDescription ?? t("Ton nicht angenommen.", "Sound not accepted."))
            }
            audioSent = end
        }

        /// Ton vorausschicken, ohne zu warten, so weit der Schreiber ihn nimmt (in Stücken zu 0,25 s). Der AAC-Kodierer
        /// hält Ton zurück; kam der Ton nur bis zum Ende des Bildes, nahm der Schreiber kein Bild mehr an (30.10.2026).
        func pumpAudio(upTo sample: Int) throws {
            let target = min(sample, audioTotal)
            while audioSent < target && audioInput.isReadyForMoreMediaData {
                try appendAudio(upTo: min(target, audioSent + rate / 4))
            }
        }
        func sampleAt(_ seconds: Double) -> Int { Int((seconds * Double(rate)).rounded(.down)) }

        let stage = t("Video mit VideoToolbox", "Video with VideoToolbox")
        for f in 0..<frames {
            try Task.checkCancellation()
            let canvas: CIImage? = try await compositor.frame(at: Double(f * plan.fps.den) / Double(plan.fps.num))
            compositor.dropFinished(before: Double(f * plan.fps.den) / Double(plan.fps.num))
            guard let pool = adaptor.pixelBufferPool else {
                throw StudioError(writer.error?.localizedDescription ?? t("Export fehlgeschlagen.", "Export failed."))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw StudioError(t("Kein Bildspeicher frei.", "No frame buffer available.")) }
            context.render(canvas ?? black, to: buffer, bounds: frameRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let ahead = sampleAt(Double(f + 1) / fps + 1)
            try pumpAudio(upTo: ahead)
            try waitUntilReady(videoInput, writer) { try pumpAudio(upTo: ahead) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f) * CMTimeValue(plan.fps.den),
                                                                      timescale: CMTimeScale(plan.fps.num))) else {
                throw StudioError(writer.error?.localizedDescription ?? t("Bild nicht angenommen.", "Frame not accepted."))
            }
            try pumpAudio(upTo: ahead)
            if f % 12 == 0 { progress(0.02 + 0.96 * Double(f + 1) / Double(frames), stage) }
        }
        // erst das Bild schließen, dann den restlichen Ton hinterher (ohne offenes Bild wartet der Schreiber nicht mehr)
        videoInput.markAsFinished()
        while audioSent < audioTotal {
            try waitUntilReady(audioInput, writer)
            try appendAudio(upTo: min(audioTotal, audioSent + rate / 4))
        }
        audioInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw StudioError(writer.error?.localizedDescription ?? t("Export fehlgeschlagen.", "Export failed."))
        }
        finished = true
        let encoder = plan.preset.codec == .proRes4444 ? "prores4444" : plan.preset.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox"
        return Result(url: url, encoder: encoder, frames: frames, renderSeconds: Date().timeIntervalSince(started),
                      loudnessBefore: measured, gainDB: gainDB, peakDBFS: peak)
    }

    /// Warten, bis der Schreiber wieder annimmt; Abbrechen wirkt sofort, nach 20 s Stillstand eine Meldung statt eines
    /// Exports, der ewig steht.
    private static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter,
                                       meanwhile: () throws -> Void = {}) throws {
        let started = Date()
        while !input.isReadyForMoreMediaData {
            try meanwhile()
            try Task.checkCancellation()
            if writer.status == .failed {
                throw StudioError(writer.error?.localizedDescription ?? t("Export fehlgeschlagen.", "Export failed."))
            }
            if Date().timeIntervalSince(started) > 20 {
                throw StudioError(t("Der Export steht: Der Schreiber nimmt seit 20 s nichts mehr an.", "The export is stuck: the writer has accepted nothing for 20 s."))
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
