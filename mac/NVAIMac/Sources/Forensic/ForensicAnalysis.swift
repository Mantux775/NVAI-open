import Accelerate
import Foundation

/// Wellenform, Spektrogramm in vier Stufen und Sprachaktivität einer Spur, im selben Dateiformat wie NVAI-open unter
/// Windows (`server/nvai/audio_tools.py` `Peaks`, `forensic_tools.py` `cmd_spectro`/`_activity`), damit die Prüf-App
/// Fälle vom Mac genauso liest wie Prüfpakete aus Windows. Alles läuft blockweise: Stunden lange Spuren füllen den
/// Speicher nicht. Ohne Abhängigkeit von der App (nur Foundation und Accelerate), damit ein Prüfprogramm diese Datei
/// allein übersetzen und gegen die Python-Ausgabe vergleichen kann.
enum ForensicFormat {
    static let dbLo: Float = -120
    static let dbHi: Float = 0
    /// Spalten je Stufe: 20 ms, 0,16 s, 2,56 s, 41 s
    static let levels = [1, 8, 128, 2048]
    /// Sprachaktivität: Werte je Sekunde
    static let actRate = 10
    /// Proben je Wellenform-Balken (48 kHz: 187,5 Balken je Sekunde)
    static let peakSamples = 256
    static let bins = 192
    static let fmaxDefault: Double = 12000
    static let specMagic: [UInt8] = Array("NVSP".utf8)
    /// Endungen der Spektrogramm-Stufen und Sprachkarten im Fallordner „fall/spec“
    static let specSuffixes = [".spec", ".spec1", ".spec2", ".spec3", ".act", ".vad"]

    static func suffix(level index: Int) -> String { index == 0 ? ".spec" : ".spec\(index)" }
}

/// Schreibt Daten gepuffert in eine Datei (große Spektrogramme: 10 h ergeben 345 MB in der feinsten Stufe).
final class BufferedFileWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private let limit: Int
    private(set) var bytes: UInt64 = 0

    init(url: URL, bufferSize: Int = 4 << 20) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        limit = bufferSize
        buffer.reserveCapacity(bufferSize)
    }

    func write(_ data: Data) throws {
        buffer.append(data)
        bytes += UInt64(data.count)
        if buffer.count >= limit { try flush() }
    }

    func write(_ raw: UnsafeRawBufferPointer) throws {
        buffer.append(contentsOf: raw)
        bytes += UInt64(raw.count)
        if buffer.count >= limit { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// An eine frühere Stelle schreiben (Kopf nachtragen); vorher alles Gepufferte hinaus.
    func patch(at offset: UInt64, _ data: Data) throws {
        try flush()
        let end = try handle.offset()
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.seek(toOffset: end)
    }

    func close() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
    }
}

/// Kleine Hilfen für Little-Endian-Köpfe.
extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) { appendLE(value.bitPattern) }
}

/// Wellenform: je 256 Proben ein Paar (min, max) als Int8, wie `audio_tools.Peaks` (Rundung wie numpy: zur geraden Zahl).
final class PeaksWriter {
    private var parts = Data()
    private var restMin: Float = .infinity
    private var restMax: Float = -.infinity
    private var restCount = 0
    private(set) var bars = 0
    private(set) var peak: Float = 0

    private static func q(_ x: Float) -> Int8 {
        Int8(max(-127, min(127, (x * 127).rounded(.toNearestOrEven))))
    }

    func add(_ samples: UnsafeBufferPointer<Float>) {
        var i = 0
        let n = samples.count
        while i < n {
            let take = min(ForensicFormat.peakSamples - restCount, n - i)
            var mn: Float = 0
            var mx: Float = 0
            let base = samples.baseAddress! + i
            vDSP_minv(base, 1, &mn, vDSP_Length(take))
            vDSP_maxv(base, 1, &mx, vDSP_Length(take))
            restMin = min(restMin, mn)
            restMax = max(restMax, mx)
            restCount += take
            i += take
            if restCount == ForensicFormat.peakSamples { emit() }
        }
    }

    private func emit() {
        parts.append(UInt8(bitPattern: Self.q(restMin)))
        parts.append(UInt8(bitPattern: Self.q(restMax)))
        peak = max(peak, abs(restMin), abs(restMax))
        bars += 1
        restMin = .infinity
        restMax = -.infinity
        restCount = 0
    }

