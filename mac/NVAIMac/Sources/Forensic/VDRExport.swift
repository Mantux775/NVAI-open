import CryptoKit
import Foundation
import zlib

/// VDR-Aufzeichnungen (Voyage Data Recorder, Furuno VR-7000, Export „VDR Data files“) auf dem Mac lesen (seit 0.5.11),
/// nach `server/nvai/vdr.py` unter Windows. Aufbau des Exports:
///
///     block.<spur>.<id>.gz  je 15 s ein tar (gzip) mit audio<n> (Ogg Vorbis, 16 kHz, Stereo = zwei Eingänge),
///                           radar<a>_<b> (Bild mit eigenem Kopf), serial (NMEA mit Empfangszeit), sporadic
///                           (Digital-, Analog- und Statuswerte), alarmblock, attachedinfo<n>, configure, *_version
///     Track.txt             <id>,<spur>,<Unix-Zeit Blockbeginn>
///     TrackInfo.txt         <spur>,<Beginn>,<Ende>
///     VdrCheckList.dat      je Block 48 Byte Name + 16 Byte MD5 der .gz-Datei
///     VdrCheckFile.dat      4 × MD5: Track.txt, TrackInfo.txt, VdrCheckList.dat, viewerConfig.dat
///
/// Dieser Teil findet die Blöcke, liest einen Block (gzip + tar), die Konfiguration (XML) und den Kopf eines Bildes,
/// gibt den Überblick (`inspect`) und prüft die Prüfsummen (`verify`). Ton: `VDRAudio`, Daten: `VDRData`, Bilder:
/// `VDRImages`, Fall anlegen: `VDRImport`.
enum VDR {
    static let blockSeconds = 15
    static let sampleRate = 16000
    static let format = "Furuno VR-7000 (VDR Data files)"

    struct Block {
        var track: Int
        var id: Int
        var gz: Bool
        var url: URL
        var name: String
        var start = 0
        var timeGuessed = false
    }

    struct Export {
        var folder: URL
        var track: Int
        var tracks: [Int]
        var blocks: [Block]
        var t0: Int
        var end: Int
        var gaps: [JSONObject]
        var listedMissing: [Int]
        var layout: String
        var times: String
        var trackInfo: String
    }

    static func isDigits<S: StringProtocol>(_ s: S) -> Bool { !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }

