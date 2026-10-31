// VideoDataset.swift - Video + Caption dataset loading for LoRA training
// Copyright 2026

import AVFoundation
import CoreImage
import Foundation
@preconcurrency import MLX

/// A training sample: video frames + caption + optional audio waveform + optional conditioning image
struct TrainingSample: Sendable {
    /// Video frames as MLXArray (1, 3, T, H, W) in [-1, 1]
    let frames: MLXArray
    /// Text caption
    let caption: String
    /// Audio waveform (optional), float32 1D array
    let audioWaveform: MLXArray?
    /// I2V conditioning image (optional), loaded as (1, 3, 1, H, W) in [-1, 1]
    let image: MLXArray?
    /// Source file name (for logging)
    let filename: String
}

/// Loads training data from a directory of videos + captions.
///
/// Expected format (ostris convention):
/// ```
/// dataset/
///   video1.mp4
///   video1.txt
///   video2.mp4
///   video2.txt
/// ```
///
/// Each `.txt` file contains the caption for the corresponding video.
class VideoDataset {
    /// All available samples
    let samples: [SampleInfo]

    /// Maximum resolution budget (each video fits within this box preserving aspect ratio)
    let maxWidth: Int
    let maxHeight: Int

    /// Target frame count
    let numFrames: Int

    /// Whether to extract audio
    let extractAudio: Bool

    /// Audio sample rate for extraction
    let audioSampleRate: Int

    struct SampleInfo: Sendable {
        let videoPath: String
        let captionPath: String
        let filename: String
        /// Path to a conditioning image (.png alongside the video), if present
        let imagePath: String?
    }

    init(
        directory: String,
        width: Int,
        height: Int,
        numFrames: Int,
        extractAudio: Bool = false,
        audioSampleRate: Int = 16000
    ) throws {
        self.maxWidth = width
        self.maxHeight = height
        self.numFrames = numFrames
        self.extractAudio = extractAudio
        self.audioSampleRate = audioSampleRate

        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else {
            throw TrainingError.datasetError("Directory not found: \(directory)")
        }

        let contents = try fm.contentsOfDirectory(atPath: directory)
        let videoExtensions = Set(["mp4", "mov", "m4v"])

        var foundSamples: [SampleInfo] = []
        for file in contents {
            let ext = (file as NSString).pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { continue }

            let baseName = (file as NSString).deletingPathExtension
            let captionFile = baseName + ".txt"
            let captionPath = (directory as NSString).appendingPathComponent(captionFile)

            guard fm.fileExists(atPath: captionPath) else {
                print("Warning: No caption file for \(file), skipping")
                continue
            }

            // Check for optional I2V conditioning image (baseName.png alongside the video)
            let imageName = baseName + ".png"
            let imagePath = (directory as NSString).appendingPathComponent(imageName)
            let resolvedImagePath: String? = fm.fileExists(atPath: imagePath) ? imagePath : nil

            foundSamples.append(SampleInfo(
                videoPath: (directory as NSString).appendingPathComponent(file),
                captionPath: captionPath,
                filename: file,
                imagePath: resolvedImagePath
            ))
        }

        guard !foundSamples.isEmpty else {
            throw TrainingError.datasetError("No video+caption pairs found in \(directory)")
        }

        self.samples = foundSamples.sorted { $0.filename < $1.filename }
    }

    /// Load a training sample at the given index
    func loadSample(at index: Int) async throws -> TrainingSample {
        let info = samples[index % samples.count]

        // Read caption
        let caption = try String(contentsOfFile: info.captionPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Compute per-video resolution (fit within budget, preserve aspect ratio)
        let res = try await targetResolution(forVideoAt: info.videoPath)

        // Extract video frames at the computed resolution
        let frames = try await extractFrames(from: info.videoPath, width: res.width, height: res.height)

        // Extract audio if needed
        var audioWaveform: MLXArray? = nil
        if extractAudio {
            audioWaveform = try await extractAudioWaveform(from: info.videoPath)
        }

        // Load I2V conditioning image if available (same resolution as video)
        var image: MLXArray? = nil
        if let imgPath = info.imagePath {
            image = try loadImageFrame(from: imgPath, width: res.width, height: res.height)
        }

        return TrainingSample(
            frames: frames,
            caption: caption,
            audioWaveform: audioWaveform,
            image: image,
            filename: info.filename
        )
    }

    /// Number of samples
    var count: Int { samples.count }

    // MARK: - Resolution Helpers

    /// Compute target resolution for a video, fitting within the max budget and preserving aspect ratio.
    /// Both dimensions are rounded down to the nearest multiple of 32 (required by VAE).
    func targetResolution(forVideoAt path: String) async throws -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw TrainingError.datasetError("No video track in \(path)")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // Apply transform to get the actual displayed dimensions (handles rotation)
        let transformed = CGRectApplyAffineTransform(
            CGRect(origin: .zero, size: size), transform
        )
        let srcW = abs(transformed.width)
        let srcH = abs(transformed.height)

        return Self.fitResolution(
            srcWidth: srcW, srcHeight: srcH,
            maxWidth: maxWidth, maxHeight: maxHeight
        )
    }

