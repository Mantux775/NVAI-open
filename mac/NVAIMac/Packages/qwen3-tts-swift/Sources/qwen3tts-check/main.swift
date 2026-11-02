// qwen3tts-check: command-line check of Qwen3TTSKit on the Mac (load, generate, WAV, timing, memory).
//
//   qwen3tts-check info  --model DIR
//   qwen3tts-check design --model DIR --text T --instruct I [--language L] [--seed N] --out FILE.wav
//   qwen3tts-check clone  --model DIR --text T --ref REF.wav [--ref-text T] [--language L] [--seed N] --out FILE.wav
//   qwen3tts-check vd-suite   --model VOICEDESIGN_DIR --outdir DIR     (tests 1, 2, 4, 5)
//   qwen3tts-check base-suite --model BASE_DIR --ref REF.wav --outdir DIR   (test 3, ICL and x-vector)
//
// WAVs are written as 16-bit PCM mono at the model's sample rate. Numbers are printed as "key: value" lines.

import Darwin
import Foundation
import MLX
import Qwen3TTSKit

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: qwen3tts-check info|design|clone|vd-suite|base-suite --model DIR ...")
    exit(2)
}
arguments.removeFirst()

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func require(_ name: String) -> String {
    guard let value = option(name) else {
        print("missing --\(name)")
        exit(2)
    }
    return value
}

// MARK: - WAV

func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    let byteCount = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
    for sample in samples {
        let clipped = sample.isFinite ? max(-1, min(1, sample)) : 0
        append(Int16((clipped * 32767).rounded()))
    }
    try data.write(to: url)
}

