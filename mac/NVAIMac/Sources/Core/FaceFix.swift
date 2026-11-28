import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Auftrag „Gesicht nachrechnen“ (seit 1.1.0, wie `face_fix` unter Windows): das Gesicht einer Person in einem Bild
/// oder Video aus einem Originalfoto neu malen lassen (FLUX.2 Klein), im Video auf jedes Bild gelegt.
struct FaceFixJobRequest: Sendable {
    var assetID: String
    var referenceAssetID: String
    var modelID: String
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    static func parse(_ json: JSONValue?) throws -> FaceFixJobRequest {
        guard let asset = json?["asset_id"]?.stringValue, !asset.isEmpty else {
            throw APIError(422, t("asset_id fehlt.", "asset_id is missing."))
        }
        guard let ref = json?["reference_asset_id"]?.stringValue, !ref.isEmpty else {
            throw APIError(422, t("Als Vorlage ein Foto der Person wählen (reference_asset_id).",
                                  "Choose a photo of the person as the reference (reference_asset_id)."))
        }
        let fallback = ModelCatalog.status(ModelCatalog.recommended).installed ? ModelCatalog.recommended.id
            : (Models.expansionModel?.id ?? ModelCatalog.recommended.id)
        let model = json?["model_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        var seed: UInt64?
        if let s = json?["seed"]?.doubleValue, s >= 0 { seed = UInt64(s) }
        return FaceFixJobRequest(assetID: asset, referenceAssetID: ref, modelID: model, seed: seed,
                                 params: json ?? .object([:]))
    }
}

/// Bildverarbeitung für „Gesicht nachrechnen“, wie `server/nvai/face_tools.py` unter Windows: Gesicht finden (hier Apple
/// Vision statt OpenCV), Kopfausschnitt (2,4 × Gesichtsbreite) mit weichgezeichneten Gesichtszügen fürs Modell (so kommt
/// das Gesicht aus dem Foto und nicht aus dem Bild), Ergebnis ausgerichtet mit weicher Ellipse zurück; im Video das
/// nachgerechnete Gesicht in jedem Bild auf den laufenden Kopf, Licht je Bild angeglichen. Mund und Lider kommen aus dem
/// einen Bild: nur für Clips ohne Sprechen.
enum FaceFix {
    struct Box: Sendable {
        var x, y, w, h: Double   // Pixel, Ursprung oben links
        var cx: Double { x + w / 2 }
        var cy: Double { y + h / 2 }
        var json: JSONValue {
            .object(["x": .int(Int(x.rounded())), "y": .int(Int(y.rounded())), "w": .int(Int(w.rounded())),
                     "h": .int(Int(h.rounded()))])
        }
    }

    struct Crop: Sendable { var x: Int, y: Int, side: Int }

    /// Wie `face_fix.PROMPT` unter Windows. Kein „beard“: Damit bekam eine Frau einen Bart und männliche Züge
    /// (FLUX.2 Klein am M1, 2 von 2); Alter und Geschlecht kommen aus dem Foto.
    static let prompt = "Edit the first image, a close-up of a person's head. Replace the face with the face of the "
        + "person in the second image, so that it is clearly the same person, with the same age and the same gender as "
        + "in the second image: exactly their face shape, forehead, cheeks, jaw, eyes, eyebrows, nose, mouth and skin. "
        + "From the first image keep "
        + "only the headgear, the hair outline, the clothing, the head position, size and angle, the light, the colors "
        + "and the background. Both eyes are clear and natural, the same size, with the pupils centered, looking in "
        + "the same direction as in the first image. The same expression as in the first image, the mouth as in the "
        + "first image. Photorealistic, natural skin texture."

    /// Ausschnittgröße für FLUX.2 Klein: 768 auf Macs bis 16 GB, sonst 1024 (wie unter Windows).
    static var side: Int { SystemInfo.memoryGB <= 16 ? 768 : 1024 }
    static let keySeconds = 0.5

    static let ci = CIContext(options: [.cacheIntermediates: false])

