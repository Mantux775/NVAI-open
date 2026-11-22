import Accelerate
import AVFoundation
import Foundation

/// „Neuer Fall“ aus Audio- und Videodateien: was macOS lesen kann (WAV, AIFF, CAF, FLAC, ALAC, MP3, AAC/M4A, MP4/MOV
/// mit Tonspur). Jeder Kanal wird eine eigene Spur (gleiche Kanäle, etwa Doppel-Mono, nur einmal), das erste Video
/// kommt als Bild zum Ton mit. Je Spur: Originalton bitgenau als WAV, AAC zum Abspielen, Wellenform, Spektrogramm,
/// Sprachaktivität (`ForensicAnalysis`). Zuerst entsteht ein versteckter Ordner; erst wenn alles da ist, bekommt er
/// seinen Namen (ein Abbruch hinterlässt nichts Halbes in der Liste).
enum ForensicImport {
    typealias Progress = (Double, String) -> Void

    struct Request: Sendable {
        var files: [URL]
        var name: String
        /// `files` ist ein Ordner mit VDR-Daten (`VDRImport`, seit 0.5.11)
        var vdr = false
    }

    /// Prüf-App, die in den Fallordner kommt (im Prüfprogramm ohne App-Bundle von außen gesetzt).
    nonisolated(unsafe) static var reviewAppURL: URL? = Bundle.main.url(forResource: "NVAI-Pruefer", withExtension: "html")

    struct SourceAudio {
        var track: AVAssetTrack
        var sr: Int
        var channels: Int
        var codec: String
        var wavKind: WavWriter.Kind
    }

