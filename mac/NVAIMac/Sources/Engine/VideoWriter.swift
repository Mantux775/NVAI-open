import AVFoundation
import CoreVideo
import Foundation

/// RGB-Bilder → H.264-MP4 über AVAssetWriter (BT.709, keine Metadaten außer den nötigen).
enum VideoWriter {
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// `frames`: je Bild width × height × 3 Bytes (RGB). Bitrate rund 0,7 Bit je Bildpunkt und Bild.
    static func writeMP4(frames: [[UInt8]], width: Int, height: Int, fps: Int, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * 0.7))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure(text: t("MP4: Videospur nicht angenommen.", "MP4: video track rejected.")) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(text: t("MP4: Schreiben lässt sich nicht starten.", "MP4: cannot start writing.")) }
        writer.startSession(atSourceTime: .zero)
        for (index, rgb) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? Failure(text: t("MP4: kein Bildspeicher.", "MP4: no frame buffer pool.")) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer else {
                throw Failure(text: t("MP4: kein Bildspeicher frei.", "MP4: no frame buffer available."))
            }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            rgb.withUnsafeBufferPointer { src in
                for y in 0 ..< height {
                    let row = base + y * stride
                    for x in 0 ..< width {
                        let s = (y * width + x) * 3
                        row[x * 4] = src[s + 2]
                        row[x * 4 + 1] = src[s + 1]
                        row[x * 4 + 2] = src[s]
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(fps))) else {
                throw writer.error ?? Failure(text: t("MP4: Bild \(index) nicht angenommen.", "MP4: frame \(index) rejected."))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(text: t("MP4: Datei nicht fertig geschrieben.", "MP4: file not completed.")) }
    }
}