    // MARK: Gesichter

    /// Gesichter (Apple Vision), größtes zuerst.
    static func detect(_ image: CGImage) -> [Box] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return boxes(request, width: Double(image.width), height: Double(image.height))
    }

    static func detect(_ buffer: CVPixelBuffer) -> [Box] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        return boxes(request, width: Double(CVPixelBufferGetWidth(buffer)), height: Double(CVPixelBufferGetHeight(buffer)))
    }

    private static func boxes(_ request: VNDetectFaceRectanglesRequest, width: Double, height: Double) -> [Box] {
        (request.results ?? []).map { o in
            let r = o.boundingBox  // normiert, Ursprung unten links
            return Box(x: r.minX * width, y: (1 - r.maxY) * height, w: r.width * width, h: r.height * height)
        }.sorted { $0.w * $0.h > $1.w * $1.h }
    }

    /// Quadratischer Kopfausschnitt: 2,4 × Gesichtsbreite um die Gesichtsmitte, im Bild gehalten.
    static func cropBox(_ f: Box, width: Int, height: Int) -> Crop {
        let side = max(16, min(min(width, height), Int((f.w * 2.4).rounded())))
        let x = max(0, min(width - side, Int((f.cx - Double(side) / 2).rounded())))
        let y = max(0, min(height - side, Int((f.cy - Double(side) / 2).rounded())))
        return Crop(x: x, y: y, side: side)
    }

    // MARK: Zeichnen

    static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, radius)).cropped(to: input.extent)
        return ci.createCGImage(out, from: input.extent)
    }

    /// Weiche Ellipsenmaske (Graustufen, weiß innen) in Koordinaten oben links.
    static func ellipseMask(width: Int, height: Int, cx: Double, cy: Double, rx: Double, ry: Double,
                            feather: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: cx - rx, y: Double(height) - cy - ry, width: 2 * rx, height: 2 * ry))
        guard let hard = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: hard)
        let soft = input.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, feather)).cropped(to: input.extent)
        return ci.createCGImage(soft, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// `top` mit weicher Maske auf `base` in `rect` (Pixel, oben links); außerhalb bleibt `base` pixelgleich.
    static func paste(_ top: CGImage, mask: CGImage, onto base: CGImage, rect: CGRect) -> CGImage? {
        let width = base.width, height = base.height
        guard let ctx = context(width, height) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let r = CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.clip(to: r, mask: mask)
        ctx.draw(top, in: r)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func cropped(_ image: CGImage, _ c: Crop, to size: Int) -> CGImage? {
        guard let part = image.cropping(to: CGRect(x: c.x, y: c.y, width: c.side, height: c.side)) else { return nil }
        return ImageFiles.resized(part, width: size, height: size)
    }

    /// Mittlere Farbe (0–255) im Rechteck, über ein kleines Abbild gerechnet.
    static func meanColor(_ image: CGImage, _ rect: CGRect) -> (r: Double, g: Double, b: Double)? {
        let clip = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard clip.width >= 2, clip.height >= 2, let part = image.cropping(to: clip), let ctx = context(16, 16) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * 16)
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<16 {
            for x in 0..<16 {
                let i = y * ctx.bytesPerRow + x * 4
                r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
            }
        }
        return (r / 256, g / 256, b / 256)
    }

    /// Farben verschieben (Lichtangleich je Bild), Werte 0–255.
    static func shifted(_ image: CGImage, _ d: (r: Double, g: Double, b: Double)) -> CGImage? {
        guard let f = CIFilter(name: "CIColorMatrix") else { return nil }
        let input = CIImage(cgImage: image)
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(d.r / 255), y: CGFloat(d.g / 255), z: CGFloat(d.b / 255), w: 0),
                   forKey: "inputBiasVector")
        guard let out = f.outputImage else { return nil }
        return ci.createCGImage(out, from: input.extent)
    }

    /// Inneres Gesicht (Augen bis Mund) für den Lichtvergleich.
    static func inner(_ f: Box) -> CGRect {
        CGRect(x: f.x + f.w * 0.2, y: f.y + f.h * 0.15, width: f.w * 0.6, height: f.h * 0.7)
    }

    // MARK: Bild

    /// Kopfausschnitt auf `size` px und eine Fassung mit weichgezeichneten Gesichtszügen (Ellipse 0,36 × 0,42 der
    /// Gesichtsbox, Unschärfe 10 % der Breite), wie `face_tools.prepare`.
    static func prepare(_ image: CGImage, face: Box, size: Int) -> (crop: CGImage, soft: CGImage, box: Crop)? {
        let b = cropBox(face, width: image.width, height: image.height)
        guard let crop = cropped(image, b, to: size) else { return nil }
        let sc = Double(size) / Double(b.side)
        let cx = (face.cx - Double(b.x)) * sc, cy = (face.cy - Double(b.y)) * sc
        guard let mask = ellipseMask(width: size, height: size, cx: cx, cy: cy, rx: face.w * 0.36 * sc,
                                     ry: face.h * 0.42 * sc, feather: face.w * 0.08 * sc),
              let blurred = blur(crop, radius: face.w * 0.10 * sc),
              let soft = paste(blurred, mask: mask, onto: crop, rect: CGRect(x: 0, y: 0, width: size, height: size)) else {
            return nil
        }
        return (crop, soft, b)
    }

    /// FLUX-Ergebnis aufs Original: an den Ausschnitt ausgerichtet (`RestoreTools.align`), weiche Ellipse 0,62 × 0,80
    /// der Gesichtsbox um (Mitte, 62 % Höhe), Weichzeichnung 7 % der Breite; außerhalb pixelgleich.
    static func composite(_ original: CGImage, result: CGImage, crop: CGImage, face: Box, box: Crop) -> (CGImage, JSONValue)? {
        let size = crop.width
        let (aligned, alignment) = RestoreTools.align(ImageFiles.resized(result, width: size, height: size), to: crop)
        let sc = Double(size) / Double(box.side)
        let cx = (face.cx - Double(box.x)) * sc, cy = (face.y + face.h * 0.62 - Double(box.y)) * sc
        guard let mask = ellipseMask(width: size, height: size, cx: cx, cy: cy, rx: face.w * 0.62 * sc,
                                     ry: face.h * 0.80 * sc, feather: max(2, face.w * 0.07 * sc)),
              let out = paste(aligned, mask: mask, onto: original,
                              rect: CGRect(x: box.x, y: box.y, width: box.side, height: box.side)) else { return nil }
        return (out, alignment.json)
    }

    // MARK: Video

    /// Bild eines Videos zur Zeit `seconds` (Schlüsselbild).
    static func frame(_ url: URL, seconds: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    struct VideoInfo: Sendable { var frames: Int, misses: Int, width: Int, height: Int, fps: Double }

    /// Das nachgerechnete Schlüsselgesicht in jedes Bild (wie `face_tools.video`): Durchgang 1 findet das Gesicht je
    /// Bild (das dem vorigen nächste, anfangs das dem Schlüsselgesicht nächste) und glättet die Kästen über ± 2 Bilder;
    /// Durchgang 2 legt `fixed` (Kopfausschnitt `box` des fertigen Schlüsselbilds) mit demselben Maßstab und Versatz wie
    /// das Gesicht auf, Licht über den Mittelwert im inneren Gesicht (wie hat sich das Originalgesicht gegenüber dem
    /// Schlüsselbild verändert), weiche Ellipse 0,31 × 0,40 um die Gesichtsmitte. Der Ton wird durchgereicht.
    static func video(source: URL, key: CGImage, fixed: CGImage, keyFace: Box, box: Crop, to out: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> VideoInfo {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw APIError(422, t("Das Video hat keine Bildspur.", "The video has no video track."))
        }
        let natural = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        let width = Int(natural.width), height = Int(natural.height)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        // Durchgang 1: Gesichter
        var found: [Box?] = []
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            var last = keyFace
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let faces = detect(buffer)
                let pick = faces.min { abs($0.cx - last.cx) + abs($0.cy - last.cy) < abs($1.cx - last.cx) + abs($1.cy - last.cy) }
                if let pick, abs(pick.cx - last.cx) < last.w * 1.5, abs(pick.cy - last.cy) < last.h * 1.5 {
                    found.append(pick)
                    last = pick
                } else {
                    found.append(nil)
                }
                if found.count % 8 == 0 { progress(0.35 * Double(found.count) / max(1, fps * 10)) }
            }
            if reader.status == .failed { throw reader.error ?? APIError(500, "AVAssetReader") }
        }
        // geglättet über ± 2 Bilder; ohne Gesicht in der Nähe bleibt das Bild unverändert
        let smooth: [Box?] = found.indices.map { (i: Int) -> Box? in
            let near = (max(0, i - 2)...min(found.count - 1, i + 2)).compactMap { found[$0] }
            guard !near.isEmpty, found[i] != nil || near.count >= 2 else { return nil }
            let n = Double(near.count)
            return Box(x: near.map(\.x).reduce(0, +) / n, y: near.map(\.y).reduce(0, +) / n,
                       w: near.map(\.w).reduce(0, +) / n, h: near.map(\.h).reduce(0, +) / n)
        }
        let misses = smooth.filter { $0 == nil }.count

        // Maske im Ausschnitt, Licht des Schlüsselgesichts
        let size = fixed.width
        let sc = Double(size) / Double(box.side)
        guard let mask = ellipseMask(width: size, height: size, cx: (keyFace.cx - Double(box.x)) * sc,
                                     cy: (keyFace.cy - Double(box.y)) * sc, rx: keyFace.w * 0.31 * sc,
                                     ry: keyFace.h * 0.40 * sc, feather: max(1, keyFace.w * 0.07 * sc)),
              let keyMean = meanColor(key, inner(keyFace)) else {
            throw APIError(500, t("Maske ließ sich nicht anlegen.", "Could not build the mask."))
        }

        // Durchgang 2: einsetzen und schreiben
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, width * height * 16)],
        ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOut: AVAssetReaderTrackOutput?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let hint = try await audio.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioIn = input
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
                r.add(o)
                audioReader = r
                audioOut = o
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        guard writer.startWriting() else { throw writer.error ?? APIError(500, "AVAssetWriter") }
        writer.startSession(atSourceTime: .zero)
        var i = 0
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard var image = ci.createCGImage(CIImage(cvPixelBuffer: buffer), from: rect) else { continue }
            if i < smooth.count, let f = smooth[i] {
                let s = f.w / keyFace.w
                let side = Double(box.side) * s
                let x = f.cx - s * (keyFace.cx - Double(box.x)), y = f.cy - s * (keyFace.cy - Double(box.y))
                var top = fixed
                if let now = meanColor(image, inner(f)),
                   let adjusted = shifted(fixed, (now.r - keyMean.r, now.g - keyMean.g, now.b - keyMean.b)) {
                    top = adjusted
                }
                if let done = paste(top, mask: mask, onto: image, rect: CGRect(x: x, y: y, width: side, height: side)) {
                    image = done
                }
            }
            guard let pool = adaptor.pixelBufferPool else { throw APIError(500, "pixelBufferPool") }
            var target: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
            guard let target else { continue }
            ci.render(CIImage(cgImage: image), to: target)
            while !videoIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(target, withPresentationTime: time)
            i += 1
            if i % 4 == 0 { progress(0.35 + 0.6 * Double(i) / Double(max(1, found.count))) }
        }
        videoIn.markAsFinished()
        if let audioIn, let audioReader, let audioOut {
            audioReader.startReading()
            while let s = audioOut.copyNextSampleBuffer() {
                while !audioIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                audioIn.append(s)
            }
            audioIn.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? APIError(500, "AVAssetWriter") }
        progress(1)
        return VideoInfo(frames: i, misses: misses, width: width, height: height, fps: fps)
    }
}