    static func create(_ req: Request, progress: @escaping Progress, isCancelled: @escaping () -> Bool) async throws -> URL {
        guard !req.files.isEmpty else {
            throw ForensicError(t("Keine Datei gewählt.", "No file chosen."))
        }
        let fm = FileManager.default
        let root = ForensicCases.directory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // gesperrter Arbeitsordner: Bleibt er nach einem Absturz liegen, räumt ihn der nächste Start weg
        let lock = try ForensicCases.Work(in: root)
        defer { lock.finish() }
        let work = lock.url
        let fall = work.appendingPathComponent("fall", isDirectory: true)
        do {
            try fm.createDirectory(at: fall, withIntermediateDirectories: true)
            try fm.createDirectory(at: work.appendingPathComponent("bearbeitung", isDirectory: true), withIntermediateDirectories: true)
            let url = try await build(req, work: work, progress: progress, isCancelled: isCancelled)
            return url
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func build(_ req: Request, work: URL, progress: @escaping Progress,
                              isCancelled: @escaping () -> Bool) async throws -> URL {
        let fm = FileManager.default
        let fall = work.appendingPathComponent("fall", isDirectory: true)
        let started = Date()
        let created = Date().timeIntervalSince1970
        let createdISO = ForensicCases.isoNow()
        let name = String(req.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let caseName = name.isEmpty ? req.files[0].deletingPathExtension().lastPathComponent : name

        // 1. Quellen prüfen: Tonspuren, Formate, Video, Länge (für den Fortschritt)
        progress(0.005, t("liest die Dateien", "reading the files"))
        var assets: [(url: URL, asset: AVURLAsset, audio: [SourceAudio], video: AVAssetTrack?, duration: Double)] = []
        for url in req.files {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw ForensicError(t("„\(url.lastPathComponent)“ lässt sich nicht lesen (macOS kennt das Format nicht): \(error.localizedDescription)",
                                      "“\(url.lastPathComponent)” cannot be read (macOS does not know the format): \(error.localizedDescription)"))
            }
            guard !audioTracks.isEmpty else {
                throw ForensicError(t("„\(url.lastPathComponent)“ hat keine Tonspur.", "“\(url.lastPathComponent)” has no audio track."))
            }
            var audio: [SourceAudio] = []
            for track in audioTracks {
                guard let desc = try await track.load(.formatDescriptions).first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { continue }
                let (codec, kind) = describe(asbd)
                // eine beschädigte Angabe (unendlich, riesig) nicht mit Int() umrechnen: 0 gilt unten als unbekannt
                let rate = asbd.mSampleRate.isFinite && asbd.mSampleRate > 0 && asbd.mSampleRate < 1e7 ? Int(asbd.mSampleRate.rounded()) : 0
                audio.append(SourceAudio(track: track, sr: rate, channels: Int(asbd.mChannelsPerFrame),
                                         codec: codec, wavKind: kind))
            }
            guard !audio.isEmpty, audio.allSatisfy({ $0.sr > 0 && $0.channels > 0 }) else {
                throw ForensicError(t("„\(url.lastPathComponent)“: Tonformat unbekannt.", "“\(url.lastPathComponent)”: unknown audio format."))
            }
            // gleich hier statt erst nach der Prüfsumme der Quelle (dieselbe Grenze prüft `ChannelSink`)
            if let bad = audio.first(where: { !ChannelSink.rates.contains($0.sr) }) {
                throw ForensicError(t("„\(url.lastPathComponent)“: Abtastrate \(bad.sr) Hz wird nicht unterstützt (1000 bis 768 000 Hz).",
                                      "“\(url.lastPathComponent)”: sample rate \(bad.sr) Hz is not supported (1000 to 768,000 Hz)."))
            }
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            assets.append((url, asset, audio, video, duration.isFinite ? duration : 0))
        }
        let multiFile = assets.count > 1

        // 2. Prüfsummen der Quellen (Beweiskette): stehen in projekt.json
        let totalBytes = assets.reduce(Int64(0)) { $0 + Int64((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var hashedBytes: Int64 = 0
        var sources: [[String: Any]] = []
        var sourceHash: [URL: String] = [:]
        for item in assets {
            let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let before = hashedBytes
            let sha = try ForensicHash.sha256(item.url, isCancelled: isCancelled) { done in
                progress(0.01 + 0.07 * Double(before + done) / Double(max(1, totalBytes)), t("Prüfsumme der Quelle", "checksum of the source"))
            }
            hashedBytes += Int64(values?.fileSize ?? 0)
            sourceHash[item.url] = sha
            var info: [String: Any] = [
                "name": item.url.lastPathComponent, "sha256": sha, "size": values?.fileSize ?? 0,
                "sha256_time": Date().timeIntervalSince1970,
                "mtime": values?.contentModificationDate?.timeIntervalSince1970 ?? NSNull(),
                "container": item.url.pathExtension.lowercased(), "codec": item.audio[0].codec,
                "source_rate": item.audio[0].sr, "source_channels": item.audio[0].channels,
                "has_video": item.video != nil, "duration": item.duration,
            ]
            if item.audio.count > 1 { info["audio_tracks"] = item.audio.count }
            sources.append(info)
        }

        // 3. Ton lesen: je Kanal eine Spur
        let totalSamples = assets.reduce(0.0) { acc, item in acc + item.audio.reduce(0.0) { $0 + item.duration * Double($1.sr) } }
        var doneSamples = 0.0
        var tracks: [[String: Any]] = []
        var originals: [String: Any] = [:]
        var proxies: [String: String] = [:]
        var activities: [String: [String: Any]] = [:]
        var duration = 0.0
        for (fi, item) in assets.enumerated() {
            for (ai, src) in item.audio.enumerated() {
                let label = { (ch: Int?) -> String in
                    var parts: [String] = []
                    if multiFile { parts.append(item.url.deletingPathExtension().lastPathComponent) }
                    if item.audio.count > 1 { parts.append(t("Tonspur \(ai + 1)", "Audio track \(ai + 1)")) }
                    if let ch { parts.append(t("Kanal \(ch)", "Channel \(ch)")) }
                    return parts.isEmpty ? t("Original", "Original") : parts.joined(separator: " · ")
                }
                let base = doneSamples
                let result = try decode(item.asset, src, fall: fall, firstIndex: tracks.count,
                                        onlyTrack: item.audio.count == 1 && item.video == nil,
                                        isCancelled: isCancelled) { pos in
                    let f = (base + Double(pos)) / max(1, totalSamples)
                    progress(0.08 + 0.84 * min(1, f), t("liest den Ton", "reading the audio")
                             + (assets.count > 1 ? " (\(fi + 1)/\(assets.count))" : ""))
                }
                doneSamples += item.duration * Double(src.sr)
                let keep = result.channels
                for ch in keep {
                    let tid = ch.tid
                    let number = keep.count > 1 ? ch.channel + 1 : nil
                    var name = label(number)
                    if ch.alsoChannels > 0 && keep.count == 1 && src.channels > 1 {
                        name += t(" (alle \(src.channels) Kanäle gleich)", " (all \(src.channels) channels identical)")
                    }
                    let seconds = Double(ch.frames) / Double(src.sr)
                    duration = max(duration, seconds)
                    tracks.append([
                        "id": tid, "name": name, "kind": "original", "frames": ch.frames, "bars": ch.bars,
                        "peak": (Double(ch.peak) * 10000).rounded() / 10000, "offset": 0.0, "gain_db": 0.0, "mute": false,
                        "solo": false, "color": ForensicCases.colors[tracks.count % ForensicCases.colors.count], "op": NSNull(),
                        "created": created, "sr": src.sr, "spec": ch.spec,
                        "activity": ["method": "energy", "rate": ForensicFormat.actRate, "segments": ch.activity.segments.count,
                                     "speech_seconds": ch.activity.speechSeconds],
                        "source": ["file": item.url.lastPathComponent, "audio_track": ai + 1, "channel": ch.channel + 1],
                    ])
                    originals[tid] = ["file": "\(tid).wav", "sample_rate": src.sr, "channels": 1, "frames": ch.frames,
                                      "subtype": src.wavKind.subtype, "format": "wav"]
                    proxies[tid] = "\(tid).m4a"
                    activities[tid] = ["track": tid, "rate": ForensicFormat.actRate, "method": "energy",
                                       "segments": ch.activity.segments, "speech_seconds": ch.activity.speechSeconds,
                                       "floor_db": ch.activity.floorDB ?? NSNull()]
                }
            }
        }
        let data = fall.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        for (tid, act) in activities {
            try ForensicJSON.data(act, indent: nil).write(to: data.appendingPathComponent("act_\(tid).json"), options: .atomic)
        }

        // 4. Video: das erste, das WebKit abspielen kann (auf demselben APFS-Datenträger nur ein Verweis, sonst eine Kopie
        // mit Platzprüfung und Abbruch, `copyVideo`)
        var videoName: String?
        var videoInfo: [String: Any]?
        var known: [String: String] = [:]
        if let item = assets.first(where: { $0.video != nil }), let vtrack = item.video {
            progress(0.93, t("übernimmt das Video", "taking over the video"))
            let playable = (try? await item.asset.load(.isPlayable)) ?? false
            let size = (try? await vtrack.load(.naturalSize)) ?? .zero
            let fps = (try? await vtrack.load(.nominalFrameRate)) ?? 0
            let codec = (try? await vtrack.load(.formatDescriptions).first).map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            let info: [String: Any] = ["width": Int(size.width), "height": Int(size.height),
                                       "fps": fps > 0 ? (Double(fps) * 1000).rounded() / 1000 : NSNull(), "codec": codec]
            if let i = sources.firstIndex(where: { $0["name"] as? String == item.url.lastPathComponent }) {
                sources[i]["video"] = info
            }
            if playable {
                let vname = ForensicCases.safeName(item.url.deletingPathExtension().lastPathComponent) + "." + item.url.pathExtension.lowercased()
                let dir = fall.appendingPathComponent("video", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent(vname)
                try copyVideo(item.url, to: target, isCancelled: isCancelled)
                let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                videoName = vname
                if let sha = sourceHash[item.url] { known["fall/video/\(vname)"] = sha }
                videoInfo = ["path": "video/\(vname)", "name": vname, "size": bytes, "fit": ["a": 1.0, "b": 0.0],
                             "drift_ppm": 0.0, "residual_ms": ["median": 0.0, "max": 0.0], "points": 0,
                             "duration": item.duration, "time": Date().timeIntervalSince1970]
            }
        }
        if isCancelled() { throw CancellationError() }

        // 5. Fall, Manifest, Prüf-App, Anleitung, Prüfsummen
        progress(0.95, t("schreibt den Fall", "writing the case"))
        let pid = ForensicCases.newProjectID()
        let first = sources[0]
        var source = first
        source["kind"] = "file"
        if multiFile { source["files"] = sources }
        let project: [String: Any] = [
            "id": pid, "name": caseName, "created": created, "updated": Date().timeIntervalSince1970, "status": "ready",
            "error": NSNull(), "source": source, "sample_rate": first["source_rate"] ?? 0,
            "channels": first["source_channels"] ?? 0, "duration": (duration * 1000).rounded() / 1000,
            "tracks": tracks, "markers": [Any](), "profiles": [Any](), "time_origin": NSNull(),
            "video": videoInfo ?? NSNull(),
            "history": [["time": Date().timeIntervalSince1970, "op": "prepare", "program": ForensicCases.program,
                         "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]],
            "package": ["format": ForensicCases.format, "version": ForensicCases.formatVersion, "created": createdISO],
        ]
        try ForensicJSON.data(project).write(to: fall.appendingPathComponent("projekt.json"), options: .atomic)
        if let app = reviewAppURL {
            try fm.copyItem(at: app, to: work.appendingPathComponent(ForensicCases.reviewApp))
        }
        try Data(ForensicCases.readme(name: caseName, created: createdISO).utf8)
            .write(to: work.appendingPathComponent("LIESMICH.txt"), options: .atomic)
        var manifest: [String: Any] = [
            "format": ForensicCases.format, "version": ForensicCases.formatVersion, "created": createdISO,
            "program": ForensicCases.program, "project_id": pid, "name": caseName, "time_origin": NSNull(),
            "duration": (duration * 1000).rounded() / 1000, "proxies": proxies, "video": videoName ?? NSNull(),
            "images": false, "originals": originals, "segments": 0, "files": 0,
        ]
        try ForensicJSON.data(manifest).write(to: fall.appendingPathComponent("manifest.json"), options: .atomic)
        // Anzahl der gelieferten Dateien steht im Manifest selbst: einmal zählen, dann mit der Zahl neu schreiben
        let count = try ForensicCases.writeChecksums(work, known: known, isCancelled: isCancelled)
        manifest["files"] = count
        try ForensicJSON.data(manifest).write(to: fall.appendingPathComponent("manifest.json"), options: .atomic)
        known.merge(try checksumsOf(work)) { a, _ in a }
        known["fall/manifest.json"] = nil
        _ = try ForensicCases.writeChecksums(work, known: known, isCancelled: isCancelled)

        // 6. Namen geben
        let target = ForensicCases.uniqueFolder(in: ForensicCases.directory, name: ForensicCases.safeName(caseName))
        try fm.moveItem(at: work, to: target)
        progress(1, t("fertig", "done"))
        return target
    }

    /// Video in den Fall. Auf demselben Datenträger mit Klonen (APFS) legt `copyItem` nur einen Verweis an, das kostet
    /// keinen Platz. Sonst (externe Platte, Netz) eine Kopie in Blöcken zu 8 MB: vorher Platz für die ganze Datei samt
    /// Rückhalt für macOS, dabei Abbruch und Speicherwächter (`isCancelled`). Vorher kopierte `copyItem` auch dann ohne
    /// beides, ein großes Video füllte den Datenträger.
    static func copyVideo(_ source: URL, to target: URL, isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeSupportsFileCloningKey]
        let from = try? source.resourceValues(forKeys: keys)
        let to = try? target.deletingLastPathComponent().resourceValues(forKeys: keys)
        if let a = from?.volumeIdentifier, let b = to?.volumeIdentifier, a.isEqual(b), to?.volumeSupportsFileCloning == true {
            try fm.copyItem(at: source, to: target)
            return
        }
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if let free = ForensicDiskGuard.available(target), free - ForensicDiskGuard.reserve < size {
            throw ForensicError(t("Für das Video (\(ForensicDiskGuard.gb(size)) GB) ist zu wenig Platz: frei sind \(ForensicDiskGuard.gb(free)) GB, \(ForensicDiskGuard.gb(ForensicDiskGuard.reserve)) GB bleiben für macOS. Bitte Platz schaffen und den Fall neu anlegen.",
                                  "Not enough space for the video (\(ForensicDiskGuard.gb(size)) GB): \(ForensicDiskGuard.gb(free)) GB are free, \(ForensicDiskGuard.gb(ForensicDiskGuard.reserve)) GB stay free for macOS. Please free up space and create the case again."))
        }
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw ForensicError(t("Video nicht schreibbar: \(target.lastPathComponent)", "Cannot write the video: \(target.lastPathComponent)"))
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            while true {
                if isCancelled() { throw CancellationError() }
                let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// Schon berechnete Summen aus PRUEFSUMMEN.sha256 (relativer Pfad → SHA-256).
    static func checksumsOf(_ folder: URL) throws -> [String: String] {
        let text = try String(contentsOf: folder.appendingPathComponent("PRUEFSUMMEN.sha256"), encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].hasPrefix("*") else { continue }
            out[String(parts[1].dropFirst())] = String(parts[0])
        }
        return out
    }

    // MARK: Ton lesen

    struct ChannelResult {
        var tid: String
        var channel: Int
        var frames: Int
        var bars: Int
        var peak: Float
        var spec: [String: Any]
        var activity: ActivityResult
        /// so viele weitere Kanäle waren mit diesem bitgleich und wurden weggelassen
        var alsoChannels: Int
    }

    struct DecodeResult {
        var channels: [ChannelResult]
    }

    /// Eine Tonspur lesen und je Kanal alles schreiben. Die Zeit folgt den Zeitstempeln der Datei: Beginnt der Ton
    /// später als das Bild oder hat er Lücken, kommt Stille hinein (das Bild bleibt synchron).
    /// 32-Bit-Ganzzahl-Datei für den bitgenauen Leseweg, wenn AVAudioFile sie mit passenden Kanälen und Rate öffnet.
    private static func int32File(_ url: URL, channels: Int, sr: Int) -> AVAudioFile? {
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt32, interleaved: true),
              Int(f.processingFormat.channelCount) == channels, Int(f.fileFormat.sampleRate.rounded()) == sr,
              f.length > 0 else { return nil }
        return f
    }

    private static func decode(_ asset: AVURLAsset, _ src: SourceAudio, fall: URL, firstIndex: Int, onlyTrack: Bool,
                               isCancelled: () -> Bool, progress: (Int) -> Void) throws -> DecodeResult {
        let reader = try AVAssetReader(asset: asset)
        // 32-Bit-Ganzzahl als Ganzzahl lesen: Als Float (24 Bit Mantisse) fehlten im Originalton die untersten 8 Bit.
        // Spektrogramm, Vorschau und Wellenform bekommen dieselben Proben als Float. Der AVAssetReader rechnet auch bei
        // angeforderter Ganzzahl über Float (gemessen 22.11.2026: bis ±27 daneben), AVAudioFile liest sie unverändert;
        // das geht nur bei reinen Tondateien mit einer Spur (WAV, AIFF, CAF, FLAC, ALAC), Ton in Videos bleibt beim
        // AVAssetReader.
        let intPath = src.wavKind == .int32
        let intFile = intPath && onlyTrack ? int32File(asset.url, channels: src.channels, sr: src.sr) : nil
        let intBuf = intFile.flatMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: 1 << 16) }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: !intPath,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: src.sr, AVNumberOfChannelsKey: src.channels,
        ]
        if src.channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(src.channels)
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let output = AVAssetReaderTrackOutput(track: src.track, outputSettings: settings)
        guard reader.canAdd(output) else { throw ForensicError(t("Tonspur nicht lesbar.", "Audio track not readable.")) }
        reader.add(output)
        let sinks = try (0..<src.channels).map { ch -> ChannelSink in
            let tid = firstIndex + ch == 0 ? "t_orig" : "t_k\(firstIndex + ch + 1)"
            return try ChannelSink(tid: tid, fall: fall, sr: src.sr, kind: src.wavKind)
        }
        var ok = false
        defer { if !ok { sinks.forEach { $0.discard() } } }
        guard intBuf != nil || reader.startReading() else {
            throw ForensicError(t("Ton nicht lesbar: \(reader.error?.localizedDescription ?? "?")",
                                  "Audio not readable: \(reader.error?.localizedDescription ?? "?")"))
        }
        let chans = src.channels
        var identical = [Bool](repeating: true, count: chans)
        var interleaved: [Float] = []
        var interleavedInt: [Int32] = []
        var planes = [[Float]](repeating: [], count: chans)
        var planesInt = [[Int32]](repeating: [], count: intPath ? chans : 0)
        var position = 0
        var lastReport = Date.distantPast
        while true {
            if isCancelled() { reader.cancelReading(); throw CancellationError() }
            let n: Int
            var seconds = Double.nan
            if let f = intFile, let fb = intBuf {
                // reine Tondatei mit 32-Bit-Ganzzahl: ohne Zeitstempel, lückenlos
                if f.framePosition >= f.length { break }
                try f.read(into: fb, frameCount: fb.frameCapacity)
                n = Int(fb.frameLength)
                if n == 0 { break }
                let total = n * chans
                if interleavedInt.count < total { interleavedInt = [Int32](repeating: 0, count: total) }
                interleavedInt.withUnsafeMutableBytes { raw in
                    _ = memcpy(raw.baseAddress!, fb.int32ChannelData![0], total * 4)
                }
            } else {
                guard let sb = output.copyNextSampleBuffer() else { break }
                let m = CMSampleBufferGetNumSamples(sb)
                guard m > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                n = m
                let total = n * chans
                let status: OSStatus
                if intPath {
                    if interleavedInt.count < total { interleavedInt = [Int32](repeating: 0, count: total) }
                    status = interleavedInt.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total * 4, destination: raw.baseAddress!)
                    }
                } else {
                    if interleaved.count < total { interleaved = [Float](repeating: 0, count: total) }
                    status = interleaved.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total * 4, destination: raw.baseAddress!)
                    }
                }
                guard status == 0 else { continue }   // 0 = kein Fehler
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                seconds = pts.isValid ? CMTimeGetSeconds(pts) : .nan
            }
            // Lage nach Zeitstempel: Lücke → Stille, Überlappung → doppelte Proben weg, ±2 Proben gelten als nahtlos
            var skip = 0
            // unplausible Zeitstempel (beschädigte Datei) nicht in Proben umrechnen: Int() stürzte bei Überlauf ab
            if seconds.isFinite, abs(seconds) < 1e9 {
                let start = Int((seconds * Double(src.sr)).rounded())
                if start - position > 2 {
                    let gap = start - position
                    for sink in sinks { try sink.silence(gap, isCancelled: isCancelled) }
                    position += gap
                } else if position - start > 2 {
                    skip = min(n, position - start)
                }
            }
            let count = n - skip
            guard count > 0 else { continue }
            for c in 0..<chans {
                if planes[c].count < count { planes[c] = [Float](repeating: 0, count: count) }
                if intPath, planesInt[c].count < count { planesInt[c] = [Int32](repeating: 0, count: count) }
            }
            if intPath {
                interleavedInt.withUnsafeBufferPointer { src in
                    for c in 0..<chans {
                        let from = src.baseAddress! + skip * chans + c
                        planesInt[c].withUnsafeMutableBufferPointer { di in
                            planes[c].withUnsafeMutableBufferPointer { df in
                                for i in 0..<count {
                                    let v = from[i * chans]
                                    di[i] = v
                                    df[i] = Float(v) / 2_147_483_648
                                }
                            }
                        }
                    }
                }
            } else {
                interleaved.withUnsafeBufferPointer { src in
                    for c in 0..<chans {
                        let from = src.baseAddress! + skip * chans + c
                        planes[c].withUnsafeMutableBufferPointer { dst in
                            for i in 0..<count { dst[i] = from[i * chans] }
                        }
                    }
                }
            }
            // bitgleiche Kanäle an den gelesenen Proben vergleichen (bei 32-Bit-Ganzzahl nicht am Float, das die
            // untersten 8 Bit nicht unterscheidet)
            for c in 1..<max(1, chans) where identical[c] {
                if intPath {
                    identical[c] = planesInt[c].withUnsafeBytes { a in
                        planesInt[0].withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, count * 4) == 0 }
                    }
                } else {
                    identical[c] = planes[c].withUnsafeBytes { a in
                        planes[0].withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, count * 4) == 0 }
                    }
                }
            }
            for c in 0..<chans {
                try planes[c].withUnsafeBufferPointer { p in
                    if intPath {
                        try planesInt[c].withUnsafeBufferPointer { q in
                            try sinks[c].add(UnsafeBufferPointer(rebasing: p[0..<count]),
                                             raw: UnsafeBufferPointer(rebasing: q[0..<count]))
                        }
                    } else {
                        try sinks[c].add(UnsafeBufferPointer(rebasing: p[0..<count]))
                    }
                }
            }
            position += count
            if Date().timeIntervalSince(lastReport) > 0.4 {
                progress(position)
                lastReport = Date()
            }
        }
        if reader.status == .failed {
            throw ForensicError(t("Lesefehler: \(reader.error?.localizedDescription ?? "?")",
                                  "Read error: \(reader.error?.localizedDescription ?? "?")"))
        }
        guard position > 0 else { throw ForensicError(t("Die Tonspur ist leer.", "The audio track is empty.")) }
        // Doppel-Mono und Co.: Kanäle, die bitgleich mit Kanal 1 sind, nur einmal
        let duplicates = chans > 1 ? (1..<chans).filter { identical[$0] } : []
        var results: [ChannelResult] = []
        for c in 0..<chans {
            if duplicates.contains(c) {
                sinks[c].discard()
                continue
            }
            var r = try sinks[c].finish(channel: c)
            if c == 0 { r.alsoChannels = duplicates.count }
            results.append(r)
        }
        // Spur-IDs fortlaufend (t_orig, t_k2 …), auch wenn Kanäle wegfielen
        for (i, r) in results.enumerated() where i > 0 || firstIndex > 0 {
            let want = "t_k\(firstIndex + i + 1)"
            if r.tid != want {
                try sinks.first { $0.tid == r.tid }?.rename(to: want)
                results[i].tid = want
            }
        }
        ok = true
        return DecodeResult(channels: results)
    }

    /// Codec-Name (wie ffmpeg unter Windows) und das Format des Originaltons (Ganzzahl bleibt Ganzzahl).
    static func describe(_ a: AudioStreamBasicDescription) -> (String, WavWriter.Kind) {
        switch a.mFormatID {
        case kAudioFormatLinearPCM:
            let float = a.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bits = Int(a.mBitsPerChannel)
            if float { return (bits == 64 ? "pcm_f64le" : "pcm_f32le", .float32) }
            return ("pcm_s\(bits)\(bits > 8 ? (a.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? "be" : "le") : "")",
                    bits <= 16 ? .int16 : bits <= 24 ? .int24 : .int32)
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            let codec = a.mFormatID == kAudioFormatFLAC ? "flac" : "alac"
            switch a.mFormatFlags {
            case 1: return (codec, .int16)                 // 16 Bit
            case 4: return (codec, .int32)                 // 32 Bit (Ganzzahl)
            default: return (codec, .int24)                // 20 und 24 Bit (und unbekannt: 24 Bit fasst 16 verlustfrei)
            }
        default:
            let name = fourCC(a.mFormatID)
            let map = ["aac": "aac", ".mp3": "mp3", "opus": "opus", "ac-3": "ac3", "ec-3": "eac3", "aach": "aac_he"]
            return (map[name] ?? name, .float32)
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let s = String(bytes: bytes, encoding: .ascii) ?? "\(code)"
        return s.trimmingCharacters(in: .whitespaces)
    }
}