    /// „block.<spur>.<id>“ oder „block.<spur>.<id>.gz“ (wie `^block\.(\d+)\.(\d+)(\.gz)?$`).
    static func blockMatch(_ name: String) -> (Int, Int, Bool)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4, parts[0] == "block", isDigits(parts[1]), isDigits(parts[2]),
              let a = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        if parts.count == 4 { return parts[3] == "gz" ? (a, b, true) : nil }
        return (a, b, false)
    }

    static func scan(_ folder: URL, only: Set<String>? = nil) -> [Block] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [String: Block] = [:]
        for name in names {
            guard let (track, id, gz) = blockMatch(name), only.map({ $0.contains(name) }) ?? true else { continue }
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let key = "\(track).\(id)"
            // liegen .gz und entpacktes tar nebeneinander, gilt das Original (.gz, über die Prüfliste prüfbar)
            if let f = found[key], f.gz, !gz { continue }
            found[key] = Block(track: track, id: id, gz: gz, url: url, name: name)
        }
        return found.values.sorted { ($0.track, $0.id) < ($1.track, $1.id) }
    }

    static func latin1(_ d: Data) -> String { String(data: d, encoding: .isoLatin1) ?? "" }

    static func readTrackTxt(_ folder: URL) -> [Int: Int?] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Track.txt")) else { return [:] }
        var out: [Int: Int?] = [:]
        for line in latin1(data).components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, isDigits(parts[0]), let id = Int(parts[0]) else { continue }
            let tv: Int? = parts.count > 2 && isDigits(parts[2]) ? Int(parts[2]) : nil
            out[id] = .some(tv)
        }
        return out
    }

    /// Ordner mit Blöcken (auch eine Ebene tiefer) oder eine Blockdatei; Spur = die mit den meisten Blöcken.
    static func findExport(_ url: URL, track wanted: Int? = nil) throws -> Export {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ForensicError(t("Pfad nicht gefunden: \(url.lastPathComponent)", "Path not found: \(url.lastPathComponent)"))
        }
        var folder = url
        var only: Set<String>?
        if !isDir.boolValue {
            guard blockMatch(url.lastPathComponent) != nil else {
                throw ForensicError(t("Keine VDR-Blockdatei: \(url.lastPathComponent)", "Not a VDR block file: \(url.lastPathComponent)"))
            }
            folder = url.deletingLastPathComponent()
            only = [url.lastPathComponent]
        }
        var blocks = scan(folder, only: only)
        if blocks.isEmpty, only == nil {
            let subs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for sub in subs {
                let b = scan(sub)
                if !b.isEmpty { folder = sub; blocks = b; break }
            }
        }
        guard !blocks.isEmpty else {
            throw ForensicError(t("Keine VDR-Blöcke gefunden (block.<n>.<id>.gz oder entpackte Blöcke).",
                                  "No VDR blocks found (block.<n>.<id>.gz or unpacked blocks)."))
        }
        let tracks = Array(Set(blocks.map(\.track))).sorted()
        var counts: [Int: Int] = [:]
        for b in blocks { counts[b.track, default: 0] += 1 }
        // wie max() in Python: bei Gleichstand die erste (kleinste) Spur
        let track = wanted ?? tracks.reduce(tracks[0]) { best, k in counts[k]! > counts[best]! ? k : best }
        blocks = blocks.filter { $0.track == track }
        let times = readTrackTxt(folder)
        var source = times.isEmpty ? "block" : "Track.txt"
        var known: [(Int, Int)] = blocks.compactMap { b in (times[b.id] ?? nil).flatMap { $0 != 0 ? (b.id, $0) : nil } }
        if known.isEmpty {
            guard let first = timeFromBlock(blocks[0]) else {
                throw ForensicError(t("Die Zeit des ersten Blocks lässt sich nicht bestimmen.", "The time of the first block cannot be determined."))
            }
            known = [(blocks[0].id, first)]
            if blocks.count > 1 { source = "block+15s" }
        }
        let kid = known.map(\.0)
        for i in blocks.indices {
            if let tv = times[blocks[i].id] ?? nil, tv != 0 {
                blocks[i].start = tv
                continue
            }
            // bisect_left − 1, begrenzt
            var lo = 0, hi = kid.count
            while lo < hi { let m = (lo + hi) / 2; if kid[m] < blocks[i].id { lo = m + 1 } else { hi = m } }
            let k = min(max(0, lo - 1), known.count - 1)
            blocks[i].start = known[k].1 + (blocks[i].id - known[k].0) * blockSeconds
            blocks[i].timeGuessed = true
        }
        blocks.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        let t0 = blocks[0].start
        var gaps: [JSONObject] = []
        for (a, b) in zip(blocks, blocks.dropFirst()) {
            let missing = b.id - a.id - 1
            let dt = b.start - a.start
            if missing > 0 || dt != blockSeconds {
                gaps.append(JSONObject(["after": a.id, "next": b.id, "missing_ids": max(0, missing), "t": a.start + blockSeconds - t0,
                                        "seconds": dt - blockSeconds]))
            }
        }
        let have = Set(blocks.map(\.id))
        let listedMissing = (!times.isEmpty && only == nil) ? Array(Set(times.keys).subtracting(have)).sorted() : []
        let info = (try? Data(contentsOf: folder.appendingPathComponent("TrackInfo.txt"))).map { Py.strip(latin1($0)) } ?? ""
        let layout = blocks.allSatisfy(\.gz) ? "gz" : (blocks.contains(where: \.gz) ? "mixed" : "tar")
        return Export(folder: folder, track: track, tracks: tracks, blocks: blocks, t0: t0, end: blocks.last!.start + blockSeconds,
                      gaps: gaps, listedMissing: listedMissing, layout: layout, times: source, trackInfo: info)
    }

    // MARK: Block lesen (gzip + tar)

    /// Ein Block als [Grundname: Inhalt]; Grundname ohne angehängte Block-ID („serial.123456789“ → „serial“).
    static func readBlock(_ b: Block, want: ((String) -> Bool)? = nil) throws -> [String: Data] {
        try autoreleasepool {
            var raw = try Data(contentsOf: b.url, options: .mappedIfSafe)
            if b.gz { raw = try gunzip(raw) }
            return try untar(raw, want: want)
        }
    }

    /// gzip wie Python `gzip.decompress`: mehrere Glieder, Prüfsumme und Länge je Glied geprüft, Nullbytes am Ende erlaubt.
    static func gunzip(_ d: Data) throws -> Data {
        let bad = ForensicError(t("gzip beschädigt", "gzip damaged"))
        guard d.count >= 18 else { throw bad }
        // Größe des (letzten) Glieds aus dem Ende: reicht für die üblichen Ein-Glied-Dateien als Puffergröße
        let isize = d.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: d.count - 4, as: UInt32.self))) }
        var out = Data(count: max(isize, 1 << 16))
        var produced = 0
        try d.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < src.count {
                var strm = z_stream()
                guard inflateInit2_(&strm, 16 + MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw bad }
                defer { inflateEnd(&strm) }
                strm.next_in = UnsafeMutablePointer(mutating: src.baseAddress!.assumingMemoryBound(to: Bytef.self) + offset)
                strm.avail_in = uInt(src.count - offset)
                var status: Int32 = Z_OK
                repeat {
                    if produced == out.count { out.count += max(out.count, 1 << 16) }
                    let room = out.count - produced
                    status = out.withUnsafeMutableBytes { dst -> Int32 in
                        strm.next_out = dst.baseAddress!.assumingMemoryBound(to: Bytef.self) + produced
                        strm.avail_out = uInt(room)
                        let s = inflate(&strm, Z_NO_FLUSH)
                        produced += room - Int(strm.avail_out)
                        return s
                    }
                    if status == Z_BUF_ERROR && strm.avail_in == 0 { throw bad }   // abgeschnitten
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw bad }
                } while status != Z_STREAM_END
                offset = src.count - Int(strm.avail_in)
                while offset < src.count && src[offset] == 0 { offset += 1 }
            }
        }
        out.count = produced
        return out
    }

    struct TarMember {
        var data: Data
        var mtime: Int
    }

    static func untar(_ d: Data, want: ((String) -> Bool)?) throws -> [String: Data] {
        try untarMembers(d, want: want).mapValues(\.data)
    }

    /// tar lesen (ustar, GNU-Langnamen); Grundname ohne Pfad und ohne angehängte Block-ID.
    static func untarMembers(_ d: Data, want: ((String) -> Bool)?) throws -> [String: TarMember] {
        var out: [String: TarMember] = [:]
        var p = d.startIndex
        var longName: String?
        func field(_ off: Int, _ len: Int) -> String {
            let s = d.subdata(in: (p + off)..<(p + off + len))
            return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
        }
        while p + 512 <= d.endIndex {
            if d[p..<(p + 512)].allSatisfy({ $0 == 0 }) { break }
            let name = field(0, 100)
            let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let mtime = Int(field(136, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = d[p + 156]
            let prefix = field(345, 155)
            let dataStart = p + 512
            let dataEnd = min(d.endIndex, dataStart + size)
            if type == UInt8(ascii: "L") {
                longName = String(decoding: d.subdata(in: dataStart..<dataEnd).prefix { $0 != 0 }, as: UTF8.self)
            } else if type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7") {
                var full = longName ?? (prefix.isEmpty ? name : prefix + "/" + name)
                longName = nil
                full = full.replacingOccurrences(of: "\\", with: "/")
                var base = full.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? full
                if let dot = base.lastIndex(of: "."), dot > base.startIndex, isDigits(base[base.index(after: dot)...]) {
                    base = String(base[..<dot])
                }
                if want?(base) ?? true { out[base] = TarMember(data: d.subdata(in: dataStart..<dataEnd), mtime: mtime) }
            } else if type != UInt8(ascii: "x") && type != UInt8(ascii: "g") {
                longName = nil
            }
            p = dataStart + (size + 511) / 512 * 512
        }
        return out
    }

    /// Blockbeginn ohne Track.txt: Kopf von „sporadic“ (Unix-Zeit des Blockendes) oder Dateizeit von „alarmblock“.
    static func timeFromBlock(_ b: Block) -> Int? {
        guard var raw = try? Data(contentsOf: b.url) else { return nil }
        if b.gz { guard let u = try? gunzip(raw) else { return nil }; raw = u }
        guard let members = try? untarMembers(raw, want: { $0 == "sporadic" || $0 == "alarmblock" }) else { return nil }
        if let d = members["sporadic"]?.data, d.count >= 0x34 {
            let end = d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0x30, as: UInt32.self).littleEndian) }
            if end > 1_000_000_000 { return end - blockSeconds }
        }
        return members["alarmblock"]?.mtime
    }

    // MARK: Konfiguration

    typealias Categories = [String: [[String: String]]]

    /// configure-XML: [Kategorie: [[Parametername: Wert, "_id": Kanal]]].
    static func parseConfig(_ data: Data) -> Categories {
        guard let doc = try? XMLDocument(data: data, options: []) else { return [:] }
        var cats: Categories = [:]
        for c in (try? doc.nodes(forXPath: "//category")) ?? [] {
            guard let c = c as? XMLElement else { continue }
            var chans: [[String: String]] = []
            for ch in (try? c.nodes(forXPath: "data/channel")) ?? [] {
                guard let ch = ch as? XMLElement else { continue }
                var params: [String: String] = [:]
                for p in ch.elements(forName: "parameter") {
                    guard let n = p.attribute(forName: "name")?.stringValue, !n.isEmpty else { continue }
                    params[n] = p.attribute(forName: "value")?.stringValue ?? ""
                }
                params["_id"] = ch.attribute(forName: "id")?.stringValue ?? ""
                chans.append(params)
            }
            cats[c.attribute(forName: "id")?.stringValue ?? ""] = chans
        }
        return cats
    }

    static func versions(_ data: Data?) -> [String: String] {
        guard let data, let doc = try? XMLDocument(data: data, options: []) else { return [:] }
        var out: [String: String] = [:]
        for p in (try? doc.nodes(forXPath: "//parameter")) ?? [] {
            guard let p = p as? XMLElement, let n = p.attribute(forName: "name")?.stringValue, !n.isEmpty else { continue }
            out[n] = p.attribute(forName: "value")?.stringValue ?? ""
        }
        return out
    }

    static func int(_ s: String?) -> Int { Py.int(s ?? "") ?? 0 }
    static func active(_ c: [String: String]) -> Bool { (c["Active"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "true" }

    /// Mono-Kanäle aus der Kategorie „Audio“: Kanal n liegt in audio<n-1>, links der erste, rechts der zweite Eingang.
    static func audioChannels(_ cats: Categories) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var used = Set<String>()
        for ch in cats["Audio"] ?? [] where active(ch) {
            let cid = int(ch["_id"])
            guard cid >= 1 else { continue }
            let inputs = (ch["Input Type"] ?? "").split(separator: "/", omittingEmptySubsequences: false)
                .map { Py.strip(String($0)) }
            let equipment = (ch["Type No.(Equipment Name)"] ?? "").components(separatedBy: CharacterSet(charactersIn: ",/"))
                .map { Py.strip($0) }.filter { !$0.isEmpty }
            let pos = [Py.strip(ch["MIC 1/3/5/7 Position"] ?? ""), Py.strip(ch["MIC 2/4/6/8 Position"] ?? "")]
            let rate = int((ch["Sampling Frequency"] ?? "").filter { $0.isASCII && $0.isNumber }).nonZero ?? sampleRate
            for side in 0..<2 {
                let name = side < inputs.count && !inputs[side].isEmpty ? inputs[side] : "CH\(cid)\(side == 0 ? "L" : "R")"
                let slug = String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter {
                    ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39)
                }))
                var tid = "v_" + (slug.isEmpty ? "ch\(cid)\(side)" : slug)
                while used.contains(tid) { tid += "x" }
                used.insert(tid)
                out.append(["id": tid, "input": name, "position": pos[side],
                            "category": Py.strip(ch["Equipment Category"] ?? ""),
                            "equipment": side < equipment.count ? equipment[side] : "", "channel": cid,
                            "file": "audio\(cid - 1)", "side": side, "delay_ms": int(ch["Delay Offset(ms)"]), "rate": rate,
                            "codec": ch["Codec"] ?? "", "model": ch["Data Name"] ?? "", "brand": ch["Brand"] ?? ""])
            }
        }
        return out
    }

    /// Überblick wie `config_summary`: Ton, Schnittstellen, Bildquellen, Schiff, System.
    static func configSummary(_ cats: Categories) -> [String: Any] {
        let s = { (c: [String: String], k: String) in c[k] ?? "" }
        let serial: [[String: Any]] = (cats["Serial"] ?? []).filter(active).map { c in
            ["channel": int(c["_id"]), "name": s(c, "Type No.(Equipment Name)"), "brand": s(c, "Brand"), "model": s(c, "Data Name"),
             "baud": s(c, "Baud rate"), "sentences": s(c, "Note"), "board": s(c, "Board Name")]
        }
        let digital: [[String: Any]] = (cats["Digital"] ?? []).filter(active).map { c in
            ["channel": int(c["_id"]), "name": s(c, "Type No.(Equipment Name)"), "group": s(c, "Data Name"), "brand": s(c, "Brand"),
             "state1": c["Active Status(1)"].flatMap { $0.isEmpty ? nil : $0 } ?? "1",
             "state0": c["Active Status(0)"].flatMap { $0.isEmpty ? nil : $0 } ?? "0",
             "contact": s(c, "Contact Type"), "interface": s(c, "Interface (JB or SA1-8)"), "sampling": s(c, "Sampling Rate")]
        }
        let analog: [[String: Any]] = (cats["Analog"] ?? []).filter(active).map { c in
            let cal: [Any] = ["Calibration Point1", "Calibration Point1 Value", "Calibration Point2", "Calibration Point2 Value"]
                .map { c[$0].map { $0 as Any } ?? NSNull() }
            return ["channel": int(c["_id"]), "name": s(c, "Type No.(Equipment Name)"), "group": s(c, "Data Name"),
                    "brand": s(c, "Brand"), "data_type": s(c, "Data Type"), "calibration": cal,
                    "calibration_active": s(c, "Calibration Active") == "true", "unit": s(c, "Engineering Value Unit"),
                    "interface": s(c, "Interface (JB or SA1-8)"), "sampling": s(c, "Sampling Rate")]
        }
        let sensor: [[String: Any]] = (cats["Sensor"] ?? []).filter(active).map { c in
            ["channel": int(c["_id"]), "name": s(c, "Type No.(Equipment Name)"), "model": s(c, "Data Name")]
        }
        var ifaces: [Int: [String: String]] = [:]
        for c in cats["ImageInterface"] ?? [] { ifaces[int(c["_id"])] = c }
        var images: [[String: Any]] = []
        for c in cats["ImageRecordSetting"] ?? [] where active(c) {
            let rid = int(c["_id"])
            for k in ["No.1 Input source", "No.2 Input source", "No.3 Input source", "No.4 Input source"] {
                let src = int(c[k])
                guard src >= 1 else { continue }
                let itf = ifaces[src] ?? [:]
                let label = Py.strip(c["No"].flatMap { $0.isEmpty ? nil : $0 } ?? "Bild \(rid)")
                let extra = [Py.strip(s(itf, "No")), Py.strip(s(itf, "Type No.(Equipment Name)"))]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                images.append(["id": "radar\(rid - 1)_\(src - 1)", "label": label + (extra.isEmpty ? "" : " (\(extra))"),
                               "record": rid, "input": src, "jpeg_quality": s(c, "Jpeg Quality")])
            }
        }
        let first = { (k: String) in (cats[k] ?? []).first ?? [:] }
        let pick = { (c: [String: String], pairs: [(String, String)]) -> [String: Any] in
            Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, Py.strip(c[$0.1] ?? "") as Any) })
        }
        let vessel = pick(first("Vessel"), [("name", "Vessel Name"), ("imo", "Vessel IMO Number"), ("mmsi", "Vessel MMSI Number"),
                                            ("flag", "Vessel Flag")])
        let system = pick(first("System"), [("vdr_type", "VDR Type"), ("config_version", "VDR Config Version"),
                                            ("config_date", "VDR Config Date")])
        let gps: [String: Any] = ["source": Py.strip(first("Gps")["Date and Time Source / Ship Position Source (Serial Channel No. or 450 Sensor Channel No.)"]
                                             ?? "")]
        let software = first("Software").filter { !$0.key.hasPrefix("_") && !$0.value.isEmpty && $0.key != "Note" }
        return ["audio": audioChannels(cats), "serial": serial, "digital": digital, "analog": analog, "sensor": sensor,
                "images": images, "vessel": vessel, "system": system, "gps": gps, "software": software]
    }

    /// Eigenständige configure.<id>.xml bevorzugen, sonst die aus dem ersten Block.
    static func configBytes(_ ex: Export, first: [String: Data]?) -> (Data?, String) {
        for f in configFiles(ex.folder) {
            if let d = try? Data(contentsOf: ex.folder.appendingPathComponent(f)) { return (d, f) }
        }
        if let c = first?["configure"] { return (c, "block \(ex.blocks[0].id)") }
        return (nil, "")
    }

    static func configFiles(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("configure.") && $0.hasSuffix(".xml") && $0.count >= 14 }.sorted()   // wie configure.*.xml
    }

    // MARK: Bildkopf

    struct ImageHeader {
        var t: Int
        var height: Int
        var width: Int
        var signal: Bool
        var mime: String
        var head: [String: String]
        var capture: Double?
        var offset: Int
        var rawSize: Int
        var kind: String
        var noSignal: Bool
    }

    static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10,
                         "Nov": 11, "Dec": 12]
    private static let timeRegex = try! NSRegularExpression(pattern: "^\\w{3}, (\\d{1,2}) (\\w{3}) (\\d{4}) (\\d\\d):(\\d\\d):(\\d\\d)")

    /// Kopf eines Bildes (radar<a>_<b>): u32 Unix-Zeit, u16 Höhe, u16 Breite (Bit 15 = Bildsignal), u32 Kopflänge ab
    /// Byte 8, u32 Datenlänge, 4 Byte Quelle, Mime mit Längenbyte, Textzeilen „VDRI/1.0“ mit „Schlüssel: Wert“, Bilddaten.
    static func parseImage(_ d: Data) -> ImageHeader? {
        guard d.count >= 0x20 else { return nil }
        let b = d.startIndex
        func u32(_ o: Int) -> Int { Int(d[b + o]) | Int(d[b + o + 1]) << 8 | Int(d[b + o + 2]) << 16 | Int(d[b + o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[b + o]) | Int(d[b + o + 1]) << 8 }
        let tRec = u32(0), h = u16(4), w = u16(6), hl = u32(8), dl = u32(12)
        let off = 8 + hl
        let ml = Int(d[b + 0x14])
        guard off <= d.count, 0x15 + ml <= off else { return nil }
        let mime = String(decoding: d.subdata(in: (b + 0x15)..<(b + 0x15 + ml)), as: UTF8.self)
        let textData = d.subdata(in: (b + 0x15 + ml)..<(b + off))
        let text = latin1(Data(textData.prefix { $0 != 0 }))
        var head: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            head[Py.strip(String(line[..<c]))] = Py.strip(String(line[line.index(after: c)...]))
        }
        var capture: Double?
        if let time = head["Time"], let m = timeRegex.firstMatch(in: time, range: NSRange(time.startIndex..., in: time)) {
            let g = (1...6).map { Range(m.range(at: $0), in: time).map { String(time[$0]) } ?? "" }
            if let mon = months[g[1]], let day = Int(g[0]), let year = Int(g[2]), let hh = Int(g[3]), let mm = Int(g[4]),
               let ss = Int(g[5]), let days = Py.daysFromCivil(year, mon, day) {
                capture = Double(days * 86400 + hh * 3600 + mm * 60 + ss) + Double(int(head["Time-ms"])) / 1000
            }
        }
        let p = [UInt8](d[(b + off)...].prefix(4))
        let kind = p.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : p.starts(with: [0xFF, 0xD8]) ? "jpg"
            : p.starts(with: [0x42, 0x4D]) ? "bmp" : p.first == 0x78 ? "zlib" : "bin"
        return ImageHeader(t: tRec, height: h, width: w & 0x7FFF, signal: w & 0x8000 != 0, mime: mime, head: head,
                           capture: capture, offset: off, rawSize: dl, kind: kind,
                           noSignal: w & 0x8000 == 0 && (head["Source"] ?? "").isEmpty)
    }

    static func isRadar(_ name: String) -> Bool {
        guard name.hasPrefix("radar") else { return false }
        let parts = name.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 2 && isDigits(parts[0]) && isDigits(parts[1])
    }

    static func isAudioFile(_ name: String) -> Bool { name.hasPrefix("audio") && isDigits(name.dropFirst(5)) }

    // MARK: Überblick

    struct Inspection {
        var export: Export
        var cats: Categories
        var config: [String: Any]
        /// wie `inspect()` in vdr.py; der Ordner nur mit Namen (ein Fall geht an Dritte)
        var summary: JSONObject
    }

    /// Schneller Überblick (< 5 s): Zeiten, Lücken, Kanäle, Geräte, Bildquellen, Versionen, Größe.
    static func inspect(_ url: URL) throws -> Inspection {
        let started = Date()
        let ex = try findExport(url)
        var first: [String: Data]?
        for b in ex.blocks.prefix(3) {
            first = try? readBlock(b)
            if first != nil { break }
        }
        let (cfg, cfgFrom) = configBytes(ex, first: first)
        let cats = cfg.map(parseConfig) ?? [:]
        let summ = configSummary(cats)
        let versions: [String: Any] = ["vdr": Self.versions(first?["vdr_version"]), "vlc1": Self.versions(first?["vlc1_version"]),
                                       "vlc2": Self.versions(first?["vlc2_version"])]
        // Bildquellen: aus der Konfiguration, Mime und Kopfzeilen aus dem ersten Block mit Bildern
        var imgByID: [String: [String: Any]] = [:]
        for x in summ["images"] as? [[String: Any]] ?? [] { imgByID[x["id"] as! String] = x }
        for (i, b) in ex.blocks.prefix(12).enumerated() {
            let blk = i == 0 ? first : try? readBlock(b, want: { $0.hasPrefix("radar") })
            let found = (blk ?? [:]).filter { isRadar($0.key) }
            if found.isEmpty { continue }
            for (k, v) in found.sorted(by: { $0.key < $1.key }) {
                let hd = parseImage(v)
                var x = imgByID[k] ?? ["id": k, "label": k]
                if let hd {
                    x["mime"] = hd.mime
                    x["stored_as"] = hd.kind
                    x["width"] = hd.width
                    x["height"] = hd.height
                    x["header_source"] = hd.head["Source"] ?? ""
                    x["location"] = hd.head["Location"] ?? ""
                }
                imgByID[k] = x
            }
            break
        }
        let audioFiles = (first ?? [:]).keys.filter(isAudioFile).sorted()
        let fm = FileManager.default
        let fileSize = { (u: URL) in Int(((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0) }
        var size = ex.blocks.reduce(0) { $0 + fileSize($1.url) }
        var files = JSONObject()
        for n in ["Track.txt", "TrackInfo.txt", "VdrCheckList.dat", "VdrCheckFile.dat", "viewerConfig.dat"] {
            let f = ex.folder.appendingPathComponent(n)
            if fm.fileExists(atPath: f.path) {
                files.set(n, fileSize(f))
                size += fileSize(f)
            }
        }
        for n in configFiles(ex.folder) {
            let f = ex.folder.appendingPathComponent(n)
            files.set(n, fileSize(f))
            size += fileSize(f)
        }
        let audio = summ["audio"] as? [[String: Any]] ?? []
        let missingAudio = first == nil ? [] : audio.compactMap { c -> String? in
            let f = c["file"] as! String
            return first![f] == nil ? f : nil
        }
        let system = summ["system"] as? [String: Any] ?? [:]
        let product = (system["vdr_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "VDR"
        let out = JSONObject([
            "product": product, "format": format, "folder": ex.folder.lastPathComponent, "layout": ex.layout,
            "track": ex.track, "tracks": ex.tracks, "blocks": ex.blocks.count, "first_id": ex.blocks[0].id,
            "last_id": ex.blocks.last!.id, "start_utc": ex.t0, "end_utc": ex.end, "start": utc(ex.t0), "end": utc(ex.end),
            "duration": ex.end - ex.t0, "block_seconds": blockSeconds, "times": ex.times, "gaps": Array(ex.gaps.prefix(200)),
            "gap_count": ex.gaps.count, "listed_missing": Array(ex.listedMissing.prefix(200)), "trackinfo": ex.trackInfo,
            "config_from": cfgFrom, "versions": versions, "software": summ["software"], "system": summ["system"],
            "vessel": summ["vessel"], "gps": summ["gps"], "audio": audio, "audio_files": audioFiles,
            "missing_audio_files": missingAudio, "serial": summ["serial"], "digital": summ["digital"], "analog": summ["analog"],
            "sensor": summ["sensor"], "images": imgByID.keys.sorted().map { imgByID[$0]! }, "size_bytes": size, "files": files,
            "seconds": Py.round(Date().timeIntervalSince(started), 2),
        ])
        return Inspection(export: ex, cats: cats, config: summ, summary: out)
    }

    /// „JJJJ-MM-TT hh:mm:ss“ in UTC (wie `time.strftime(…, time.gmtime(t))`).
    static func utc(_ t: Int) -> String {
        let days = Int((Double(t) / 86400).rounded(.down))
        let sec = t - days * 86400
        let (y, m, d) = Py.civilFromDays(days)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", y, m, d, sec / 3600, sec % 3600 / 60, sec % 60)
    }

    // MARK: Prüfsummen

    /// Prüfsummen wie `verify`: jede Datei aus VdrCheckList.dat (MD5 der .gz-Datei) und VdrCheckFile.dat (4 × MD5 der
    /// Begleitdateien). Mehrere Dateien zugleich; `progress` bekommt den Anteil.
    static func verify(_ ex: Export, progress: VDRProgress, key: String) throws -> JSONObject {
        let started = Date()
        let folder = ex.folder
        let fm = FileManager.default
        var out = JSONObject(["folder": folder.lastPathComponent, "checklist": nil, "checkfile": nil])
        let cl = folder.appendingPathComponent("VdrCheckList.dat")
        if let raw = try? Data(contentsOf: cl) {
            var entries: [(String, String)] = []
            raw.withUnsafeBytes { b in
                var i = 0
                while i + 64 <= b.count {
                    let nameBytes = Array(b[i..<(i + 48)].prefix { $0 != 0 })
                    let name = latin1(Data(nameBytes))
                    let digest = b[(i + 48)..<(i + 64)].map { String(format: "%02x", $0) }.joined()
                    entries.append((name, digest))
                    i += 64
                }
            }
            let checks: [(String, URL?, String)] = entries.map { name, digest in
                let gz = folder.appendingPathComponent(name + ".gz"), plain = folder.appendingPathComponent(name)
                return (name, fm.fileExists(atPath: gz.path) ? gz : (fm.fileExists(atPath: plain.path) ? plain : nil), digest)
            }
            // Verfahren am ersten vorhandenen Eintrag bestimmen
            var algo: String?
            if let entry = checks.first(where: { $0.1 != nil }), let f = entry.1, let data = try? Data(contentsOf: f) {
                let digest = entry.2
                let hex = { (d: any Sequence<UInt8>) in d.map { String(format: "%02x", $0) }.joined() }
                if hex(Insecure.MD5.hash(data: data)).prefix(32) == digest { algo = "md5" }
                else if hex(Insecure.SHA1.hash(data: data)).prefix(32) == digest { algo = "sha1" }
                else if hex(SHA256.hash(data: data)).prefix(32) == digest { algo = "sha256" }
                if algo == nil && f.pathExtension != "gz" { algo = "md5" }   // nur entpackt: prüfen geht dann nicht
            }
            let algorithm = algo ?? "unbekannt"
            var states = [String](repeating: "", count: checks.count)
            let lock = NSLock()
            var done = 0
            let workers = 4
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                var i = w
                while i < checks.count {
                    if progress.cancelled { return }
                    let (_, f, digest) = checks[i]
                    var st: String
                    if let f {
                        if f.pathExtension != "gz" {
                            st = "unpacked"
                        } else if let h = try? fileHash(f, algorithm: algorithm) {
                            st = h.prefix(32) == digest ? "ok" : "bad"
                        } else {
                            st = "bad"
                        }
                    } else {
                        st = "missing"
                    }
                    lock.lock()
                    states[i] = st
                    done += 1
                    if done % 50 == 0 { progress.set(key, Double(done) / Double(max(1, checks.count))) }
                    lock.unlock()
                    i += workers
                }
            }
            if progress.cancelled { throw CancellationError() }
            let names = { (s: String) in zip(checks, states).filter { $0.1 == s }.map { $0.0.0 } }
            let bad = names("bad"), missing = names("missing")
            let listed = Set(entries.map(\.0))
            let unlisted = scan(folder).map(\.name).filter { !listed.contains($0.hasSuffix(".gz") ? String($0.dropLast(3)) : $0) }.sorted()
            out.set("checklist", JSONObject([
                "algorithm": algorithm, "covers": ".gz", "listed": entries.count, "ok": names("ok").count,
                "bad": Array(bad.prefix(500)), "bad_count": bad.count, "missing": Array(missing.prefix(500)),
                "missing_count": missing.count, "unpacked": names("unpacked").count, "unlisted": Array(unlisted.prefix(200)),
                "unlisted_count": unlisted.count,
            ]))
        }
        let cf = folder.appendingPathComponent("VdrCheckFile.dat")
        if let raw = try? Data(contentsOf: cf) {
            let expected = ["Track.txt", "TrackInfo.txt", "VdrCheckList.dat", "viewerConfig.dat"]
            var cands: [(String, String)] = []
            for n in expected + configFiles(folder) {
                let f = folder.appendingPathComponent(n)
                if fm.fileExists(atPath: f.path), let h = try? fileHash(f, algorithm: "md5") { cands.append((n, h)) }
            }
            var parts: [JSONObject] = []
            for k in 0..<(raw.count / 16) {
                let dg = raw[(raw.startIndex + 16 * k)..<(raw.startIndex + 16 * k + 16)].map { String(format: "%02x", $0) }.joined()
                let exp: String? = k < expected.count ? expected[k] : nil
                let match = cands.first { $0.1 == dg }?.0
                parts.append(JSONObject(["expected": exp, "matches": match, "ok": match != nil && (exp == nil || match == exp)]))
            }
            out.set("checkfile", JSONObject(["layout": "\(raw.count / 16) × MD5", "parts": parts,
                                             "ok": parts.allSatisfy { $0["ok"] as? Bool == true }, "not_covered": configFiles(folder)]))
        }
        let list = out["checklist"] as? JSONObject
        let file = out["checkfile"] as? JSONObject
        if list == nil && file == nil {
            out.set("ok", nil)   // nichts zu prüfen (etwa ein einzelner entpackter Block)
            out.set("note", "Keine VdrCheckList.dat/VdrCheckFile.dat im Ordner.")
        } else {
            let clOK = list.map { ($0["bad_count"] as? Int) == 0 && ($0["missing_count"] as? Int) == 0 && ($0["unpacked"] as? Int) == 0 } ?? true
            out.set("ok", clOK && (file.map { $0["ok"] as? Bool == true } ?? true))
        }
        out.set("seconds", Py.round(Date().timeIntervalSince(started), 2))
        progress.set(key, 1)
        return out
    }

    /// Prüfsumme einer Datei stückweise (md5, sha1, sha256), hexadezimal.
    static func fileHash(_ url: URL, algorithm: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            switch algorithm {
            case "sha1": sha1.update(data: chunk)
            case "sha256": sha256.update(data: chunk)
            default: md5.update(data: chunk)
            }
        }
        let digest: [UInt8]
        switch algorithm {
        case "sha1": digest = Array(sha1.finalize())
        case "sha256": digest = Array(sha256.finalize())
        default: digest = Array(md5.finalize())
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Fortschritt und Abbruch zwischen den Rechen-Threads und dem Auftrag: Die Threads setzen nur Anteile und lesen den
/// Abbruch; `progress` und `isCancelled` des Aufrufers ruft allein der Auftrag (`VDRImport`).
final class VDRProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var weights: [String: Double] = [:]
    private var fractions: [String: Double] = [:]
    private var _cancelled = false

    func add(_ key: String, weight: Double) {
        lock.lock(); weights[key] = weight; fractions[key] = 0; lock.unlock()
    }

    func set(_ key: String, _ f: Double) {
        lock.lock(); fractions[key] = max(fractions[key] ?? 0, min(1, f)); lock.unlock()
    }

    var total: Double {
        lock.lock(); defer { lock.unlock() }
        let w = weights.values.reduce(0, +)
        return w > 0 ? weights.reduce(0) { $0 + $1.value * (fractions[$1.key] ?? 0) } / w : 0
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Rechnen und Lesen wie Python, damit die Dateien zu denen aus Windows passen (`round` mit korrekter Dezimalrundung,
/// `numpy.percentile` linear, `str.strip`, `int()`, `float()`, Ganzzahl-Teilung mit Abrunden, UTC-Tage).
enum Py {
    private static let powers: [Double] = (0...22).map { pow(10, Double($0)) }

    /// `round(x, n)`: auf n Nachkommastellen, korrekt gerundet am exakten Binärwert, halbe Werte zur geraden Ziffer.
    static func round(_ x: Double, _ n: Int) -> Double {
        guard x.isFinite, n >= 0, n <= 22 else { return x }
        let p = powers[n]
        let y = x * p
        guard abs(y) < 4.0e15 else { return x }
        let fl = y.rounded(.down)
        let frac = y - fl
        // eindeutig, wenn der Rest klar von 0,5 weg liegt (Fehler von x·10ⁿ höchstens eine halbe Stelle)
        if abs(frac - 0.5) > abs(y) * 4e-16 + 1e-300 {
            let r = frac > 0.5 ? fl + 1 : fl
            return r / p
        }
        // knapp an der Hälfte: über die genaue Dezimaldarstellung
        let s = String(format: "%.\(n)f", x)
        return Double(s) ?? x
    }

    /// numpy.percentile (linear) auf sortierten Werten.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return .nan }
        let quant = q / 100
        let vi = Double(n) * quant + (1 + quant * (1 - 1 - 1)) - 1
        var prev = vi.rounded(.down)
        var next = prev + 1
        if vi >= Double(n - 1) { prev = -1; next = -1 }
        if vi < 0 { prev = 0; next = 0 }
        let gamma = vi - prev
        let a = sorted[prev < 0 ? n - 1 : Int(prev)]
        let b = sorted[next < 0 ? n - 1 : min(n - 1, Int(next))]
        let diff = b - a
        return gamma >= 0.5 ? b - diff * (1 - gamma) : a + diff * gamma
    }

    /// numpy.median auf sortierten Werten.
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Python `a // b` für Gleitkommazahlen.
    static func floorDiv(_ vx: Double, _ wx: Double) -> Double {
        var mod = fmod(vx, wx)
        var div = (vx - mod) / wx
        if mod != 0 {
            if (wx < 0) != (mod < 0) {
                mod += wx
                div -= 1
            }
        }
        if div != 0 {
            var fl = div.rounded(.down)
            if div - fl > 0.5 { fl += 1 }
            return fl
        }
        return (vx / wx).sign == .minus ? -0.0 : 0.0
    }

    /// Leerzeichen wie `str.isspace` im Latin-1-Bereich
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0: return true
        default: return u.properties.isWhitespace
        }
    }

    static func strip(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let a = scalars.firstIndex(where: { !isSpace($0) }) else { return "" }
        let b = scalars.lastIndex(where: { !isSpace($0) })!
        return String(scalars[a...b])
    }

    /// `int(s)` für Dezimalzahlen: Leerzeichen außen, Vorzeichen, Ziffern (Unterstriche zwischen Ziffern).
    static func int(_ s: String, radix: Int = 10) -> Int? {
        var t = Substring(strip(s))
        var neg = false
        if t.first == "+" || t.first == "-" {
            neg = t.first == "-"
            t = t.dropFirst()
        }
        if radix == 16, t.lowercased().hasPrefix("0x") { t = t.dropFirst(2) }
        guard !t.isEmpty, !t.hasPrefix("_"), !t.hasSuffix("_"), !t.contains("__") else { return nil }
        let digits = t.filter { $0 != "_" }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let v = Int(digits, radix: radix) else { return nil }
        return neg ? -v : v
    }

    /// `float(s)`: wie Python (Leerzeichen außen erlaubt, keine Hexadezimal-Schreibweise).
    static func float(_ s: String) -> Double? {
        let t = strip(s)
        guard !t.isEmpty, !t.contains("x"), !t.contains("X") else { return nil }
        if let d = Double(t) { return d }
        if t.contains("_") {
            // Unterstriche nur zwischen Ziffern
            let chars = Array(t)
            for (i, c) in chars.enumerated() where c == "_" {
                guard i > 0, i < chars.count - 1, chars[i - 1].isNumber, chars[i + 1].isNumber else { return nil }
            }
            return Double(t.replacingOccurrences(of: "_", with: ""))
        }
        return nil
    }

    /// Tage seit 1970-01-01 für (Jahr, Monat, 1) + Tag − 1, wie `calendar.timegm` (Tag ungeprüft, Monat 1–12).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int? {
        guard (1...12).contains(m), (1...9999).contains(y0) else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468 + d - 1
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