/// Reads 16-bit PCM or 32-bit float WAV (mono or the first channel). Returns samples and rate.
func readWAV(_ url: URL) throws -> ([Float], Int) {
    let data = try Data(contentsOf: url)
    func u32(_ at: Int) -> UInt32 { data.subdata(in: at ..< at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    func u16(_ at: Int) -> UInt16 { data.subdata(in: at ..< at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
    guard data.count > 44, String(decoding: data[0 ..< 4], as: UTF8.self) == "RIFF" else {
        throw NSError(domain: "wav", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a RIFF file"])
    }
    var offset = 12
    var format = 0, channels = 1, rate = 0, bits = 0
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
        let size = Int(u32(offset + 4))
        if id == "fmt " {
            format = Int(u16(offset + 8)); channels = Int(u16(offset + 10)); rate = Int(u32(offset + 12))
            bits = Int(u16(offset + 22))
        } else if id == "data" {
            let start = offset + 8
            let end = min(data.count, start + size)
            var samples = [Float]()
            if format == 1, bits == 16 {
                let frameBytes = 2 * channels
                samples.reserveCapacity((end - start) / frameBytes)
                var i = start
                while i + 2 <= end {
                    samples.append(Float(Int16(bitPattern: u16(i))) / 32768)
                    i += frameBytes
                }
            } else if format == 3, bits == 32 {
                let frameBytes = 4 * channels
                var i = start
                while i + 4 <= end {
                    samples.append(Float(bitPattern: u32(i)))
                    i += frameBytes
                }
            } else {
                throw NSError(domain: "wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported WAV format \(format)/\(bits)"])
            }
            return (samples, rate)
        }
        offset += 8 + size + (size % 2)
    }
    throw NSError(domain: "wav", code: 3, userInfo: [NSLocalizedDescriptionKey: "no data chunk"])
}

// MARK: - Measurements

func dB(_ value: Double) -> String {
    value > 0 ? String(format: "%.1f dBFS", 20 * log10(value)) : "-inf dBFS"
}

/// RMS, peak, NaN/Inf count and silence (20 ms windows below -50 dBFS, leading/trailing/total).
func describeAudio(_ samples: [Float], sampleRate: Int) -> [(String, String)] {
    let nonFinite = samples.filter { !$0.isFinite }.count
    let finite = samples.map { $0.isFinite ? Double($0) : 0 }
    let rms = finite.isEmpty ? 0 : sqrt(finite.reduce(0) { $0 + $1 * $1 } / Double(finite.count))
    let peak = finite.map(abs).max() ?? 0
    let window = sampleRate / 50
    var silent = [Bool]()
    var index = 0
    while index < finite.count {
        let end = min(finite.count, index + window)
        let slice = finite[index ..< end]
        let windowRMS = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Double(slice.count))
        silent.append(windowRMS < pow(10, -50.0 / 20))
        index = end
    }
    let leading = silent.prefix { $0 }.count
    let trailing = silent.reversed().prefix { $0 }.count
    let total = silent.filter { $0 }.count
    return [
        ("samples", "\(samples.count)"),
        ("audio_seconds", String(format: "%.2f", Double(samples.count) / Double(sampleRate))),
        ("rms", dB(rms)),
        ("peak", String(format: "%.3f (%@)", peak, dB(peak))),
        ("nan_or_inf", "\(nonFinite)"),
        ("silence_total", String(format: "%.0f %% of 20 ms windows below -50 dBFS", silent.isEmpty ? 0 : 100 * Double(total) / Double(silent.count))),
        ("silence_lead_trail", String(format: "%.2f s / %.2f s", Double(leading) * 0.02, Double(trailing) * 0.02)),
    ]
}

/// Physical footprint of this process (what Activity Monitor calls "Memory").
func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func gb(_ bytes: Int) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

func report(_ title: String, _ lines: [(String, String)]) {
    print("== \(title)")
    for (key, value) in lines { print("  \(key): \(value)") }
    fflush(stdout)
}

func loadModel(_ path: String) -> (Qwen3TTS, Double) {
    Memory.peakMemory = 0
    let start = Date()
    do {
        let tts = try Qwen3TTS.load(directory: URL(fileURLWithPath: path))
        let seconds = Date().timeIntervalSince(start)
        report("load", [
            ("model", path),
            ("kind", tts.kind.rawValue),
            ("sample_rate", "\(tts.sampleRate) Hz (reference input \(tts.referenceSampleRate) Hz)"),
            ("languages", tts.languages.joined(separator: ", ")),
            ("speakers", tts.speakers.isEmpty ? "-" : tts.speakers.joined(separator: ", ")),
            ("sampling", "do_sample \(tts.sampling.doSample), temperature \(tts.sampling.temperature), top_k \(tts.sampling.topK), top_p \(tts.sampling.topP), repetition_penalty \(tts.sampling.repetitionPenalty), subtalker \(tts.sampling.subtalkerDoSample)/\(tts.sampling.subtalkerTemperature)/\(tts.sampling.subtalkerTopK)/\(tts.sampling.subtalkerTopP), max_new_tokens \(tts.sampling.maxNewTokens)"),
            ("load_seconds", String(format: "%.2f", seconds)),
            ("mlx_active_after_load", gb(Memory.activeMemory)),
            ("mlx_peak_during_load", gb(Memory.peakMemory)),
            ("process_footprint", gb(physFootprint())),
        ])
        return (tts, seconds)
    } catch {
        print("load failed: \(error.localizedDescription) [\(error)]")
        exit(1)
    }
}

/// Runs one generation, writes the WAV, prints timing, audio and memory numbers.
@discardableResult
func runCase(
    _ title: String, tts: Qwen3TTS, out: URL?, _ body: () throws -> [Float]
) -> [Float]? {
    Memory.peakMemory = 0
    let start = Date()
    do {
        let samples = try body()
        let seconds = Date().timeIntervalSince(start)
        let audioSeconds = Double(samples.count) / Double(tts.sampleRate)
        var lines: [(String, String)] = [
            ("generation_seconds", String(format: "%.2f", seconds)),
            ("real_time_factor", String(format: "%.2f (generation time / audio length)", audioSeconds > 0 ? seconds / audioSeconds : 0)),
        ]
        if let run = tts.lastRun {
            lines += [
                ("frames", "\(run.generatedFrames) of cap \(run.frameCap), \(run.stoppedAtEndToken ? "ended by the model (EOS)" : "STOPPED BY CAP")"),
                ("text_tokens / prompt_tokens / reference_frames", "\(run.textTokens) / \(run.promptLength) / \(run.referenceFrames)"),
                ("prepare / generate / decode seconds", String(format: "%.2f / %.2f / %.2f", run.prepareSeconds, run.generateSeconds, run.decodeSeconds)),
                ("frames_per_second", String(format: "%.1f (real time = 12.5)", run.generateSeconds > 0 ? Double(run.generatedFrames) / run.generateSeconds : 0)),
            ]
        }
        lines += describeAudio(samples, sampleRate: tts.sampleRate)
        lines += [
            ("mlx_peak", gb(Memory.peakMemory)),
            ("mlx_active_after", gb(Memory.activeMemory)),
            ("process_footprint", gb(physFootprint())),
        ]
        if let out {
            try writeWAV(samples, sampleRate: tts.sampleRate, to: out)
            lines.append(("wav", out.path))
        }
        report(title, lines)
        return samples
    } catch is CancellationError {
        report(title, [("result", "CancellationError after \(String(format: "%.2f", Date().timeIntervalSince(start))) s")])
        return nil
    } catch {
        report(title, [("result", "ERROR \(error.localizedDescription) [\(error)]")])
        return nil
    }
}

// MARK: - Texts of the NVAI-open check

let germanText = "Willkommen in der alten Mühle. Hier wurde früher Korn gemahlen, heute erzählt sie Geschichten."
let germanInstruct = "Eine ruhige, tiefe Männerstimme, etwa fünfzig Jahre alt, warm und leicht rau."
let englishText = "The old mill has stood here for three hundred years."
let englishInstruct = "A calm, deep male voice, about fifty, warm and slightly rough."
let cloneText = "Morgen früh geht es weiter, dann zeige ich euch den Keller."
let noCancel: () -> Bool = { false }

// MARK: - Commands

switch command {
case "info":
    _ = loadModel(require("model"))

case "tokens":
    // Prints token ids of each line of --file (UTF-8), one "ids: ..." line per input line.
    let (tts, _) = loadModel(require("model"))
    let text = try String(contentsOfFile: require("file"), encoding: .utf8)
    for line in text.components(separatedBy: "\n") where !line.isEmpty {
        let unescaped = line.replacingOccurrences(of: "\\n", with: "\n")
        print("ids: " + tts.textTokenIDs(unescaped).map(String.init).joined(separator: " "))
    }

case "design":
    let (tts, _) = loadModel(require("model"))
    let seed = option("seed").flatMap(UInt64.init)
    runCase("design", tts: tts, out: URL(fileURLWithPath: require("out"))) {
        try tts.design(
            text: require("text"), instruct: option("instruct") ?? "", language: option("language") ?? "Auto",
            seed: seed, shouldCancel: noCancel
        )
    }

case "clone":
    let (tts, _) = loadModel(require("model"))
    let seed = option("seed").flatMap(UInt64.init)
    let (reference, rate) = try readWAV(URL(fileURLWithPath: require("ref")))
    print("reference: \(reference.count) samples at \(rate) Hz")
    runCase("clone", tts: tts, out: URL(fileURLWithPath: require("out"))) {
        try tts.clone(
            text: require("text"), referenceAudio: reference, referenceText: option("ref-text"),
            language: option("language") ?? "Auto", seed: seed, shouldCancel: noCancel
        )
    }

case "vd-suite":
    let outDir = URL(fileURLWithPath: require("outdir"))
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let (tts, _) = loadModel(require("model"))

    let first = runCase("test1 VoiceDesign German seed 7", tts: tts, out: outDir.appendingPathComponent("t1_voicedesign_de_seed7.wav")) {
        try tts.design(text: germanText, instruct: germanInstruct, language: "German", seed: 7, shouldCancel: noCancel)
    }
    runCase("test2 VoiceDesign English seed 7", tts: tts, out: outDir.appendingPathComponent("t2_voicedesign_en_seed7.wav")) {
        try tts.design(text: englishText, instruct: englishInstruct, language: "English", seed: 7, shouldCancel: noCancel)
    }
    let second = runCase("test4 VoiceDesign German seed 7 again", tts: tts, out: outDir.appendingPathComponent("t4_voicedesign_de_seed7_repeat.wav")) {
        try tts.design(text: germanText, instruct: germanInstruct, language: "German", seed: 7, shouldCancel: noCancel)
    }
    if let first, let second {
        let sameLength = first.count == second.count
        let maxDiff = sameLength ? zip(first, second).map { abs($0 - $1) }.max() ?? 0 : Float.nan
        report("test4 determinism", [
            ("lengths", "\(first.count) vs \(second.count)"),
            ("identical", "\(sameLength && maxDiff == 0)"),
            ("max_abs_difference", sameLength ? "\(maxDiff)" : "n/a (different length)"),
        ])
    }
    // Different seed for contrast: should differ.
    let other = runCase("test4b VoiceDesign German seed 8 (contrast)", tts: tts, out: nil) {
        try tts.design(text: germanText, instruct: germanInstruct, language: "German", seed: 8, shouldCancel: noCancel)
    }
    if let first, let other {
        report("test4b seed 8 vs seed 7", [("identical", "\(first == other)"), ("lengths", "\(first.count) vs \(other.count)")])
    }

    // Test 5: cancel about 1 s after the start.
    let cancelAfter = Double(option("cancel-after") ?? "1.0") ?? 1.0
    var cancelRequestedAt: Date?
    let start = Date()
    runCase("test5 cancellation after \(cancelAfter) s", tts: tts, out: nil) {
        try tts.design(text: germanText, instruct: germanInstruct, language: "German", seed: 7) {
            if Date().timeIntervalSince(start) >= cancelAfter {
                if cancelRequestedAt == nil { cancelRequestedAt = Date() }
                return true
            }
            return false
        }
    }
    if let cancelRequestedAt {
        report("test5 cancellation", [
            ("cancel_requested_after", String(format: "%.2f s", cancelRequestedAt.timeIntervalSince(start))),
            ("returned_after", String(format: "%.2f s", Date().timeIntervalSince(start))),
            ("stop_latency", String(format: "%.3f s (cancel returned true -> CancellationError thrown)", Date().timeIntervalSince(cancelRequestedAt))),
        ])
    }
    // The engine still works after a cancel.
    runCase("test5b generation after cancel (seed 7)", tts: tts, out: nil) {
        try tts.design(text: englishText, instruct: englishInstruct, language: "English", seed: 7, shouldCancel: noCancel)
    }

case "base-suite":
    let outDir = URL(fileURLWithPath: require("outdir"))
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let (reference, rate) = try readWAV(URL(fileURLWithPath: require("ref")))
    let referenceText = option("ref-text") ?? germanText
    report("reference", [("file", require("ref")), ("rate", "\(rate) Hz")] + describeAudio(reference, sampleRate: rate))
    let (tts, _) = loadModel(require("model"))
    guard rate == tts.referenceSampleRate else {
        print("reference must be \(tts.referenceSampleRate) Hz")
        exit(1)
    }
    runCase("test3a Base clone ICL (with reference text) seed 7", tts: tts, out: outDir.appendingPathComponent("t3a_clone_icl_de_seed7.wav")) {
        try tts.clone(text: cloneText, referenceAudio: reference, referenceText: referenceText, language: "German", seed: 7, shouldCancel: noCancel)
    }
    runCase("test3b Base clone x-vector only (no reference text) seed 7", tts: tts, out: outDir.appendingPathComponent("t3b_clone_xvector_de_seed7.wav")) {
        try tts.clone(text: cloneText, referenceAudio: reference, referenceText: nil, language: "German", seed: 7, shouldCancel: noCancel)
    }
    if option("repeat") != nil {
        runCase("test3a again (reference cache, seed 7)", tts: tts, out: nil) {
            try tts.clone(text: cloneText, referenceAudio: reference, referenceText: referenceText, language: "German", seed: 7, shouldCancel: noCancel)
        }
    }

default:
    print("unknown command \(command)")
    exit(2)
}