struct ForensicError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Alles, was aus einem Kanal entsteht.
final class ChannelSink {
    private(set) var tid: String
    private let fall: URL
    private let sr: Int
    private let wav: WavWriter
    private let proxy: AACProxyWriter
    private let peaks = PeaksWriter()
    private let spec: SpectrogramBuilder
    private var zeros: [Float] = []

    /// Abtastraten, die ein Fall nimmt: Darunter wäre der Spaltenabstand des Spektrogramms 0 (Endlosschleife), darüber
    /// scheitern AAC und die Umrechnung; solche Werte kommen nur aus beschädigten Dateien oder Konfigurationen.
    static let rates = 1000...768_000

    init(tid: String, fall: URL, sr: Int, kind: WavWriter.Kind) throws {
        guard Self.rates.contains(sr) else {
            throw ForensicError(t("Abtastrate \(sr) Hz wird nicht unterstützt (1000 bis 768 000 Hz); die Datei oder die Konfiguration ist vermutlich beschädigt.",
                                  "Sample rate \(sr) Hz is not supported (1000 to 768,000 Hz); the file or the configuration is probably damaged."))
        }
        self.tid = tid
        self.fall = fall
        self.sr = sr
        wav = try WavWriter(url: fall.appendingPathComponent("original/\(tid).wav"), sr: sr, kind: kind)
        proxy = try AACProxyWriter(url: fall.appendingPathComponent("proxy/\(tid).m4a"), sr: sr)
        try FileManager.default.createDirectory(at: fall.appendingPathComponent("spec"), withIntermediateDirectories: true)
        do {
            spec = try SpectrogramBuilder(outBase: fall.appendingPathComponent("spec/\(tid)"), sr: sr)
        } catch {
            // ForensicAnalysis.swift bleibt ohne App-Abhängigkeit (Prüfprogramm); die Meldung für Nutzer kommt von hier
            guard error is SpectrogramBuilder.SetupError else { throw error }
            throw ForensicError(t("Das Spektrogramm lässt sich nicht einrichten (FFT); vermutlich ist der Arbeitsspeicher knapp.",
                                  "The spectrogram cannot be set up (FFT); memory is probably low."))
        }
    }

