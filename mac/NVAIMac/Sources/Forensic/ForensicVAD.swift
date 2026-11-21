import AVFoundation
import CoreML
import Foundation

/// Ton einer Spur als Mono mit 16 kHz (Spracherkennung und Sprachfinder), wie `forensic_tools._read16`.
enum Audio16k {
    static let rate = 16000.0

    /// Abschnitt [start, end] in Sekunden.
    static func read(_ url: URL, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let a = max(0, AVAudioFramePosition(start * sr))
        let n = AVAudioFrameCount(max(1, min(Double(file.length - a), (end - start) * sr)))
        guard a < file.length else { return [] }
        file.framePosition = a
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return [] }
        try file.read(into: buf, frameCount: n)
        return try resample(buf)
    }

    /// Ganze Spur in Blöcken (16 kHz), `seconds` je Block; der Umrechner läuft über die Blockgrenzen weiter.
    static func stream(_ url: URL, seconds: Double, isCancelled: () -> Bool, _ body: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false)!
        let converter = inFormat.sampleRate == rate ? nil : AVAudioConverter(from: mono, to: outFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let step = AVAudioFrameCount(seconds * inFormat.sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: step) else { return }
        var ended = false
        while !ended {
            if isCancelled() { throw CancellationError() }
            try file.read(into: buf, frameCount: step)
            ended = buf.frameLength < step || file.framePosition >= file.length
            let m = downmix(buf, format: mono)
            guard let converter else {
                try body(Array(UnsafeBufferPointer(start: m.floatChannelData![0], count: Int(m.frameLength))))
                continue
            }
            var given = false
            var out: [Float] = []
            while true {
                let cap = AVAudioFrameCount(Double(m.frameLength) * rate / inFormat.sampleRate) + 2048
                guard let o = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { break }
                var error: NSError?
                let status = converter.convert(to: o, error: &error) { _, st in
                    if !given { given = true; st.pointee = .haveData; return m }
                    st.pointee = ended ? .endOfStream : .noDataNow
                    return nil
                }
                if let error { throw error }
                out.append(contentsOf: UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
                if status != .haveData { break }
            }
            if !out.isEmpty { try body(out) }
        }
    }

    private static func downmix(_ buf: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let n = Int(buf.frameLength)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, n)))!
        out.frameLength = AVAudioFrameCount(n)
        let ch = Int(buf.format.channelCount)
        let dst = out.floatChannelData![0]
        let src = buf.floatChannelData!
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<ch { s += src[c][i] }
            dst[i] = s / Float(ch)
        }
        return out
    }

    private static func resample(_ buf: AVAudioPCMBuffer) throws -> [Float] {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false)!
        let m = downmix(buf, format: mono)
        if buf.format.sampleRate == rate {
            return Array(UnsafeBufferPointer(start: m.floatChannelData![0], count: Int(m.frameLength)))
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: mono, to: outFormat) else { return [] }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let cap = AVAudioFrameCount(Double(m.frameLength) * rate / buf.format.sampleRate) + 2048
        guard let o = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var given = false
        var error: NSError?
        _ = converter.convert(to: o, error: &error) { _, st in
            if !given { given = true; st.pointee = .haveData; return m }
            st.pointee = .endOfStream
            return nil
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
    }
}

/// Silero VAD 6.0 als Core ML (FluidInference/silero-vad-coreml, MIT): Sprachwahrscheinlichkeit je 32 ms bei 16 kHz.
/// Das Modell bekommt je Fenster 64 Proben Vorlauf (Ende des vorigen Fensters) plus 512 neue und trägt seinen Zustand
/// (hidden/cell, je 128) weiter, wie Silero 5/6 selbst. Je Abschnitt beginnt es neu (wie `silero_vad.probs`).
final class SileroVAD {
    static let window = 512
    static let context = 64
    private let model: MLModel
    private let input: MLMultiArray
    private let hidden: MLMultiArray
    private let cell: MLMultiArray
    private let provider: MLDictionaryFeatureProvider

