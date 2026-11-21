import Foundation

/// Ton eines VDR-Exports (seit 0.5.11), wie `task_audio`, `task_granules` und `_audio_offsets` in `server/nvai/vdr.py`:
/// je Ogg-Datei (Kanalpaar, z. B. audio0 = VHF1/VHF2) EIN Dekoder über alle Blöcke (`VorbisChain`), links und rechts
/// werden zwei Mono-Spuren. Der Ton läuft fortlaufend; das Blockraster aus Track.txt ist nur Leitplanke (erst ab 2 s
/// Abweichung Stille bzw. Kürzen, an Lücken neuer Dekoder). Weil der erste Schnitt jeder Datei-Nummer zufällig liegt,
/// wird jede Datei um den Median ihrer Schnittlage gegen das Raster verschoben (`offsets`).
///
/// Je Spur wie bei Windows: Originalton 16 Bit (gerundet wie libsndfile beim Schreiben der FLAC-Arbeitsdatei: ×32768,
/// halbe Werte zur geraden Zahl, ab 32767 begrenzt), Lautheit nach BS.1770, Pegel je Sekunde, Netzbrummen, Prüfung der
/// Nähte; dazu wie bei jedem Fall vom Mac AAC zum Abspielen, Wellenform, Spektrogramm und Aktivität (`ChannelSink`).
enum VDRAudio {
    static let maxDrift = 2.0

    struct Job {
        var file: String
        /// Spur-ID und Seite (0 links, 1 rechts)
        var sides: [(tid: String, side: Int)]
        var blocks: [VDR.Block]
        var t0: Int
        var duration: Double
        var sr: Int
        /// Versatz der Schnitte dieser Datei (s, aus `offsets`)
        var offset: Double
        var fall: URL
    }

    struct SideResult {
        var tid: String
        var side: Int
        var sink: ForensicImport.ChannelResult
        /// Ergebnis wie `task_audio` ohne „levels“ (für vdr.json)
        var info: JSONObject
        var levels: [Double]
        var analysis: JSONObject
        var rmsDB: JSONObject
        var duration: Double
        var frames: Int
        var peak: Double
        var bars: Int
        var pads: [JSONObject]
    }

    // MARK: Schnittlage (Granule-Vorlauf)

    /// Probenzahl (letzte Granule-Position) jeder Tondatei eines Blocks, ohne zu dekodieren (`task_granules`).
    static func granules(_ files: [String: Data], wanted: Set<String>) -> [String: Int64?] {
        var out: [String: Int64?] = [:]
        for (name, data) in files where wanted.contains(name) { out[name] = .some(VDROgg.lastGranule(data)) }
        return out
    }

    /// Je Ogg-Datei: wo die Schnitte des durchlaufenden Tons im Mittel gegen das Blockraster liegen (`_audio_offsets`).
    static func offsets(blocks: [VDR.Block], t0: Int, granules: [Int: [String: Int64?]], files: [String]) -> JSONObject {
        let sr = Double(VDR.sampleRate)
        var out = JSONObject()
        for f in files {
            var cum = 0
            var devs: [Double] = []
            var prevID: Int?
            for b in blocks {
                let gp: Int64? = (granules[b.id]?[f]) ?? nil
                if gp == nil || (prevID != nil && b.id != prevID! + 1) {
                    // Lücke: der Ton setzt dort wieder am Raster an
                    cum = Int((Double(b.start - t0) * sr).rounded(.toNearestOrEven))
                }
                guard let gp else {
                    prevID = nil
                    continue
                }
                devs.append(Double(cum) / sr - Double(b.start - t0))
                cum += Int(gp)
                prevID = b.id
            }
            if devs.count >= 20 {
                devs.sort()
                let med = devs[devs.count / 2]
                out.set(f, JSONObject(["offset_s": Py.round(-med, 3), "median_drift_s": Py.round(med, 3), "blocks": devs.count,
                                       "p10": Py.round(devs[devs.count / 10], 3), "p90": Py.round(devs[devs.count * 9 / 10], 3)]))
            }
        }
        return out
    }