    /// `raw`: dieselben Proben als 32-Bit-Ganzzahl (Quelle mit 32 Bit Ganzzahl); dann schreibt der Originalton sie
    /// bitgenau, alles andere nimmt die Float-Fassung.
    func add(_ x: UnsafeBufferPointer<Float>, raw: UnsafeBufferPointer<Int32>? = nil) throws {
        if let raw { try wav.add(raw) } else { try wav.add(x) }
        try proxy.add(x)
        peaks.add(x)
        try spec.add(x)
    }

    /// Stille (Lücke laut Zeitstempel). Je 65 536 Proben wird der Abbruch geprüft: Eine lange Lücke lief vorher ohne
    /// Halt durch, auch am Speicherwächter vorbei (er wirkt über den Abbruch).
    func silence(_ n: Int, isCancelled: () -> Bool) throws {
        var left = n
        while left > 0 {
            if isCancelled() { throw CancellationError() }
            let k = min(left, 1 << 16)
            if zeros.count < k { zeros = [Float](repeating: 0, count: k) }
            try zeros.withUnsafeBufferPointer { try add(UnsafeBufferPointer(rebasing: $0[0..<k])) }
            left -= k
        }
    }

    func finish(channel: Int) throws -> ForensicImport.ChannelResult {
        try wav.close()
        try proxy.close()
        let bars = try peaks.save(to: fall.appendingPathComponent("peaks/\(tid).peaks"))
        let act = try spec.finish(actURL: fall.appendingPathComponent("spec/\(tid).act"))
        return ForensicImport.ChannelResult(tid: tid, channel: channel, frames: Int(wav.frames), bars: bars, peak: peaks.peak,
                                            spec: spec.info, activity: act, alsoChannels: 0)
    }