    /// Fit source dimensions into a max budget, preserving aspect ratio, rounding to 32.
    static func fitResolution(
        srcWidth: CGFloat, srcHeight: CGFloat,
        maxWidth: Int, maxHeight: Int
    ) -> (width: Int, height: Int) {
        let scale = min(
            CGFloat(maxWidth) / srcWidth,
            CGFloat(maxHeight) / srcHeight
        )
        // Round down to nearest 32 (minimum 32)
        let w = max(32, Int(srcWidth * scale) / 32 * 32)
        let h = max(32, Int(srcHeight * scale) / 32 * 32)
        return (w, h)
    }

    // MARK: - Image Loading

    /// Load a single image file as a (1, 3, 1, H, W) tensor in [-1, 1].
    /// Center-cropped and resized to the given dimensions.
    private func loadImageFrame(from path: String, width: Int, height: Int) throws -> MLXArray {
        return try loadImage(from: path, width: width, height: height)
    }

    // MARK: - Frame Extraction

    /// Extract frames from a video file using AVFoundation
    private func extractFrames(from path: String, width: Int, height: Int) async throws -> MLXArray {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        // Get video duration and frame rate
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Calculate frame times — evenly spaced across video duration
        let frameCount = numFrames
        var frameTimes: [CMTime] = []
        for i in 0..<frameCount {
            let t = durationSeconds * Double(i) / Double(frameCount - 1)
            frameTimes.append(CMTime(seconds: t, preferredTimescale: 600))
        }

        // Set up image generator (no maximumSize — we handle resize ourselves)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        // Extract frames
        var frameArrays: [MLXArray] = []
        let ciContext = CIContext()

        for time in frameTimes {
            let (image, _) = try await generator.image(at: time)

            // Convert CGImage to CIImage for processing
            let ciImage = CIImage(cgImage: image)

            // Center-crop to target aspect ratio, then resize (preserves proportions)
            let srcW = ciImage.extent.width
            let srcH = ciImage.extent.height
            let targetAspect = CGFloat(width) / CGFloat(height)
            let srcAspect = srcW / srcH

            let cropRect: CGRect
            if srcAspect > targetAspect {
                // Source is wider — crop horizontally
                let cropW = srcH * targetAspect
                let offsetX = (srcW - cropW) / 2
                cropRect = CGRect(x: offsetX, y: 0, width: cropW, height: srcH)
            } else {
                // Source is taller — crop vertically
                let cropH = srcW / targetAspect
                let offsetY = (srcH - cropH) / 2
                cropRect = CGRect(x: 0, y: offsetY, width: srcW, height: cropH)
            }

            let cropped = ciImage.cropped(to: cropRect)
            // Translate to origin after crop, then scale to target size
            let originImage = cropped.transformed(by: CGAffineTransform(
                translationX: -cropRect.origin.x, y: -cropRect.origin.y
            ))
            let scaleX = CGFloat(width) / cropRect.width
            let scaleY = CGFloat(height) / cropRect.height
            let scaledImage = originImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            // Get pixel data as RGBA
            let w = width
            let h = height
            var pixelData = [UInt8](repeating: 0, count: w * h * 4)
            ciContext.render(
                scaledImage,
                toBitmap: &pixelData,
                rowBytes: w * 4,
                bounds: CGRect(x: 0, y: 0, width: w, height: h),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            // Convert to float32 CHW format in [-1, 1]
            var rChannel = [Float](repeating: 0, count: w * h)
            var gChannel = [Float](repeating: 0, count: w * h)
            var bChannel = [Float](repeating: 0, count: w * h)

            for i in 0..<(w * h) {
                rChannel[i] = Float(pixelData[i * 4]) / 127.5 - 1.0
                gChannel[i] = Float(pixelData[i * 4 + 1]) / 127.5 - 1.0
                bChannel[i] = Float(pixelData[i * 4 + 2]) / 127.5 - 1.0
            }

            // Shape: (3, H, W)
            let r = MLXArray(rChannel, [1, h, w])
            let g = MLXArray(gChannel, [1, h, w])
            let b = MLXArray(bChannel, [1, h, w])
            let frame = MLX.concatenated([r, g, b], axis: 0)
            frameArrays.append(frame)
        }

        // Stack frames: (T, 3, H, W) → (1, 3, T, H, W)
        let stacked = MLX.stacked(frameArrays, axis: 0)  // (T, 3, H, W)
        let transposed = stacked.transposed(1, 0, 2, 3)   // (3, T, H, W)
        let batched = transposed.expandedDimensions(axis: 0)  // (1, 3, T, H, W)

        return batched.asType(.float32)
    }

    // MARK: - Audio Extraction

    /// Extract audio waveform from video using AVAssetReader
    private func extractAudioWaveform(from path: String) async throws -> MLXArray {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        // Check for audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            // No audio track — return silence
            let duration = try await asset.load(.duration)
            let numSamples = Int(CMTimeGetSeconds(duration) * Double(audioSampleRate))
            return MLXArray.zeros([numSamples]).asType(.float32)
        }

        // Configure reader for PCM float32 mono
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        var allSamples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = [UInt8](repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

                // Interpret as Float32
                let floatCount = length / MemoryLayout<Float>.size
                data.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                        allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
                    }
                }
            }
        }

        guard reader.status == .completed else {
            throw TrainingError.datasetError("Audio extraction failed for \(path)")
        }

        return MLXArray(allSamples)
    }
}