    // MARK: Eine Ogg-Datei über alle Blöcke

    /// Was je Seite (Spur) mitläuft: Originalton und Analyse (`ChannelSink`), Lautheit, Pegel je Sekunde, Nähte.
    private final class SideState {
        let tid: String
        let side: Int
        let sink: ChannelSink
        let loud: LoudnessMeter
        var sq: [Double] = []
        var cnt: [Int] = []
        var peak: Float = 0
        var tail: [Float]?
        var joins: [Double] = []
        var suspicious: [[Double]] = []
        var q: [Float] = []

        init(tid: String, side: Int, fall: URL, sr: Int) throws {
            self.tid = tid
            self.side = side
            sink = try ChannelSink(tid: tid, fall: fall, sr: sr, kind: .int16)
            loud = LoudnessMeter(sr: sr)
        }

        /// Proben schreiben (ab Lage `pos`): Original gerundet wie libsndfile, Analyse und Pegel aus dem Dekoder-Wert.
        func write(_ y: UnsafeBufferPointer<Float>, pos: Int, sr: Int) throws {
            let n = y.count
            guard n > 0 else { return }
            if q.count < n { q = [Float](repeating: 0, count: n) }
            for i in 0..<n {
                let c = min(max(y[i], -1), 1)                      // np.clip wie Writer.add
                peak = max(peak, abs(c))
                let v = c * 32768
                q[i] = v >= 32767 ? 32767 / 32768 : (v <= -32768 ? -1 : v.rounded(.toNearestOrEven) / 32768)
            }
            try q.withUnsafeBufferPointer { try sink.add(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            loud.add(y)
            // Pegel je Sekunde (Mittel der Quadrate, Grundlage für levels.json und rms_db)
            let first = pos / sr
            let lastSec = (pos + n - 1) / sr
            if lastSec >= sq.count {
                let grow = lastSec + 1 - sq.count + 64
                sq.append(contentsOf: repeatElement(0, count: grow))
                cnt.append(contentsOf: repeatElement(0, count: grow))
            }
            var i = 0
            var sec = first
            while i < n {
                let until = min(n, (sec + 1) * sr - pos)
                var acc = 0.0
                for j in i..<until { let d = Double(y[j]); acc += d * d }
                sq[sec] += acc
                cnt[sec] += until - i
                i = until
                sec += 1
            }
        }

        func zeros(_ n: Int, pos: Int, sr: Int) throws {
            var left = n
            var p = pos
            let chunk = [Float](repeating: 0, count: min(n, 1 << 16))
            while left > 0 {
                let k = min(left, chunk.count)
                try chunk.withUnsafeBufferPointer { try write(UnsafeBufferPointer(rebasing: $0[0..<k]), pos: p, sr: sr) }
                left -= k
                p += k
            }
        }
    }

    /// Eine Ogg-Datei (beide Seiten) über alle Blöcke; Fortschritt unter `key`.
    static func run(_ job: Job, progress: VDRProgress, key: String) throws -> [SideResult] {
        let sr = job.sr
        let sides = try job.sides.map { try SideState(tid: $0.tid, side: $0.side, fall: job.fall, sr: sr) }
        var ok = false
        defer { if !ok { sides.forEach { $0.sink.discard() } } }
        let chain = VorbisChain()
        defer { chain.close() }
        var pos = 0
        var prevID: Int?
        var lengths: [Int] = []
        var leads: [Int] = []
        var drifts: [Double] = []
        var restarts: [JSONObject] = []
        var pads: [JSONObject] = []
        var missing: [Int] = []
        var undecodable = 0
        let maxDrift = Int(Self.maxDrift * Double(sr))
        let r3 = { (x: Double) in Py.round(x, 3) }

        // gemeinsamer Bezug aller Kanäle: um den üblichen Versatz der Schnitte verschieben
        let shift = Int((job.offset * Double(sr)).rounded(.toNearestOrEven))
        var skip = 0
        if shift > 0 {
            for s in sides { try s.zeros(shift, pos: pos, sr: sr) }
            pos += shift
        } else if shift < 0 {
            skip = -shift
        }
        for (k, b) in job.blocks.enumerated() {
            if progress.cancelled { throw CancellationError() }
            let expected = Int((Double(b.start - job.t0) * Double(sr)).rounded(.toNearestOrEven))
            let files = (try? VDR.readBlock(b, want: { $0 == job.file })) ?? [:]
            guard let data = files[job.file], !data.isEmpty else {
                missing.append(b.id)
                chain.close()
                chain.dropPending()
                prevID = nil
                continue
            }
            let gp = VDROgg.lastGranule(data).map(Int.init)
            let fresh = !chain.isOpen || prevID == nil || b.id != prevID! + 1
            var x = chain.decode(data, fresh: fresh)
            var restarted = false
            if !fresh, let gp, (x?.count ?? -1) != gp {
                // Kodierer neu angelaufen (oder Datei beschädigt): diese Datei für sich dekodieren
                x = chain.decode(data, fresh: true)
                restarted = true
                restarts.append(JSONObject(["block": b.id, "t": Py.round(Double(expected) / Double(sr), 2)]))
            }
            guard var block = x else {
                // ohne lesbare Kopfpakete: wie ein fehlender Block (Windows bräche hier ab)
                undecodable += 1
                missing.append(b.id)
                chain.close()
                chain.dropPending()
                prevID = nil
                continue
            }
            if (fresh || restarted), let gp, gp - block.count > 0, gp - block.count <= 8192 {
                // Vorlauf, der den Vorgänger braucht: als Stille, damit die Zeit stimmt
                let lead = gp - block.count
                leads.append(lead)
                block.left.insert(contentsOf: repeatElement(0, count: lead), at: 0)
                block.right.insert(contentsOf: repeatElement(0, count: lead), at: 0)
            }
            lengths.append(block.count)
            prevID = b.id
            var from = 0
            if skip > 0 {
                let cut0 = min(skip, block.count)
                from = cut0
                skip -= cut0
            }
            var count = block.count - from
            var joinAllowed = !fresh && !restarted
            if pos < expected - maxDrift {
                let gap = expected - pos
                pads.append(JSONObject(["t": Py.round(Double(pos) / Double(sr), 2), "seconds": r3(Double(gap) / Double(sr)),
                                        "block": b.id, "kind": "pad"]))
                for s in sides {
                    try s.zeros(gap, pos: pos, sr: sr)
                    s.tail = nil
                }
                pos += gap
            } else if pos > expected + maxDrift {
                let cut = min(count, pos - expected)
                pads.append(JSONObject(["t": Py.round(Double(pos) / Double(sr), 2), "seconds": r3(-Double(cut) / Double(sr)),
                                        "block": b.id, "kind": "overlap"]))
                from += cut
                count -= cut
            }
            drifts.append(Double(pos - expected) / Double(sr))
            if count == 0 { joinAllowed = false }
            // beide Seiten nebeneinander (AAC und Spektrogramm kosten je Spur am meisten; die Seiten teilen nichts)
            let at = pos, range = from..<(from + count), checkJoin = joinAllowed, decoded = block
            let failure = SideFailure()
            DispatchQueue.concurrentPerform(iterations: sides.count) { i in
                let s = sides[i]
                do {
                    try (s.side == 0 ? decoded.left : decoded.right).withUnsafeBufferPointer { all in
                        let y = UnsafeBufferPointer(rebasing: all[range])
                        if checkJoin, let tail = s.tail, let m = joinMetric(tail: tail, head: y) {
                            s.joins.append(m)
                            if m > 3.0 && s.suspicious.count < 50 {
                                s.suspicious.append([r3(Double(at) / Double(sr)), Py.round(m, 1)])
                            }
                        }
                        try s.write(y, pos: at, sr: sr)
                        s.tail = y.count >= 256 ? Array(y[(y.count - 256)...]) : nil
                    }
                } catch {
                    failure.set(error)
                }
            }
            if let error = failure.error { throw error }
            pos += count
            if k % 10 == 0 { progress.set(key, Double(k + 1) / Double(job.blocks.count) * 0.97) }
        }
        // bis zum Ende der Aufnahme auffüllen (alle Spuren decken die ganze Aufnahme ab)
        let total = Int((job.duration * Double(sr)).rounded(.toNearestOrEven))
        if pos < total {
            for s in sides { try s.zeros(total - pos, pos: pos, sr: sr) }
            pos = total
        }
        progress.set(key, 0.98)

        var results: [SideResult] = []
        for s in sides {
            let sinkResult = try s.sink.finish(channel: s.side)
            let wav = job.fall.appendingPathComponent("original/\(s.tid).wav")
            var analysis = s.loud.result()
            analysis.set("hum", humAnalysis(wav: wav, sr: sr, frames: pos, duration: Double(pos) / Double(sr)))
            let nsec = max(1, Int((Double(pos) / Double(sr)).rounded(.up)))
            var db = [Double](repeating: -120, count: nsec)
            for i in 0..<nsec {
                let c = i < s.cnt.count ? max(s.cnt[i], 1) : 1
                let rms = i < s.sq.count ? (s.sq[i] / Double(c)).squareRoot() : 0
                db[i] = 20 * log10(max(rms, 1e-6))
            }
            let sortedDB = db.sorted()
            let floor = Py.percentile(sortedDB, 10)
            let active = db.filter { $0 > floor + 10 }.count
            let rmsDB = JSONObject([
                "p10": Py.round(floor, 1), "p50": Py.round(Py.percentile(sortedDB, 50), 1),
                "p90": Py.round(Py.percentile(sortedDB, 90), 1), "max": Py.round(sortedDB.last ?? -120, 1),
                "active_s": active, "active_share": Py.round(Double(active) / Double(nsec), 4),
            ])
            let joins = s.joins.sorted()
            var joinInfo = JSONObject(["checked": joins.count])
            joinInfo.set("median", joins.isEmpty ? nil : Py.round(Py.median(joins), 2))
            joinInfo.set("p99", joins.isEmpty ? nil : Py.round(Py.percentile(joins, 99), 2))
            joinInfo.set("max", joins.isEmpty ? nil : Py.round(joins.last!, 2))
            joinInfo.set("suspicious", joins.filter { $0 > 3.0 }.count)
            joinInfo.set("examples", Array(s.suspicious.prefix(20)))
            let peak = Py.round(Double(s.peak), 4)
            let duration = r3(Double(pos) / Double(sr))
            var info = JSONObject([
                "id": s.tid, "file": job.file, "side": s.side, "frames": sinkResult.frames, "bars": sinkResult.bars, "peak": peak,
                "duration": duration, "sample_rate": sr, "analysis": analysis, "offset_s": r3(Double(shift) / Double(sr)),
                "rms_db": rmsDB, "blocks": lengths.count,
            ])
            info.set("missing_blocks", Array(missing.prefix(200)))
            info.set("missing_count", missing.count)
            var fileSeconds = JSONObject()
            fileSeconds.set("min", lengths.min().map { r3(Double($0) / Double(sr)) })
            fileSeconds.set("max", lengths.max().map { r3(Double($0) / Double(sr)) })
            fileSeconds.set("mean", lengths.isEmpty ? nil : Py.round(Double(lengths.reduce(0, +)) / Double(lengths.count) / Double(sr), 4))
            fileSeconds.set("not_15s", lengths.filter { $0 != VDR.blockSeconds * sr }.count)
            info.set("file_seconds", fileSeconds)
            info.set("lead_in", JSONObject(["count": leads.count, "samples": Array(Set(leads).sorted().prefix(10))]))
            var drift = JSONObject()
            drift.set("min", drifts.min().map(r3))
            drift.set("max", drifts.max().map(r3))
            drift.set("end", drifts.last.map(r3))
            info.set("drift_s", drift)
            info.set("restarts", Array(restarts.prefix(50)))
            info.set("restart_count", restarts.count)
            info.set("pads", Array(pads.prefix(200)))
            info.set("pad_count", pads.count)
            info.set("joins", joinInfo)
            if undecodable > 0 || !chain.anomalies.isEmpty {
                // nur am Mac: Dateien ohne lesbare Kopfpakete und Auffälligkeiten des Ogg-Stroms
                var dec = JSONObject(["undecodable": undecodable])
                for (k2, v) in chain.anomalies.sorted(by: { $0.key < $1.key }) { dec.set(k2, v) }
                info.set("decoder", dec)
            }
            results.append(SideResult(tid: s.tid, side: s.side, sink: sinkResult, info: info, levels: db.map { Py.round($0, 1) },
                                      analysis: analysis, rmsDB: rmsDB, duration: duration, frames: sinkResult.frames, peak: peak,
                                      bars: sinkResult.bars, pads: pads))
        }
        progress.set(key, 1)
        ok = true
        return results
    }

    /// erster Fehler der nebeneinander laufenden Seiten
    private final class SideFailure: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var error: Error?
        func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    }