    /// Dateien unter neuem Spur-Namen (wenn davor Kanäle wegfielen).
    func rename(to new: String) throws {
        let fm = FileManager.default
        let pairs = [("original", ".wav"), ("proxy", ".m4a"), ("peaks", ".peaks")]
            + ForensicFormat.specSuffixes.map { ("spec", $0) }
        for (dir, ext) in pairs {
            let a = fall.appendingPathComponent("\(dir)/\(tid)\(ext)")
            if fm.fileExists(atPath: a.path) { try fm.moveItem(at: a, to: fall.appendingPathComponent("\(dir)/\(new)\(ext)")) }
        }
        tid = new
    }

    func discard() {
        try? wav.close()
        try? proxy.close()
        spec.discard()
        let fm = FileManager.default
        let pairs = [("original", ".wav"), ("proxy", ".m4a"), ("peaks", ".peaks")] + ForensicFormat.specSuffixes.map { ("spec", $0) }
        for (dir, ext) in pairs { try? fm.removeItem(at: fall.appendingPathComponent("\(dir)/\(tid)\(ext)")) }
    }
}

/// Originalton einer Spur als WAV (mono). Vorn steht ein JUNK-Block, der bei über 4 GB zum ds64-Block wird (RF64, wie
/// lange Bänder); die Prüf-App liest beides (`frontend/src/review/wav.ts`).
final class WavWriter {
    enum Kind {
        case int16, int24, int32, float32