    /// Letzter angefangener Balken, dann schreiben. Ergebnis: Anzahl der Balken.
    @discardableResult
    func save(to url: URL) throws -> Int {
        if restCount > 0 { emit() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try parts.write(to: url, options: .atomic)
        return bars
    }
}

/// Eine Stufe des Spektrogramms: Spalten als UInt8, je `factor` Spalten zusammengefasst (Maximum je Band), Kopf mit
/// 32 Byte am Anfang (`<4sHHIIfIff`: NVSP, Version 1, Bänder, Spaltenabstand in Proben, Abtastrate, fmax, Spalten,
/// dB-Untergrenze, dB-Obergrenze), wie `forensic_tools.SpecFile`.
final class SpecLevelWriter {
    let url: URL
    private let part: URL
    private let writer: BufferedFileWriter
    private let bins: Int
    private let hop: Int
    private let sr: Int
    private let fmax: Float
    private let factor: Int
    private var acc: [UInt8]
    private var accCount = 0
    private(set) var cols = 0

    init(url: URL, bins: Int, hop: Int, sr: Int, fmax: Double, factor: Int) throws {
        self.url = url
        part = url.appendingPathExtension("part")
        writer = try BufferedFileWriter(url: part)
        self.bins = bins
        self.hop = hop
        self.sr = sr
        self.fmax = Float(fmax)
        self.factor = factor
        acc = [UInt8](repeating: 0, count: bins)
        try writer.write(Data(count: 32))
    }

    func add(_ column: UnsafeBufferPointer<UInt8>) throws {
        if factor == 1 {
            try writer.write(UnsafeRawBufferPointer(column))
            cols += 1
            return
        }
        if accCount == 0 {
            for b in 0..<bins { acc[b] = column[b] }
        } else {
            for b in 0..<bins where column[b] > acc[b] { acc[b] = column[b] }
        }
        accCount += 1
        if accCount == factor { try emit() }
    }

    private func emit() throws {
        try acc.withUnsafeBytes { try writer.write($0) }
        cols += 1
        accCount = 0
    }

    func close() throws {
        if accCount > 0 { try emit() }
        var head = Data()
        head.append(contentsOf: ForensicFormat.specMagic)
        head.appendLE(UInt16(1))
        head.appendLE(UInt16(bins))
        head.appendLE(UInt32(hop * factor))
        head.appendLE(UInt32(sr))
        head.appendLE(fmax)
        head.appendLE(UInt32(cols))
        head.appendLE(ForensicFormat.dbLo)
        head.appendLE(ForensicFormat.dbHi)
        try writer.patch(at: 0, head)
        try writer.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: part, to: url)
    }

    /// Abbruch: halbe Datei weg.
    func discard() {
        try? writer.close()
        try? FileManager.default.removeItem(at: part)
    }
}

/// Ergebnis der groben Sprachaktivität (ohne KI), wie `forensic_tools._activity`.
struct ActivityResult {
    var values: [UInt8]
    var segments: [[Double]]
    var speechSeconds: Double
    var floorDB: Double?
}

/// Spektrogramm einer Spur in vier Stufen und die Werte für die Sprachaktivität, wie `cmd_spectro`: Fenster mittig auf
/// jeder Spalte (Spalte i deckt [i·hop, (i+1)·hop)), Hann-Fenster wie numpy (symmetrisch), Leistung so skaliert, dass ein
/// voll ausgesteuerter Sinus 0 dB ergibt, Bänder gleich breit bis fmax.
final class SpectrogramBuilder {
    let sr: Int
    let bins: Int
    let fmax: Double
    let hop: Int
    let nfft: Int
    /// Spalten insgesamt: eine je angefangene 20 ms der Spur (Länge erst am Ende sicher bekannt)
    var totalCols: Int { Int((Double(fed) / Double(hop)).rounded(.up)) }
    private var fed = 0
    private let levels: [SpecLevelWriter]
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let window: [Float]
    private let norm: Float
    private let starts: [Int]
    private let ends: [Int]
    private let kmax: Int
    private let speech: [Int]
    private var pending: [Float]
    private var readPos = 0
    private(set) var doneCols = 0
    private var act: [Float] = []          // je Spalte: Sprachband-Pegel (dB), Tonhaltigkeit (dB)
    // Arbeitspuffer
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var band: [Double]
    private var db: [Double]
    private var q: [UInt8]
    private var speechDB: [Double]

