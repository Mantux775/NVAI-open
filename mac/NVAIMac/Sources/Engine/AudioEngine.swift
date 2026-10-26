import Foundation
import MLX
import StableAudio3

/// Stable Audio 3 Medium über MLX (seit 0.4.7, `AudioCatalog`). Hält das Modell zwischen Aufträgen; auf Macs bis
/// 16 GB entlädt die Warteschlange vorher die Bildmodelle.
actor AudioEngine {
    static let shared = AudioEngine()

    private var model: StableAudio3MusicGen?

    var isLoaded: Bool { model != nil }

    func load() async throws {
        if model != nil { return }
        guard AudioCatalog.installed else {
            throw APIError(409, t("Stable Audio 3 ist nicht geladen (unter „Modelle“).", "Stable Audio 3 is not downloaded (under \"Models\")."))
        }
        model = try await StableAudio3MusicGen.fromPretrained(variant: .mediumInt8,
                                                              localBundleOverride: AudioCatalog.directory)
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    /// Stereo, 44,1 kHz, als WAV (16 Bit).
    func generate(prompt: String, seconds: Double, steps: Int, cfg: Double, seed: UInt64) throws -> Data {
        guard let model else { throw APIError(500, t("Stable Audio 3 ist nicht geladen.", "Stable Audio 3 is not loaded.")) }
        let params = StableAudio3GenerationParams(seconds: Float(seconds), steps: steps, cfgScale: Float(cfg), seed: seed)
        var (left, right) = model.generate(prompt: AudioCatalog.prompt(prompt, seconds: seconds), params: params)
        Memory.clearCache()
        Self.limit(&left, &right, sampleRate: 44_100)
        return Self.wav(left: left, right: right, sampleRate: 44_100)
    }

    /// Begrenzer wie `NVAIAudioLimiter` unter Windows: Grenze −1 dBFS, 5 ms Vorlauf, 80 ms Rücklauf. Gemessen am
    /// 25.10.2026: ein 60-s-Marsch erreichte ohne Begrenzer 0,0 dBFS.
    static func limit(_ left: inout [Float], _ right: inout [Float], sampleRate: Int,
                      ceilingDB: Float = -1, lookaheadMS: Float = 5, releaseMS: Float = 80) {
        let n = min(left.count, right.count)
        guard n > 0 else { return }
        let ceiling = powf(10, ceilingDB / 20)
        let ahead = max(1, Int(Float(sampleRate) * lookaheadMS / 1000))
        let release = 1 - expf(-1 / (Float(sampleRate) * releaseMS / 1000))
        // Nötige Verstärkung je Abtastwert, dann das Minimum über die nächsten `ahead` Werte (Vorlauf).
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let peak = max(abs(left[i]), abs(right[i]))
            if peak > ceiling { need[i] = ceiling / peak }
        }
        var window = [Float](repeating: 1, count: n)
        var deque: [Int] = []
        var head = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            while deque.count > head, need[deque[deque.count - 1]] >= need[i] { deque.removeLast() }
            deque.append(i)
            while deque[head] > i + ahead { head += 1 }
            window[i] = need[deque[head]]
        }
        var gain: Float = 1
        for i in 0..<n {
            let target = window[i]
            gain = target < gain ? target : gain + release * (target - gain)
            left[i] *= gain
            right[i] *= gain
        }
    }

    /// 16-Bit-PCM, Stereo, verschränkt; Spitzen über ±1 werden begrenzt.
    static func wav(left: [Float], right: [Float], sampleRate: Int) -> Data {
        let frames = min(left.count, right.count)
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            pcm[i * 2] = Int16(max(-1, min(1, left[i])) * 32767)
            pcm[i * 2 + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        var data = Data()
        func add<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); add(UInt32(16)); add(UInt16(1)); add(UInt16(2))
        add(UInt32(sampleRate)); add(UInt32(sampleRate * 4)); add(UInt16(4)); add(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); add(UInt32(bytes))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Lautheit grob (RMS und Spitze in dBFS) fürs Protokoll.
    static func levels(left: [Float]) -> (rms: Double, peak: Double) {
        guard !left.isEmpty else { return (-120, -120) }
        let sum = left.reduce(Double(0)) { $0 + Double($1 * $1) }
        let peak = left.map { abs($0) }.max() ?? 0
        return (10 * log10(max(1e-12, sum / Double(left.count))), 20 * log10(max(1e-12, Double(peak))))
    }
}
