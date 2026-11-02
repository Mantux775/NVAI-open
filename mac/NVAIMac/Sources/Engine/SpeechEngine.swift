import AVFoundation
import Foundation
import MLX
import Qwen3TTSKit

/// Sprecherstimme über MLX (seit 0.5.3, `SpeechCatalog`, Paket `Packages/qwen3-tts-swift`). Hält eine der zwei
/// Fassungen im Speicher: VoiceDesign für eine beschriebene Stimme, Base zum Übernehmen aus einer Aufnahme. Auf Macs
/// bis 16 GB entlädt die Warteschlange vorher die übrigen Modelle.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var model: Qwen3TTS?

    var loadedKind: Qwen3TTS.Kind? { model?.kind }
    var isLoaded: Bool { model != nil }

    /// Lädt die Fassung für `kind` (`.voiceDesign` oder `.base`); eine andere geladene wird vorher freigegeben.
    func load(_ kind: Qwen3TTS.Kind) throws {
        if model?.kind == kind { return }
        unload()
        guard SpeechCatalog.installed else {
            throw APIError(409, t("Die Sprecherstimme ist nicht geladen (unter „Modelle“).", "The narrator voice is not downloaded (under \"Models\")."))
        }
        model = try Qwen3TTS.load(directory: kind == .base ? SpeechCatalog.baseDirectory : SpeechCatalog.designDirectory)
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    var sampleRate: Int { model?.sampleRate ?? 24_000 }
    var referenceSampleRate: Int { model?.referenceSampleRate ?? 24_000 }

    /// Stimme aus der Beschreibung `instruct`. Bricht ab, sobald der aufrufende Task abgebrochen wird.
    func design(text: String, instruct: String, language: String, seed: UInt64) throws -> [Float] {
        guard let model, model.kind == .voiceDesign else {
            throw APIError(500, t("VoiceDesign ist nicht geladen.", "VoiceDesign is not loaded."))
        }
        defer { Memory.clearCache() }
        return try model.design(text: text, instruct: instruct, language: language, seed: seed, shouldCancel: { Task.isCancelled })
    }

    /// Stimme aus einer Aufnahme (Mono, `referenceSampleRate`); ohne `referenceText` nur der Stimmklang.
    func clone(text: String, reference: [Float], referenceText: String?, language: String, seed: UInt64) throws -> [Float] {
        guard let model, model.kind == .base else {
            throw APIError(500, t("Base ist nicht geladen.", "Base is not loaded."))
        }
        defer { Memory.clearCache() }
        return try model.clone(text: text, referenceAudio: reference, referenceText: referenceText, language: language,
                               seed: seed, shouldCancel: { Task.isCancelled })
    }

    // MARK: Aufnahme lesen, Ergebnis aufbereiten

    static let referenceMaxSeconds = 20.0

    /// Tonspur einer Datei (Ton oder Video) als Mono-Float in `sampleRate`, höchstens `referenceMaxSeconds`.
    /// `trimmed`: Die Aufnahme war länger; dann passt ihr Text nicht mehr, und es zählt nur der Stimmklang.
    static func readReference(_ url: URL, sampleRate: Int) async throws -> (samples: [Float], trimmed: Bool) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw APIError(422, t("Die Aufnahme hat keine Tonspur.", "The recording has no audio track."))
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: referenceMaxSeconds + 1, preferredTimescale: 600))
        guard reader.startReading() else {
            throw APIError(422, t("Die Aufnahme ließ sich nicht lesen.", "The recording could not be read."))
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples += chunk
        }
        let limit = Int(referenceMaxSeconds * Double(sampleRate))
        let trimmed = samples.count > limit
        if trimmed { samples = Array(samples[..<limit]) }
        guard samples.count >= sampleRate else {
            throw APIError(422, t("Die Aufnahme ist kürzer als eine Sekunde; drei Sekunden und mehr sind gut.",
                                  "The recording is shorter than one second; three seconds or more work well."))
        }
        return (samples, trimmed)
    }

    /// Ränder kürzen und Pegel angleichen, wie der Worker unter Windows (seit 0.5.21/0.5.3): Qwen3-TTS beginnt einen
    /// Satz je nach Seed mit bis zu 1,4 s Stille, und auf dem Mac kam ein Satz mit −11,5 dBFS Spitze heraus. Als Stille
    /// gilt ein 20-ms-Fenster unter Spitze − 45 dB; 0,15 s Vorlauf und 0,3 s Nachlauf bleiben. Dann die Spitze auf
    /// −1 dBFS, um höchstens 20 dB angehoben.
    static func tidy(_ x: [Float], sampleRate: Int) -> [Float] {
        guard let peak = x.map(abs).max(), peak > 0 else { return x }
        let window = max(1, sampleRate / 50)
        let floor = peak * powf(10, -45 / 20)
        var first: Int?
        var last = 0
        var start = 0
        while start < x.count {
            let end = min(x.count, start + window)
            if x[start..<end].contains(where: { abs($0) >= floor }) {
                if first == nil { first = start }
                last = end
            }
            start = end
        }
        guard let first else { return x }
        let from = max(0, first - Int(0.15 * Double(sampleRate)))
        let to = min(x.count, last + Int(0.3 * Double(sampleRate)))
        let gain = min(powf(10, -1 / 20) / peak, 10)
        return x[from..<to].map { $0 * gain }
    }

    /// Mono-WAV mit 16 Bit.
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }  // Apple Silicon ist little-endian wie WAV
        return data
    }
}