    /// `outBase`: Pfad ohne Endung (…/fall/spec/<Spur>); `expectedFrames`: ungefähre Länge (nur für die Puffergröße).
    init(outBase: URL, sr: Int, expectedFrames: Int = 0, bins: Int = ForensicFormat.bins, fmax: Double = ForensicFormat.fmaxDefault) throws {
        let fm = min(Double(sr) / 2, fmax)
        // Python: int(round(sr * 0.02)) rundet halbe Werte zur geraden Zahl (11 025 Hz → 220)
        let hp = Int((Double(sr) * 0.02).rounded(.toNearestOrEven))
        let n = sr >= 32000 ? 2048 : 1024
        let l2 = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "Forensic", code: 1, userInfo: [NSLocalizedDescriptionKey: "FFT setup"])
        }
        // Hann-Fenster wie np.hanning (symmetrisch, Nenner N − 1)
        let win = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        let wsum = win.reduce(0.0) { $0 + Double($1) }
        // Bänder: erster FFT-Bin je Band wie _band_starts (np.searchsorted, links), Bänder ohne eigenen Bin nehmen den
        // Nachbarn (Ende ≤ Anfang: ein Bin, Anzahl 1)
        let km = Int((fm * Double(n) / Double(sr)).rounded(.down)) + 1
        var bandOf = [Int](repeating: 0, count: km)
        for k in 0..<km {
            let f = Double(k) * Double(sr) / Double(n)
            bandOf[k] = min(bins - 1, Int((f / fm * Double(bins)).rounded(.down)))
        }
        var s = [Int](repeating: 0, count: bins)
        for b in 0..<bins {
            var lo = 0
            var hi = km
            while lo < hi {
                let mid = (lo + hi) / 2
                if bandOf[mid] < b { lo = mid + 1 } else { hi = mid }
            }
            s[b] = min(lo, km - 1)
        }
        let top = min(3800.0, fm)
        let sp = (0..<bins).filter { b -> Bool in
            let fb = (Double(b) + 0.5) * fm / Double(bins)
            return fb >= 250 && fb <= top
        }
        var writers: [SpecLevelWriter] = []
        do {
            for (index, factor) in ForensicFormat.levels.enumerated() {
                writers.append(try SpecLevelWriter(url: URL(fileURLWithPath: outBase.path + ForensicFormat.suffix(level: index)),
                                                   bins: bins, hop: hp, sr: sr, fmax: fm, factor: factor))
            }
        } catch {
            for w in writers { w.discard() }
            vDSP_destroy_fftsetup(setup)
            throw error
        }
        self.sr = sr
        self.bins = bins
        self.fmax = fm
        hop = hp
        nfft = n
        log2n = l2
        fft = setup
        window = win
        norm = Float(4.0 / (wsum * wsum))
        kmax = km
        starts = s
        ends = (0..<bins).map { $0 + 1 < bins ? s[$0 + 1] : km }
        speech = sp
        levels = writers
        pending = [Float](repeating: 0, count: n / 2 - hp / 2)
        frame = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2 + 1)
        band = [Double](repeating: 0, count: bins)
        db = [Double](repeating: 0, count: bins)
        q = [UInt8](repeating: 0, count: bins)
        speechDB = [Double](repeating: 0, count: sp.count)
        act.reserveCapacity(min(expectedFrames / max(1, hp) + 1, 4_000_000) * 2)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Kopf der Stufen für projekt.json (`spec`)
    var info: [String: Any] {
        ["bins": bins, "hop": hop, "sr": sr, "fmax": fmax,
         "levels": zip(ForensicFormat.levels, levels).map { ["factor": $0, "cols": $1.cols] }]
    }

    var levelCols: [Int] { levels.map(\.cols) }

    func add(_ samples: UnsafeBufferPointer<Float>) throws {
        pending.append(contentsOf: samples)
        fed += samples.count
        try drain(final: false)
    }

    private func drain(final: Bool) throws {
        while pending.count - readPos >= nfft && (!final || doneCols < totalCols) {
            try column(at: readPos)
            readPos += hop
        }
        // verbrauchte Proben gelegentlich vorn abschneiden
        if readPos > 1 << 20 || (final && readPos > 0) {
            pending.removeFirst(min(readPos, pending.count))
            readPos = 0
        }
    }

    private func column(at offset: Int) throws {
        pending.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(nfft))
        }
        // reelle FFT (vDSP liefert das Doppelte der DFT; DC in real[0], Nyquist in imag[0])
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(nfft / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        let half = nfft / 2
        let scale = norm / 4
        power[0] = real[0] * real[0] * scale
        power[half] = imag[0] * imag[0] * scale
        for k in 1..<min(kmax, half) {
            power[k] = (real[k] * real[k] + imag[k] * imag[k]) * scale
        }
        let lo = Double(ForensicFormat.dbLo)
        let range = Double(ForensicFormat.dbHi - ForensicFormat.dbLo)
        for b in 0..<bins {
            let a = starts[b]
            let e = ends[b]
            var v: Double
            if a < e {
                var sum = 0.0
                for k in a..<e { sum += Double(power[k]) }
                v = sum / Double(e - a)
            } else {
                v = Double(power[a])
            }
            band[b] = v
            let d = 10 * log10(v + 1e-14)
            db[b] = d
            // wie numpy in doppelter Genauigkeit, damit die Rundung an denselben Stellen kippt
            let x = (d - lo) / range * 255 + 0.5
            q[b] = UInt8(max(0, min(255, x)))
        }
        try q.withUnsafeBufferPointer { col in
            for level in levels { try level.add(col) }
        }
        // Sprachband: mittlere Leistung (dB) und Spitze über dem Median (Tonhaltigkeit: Alarme, Piepser)
        var mean = 0.0
        for (i, b) in speech.enumerated() {
            mean += band[b]
            speechDB[i] = db[b]
        }
        mean /= Double(max(1, speech.count))
        var lvl: Float = 0
        var ton: Float = 0
        if !speech.isEmpty {
            speechDB.sort()
            let n = speechDB.count
            let med = n % 2 == 1 ? speechDB[n / 2] : (speechDB[n / 2 - 1] + speechDB[n / 2]) / 2
            lvl = Float(10 * log10(mean + 1e-14))
            ton = Float(speechDB[n - 1] - med)
        }
        act.append(lvl)
        act.append(ton)
        doneCols += 1
    }

    /// Rest mit Stille auffüllen, Stufen schließen, Aktivität berechnen und `<outBase>.act` schreiben.
    func finish(actURL: URL) throws -> ActivityResult {
        let missing = totalCols - doneCols
        if missing > 0 {
            let need = nfft + max(0, missing - 1) * hop
            let have = pending.count - readPos
            if have < need { pending.append(contentsOf: [Float](repeating: 0, count: need - have)) }
            try drain(final: true)
        }
        for level in levels { try level.close() }
        let result = Self.activity(act, hop: hop, sr: sr)
        try FileManager.default.createDirectory(at: actURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(result.values).write(to: actURL, options: .atomic)
        act = []
        return result
    }

    func discard() {
        for level in levels { level.discard() }
    }

    /// Grobe Sprachaktivität ohne KI, wie `_activity`: Pegel im Sprachband über dem gleitenden Rauschboden (Minimum über
    /// 8 s, geglättet über 30 s), stark tonale Stellen (Spitze > 25 dB über dem Bandmedian) zählen kaum; je 0,1 s ein
    /// Wert 0–255 und Abschnitte ab 0,4 s, Lücken unter 0,5 s überbrückt.
    static func activity(_ cols: [Float], hop: Int, sr: Int) -> ActivityResult {
        let rate = ForensicFormat.actRate
        let per = max(1, Int((Double(sr) / Double(hop) / Double(rate)).rounded(.toNearestOrEven)))
        let total = cols.count / 2
        let n = total / per
        guard n > 0 else { return ActivityResult(values: [], segments: [], speechSeconds: 0, floorDB: nil) }
        var lvl = [Double](repeating: 0, count: n)
        var ton = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            var mx: Float = -.infinity
            for j in 0..<per {
                s += cols[2 * (i * per + j)]
                mx = max(mx, cols[2 * (i * per + j) + 1])
            }
            lvl[i] = Double(s / Float(per))
            ton[i] = mx
        }
        // Rauschboden: Minimum über 8 s (Ränder fortgesetzt), dann gleitender Mittelwert über 30 s
        let w = 8 * rate
        let padL = w / 2
        let mins = (0..<n).map { i -> Double in
            var m = Double.infinity
            for j in 0..<w {
                let k = min(n - 1, max(0, i + j - padL))
                m = min(m, lvl[k])
            }
            return m
        }
        let k = 30 * rate
        let kl = k / 2
        var prefix = [Double](repeating: 0, count: n + k)
        var acc = 0.0
        for i in 0..<(n + k - 1) {
            acc += mins[min(n - 1, max(0, i - kl))]
            prefix[i + 1] = acc
        }
        var floor = [Double](repeating: 0, count: n)
        for i in 0..<n { floor[i] = (prefix[i + k] - prefix[i]) / Double(k) }
        var values = [UInt8](repeating: 0, count: n)
        var on = [Bool](repeating: false, count: n)
        for i in 0..<n {
            var score = min(1, max(0, (lvl[i] - floor[i] - 4.0) / 14.0))
            if ton[i] > 25 { score *= 0.15 }
            values[i] = UInt8(score * 255 + 0.5)
            on[i] = score > 0.35
        }
        var segs: [[Double]] = []
        var i = 0
        while i < n {
            if on[i] {
                var j = i
                while j < n && on[j] { j += 1 }
                let a = Double(i) / Double(rate)
                let b = Double(j) / Double(rate)
                if let last = segs.last, a - last[1] < 0.5 {
                    segs[segs.count - 1][1] = b
                } else {
                    segs.append([a, b])
                }
                i = j
            } else {
                i += 1
            }
        }
        let round1 = { (x: Double) in (x * 10).rounded() / 10 }
        segs = segs.filter { $0[1] - $0[0] >= 0.4 }.map { [round1($0[0]), round1($0[1])] }
        let speechSeconds = round1(segs.reduce(0) { $0 + $1[1] - $1[0] })
        let sorted = floor.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return ActivityResult(values: values, segments: Array(segs.prefix(20000)), speechSeconds: speechSeconds,
                              floorDB: round1(median))
    }
}