    /// Sprung an einer Naht: Vorhersagefehler 2. Ordnung an der Naht gegen das 99. Perzentil der Umgebung (`_join_metric`).
    static func joinMetric(tail: [Float], head: UnsafeBufferPointer<Float>) -> Double? {
        guard tail.count >= 128, head.count >= 128 else { return nil }
        var seg = [Double](repeating: 0, count: 256)
        for i in 0..<128 {
            seg[i] = Double(tail[tail.count - 128 + i])
            seg[128 + i] = Double(head[i])
        }
        var e = [Double](repeating: 0, count: 254)
        for j in 0..<254 { e[j] = abs(seg[j + 2] - 2 * seg[j + 1] + seg[j]) }
        let k = 126   // e[k] sagt seg[128] = erste Probe nach der Naht voraus
        let around = (Array(e[0..<(k - 4)]) + Array(e[(k + 4)...])).sorted()
        let ref = Py.percentile(around, 99)
        if ref < 1e-5 { return nil }
        return max(e[k - 1], e[k], e[k + 1]) / ref
    }

    // MARK: Netzbrummen

    /// Netzbrummen wie `audio_tools.detect_hum`: Welch-Spektrum (Hann, 2 s, halbe Überlappung) über bis zu 10 Stellen à
    /// 6 s aus der 16-Bit-Datei; Pegel bei 50/60 Hz und Oberwellen gegen die Nachbarn. Gerechnet werden nur die Bänder,
    /// die die Auswertung braucht. nil: keine Stelle lang genug (wie {"hum": None}).
    static func humAnalysis(wav: URL, sr: Int, frames: Int, duration: Double) -> Any? {
        guard let handle = try? FileHandle(forReadingFrom: wav) else { return nil }
        defer { try? handle.close() }
        let num = min(10, max(1, Int(Py.floorDiv(duration, 6))))
        let stop = max(0.0, duration - 6)
        var picks: [Double] = []
        if num == 1 {
            picks = [0]
        } else {
            let step = stop / Double(num - 1)
            picks = (0..<num).map { Double($0) * step }
            picks[num - 1] = stop
        }
        let bases = [50, 60]
        var spec: [Int: Double] = [:]   // Band → Summe der Leistungsdichte
        var haveSpec = false
        var binsWanted: [Int] = []
        var nfftUsed = 0
        for t0 in picks {
            let first = Int((t0 * Double(sr)).rounded(.toNearestOrEven))
            let last = Int(((t0 + 6.0) * Double(sr)).rounded(.toNearestOrEven))
            let end = min(frames, last, first + 6 * sr)
            guard end - first >= sr else { continue }
            guard let x = readInt16(handle, from: first, count: end - first) else { continue }
            let nperseg = min(2 * sr, x.count)
            if nfftUsed != nperseg {
                // Bänder bei Abstand fs/nperseg (scipy: nperseg wird auf die Länge gekürzt)
                nfftUsed = nperseg
                binsWanted = []
                let df = Double(sr) / Double(nperseg)
                for base in bases {
                    for h in 1...5 {
                        let i = Int((Double(base * h) / df).rounded(.toNearestOrEven))
                        if i + 6 >= nperseg / 2 + 1 { break }
                        binsWanted += Array((i - 6)...(i + 6))
                    }
                }
                binsWanted = Array(Set(binsWanted)).sorted()
                if haveSpec { spec = [:]; haveSpec = false }
            }
            for (k, p) in welch(x, nperseg: nperseg, fs: Double(sr), bins: binsWanted) { spec[k, default: 0] += p }
            haveSpec = true
        }
        guard haveSpec, nfftUsed > 0 else { return nil }
        let df = Double(sr) / Double(nfftUsed)
        var res: [Int: [Double]] = [:]
        for base in bases {
            var excess: [Double] = []
            for h in 1...5 {
                let i = Int((Double(base * h) / df).rounded(.toNearestOrEven))
                if i + 6 >= nfftUsed / 2 + 1 { break }
                let around = Py.median(((i - 6)..<(i - 2)).map { spec[$0] ?? 0 } + ((i + 3)..<(i + 7)).map { spec[$0] ?? 0 })
                let top = ((i - 1)...(i + 1)).map { spec[$0] ?? 0 }.max()!
                excess.append(10 * log10(max(top, 1e-20) / max(around, 1e-20)))
            }
            res[base] = excess
        }
        let score = { (b: Int) in res[b]!.sorted(by: >).prefix(3).reduce(0, +) }
        let best = score(60) > score(50) ? 60 : 50
        let strength = score(best) / 3
        return JSONObject(["freq": best, "db_over_floor": Py.round(strength, 1),
                           "harmonics_db": res[best]!.map { Py.round($0, 1) }, "present": strength > 8])
    }