    init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly   // winziges Netz: Neural Engine und GPU lohnen den Wechsel nicht
        model = try MLModel(contentsOf: directory, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.context + Self.window)], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: ["audio_input": input, "hidden_state": hidden, "cell_state": cell])
    }

    /// Wahrscheinlichkeit je 32-ms-Fenster (Zustand vorher zurückgesetzt).
    func probabilities(_ x: UnsafeBufferPointer<Float>) throws -> [Float] {
        let w = Self.window
        let c = Self.context
        let n = x.count / w
        var out = [Float](repeating: 0, count: n)
        let inp = input.dataPointer.bindMemory(to: Float.self, capacity: c + w)
        let h = hidden.dataPointer.bindMemory(to: Float.self, capacity: 128)
        let s = cell.dataPointer.bindMemory(to: Float.self, capacity: 128)
        for i in 0..<128 { h[i] = 0; s[i] = 0 }
        for i in 0..<c { inp[i] = 0 }
        for k in 0..<n {
            let base = x.baseAddress! + k * w
            memcpy(inp + c, base, w * 4)
            let result = try model.prediction(from: provider)
            out[k] = Self.first(result.featureValue(for: "vad_output")?.multiArrayValue)
            Self.copy(result.featureValue(for: "new_hidden_state")?.multiArrayValue, to: h)
            Self.copy(result.featureValue(for: "new_cell_state")?.multiArrayValue, to: s)
            memcpy(inp, base + (w - c), c * 4)
        }
        return out
    }

    private static func first(_ a: MLMultiArray?) -> Float {
        guard let a else { return 0 }
        return a.dataType == .float32 ? a.dataPointer.bindMemory(to: Float.self, capacity: 1)[0] : a[0].floatValue
    }

    private static func copy(_ a: MLMultiArray?, to dst: UnsafeMutablePointer<Float>) {
        guard let a else { return }
        if a.dataType == .float32 {
            memcpy(dst, a.dataPointer, 128 * 4)
        } else {
            for i in 0..<128 { dst[i] = a[i].floatValue }
        }
    }

    /// Sprachstrecken (Anfang, Ende in s, mittlere Wahrscheinlichkeit) wie `silero_vad.speech_spans`.
    func speechSpans(_ x: [Float], threshold: Float = 0.5, minSpeech: Double = 0.25, minGap: Double = 0.4,
                     pad: Double = 0.15) throws -> [(Double, Double, Double)] {
        let p = try x.withUnsafeBufferPointer { try probabilities($0) }
        let step = Double(Self.window) / Audio16k.rate
        var spans: [[Double]] = []
        var i = 0
        while i < p.count {
            if p[i] > threshold {
                var j = i
                while j < p.count && p[j] > threshold { j += 1 }
                let a = Double(i) * step
                let b = Double(j) * step
                if let last = spans.last, a - last[1] < minGap { spans[spans.count - 1][1] = b } else { spans.append([a, b]) }
                i = j
            } else {
                i += 1
            }
        }
        let total = Double(x.count) / Audio16k.rate
        return spans.compactMap { s in
            guard s[1] - s[0] >= minSpeech else { return nil }
            let ia = Int(s[0] / step)
            let ib = max(ia + 1, Int(s[1] / step))
            let slice = p[ia..<min(ib, p.count)]
            let mean = slice.isEmpty ? 0 : Double(slice.reduce(0, +)) / Double(slice.count)
            return (max(0, s[0] - pad), min(total, s[1] + pad), mean)
        }
    }

    /// Sprachkarte einer ganzen Spur: je 0,1 s ein Wert 0–255 (höchste Fensterwahrscheinlichkeit), Datei `.vad`, wie
    /// `cmd_vadmap` (Stücke zu 32 s, jedes beginnt neu). Ergebnis: Sekunden mit Sprache.
    func speechMap(track url: URL, out: URL, isCancelled: () -> Bool, progress: (Double) -> Void) throws -> Double {
        let duration = try { () -> Double in
            let f = try AVAudioFile(forReading: url)
            return Double(f.length) / f.processingFormat.sampleRate
        }()
        let bins = Int((duration * Double(ForensicFormat.actRate)).rounded(.up))
        var map = [UInt8](repeating: 0, count: bins + 1)
        let chunk = Self.window * 1000                   // 32 s
        var pending: [Float] = []
        var offset = 0                                   // Proben (16 kHz) vor `pending`
        let rate = Double(ForensicFormat.actRate)
        func run(_ x: ArraySlice<Float>, at start: Int) throws {
            var block = Array(x)
            if block.count % Self.window != 0 { block += [Float](repeating: 0, count: Self.window - block.count % Self.window) }
            let p = try block.withUnsafeBufferPointer { try probabilities($0) }
            for (k, v) in p.enumerated() {
                let t = (Double(start) + Double(k * Self.window)) / Audio16k.rate
                let bin = Int(t * rate)
                guard bin < map.count else { break }
                map[bin] = max(map[bin], UInt8(min(255, v * 255 + 0.5)))
            }
        }
        try Audio16k.stream(url, seconds: 60, isCancelled: isCancelled) { x in
            pending += x
            while pending.count >= chunk {
                try run(pending[0..<chunk], at: offset)
                pending.removeFirst(chunk)
                offset += chunk
            }
            progress(min(1, Double(offset) / Audio16k.rate / max(1, duration)))
        }
        if !pending.isEmpty { try run(pending[...], at: offset) }
        let values = Array(map.prefix(bins))
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(values).write(to: out, options: .atomic)
        return Double(values.filter { $0 > 128 }.count) / rate
    }
}