        var bits: Int { self == .int16 ? 16 : self == .int24 ? 24 : 32 }
        var subtype: String {
            switch self {
            case .int16: return "PCM_16"
            case .int24: return "PCM_24"
            case .int32: return "PCM_32"
            case .float32: return "FLOAT"
            }
        }
    }

    let url: URL
    let kind: Kind
    let sr: Int
    private let writer: BufferedFileWriter
    private(set) var frames: Int64 = 0
    private var bytes: [UInt8] = []
    private var closed = false
    static let headerSize = 80

    init(url: URL, sr: Int, kind: Kind) throws {
        self.url = url
        self.sr = sr
        self.kind = kind
        writer = try BufferedFileWriter(url: url)
        try writer.write(header(dataBytes: 0))
    }

    private func header(dataBytes: UInt64) -> Data {
        let block = kind.bits / 8
        let riff = UInt64(Self.headerSize - 8) + dataBytes
        let rf64 = riff > UInt64(UInt32.max)
        var h = Data()
        h.append(contentsOf: Array((rf64 ? "RF64" : "RIFF").utf8))
        h.appendLE(rf64 ? UInt32.max : UInt32(riff))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array((rf64 ? "ds64" : "JUNK").utf8))
        h.appendLE(UInt32(28))
        if rf64 {
            h.appendLE(riff)
            h.appendLE(dataBytes)
            h.appendLE(UInt64(frames))
            h.appendLE(UInt32(0))
        } else {
            h.append(Data(count: 28))
        }
        h.append(contentsOf: Array("fmt ".utf8))
        h.appendLE(UInt32(16))
        h.appendLE(UInt16(kind == .float32 ? 3 : 1))
        h.appendLE(UInt16(1))
        h.appendLE(UInt32(sr))
        h.appendLE(UInt32(sr * block))
        h.appendLE(UInt16(block))
        h.appendLE(UInt16(kind.bits))
        h.append(contentsOf: Array("data".utf8))
        h.appendLE(rf64 ? UInt32.max : UInt32(dataBytes))
        return h
    }

    func add(_ x: UnsafeBufferPointer<Float>) throws {
        let n = x.count
        switch kind {
        case .float32:
            try writer.write(UnsafeRawBufferPointer(x))
        case .int16:
            if bytes.count < n * 2 { bytes = [UInt8](repeating: 0, count: n * 2) }
            bytes.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let v = (x[i] * 32768).rounded()
                    out[i] = Int16(max(-32768, min(32767, v))).littleEndian
                }
            }
            try bytes.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<(n * 2)])) }
        case .int24:
            if bytes.count < n * 3 { bytes = [UInt8](repeating: 0, count: n * 3) }
            for i in 0..<n {
                let v = Int32(max(-8_388_608, min(8_388_607, (Double(x[i]) * 8_388_608).rounded())))
                bytes[3 * i] = UInt8(truncatingIfNeeded: v)
                bytes[3 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                bytes[3 * i + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
            try bytes.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<(n * 3)])) }
        case .int32:   // nur Stille kommt hier als Float an; die Proben selbst über add(_: Int32)
            if bytes.count < n * 4 { bytes = [UInt8](repeating: 0, count: n * 4) }
            bytes.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int32.self)
                for i in 0..<n {
                    let v = (Double(x[i]) * 2_147_483_648).rounded()
                    out[i] = Int32(max(-2_147_483_648, min(2_147_483_647, v))).littleEndian
                }
            }
            try bytes.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<(n * 4)])) }
        }
        frames += Int64(n)
    }

    /// 32-Bit-Ganzzahl bitgenau (Quelle mit 32 Bit Ganzzahl, siehe ForensicImport.decode).
    func add(_ x: UnsafeBufferPointer<Int32>) throws {
        guard kind == .int32 else {
            let f = x.map { Float($0) / 2_147_483_648 }
            try f.withUnsafeBufferPointer { try add($0) }
            return
        }
        let n = x.count
        if bytes.count < n * 4 { bytes = [UInt8](repeating: 0, count: n * 4) }
        bytes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int32.self)
            for i in 0..<n { out[i] = x[i].littleEndian }
        }
        try bytes.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<(n * 4)])) }
        frames += Int64(n)
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        let data = UInt64(frames) * UInt64(kind.bits / 8)
        try writer.patch(at: 0, header(dataBytes: data))
        try writer.close()
    }
}