    /// Proben aus der eigenen 16-Bit-WAV (Kopf 80 Byte, `WavWriter`), als Gleitkomma wie soundfile (÷32768).
    private static func readInt16(_ h: FileHandle, from: Int, count: Int) -> [Double]? {
        do {
            try h.seek(toOffset: UInt64(WavWriter.headerSize + from * 2))
            guard let d = try h.read(upToCount: count * 2), d.count == count * 2 else { return nil }
            return d.withUnsafeBytes { raw in
                (0..<count).map { Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
        } catch {
            return nil
        }
    }

    /// Welch-Leistungsdichte wie scipy.signal.welch (Hann periodisch, halbe Überlappung, Mittelwert abziehen, einseitig,
    /// „density“) nur für die gewünschten Bänder.
    private static func welch(_ x: [Double], nperseg n: Int, fs: Double, bins: [Int]) -> [Int: Double] {
        let step = n - n / 2
        let segments = (x.count - n) / step + 1
        guard segments > 0, n > 1 else { return [:] }
        var win = [Double](repeating: 0, count: n)
        var wsum = 0.0
        for i in 0..<n {
            win[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            wsum += win[i] * win[i]
        }
        let scale = 1.0 / (fs * wsum)
        var cosT = [Double](repeating: 0, count: n)
        var sinT = [Double](repeating: 0, count: n)
        for i in 0..<n {
            cosT[i] = cos(2 * Double.pi * Double(i) / Double(n))
            sinT[i] = sin(2 * Double.pi * Double(i) / Double(n))
        }
        var out: [Int: Double] = [:]
        var v = [Double](repeating: 0, count: n)
        for s in 0..<segments {
            let a = s * step
            var mean = 0.0
            for i in 0..<n { mean += x[a + i] }
            mean /= Double(n)
            for i in 0..<n { v[i] = win[i] * (x[a + i] - mean) }
            for k in bins where k >= 0 && k <= n / 2 {
                var re = 0.0
                var im = 0.0
                var idx = 0
                for i in 0..<n {
                    re += v[i] * cosT[idx]
                    im -= v[i] * sinT[idx]
                    idx += k
                    if idx >= n { idx -= n }
                }
                var p = (re * re + im * im) * scale
                if k > 0 && !(n % 2 == 0 && k == n / 2) { p *= 2 }
                out[k, default: 0] += p / Double(segments)
            }
        }
        return out
    }
}

/// Integrierte Lautheit nach ITU-R BS.1770-4 wie `audio_tools.Loudness` (K-Filter, 400-ms-Fenster, absolutes und
/// relatives Tor), dazu Rauschboden (10. Perzentil der 100-ms-Pegel), Spitze und übersteuerte Proben. Mono.
final class LoudnessMeter {
    private let sos: [[Double]]
    private var z: [[Double]] = [[0, 0], [0, 0]]
    private let slice: Int
    private var accW = 0.0
    private var accR = 0.0
    private var accN = 0
    private var ms: [Double] = []
    private var rms: [Double] = []
    private var peak: Float = 0
    private var clipped = 0

    init(sr: Int) {
        let fs = Double(sr)
        var f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0 = 38.13547087602444
        q = 0.5003270373238773
        g = 0
        k = tan(Double.pi * f0 / fs)
        let hp = [1.0, -2.0, 1.0, 1.0, 2 * (k * k - 1) / (1 + k / q + k * k), (1 - k / q + k * k) / (1 + k / q + k * k)]
        sos = [shelf, hp]
        slice = Int(Double(sr) * 0.1)
        _ = g
    }

    func add(_ x: UnsafeBufferPointer<Float>) {
        let thr = Float(0.999)
        let s0 = sos[0], s1 = sos[1]
        var z00 = z[0][0], z01 = z[0][1], z10 = z[1][0], z11 = z[1][1]
        for v in x {
            let a = abs(v)
            if a > peak { peak = a }
            if a >= thr { clipped += 1 }
            // scipy.signal.sosfilt: Direktform II transponiert, doppelte Genauigkeit
            let xin = Double(v)
            let y0 = s0[0] * xin + z00
            z00 = s0[1] * xin - s0[4] * y0 + z01
            z01 = s0[2] * xin - s0[5] * y0
            let y1 = s1[0] * y0 + z10
            z10 = s1[1] * y0 - s1[4] * y1 + z11
            z11 = s1[2] * y0 - s1[5] * y1
            accW += y1 * y1
            accR += xin * xin
            accN += 1
            if accN == slice {
                ms.append(accW / Double(slice))
                rms.append((accR / Double(slice)).squareRoot())
                accW = 0
                accR = 0
                accN = 0
            }
        }
        z = [[z00, z01], [z10, z11]]
    }

    func result() -> JSONObject {
        var out = JSONObject()
        guard ms.count >= 4 else {
            out.set("lufs", nil)
            out.set("noise_floor_db", nil)
            out.set("peak_db", nil)
            out.set("clipped", clipped)
            return out
        }
        var win = [Double](repeating: 0, count: ms.count - 3)
        for i in 0..<win.count { win[i] = ms[i] * 0.25 + ms[i + 1] * 0.25 + ms[i + 2] * 0.25 + ms[i + 3] * 0.25 }
        let lk = { (w: Double) in -0.691 + 10 * log10(max(w, 1e-12)) }
        let gated = win.filter { lk($0) > -70 }
        var lufs: Double?
        if !gated.isEmpty {
            let rel = -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count)) - 10
            let g2 = gated.filter { lk($0) > rel }
            if !g2.isEmpty { lufs = Py.round(-0.691 + 10 * log10(g2.reduce(0, +) / Double(g2.count)), 1) }
        }
        let loud = rms.filter { $0 > 1e-7 }.sorted()
        let floor = loud.isEmpty ? 0.0 : Py.percentile(loud, 10)
        out.set("lufs", lufs)
        out.set("noise_floor_db", Py.round(20 * log10(max(floor, 1e-7)), 1))
        out.set("peak_db", Py.round(20 * log10(max(Double(peak), 1e-7)), 1))
        out.set("clipped", clipped)
        return out
    }
}