/// Ton zum Abspielen in der Prüf-App: AAC in M4A, mono. Raten, die AAC nicht kennt, und über 48 kHz werden umgerechnet.
final class AACProxyWriter {
    private let file: AVAudioFile
    private let inFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var closed = false
    static let rates = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    init(url: URL, sr: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rate = Self.rates.contains(sr) ? sr : (Self.rates.first { $0 >= sr } ?? 48000)
        let kbps = rate >= 32000 ? 96 : rate >= 22050 ? 64 : rate >= 16000 ? 48 : 32
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: kbps * 1000]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            settings[AVEncoderBitRateKey] = nil
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sr), channels: 1, interleaved: false)!
        converter = rate == sr ? nil : AVAudioConverter(from: inFormat, to: file.processingFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    func add(_ x: UnsafeBufferPointer<Float>) throws {
        guard x.count > 0, let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)) else { return }
        buf.frameLength = AVAudioFrameCount(x.count)
        memcpy(buf.floatChannelData![0], x.baseAddress!, x.count * 4)
        guard let converter else {
            try file.write(from: buf)
            return
        }
        try convert(converter, input: buf, end: false)
    }

    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, end: Bool) throws {
        let ratio = file.processingFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 4096
        var given = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inStatus in
                if let input, !given {
                    given = true
                    inStatus.pointee = .haveData
                    return input
                }
                inStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if out.frameLength > 0 { try file.write(from: out) }
            if status != .haveData { break }
        }
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        if let converter { try convert(converter, input: nil, end: true) }
        file.close()
    }
}
