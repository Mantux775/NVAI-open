import CryptoKit
import Foundation
import zlib

/// Ein Ereignis der Zeitleiste (events.json): Zeiten in Sekunden ab Aufnahmebeginn; Zustände bekommen ein Ende.
final class VDREvent {
    var t: Double
    var end: Double?
    var kind: String
    var label: String
    var detail: String
    var source: String
    var open = false

    init(t: Double, end: Double? = nil, kind: String, label: String, detail: String, source: String) {
        self.t = t
        self.end = end
        self.kind = kind
        self.label = label
        self.detail = detail
        self.source = source
    }

    var json: JSONObject {
        var o = JSONObject(["t": t, "end": end, "kind": kind, "label": label, "detail": detail, "source": source])
        if open { o.set("open", true) }
        return o
    }

    /// stabil nach (t, Art) sortieren wie `list.sort(key=lambda e: (e["t"], e["kind"]))`
    static func sorted(_ list: [VDREvent]) -> [VDREvent] {
        list.enumerated().sorted { a, b in
            if a.element.t != b.element.t { return a.element.t < b.element.t }
            if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// Ereignisliste wie `vdr.Events`; Zustände mit Anfang und Ende über einen Schlüssel.
final class VDREvents {
    private(set) var items: [VDREvent] = []
    private var open: [String: VDREvent] = [:]

    @discardableResult
    func point(_ t: Double, _ kind: String, _ label: String, _ detail: String = "", _ source: String = "") -> VDREvent {
        let ev = VDREvent(t: Py.round(t, 3), kind: kind, label: label, detail: detail, source: source)
        items.append(ev)
        return ev
    }

    @discardableResult
    func start(_ key: String, _ t: Double, _ kind: String, _ label: String, _ detail: String = "", _ source: String = "") -> VDREvent {
        stop(key, t)
        let ev = point(t, kind, label, detail, source)
        open[key] = ev
        return ev
    }

    @discardableResult
    func stop(_ key: String, _ t: Double) -> VDREvent? {
        guard let ev = open.removeValue(forKey: key) else { return nil }
        ev.end = Py.round(max(t, ev.t), 3)
        return ev
    }

    func finish(_ tEnd: Double) {
        // in der Reihenfolge des Öffnens (wie ein Python-dict)
        for ev in items where open.values.contains(where: { $0 === ev }) {
            ev.end = Py.round(max(tEnd, ev.t), 3)
            ev.open = true
        }
        open = [:]
    }
}

/// Daten eines VDR-Exports (seit 0.5.11), wie `task_data` in `server/nvai/vdr.py`: ein Durchlauf über alle Blöcke mit
/// NMEA (Reihen je Sekunde, Alarme, Telegraf, Autopilot, AIS), sporadic (Digital/Analog), alarmblock (Ereignisprotokoll
/// des VDR), attachedinfo (Karteninfo) und Wechsel der Konfiguration. Schreibt data/series.json und data/ais.json und
/// gibt die Ereignisse und Kennzahlen zurück. Texte in der Sprache des Auftrags.
final class VDRData {
    struct Result {
        var events: [VDREvent]
        /// „data“ in vdr.json (ohne Ereignisse und Karteninfo)
        var info: JSONObject
        var ecdis: JSONObject
    }

    static let ticksPerSecond = 192_500.0

    /// Reihen: Schlüssel → (Deutsch, Englisch, Einheit, Nachkommastellen, Halten)
    static let seriesMeta: [String: (String, String, String, Int, Bool)] = [
        "lat": ("Breite", "Latitude", "°", 6, false), "lon": ("Länge", "Longitude", "°", 6, false),
        "sog": ("Geschwindigkeit über Grund", "Speed over ground", "kn", 2, false),
        "cog": ("Kurs über Grund", "Course over ground", "°", 1, false),
        "hdg": ("Steuerkurs (Kreisel)", "Heading (gyro)", "°", 1, false),
        "rot": ("Drehrate", "Rate of turn", "°/min", 1, false),
        "stw": ("Geschwindigkeit durchs Wasser", "Speed through water", "kn", 2, false),
        "depth": ("Wassertiefe unter Schwinger", "Depth below transducer", "m", 1, false),
        "rudder": ("Ruderlage", "Rudder angle", "°", 1, false),
        "rudder_order": ("Ruderbefehl (Autopilot)", "Rudder order (autopilot)", "°", 1, false),
        "heading_order": ("Sollkurs (Autopilot)", "Heading order (autopilot)", "°", 1, false),
        "rpm": ("Drehzahl", "Engine speed", "1/min", 1, false),
        "pitch": ("Propellersteigung", "Propeller pitch", "%", 1, false),
        "rpm_order": ("Drehzahlvorgabe", "RPM order", "1/min", 1, false),
        "pitch_order": ("Steigungsvorgabe", "Pitch order", "%", 1, false),
        "wind_rel_dir": ("Wind relativ, Richtung", "Relative wind direction", "°", 0, false),
        "wind_rel_speed": ("Wind relativ, Stärke", "Relative wind speed", "kn", 1, false),
        "wind_true_dir": ("Wind wahr, Richtung", "True wind direction", "°", 0, false),
        "wind_true_speed": ("Wind wahr, Stärke", "True wind speed", "kn", 1, false),
        "telegraph_order": ("Maschinentelegraf Befehl", "Engine telegraph order", "Stufe/step", 0, true),
        "telegraph_answer": ("Maschinentelegraf Antwort", "Engine telegraph answer", "Stufe/step", 0, true),
    ]
    static let telegraph: [String: (Int, String, String)] = [
        "00": (0, "Stopp", "Stop"), "01": (1, "Voraus äußerst langsam", "Ahead dead slow"),
        "02": (2, "Voraus langsam", "Ahead slow"), "03": (3, "Voraus halbe", "Ahead half"),
        "04": (4, "Voraus voll", "Ahead full"), "05": (5, "Voraus volle Seefahrt", "Ahead navigation full"),
        "11": (-1, "Zurück äußerst langsam", "Astern dead slow"), "12": (-2, "Zurück langsam", "Astern slow"),
        "13": (-3, "Zurück halbe", "Astern half"), "14": (-4, "Zurück voll", "Astern full"),
        "15": (-5, "Zurück äußerste Kraft", "Astern crash/emergency full"),
    ]
    static let subTelegraph: [String: (String, String)] = [
        "20": ("Maschine klar (S/B)", "Stand-by engine (S/B)"), "30": ("Seefahrt (F/A)", "Full away (F/A)"),
        "40": ("Maschine fertig (F/E)", "Finished with engine (F/E)"),
    ]
    static let location: [String: (String, String)] = [
        "B": ("Brücke", "bridge"), "P": ("Nock Backbord", "port wing"), "S": ("Nock Steuerbord", "starboard wing"),
        "C": ("Maschinenkontrollraum", "engine control room"), "E": ("Maschine vor Ort", "engine side"), "W": ("Nock", "wing"),
    ]
    static let steering: [String: (String, String)] = [
        "M": ("Handsteuerung", "manual steering"), "S": ("Kursregelung (eigenständig)", "stand-alone heading control"),
        "H": ("Kursregelung", "heading control"), "T": ("Bahnregelung", "track control"), "R": ("Ruderregelung", "rudder control"),
    ]
    static let navStatus = ["under way using engine", "at anchor", "not under command", "restricted manoeuvrability",
                            "constrained by draught", "moored", "aground", "engaged in fishing", "under way sailing",
                            "reserved (HSC)", "reserved (WIG)", "power-driven towing astern", "power-driven pushing ahead",
                            "reserved", "AIS-SART/MOB/EPIRB active", "undefined"]
    static let wind: [String: Double] = ["N": 1.0, "K": 1 / 1.852, "M": 1.9438445, "S": 0.8689762]

    private struct FieldError: Error {}

    private let de: Bool
    private let t0: Int
    private let nSec: Int
    private let duration: Double
    private var serialNames: [Int: String] = [:]
    private var digitalOrder: [Int] = []
    private var digital: [Int: [String: Any]] = [:]
    private var analogOrder: [Int] = []
    private var analog: [Int: [String: Any]] = [:]
    private var seriesKeys: [String] = []
    private var series: [String: [Double?]] = [:]
    private var holdKeys: [String] = []
    private var hold: [String: [(Double, Double?)]] = [:]
    private let ev = VDREvents()
    private let ais: VDRAIS
    private var counts = JSONObject()
    private var badChecksum = JSONObject()
    private var clock: [Double] = []
    private var ecdis = JSONObject()
    private var ecdisLast: [String: [String: String]] = [:]
    private var cfgCRC: UInt32?
    private var cfgChanges: [JSONObject] = []
    private var verSeen: [String: String] = [:]
    private var alarmState: [String: (active: Bool, ack: String, ev: VDREvent)] = [:]
    private var etlState: [String: (String, String, String)] = [:]
    private var htdMode: String?
    private var htdOverride: String?
    private var htdHeading: Double?
    private var htdEvent: VDREvent?
    private var hbtState: [String: String] = [:]
    private var digState: [Int: (Int?, Bool)] = [:]
    private var digPointsOrder: [Int] = []
    private var digPoints: [Int: [(Double, Double?)]] = [:]
    private var anaValid: [Int: Bool] = [:]
    private var prevTick: Int?
    private var invalidSince: Double?
    private var spRecords = 0, spBlocks = 0, spFrozen = 0
    private var syslogOpen: [String: VDREvent] = [:]
    private var syslogOrder: [String] = []
    private var alertOpen: [String: VDREvent] = [:]
    private var alertOrder: [String] = []
    private var linesTotal = 0
    private var unreadable: [Int] = []

    private func L(_ de: String, _ en: String) -> String { self.de ? de : en }

    init(t0: Int, duration: Double, config: [String: Any], lang: Lang) {
        de = lang == .de
        self.t0 = t0
        self.duration = duration
        // Reihen je Sekunde: begrenzt wie `VDR.checkTimes` (eine verstellte Uhr ergab sonst Reihen über Jahre und Int()
        // stürzte bei unendlicher Dauer ab)
        nSec = Int((duration.isFinite ? min(max(duration, 0), Double(VDR.maxSpanSeconds)) : 0).rounded(.up)) + 1
        for d in config["serial"] as? [[String: Any]] ?? [] {
            serialNames[d["channel"] as? Int ?? 0] = d["name"] as? String ?? ""
        }
        for d in config["digital"] as? [[String: Any]] ?? [] {
            let c = d["channel"] as? Int ?? 0
            if digital[c] == nil { digitalOrder.append(c) }
            digital[c] = d
        }
        for d in config["analog"] as? [[String: Any]] ?? [] {
            let c = d["channel"] as? Int ?? 0
            if analog[c] == nil { analogOrder.append(c) }
            analog[c] = d
        }
        let vessel = config["vessel"] as? [String: Any] ?? [:]
        ais = VDRAIS(ownMMSI: vessel["mmsi"] as? String ?? "", de: lang == .de)
    }

    // MARK: Durchlauf

    static func run(blocks: [VDR.Block], t0: Int, duration: Double, config: [String: Any], dataDir: URL, lang: Lang,
                    progress: VDRProgress, key: String) throws -> Result {
        let d = VDRData(t0: t0, duration: duration, config: config, lang: lang)
        let want: (String) -> Bool = {
            ["serial", "sporadic", "alarmblock", "configure", "vdr_version", "vlc1_version", "vlc2_version"].contains($0)
                || $0.hasPrefix("attachedinfo")
        }
        for (k, b) in blocks.enumerated() {
            if progress.cancelled { throw CancellationError() }
            guard let blk = try? VDR.readBlock(b, want: want) else {
                d.unreadable.append(b.id)
                continue
            }
            autoreleasepool { d.block(b, blk) }
            if k % 25 == 0 { progress.set(key, Double(k + 1) / Double(blocks.count)) }
        }
        return try d.finish(dataDir: dataDir)
    }

    private func block(_ b: VDR.Block, _ blk: [String: Data]) {
        let tb = Double(b.start - t0)
        // Konfiguration und Versionen je Block vergleichen (gleich in jedem Block erwartet)
        if let c = blk["configure"], !c.isEmpty {
            let crc = c.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt($0.count))) }
            if let cfgCRC, crc != cfgCRC {
                cfgChanges.append(JSONObject(["t": b.start - t0, "block": b.id]))
                ev.point(tb, "system", L("Konfiguration des VDR geändert", "VDR configuration changed"), "", "VDR")
            }
            cfgCRC = crc
        }
        for vn in ["vdr_version", "vlc1_version", "vlc2_version"] {
            guard let v = blk[vn], !v.isEmpty else { continue }
            let h = Insecure.MD5.hash(data: v).map { String(format: "%02x", $0) }.joined()
            if let seen = verSeen[vn], seen != h {
                ev.point(tb, "system", L("Version geändert (\(vn))", "Version changed (\(vn))"), "", "VDR")
            }
            verSeen[vn] = h
        }
        // ---- serielle Daten
        if let serial = blk["serial"] {
            serial.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var a = 0
                while a <= bytes.count {
                    var e = a
                    while e < bytes.count && bytes[e] != 0x0A { e += 1 }
                    serialLine(UnsafeBufferPointer(rebasing: bytes[a..<e]))
                    a = e + 1
                }
            }
        }
        // ---- sporadic: Digital/Analog
        if let spd = blk["sporadic"], !spd.isEmpty, let sp = VDRSporadic(spd) { sporadic(sp, tb: tb) }
        // ---- alarmblock: Ereignisprotokoll des VDR
        if let alarm = blk["alarmblock"] {
            for line in VDR.latin1(alarm).split(separator: "\n", omittingEmptySubsequences: false) {
                let ln = String(line)
                if !Py.strip(ln).isEmpty { syslog(ln, tBlock: b.start) }
            }
        }
        // ---- attachedinfo: Zusatzangaben je Bildquelle (Karten der ECDIS)
        for (name, data) in blk.sorted(by: { $0.key < $1.key }) where name.hasPrefix("attachedinfo") && data.count >= 8 {
            var kv = JSONObject()
            var plain: [String: String] = [:]
            for line in VDR.latin1(data.subdata(in: (data.startIndex + 8)..<data.endIndex)).components(separatedBy: "\r\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = Py.strip(String(line[..<eq])), v = Py.strip(String(line[line.index(after: eq)...]))
                kv.set(k, v)
                plain[k] = v
            }
            var lst = ecdis[name] as? [Any] ?? []
            if lst.isEmpty || ecdisLast[name] != plain {
                lst.append([b.start - t0, kv] as [Any])
                ecdis.set(name, lst)
                ecdisLast[name] = plain
            }
        }
    }

    // MARK: NMEA

    private func count(_ key: String, in obj: inout JSONObject) {
        obj.set(key, (obj[key] as? Int ?? 0) + 1)
    }

    private func srcName(_ chan: Int?) -> String {
        let nm = chan.flatMap { serialNames[$0] } ?? ""
        return "\(L("Seriell", "Serial")) \(chan.map(String.init) ?? "None")" + (nm.isEmpty ? "" : " (\(nm))")
    }

    /// „<präfix>:<c9,1000XX,1>:…|TT/MM/JJJJ hh:mm:ss.mmm $…“ → (Unix-Zeit, serieller Kanal, Satz), wie `parse_serial_line`.
    static func parseSerial(_ ln: UnsafeBufferPointer<UInt8>) -> (Double, Int?, String)? {
        guard let bar = ln.firstIndex(of: 0x7C), ln.count >= bar + 25 else { return nil }
        var chan: Int?
        if let lt = ln[..<bar].firstIndex(of: 0x3C), let gt = ln[lt..<bar].firstIndex(of: 0x3E), gt > lt {
            let tag = latin1(ln[(lt + 1)..<gt]).split(separator: ",", omittingEmptySubsequences: false)
            if tag.count > 1, let v = Py.int(String(tag[1]), radix: 16) { chan = v - 0x100000 }
        }
        let ts = latin1(ln[(bar + 1)..<(bar + 24)])
        let c = Array(ts.unicodeScalars)
        func part(_ a: Int, _ b: Int) -> Int? { Py.int(String(String.UnicodeScalarView(c[a..<b]))) }
        guard c.count == 23, let year = part(6, 10), let month = part(3, 5), let day = part(0, 2), let hh = part(11, 13),
              let mm = part(14, 16), let ss = part(17, 19), let ms = part(20, 23),
              let days = Py.daysFromCivil(year, month, day) else { return nil }
        let t = Double(days * 86400 + hh * 3600 + mm * 60 + ss) + Double(ms) / 1000
        var s = latin1(ln[(bar + 25)...])
        while let last = s.unicodeScalars.last, last == "\r" || last == "\n" { s.unicodeScalars.removeLast() }
        return (t, chan, s)
    }

    static func latin1(_ b: Slice<UnsafeBufferPointer<UInt8>>) -> String {
        if b.allSatisfy({ $0 < 0x80 }) { return String(decoding: b, as: UTF8.self) }
        return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    /// Prüfsumme; nil, wenn keine angehängt ist (`_nmea_ok`).
    static func nmeaOK(_ s: [Unicode.Scalar]) -> Bool? {
        guard let star = s.lastIndex(of: "*"), s.count >= star + 3 else { return nil }
        var x: UInt32 = 0
        for ch in s[1..<max(1, star)] { x ^= ch.value }
        guard let v = Py.int(String(String.UnicodeScalarView(s[(star + 1)..<(star + 3)])), radix: 16) else { return false }
        return Int(x) == v
    }

    private func serialLine(_ ln: UnsafeBufferPointer<UInt8>) {
        // Leerzeilen (auch nur Leerzeichen) überspringen
        guard ln.contains(where: { !Py.isSpace(Unicode.Scalar($0)) }) else { return }
        guard let (tAbs, chan, s) = Self.parseSerial(ln) else {
            count("unparsed", in: &counts)
            return
        }
        linesTotal += 1
        let t = tAbs - Double(t0)
        let u = Array(s.unicodeScalars)
        guard u.count >= 6, u[0] == "$" || u[0] == "!" else { return }
        let ok = Self.nmeaOK(u)
        let prop = u[1] == "P"
        let fmt = String(String.UnicodeScalarView(prop ? u[1..<5] : u[3..<6]))
        let talker = prop ? "P" : String(String.UnicodeScalarView(u[1..<3]))
        let chanText = chan.map(String.init) ?? "None"
        let ckey = prop ? "\(chanText):\(fmt)" : "\(chanText):\(talker)\(fmt)"
        count(ckey, in: &counts)
        if ok == false {
            count(ckey, in: &badChecksum)
            return
        }
        let star = u.lastIndex(of: "*")
        let body = star.map { $0 > 0 ? u[1..<$0] : u[1...] } ?? u[1...]
        let f = String(String.UnicodeScalarView(body)).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let src = srcName(chan)
        do {
            try sentence(fmt, f, t: t, tAbs: tAbs, chan: chan, talker: talker, src: src)
        } catch {
            count("field_errors", in: &counts)
        }
    }

    private func put(_ key: String, _ tRel: Double, _ v: Double?, _ nd: Int) throws {
        guard let v else { return }
        let i = Int(tRel)   // int() schneidet ab
        guard i >= 0 && i < nSec else { return }
        let value: Double
        if nd > 0 {
            value = Py.round(v, nd)
        } else {
            guard v.isFinite else { throw FieldError() }   // int(round(nan)) → ValueError
            value = v.rounded(.toNearestOrEven)
        }
        if series[key] == nil {
            seriesKeys.append(key)
            series[key] = [Double?](repeating: nil, count: nSec)
        }
        series[key]![i] = value
    }

    private func f(_ x: String) -> Double? { Py.float(x) }

    /// NMEA Grad/Minuten („5330.5000“, N = 53,508333°) → Dezimalgrad (`_dm`).
    private func dm(_ v: String, _ hemi: String) throws -> Double? {
        guard let x = Py.float(v) else { return nil }
        guard x.isFinite else { throw FieldError() }
        let deg = Py.floorDiv(x, 100)
        guard deg.isFinite else { throw FieldError() }
        let val = deg + (x - deg * 100) / 60
        return hemi == "S" || hemi == "W" ? -val : val
    }

    private func sentence(_ fmt: String, _ f: [String], t: Double, tAbs: Double, chan: Int?, talker: String, src: String) throws {
        let n = f.count
        switch fmt {
        case "RMC" where n > 8 && f[2] == "A":
            try put("lat", t, dm(f[3], f[4]), 6)
            try put("lon", t, dm(f[5], f[6]), 6)
            try put("sog", t, self.f(f[7]), 2)
            try put("cog", t, self.f(f[8]), 1)
        case "GGA" where n > 6 && f[6] != "" && f[6] != "0":
            try put("lat", t, dm(f[2], f[3]), 6)
            try put("lon", t, dm(f[4], f[5]), 6)
        case "GLL" where n > 6 && f[6] == "A":
            try put("lat", t, dm(f[1], f[2]), 6)
            try put("lon", t, dm(f[3], f[4]), 6)
        case "VTG" where n > 7 && (n < 10 || f[9] != "N"):
            try put("cog", t, self.f(f[1]), 1)
            try put("sog", t, self.f(f[5]), 2)
        case "HDT" where n > 1, "THS" where n > 1:
            if fmt == "HDT" || (n > 2 && f[2] == "A") { try put("hdg", t, self.f(f[1]), 1) }
        case "ROT" where n > 2 && f[2] == "A":
            try put("rot", t, self.f(f[1]), 1)
        case "VHW" where n > 5:
            try put("stw", t, self.f(f[5]), 2)
        case "VBW" where n > 3 && f[3] == "A" && series["stw"] == nil:
            try put("stw", t, self.f(f[1]), 2)
        case "DPT" where n > 1:
            try put("depth", t, self.f(f[1]), 1)
        case "RSA" where n > 2 && f[2] == "A":
            try put("rudder", t, self.f(f[1]), 1)
        case "HTD" where n > 10, "HTC" where n > 10:
            if let ang = self.f(f[2]) { try put("rudder_order", t, f[3] == "L" ? -ang : ang, 1) }
            try put("heading_order", t, self.f(f[10]), 1)
            autopilot(t, f, src)
        case "RPM" where n > 5 && f[5] == "A" && ["0", "1", ""].contains(f[2]):
            try put("rpm", t, self.f(f[3]), 1)
            try put("pitch", t, self.f(f[4]), 1)
        case "PRC" where n > 6:
            if f[4] != "V" && f[4] != "" { try put("rpm_order", t, self.f(f[3]), 1) }
            if f[6] != "V" && f[6] != "" { try put("pitch_order", t, self.f(f[5]), 1) }
        case "MWV" where n > 5 && f[5] == "A":
            var ws = self.f(f[3])
            if let w = ws { ws = w * (Self.wind[f[4]] ?? 1.0) }
            if f[2] == "R" {
                try put("wind_rel_dir", t, self.f(f[1]), 0)
                try put("wind_rel_speed", t, ws, 1)
            } else if f[2] == "T" {
                try put("wind_true_dir", t, self.f(f[1]), 0)
                try put("wind_true_speed", t, ws, 1)
            }
        case "ETL" where n > 6:
            try telegraphSentence(t, f, src)
        case "ZDA" where n > 4:
            let hhmmss = Array(f[1].unicodeScalars)
            if hhmmss.count >= 6 && !f[2].isEmpty && !f[3].isEmpty && !f[4].isEmpty {
                let s = { (a: Int, b: Int?) in String(String.UnicodeScalarView(hhmmss[a..<(b ?? hhmmss.count)])) }
                guard let y = Py.int(f[4]), let m = Py.int(f[3]), let d = Py.int(f[2]), let days = Py.daysFromCivil(y, m, d),
                      let hh = Py.int(s(0, 2)), let mi = Py.int(s(2, 4)), let sec = Py.float(s(4, nil)) else { throw FieldError() }
                let g = Double(days * 86400 + hh * 3600 + mi * 60) + sec
                clock.append(g - tAbs)
            }
        case "ALR" where n > 4:
            alarmALR(t, chan, talker, f, src)
        case "ALA" where n > 7:
            alarmALA(t, chan, f, src)
        case "ALF" where n > 13:
            alertALF(t, chan, f, src)
        case "ACN" where n > 5:
            ev.point(t, "alert", L("Befehl an Alarm", "Alert command") + " \(f[2]) \(f[3])",
                     L("Befehl", "command") + " \(f[5]), " + L("Zustand", "state") + " \(n > 6 ? f[6] : "")", src)
        case "ACK" where n > 1:
            ev.point(t, "alarm", L("Alarm quittiert", "Alarm acknowledged") + " \(f[1])", "", src)
        case "TXT" where n > 3, "EVE" where n > 3:
            // TXT: anzahl, nummer, kennung, text; EVE: zeit, kennung, text
            let msg = fmt == "TXT" && n > 4 ? f[4] : (fmt == "EVE" ? f[3] : f[n - 1])
            let detail = String(f[1...].joined(separator: ",").unicodeScalars.prefix(300))
            ev.point(t, "text", Py.strip("\(talker)\(fmt): \(msg)"), String(String.UnicodeScalarView(detail.unicodeScalars)), src)
        case "HBT" where n > 2:
            let hk = "\(chan.map(String.init) ?? "None")|\(talker)"
            if (hbtState[hk] ?? "A") != f[2] {
                ev.point(t, "system", L("Lebenszeichen geändert", "Heartbeat status changed") + ": \(talker) \(f[2])", "", src)
            }
            hbtState[hk] = f[2]
        case "VDM", "VDO":
            ais.feed(t, chan, f, own: fmt == "VDO", ev: ev)
        default:
            break
        }
    }

    private func fmt1(_ x: Double) -> String { String(format: "%.1f", x) }

    private func autopilot(_ t: Double, _ f: [String], _ src: String) {
        let mode = f[4]
        if !mode.isEmpty && mode != htdMode {
            let prev = htdMode
            let name = Self.steering[mode] ?? (mode, mode)
            let was: String
            if let prev, !prev.isEmpty {
                let p = Self.steering[prev] ?? (prev, prev)
                was = L("vorher", "was") + " \(L(p.0, p.1))"
            } else {
                was = L("Stand bei Aufnahmebeginn", "state at start of recording")
            }
            ev.point(t, "autopilot", L("Steuerart", "Steering mode") + ": \(L(name.0, name.1))", was + " (HTD \(mode))", src)
            htdMode = mode
        }
        if !f[1].isEmpty && f[1] != htdOverride {
            if htdOverride != nil {
                ev.point(t, "autopilot", L("Übersteuerung", "Override") + (f[1] == "A" ? L(" aktiv", " active") : L(" aus", " off")),
                         "HTD \(f[1])", src)
            }
            htdOverride = f[1]
        }
        let hd = Py.float(f[10])
        if let hd {
            let last = htdHeading
            let changed: Bool
            if let last {
                changed = abs(Py.mod(hd - last + 180, 360) - 180) >= 1.0
            } else {
                changed = true
            }
            if changed {
                if let pend = htdEvent, t - pend.t < 10 {
                    pend.label = L("Sollkurs", "Heading order") + " \(fmt1(hd))°"
                } else {
                    htdEvent = ev.point(t, "autopilot", L("Sollkurs", "Heading order") + " \(fmt1(hd))°",
                                        last.map { L("vorher", "was") + " \(fmt1($0))°" }
                                            ?? L("Stand bei Aufnahmebeginn", "state at start of recording"), src)
                }
                htdHeading = hd
            }
        }
    }

    private func telegraphSentence(_ t: Double, _ f: [String], _ src: String) throws {
        // $--ETL,zeit,O/A,stellung,unter-telegraf,ort,maschine
        let typ = f[2], pos = f[3], sub = f[4], loc = f[5], eng = f[6]
        guard typ == "O" || typ == "A" else { return }
        if let tg = Self.telegraph[pos] { try put(typ == "O" ? "telegraph_order" : "telegraph_answer", t, Double(tg.0), 0) }
        let key = "\(typ)|\(eng)"
        if let st = etlState[key], st == (pos, sub, loc) { return }
        let first = etlState[key] == nil
        etlState[key] = (pos, sub, loc)
        let what = typ == "O" ? L("Maschinentelegraf Befehl", "Engine telegraph order") : L("Maschinentelegraf Antwort", "Engine telegraph answer")
        let lab = Self.telegraph[pos].map { L($0.1, $0.2) } ?? (pos.isEmpty ? "–" : pos)
        var det: [String] = []
        if let s = Self.subTelegraph[sub] { det.append(L(s.0, s.1)) }
        if let l = Self.location[loc] { det.append(L(l.0, l.1)) }
        if eng != "" && eng != "0" { det.append(L("Maschine", "engine") + " \(eng)") }
        if first { det.append(L("erster Wert der Aufnahme", "first value in the recording")) }
        ev.point(t, "telegraph", "\(what): \(lab)", det.joined(separator: ", ") + " (ETL \(pos),\(sub),\(loc))", src)
    }

    private func acked(_ ack: String) -> String { ack == "A" ? L("quittiert", "acknowledged") : L("nicht quittiert", "not acknowledged") }

    private func alarmALR(_ t: Double, _ chan: Int?, _ talker: String, _ f: [String], _ src: String) {
        // $--ALR,zeit,nummer,zustand A/V,quittung A/V,text
        let num = f[2]
        guard !num.isEmpty else { return }
        let key = "ALR|\(chan.map(String.init) ?? "None")|\(talker)|\(num)"
        let active = f[3] == "A"
        let ack = f[4]
        let text = Py.strip(f.count > 5 ? f[5] : "")
        let cur = alarmState[key]
        if active && (cur == nil || !cur!.active) {
            let e = ev.start(key, t, "alarm", text.isEmpty ? L("Alarm \(num)", "Alarm \(num)") : text,
                             "\(talker)ALR \(num), " + acked(ack) + (f[1].isEmpty ? "" : ", \(L("Zeit im Satz", "time in sentence")) \(f[1])"), src)
            alarmState[key] = (true, ack, e)
        } else if active, let c = cur, c.ack != ack {
            if ack == "A" { c.ev.detail += "; \(L("quittiert bei", "acknowledged at")) \(fmt1(t)) s" }
            alarmState[key]!.ack = ack
        } else if !active, let c = cur, c.active {
            ev.stop(key, t)
            alarmState[key]!.active = false
        }
    }

    private func alarmALA(_ t: Double, _ chan: Int?, _ f: [String], _ src: String) {
        // $--ALA,zeit,system,teilsystem,instanz,typ,zustand,quittung,text  (Zustand N/V = normal, sonst Alarm)
        let key = "ALA|\(chan.map(String.init) ?? "None")|\(f[2])|\(f[3])|\(f[4])|\(f[5])"
        let active = !(f[6] == "N" || f[6] == "V" || f[6] == "")
        let ack = f[7]
        let text = f.count > 8 ? Py.strip(f[8]) : ""
        let cur = alarmState[key]
        if active && (cur == nil || !cur!.active) {
            let e = ev.start(key, t, "alarm", text.isEmpty ? "ALA \(f[2]) \(f[3]) \(f[4]) \(f[5])" : text,
                             "ALA \(f[2])/\(f[3])/\(f[4])/\(f[5]), \(L("Zustand", "condition")) \(f[6]), " + acked(ack)
                                + (f[1].isEmpty ? "" : ", \(L("Zeit im Satz", "time in sentence")) \(f[1])"), src)
            alarmState[key] = (true, ack, e)
        } else if active, let c = cur, c.ack != ack {
            if ack == "A" { c.ev.detail += "; \(L("quittiert bei", "acknowledged at")) \(fmt1(t)) s" }
            alarmState[key]!.ack = ack
        } else if !active, let c = cur, c.active {
            ev.stop(key, t)
            alarmState[key]!.active = false
        }
    }

    private func alertALF(_ t: Double, _ chan: Int?, _ f: [String], _ src: String) {
        // $--ALF,anzahl,nummer,folge,zeit,kategorie,priorität,zustand,hersteller,kennung,instanz,revision,eskalation,text
        guard f[2] == "1" || f[2] == "" else { return }
        let key = "ALF|\(chan.map(String.init) ?? "None")|\(f[8])|\(f[9])|\(f[10])"
        let state = f[7]
        let active = ["V", "S", "A", "O"].contains(state)
        let cur = alarmState[key]
        let text = f.count > 13 ? Py.strip(f[13]) : ""
        if active && (cur == nil || !cur!.active) {
            let e = ev.start(key, t, "alert", text.isEmpty ? "ALF \(f[8]) \(f[9])" : text,
                             "ALF \(f[8]) \(f[9]).\(f[10]), \(L("Priorität", "priority")) \(f[6]), \(L("Kategorie", "category")) \(f[5]), "
                                + "\(L("Zustand", "state")) \(state)", src)
            alarmState[key] = (true, state, e)
        } else if active, let c = cur, c.ack != state {
            c.ev.detail += "; \(state) \(L("bei", "at")) \(fmt1(t)) s"
            alarmState[key]!.ack = state
        } else if !active, let c = cur, c.active {
            ev.stop(key, t)
            alarmState[key]!.active = false
        }
    }

    // MARK: sporadic

    private func sporadic(_ sp: VDRSporadic, tb: Double) {
        spBlocks += 1
        let previous = prevTick
        let at = sp.clock(tBlock: tb, prevTick: previous)
        if previous != nil && previous == sp.tickEnd { spFrozen += 1 }
        prevTick = sp.tickEnd
        var anyInvalid = false
        for c in digitalOrder {
            let dd = digital[c]!
            for r in sp.chains[VDRSporadic.Key(111, 1, c)] ?? [] {
                spRecords += 1
                let t = at(r.sec, r.tick)
                let valid = r.flags & 0x4000 == 0
                anyInvalid = anyInvalid || !valid
                let st = digState[c]
                if let st, st.0 == r.value && st.1 == valid { continue }
                let name = (dd["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Digital \(c)"
                let src = "Digital \(c)"
                if digPoints[c] == nil { digPointsOrder.append(c) }
                digPoints[c, default: []].append((t, valid ? ((r.value ?? 0) != 0 ? 1 : 0) : nil))
                let valText = r.value.map(String.init) ?? "None"
                if valid {
                    let txt = (r.value ?? 0) != 0 ? (dd["state1"] as? String ?? "1") : (dd["state0"] as? String ?? "0")
                    ev.start("digital|\(c)", t, "digital", "\(name): \(txt)", L("Rohwert \(valText)", "raw value \(valText)")
                                + (st == nil ? L(", Zustand bei Aufnahmebeginn", ", state at start of recording") : ""), src)
                } else {
                    ev.start("digital|\(c)", t, "digital", "\(name): " + L("kein gültiges Signal", "no valid signal"),
                             L("Eingang meldet ungültig (Merker 0x4000)", "input flagged invalid (flag 0x4000)"), src)
                }
                digState[c] = (r.value, valid)
            }
        }
        for c in analogOrder {
            let ad = analog[c]!
            let keyS = "analog_\(c)"
            for r in sp.chains[VDRSporadic.Key(110, 1, c)] ?? [] {
                spRecords += 1
                let t = at(r.sec, r.tick)
                let valid = r.flags & 0x4000 == 0
                anyInvalid = anyInvalid || !valid
                if (anaValid[c] ?? true) != valid {
                    if !valid {
                        let name = (ad["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Analog \(c)"
                        ev.start("analog|\(c)", t, "analog", "\(name): " + L("kein gültiger Wert", "no valid value"), "", "Analog \(c)")
                    } else {
                        ev.stop("analog|\(c)", t)
                    }
                }
                anaValid[c] = valid
                guard let raw = r.value else { continue }
                var v = raw & 0xFFFF
                if v & 0x8000 != 0 { v -= 0x10000 }
                if hold[keyS] == nil { holdKeys.append(keyS) }
                hold[keyS, default: []].append((t, valid ? Double(v) : nil))
            }
        }
        if anyInvalid && invalidSince == nil {
            invalidSince = tb
            ev.start("sporadic_invalid", tb, "system", L("Digital-/Analogeingänge ohne gültige Daten", "Digital/analog inputs without valid data"),
                     L("Merker 0x4000 an den Eingängen (Verbindung zur Anschlussbox?)", "flag 0x4000 on the inputs (junction box link?)"),
                     "sporadic")
        } else if !anyInvalid && invalidSince != nil {
            ev.stop("sporadic_invalid", tb)
            invalidSince = nil
        }
    }

    // MARK: alarmblock

    private static let syslogRegex = try! NSRegularExpression(
        pattern: "^(\\d+)/(\\d+)/(\\d+)/(\\d+)/(\\d+)/(\\d+)/(\\d+)/(\\d+):<([^>]*)>:[^|]*\\|(.*)$", options: [.dotMatchesLineSeparators])

    /// alarmblock: „JJJ/MM/TT/hh/mm/ss/mmm/folge:<typ,quelle,…>:…|feld|feld|…|“, Typ 0x1f4 = Alarm des VDR, 0xd3 = Protokoll.
    /// Datum aus dem Block, Uhrzeit aus dem Präfix (`_syslog`).
    private func syslog(_ line: String, tBlock: Int) {
        let ln = Py.strip(line)
        guard let m = Self.syslogRegex.firstMatch(in: ln, range: NSRange(ln.startIndex..., in: ln)) else { return }
        let g = (1...10).map { Range(m.range(at: $0), in: ln).map { String(ln[$0]) } ?? "" }
        guard let h = Py.int(g[3]), let mi = Py.int(g[4]), let s = Py.int(g[5]), let ms = Py.int(g[6]) else { return }
        let tod = Double(h * 3600 + mi * 60 + s) + Double(ms) / 1000
        let day0 = (tBlock / 86400) * 86400
        var tAbs = Double(day0) + tod
        if tAbs - Double(tBlock) > 43200 { tAbs -= 86400 } else if Double(tBlock) - tAbs > 43200 { tAbs += 86400 }
        let t = tAbs - Double(t0)
        let tag = g[8].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let parts = g[9].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let typ = tag[0].lowercased()
        if typ == "1f4" && parts.count >= 5 {
            // Alert|Text|Nummer|Zustand|Priorität   (A: aktiv, N: normal)
            let text = Py.strip(parts[1]), num = Py.strip(parts[2]), state = Py.strip(parts[3]), prio = Py.strip(parts[4])
            if state.hasPrefix("N") {
                if let d = alertOpen.removeValue(forKey: num) {
                    alertOrder.removeAll { $0 == num }
                    d.end = Py.round(max(t, d.t), 3)
                } else {
                    ev.point(t, "alert", text, "VDR \(num): \(state) (\(prio))", "VDR")
                }
            } else if alertOpen[num] == nil {
                alertOpen[num] = ev.point(t, "alert", text, "VDR \(num): \(state) (\(prio))", "VDR")
                alertOrder.append(num)
            }
        } else {
            let cat = parts.isEmpty ? "" : Py.strip(parts[0])
            let what = parts.count > 1 ? Py.strip(parts[1]) : ""
            let rest = parts.dropFirst(2).map { Py.strip($0) }.filter { !$0.isEmpty }
            let key = "\(cat)|\(what)"
            if rest.first == "Occurrence" {
                if syslogOpen[key] == nil { syslogOrder.append(key) }
                syslogOpen[key] = ev.point(t, "system", "\(cat): \(what)", rest.joined(separator: " "), "VDR")
            } else if let r0 = rest.first, r0 == "Recovered" || r0 == "Recovery", let e = syslogOpen.removeValue(forKey: key) {
                syslogOrder.removeAll { $0 == key }
                e.end = Py.round(max(t, e.t), 3)
            } else {
                ev.point(t, "system", "\(cat): \(what)", rest.joined(separator: " · "), "VDR")
            }
        }
    }

    // MARK: Abschluss

    private func finish(dataDir: URL) throws -> Result {
        let tEnd = duration
        ev.finish(tEnd)
        for k in alertOrder { if let d = alertOpen[k], d.end == nil { d.end = tEnd; d.open = true } }
        for k in syslogOrder { if let d = syslogOpen[k], d.end == nil { d.end = tEnd; d.open = true } }
        // Digital- und Analogreihen: gespeichert wird nur bei Änderung → je Sekunde der letzte Wert, dazwischen halten
        var holdSeries: [(String, [(Double, Double?)])] = holdKeys.map { ($0, hold[$0]!) }
        holdSeries += digPointsOrder.map { ("digital_\($0)", digPoints[$0]!) }
        for (key, pts0) in holdSeries {
            let pts = pts0.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
                .map(\.element)
            var arr = [Double?](repeating: nil, count: nSec)
            var cur: Double?
            var j = 0
            for i in 0..<nSec {
                while j < pts.count && pts[j].0 < Double(i + 1) {
                    cur = pts[j].1
                    j += 1
                }
                arr[i] = cur
            }
            if series[key] == nil { seriesKeys.append(key) }
            series[key] = arr
        }
        var meta = JSONObject()
        for key in seriesKeys {
            let values = series[key]!
            var o = JSONObject()
            var isInt = false
            if let m = Self.seriesMeta[key] {
                o = JSONObject(["label_de": m.0, "label_en": m.1, "unit": m.2, "hold": m.4])
                isInt = m.3 == 0
            } else if key.hasPrefix("analog_"), let c = Int(key.dropFirst(7)), let ad = analog[c] {
                let label = "Analog \(c): \(ad["name"] as? String ?? "")"
                o = JSONObject(["label_de": label, "label_en": label, "unit": L("roh (16 bit)", "raw (16 bit)"), "hold": true])
                isInt = true
            } else if key.hasPrefix("digital_"), let c = Int(key.dropFirst(8)), let dd = digital[c] {
                let label = "Digital \(c): \(dd["name"] as? String ?? "")"
                o = JSONObject(["label_de": label, "label_en": label,
                                "unit": "1=\(dd["state1"] as? String ?? "1"), 0=\(dd["state0"] as? String ?? "0")", "hold": true])
                isInt = true
            }
            // ganzzahlige Reihen (Wind-Richtung, Telegraf, Digital, Analog-Rohwerte) wie in Python als int
            if isInt {
                o.set("values", values.map { $0.flatMap { $0.isFinite ? Int($0) : nil } } as [Int?])
            } else {
                o.set("values", values)
            }
            meta.set(key, o)
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try ForensicJSON.data(JSONObject(["t0_utc": t0, "dt": 1.0, "n": nSec, "series": meta]), compact: true)
            .write(to: dataDir.appendingPathComponent("series.json"), options: .atomic)
        try ForensicJSON.data(JSONObject(["own": ais.own, "targets": ais.targetsJSON, "messages": ais.counts]), compact: true)
            .write(to: dataDir.appendingPathComponent("ais.json"), options: .atomic)
        let events = VDREvent.sorted(ev.items)
        clock.sort()
        var gps = JSONObject(["n": clock.count])
        gps.set("median", clock.isEmpty ? nil : Py.round(clock[clock.count / 2], 3))
        gps.set("min", clock.first.map { Py.round($0, 3) })
        gps.set("max", clock.last.map { Py.round($0, 3) })
        let info = JSONObject([
            "counts": counts, "bad_checksum": badChecksum, "lines": linesTotal, "series": seriesKeys.sorted(),
            "ais_targets": ais.targetCount, "ais_messages": ais.counts, "ais_errors": ais.errors, "config_changes": cfgChanges,
            "unreadable": unreadable,
            "sporadic": JSONObject(["records": spRecords, "blocks": spBlocks, "frozen_blocks": spFrozen]),
            "gps_clock_offset_s": gps,
        ])
        return Result(events: events, info: info, ecdis: ecdis)
    }
}

// MARK: - sporadic

/// Digital-, Analog- und Statuswerte eines Blocks (`parse_sporadic`): Kopf (96 Byte), Kanaltabelle (Typ, Unterart, Kanal,
/// 16) × n, zwei Versatztabellen (erster und letzter Eintrag je Kanal), Einträge als verkettete Liste: u32 nächster
/// Eintrag (Bit 30: Wert folgt), u16 Kanalindex, u16 Merker, u32 Sekunde (VDR-intern), u32 Zähler (30 bit), [u32 Wert].
struct VDRSporadic {
    struct Key: Hashable {
        var typ: Int, sub: Int, ch: Int
        init(_ typ: Int, _ sub: Int, _ ch: Int) { self.typ = typ; self.sub = sub; self.ch = ch }
    }

    struct Record {
        var flags: Int
        var sec: Int
        var tick: Int
        var value: Int?
    }

    var header: [Int]
    var chains: [Key: [Record]] = [:]
    var secStart: Int { header[2] }
    var tickEnd: Int { header[9] & 0x3FFF_FFFF }

    init?(_ d: Data) {
        guard d.count >= 0x60 else { return nil }
        let parsed: (header: [Int], chains: [Key: [Record]])? = d.withUnsafeBytes { b in
            func u32(_ o: Int) -> Int { Int(b.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
            func u16(_ o: Int) -> Int { Int(b.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
            let h = (0..<24).map { u32($0 * 4) }
            let n = h[1]
            guard n > 0, 0x60 + 16 * n <= b.count else { return nil }
            var chains: [Key: [Record]] = [:]
            let limit = b.count / 16 + 1
            for i in 0..<n {
                let base = 0x60 + 8 * i
                let key = Key(u16(base), u16(base + 2), u16(base + 4))
                var off = u32(0x60 + 8 * n + 4 * i)
                var recs: [Record] = []
                var guardCount = 0
                while off != 0 && off + 16 <= b.count && guardCount < limit {
                    let nxt = u32(off), idx = u16(off + 4), fl = u16(off + 6), sec = u32(off + 8), cnt = u32(off + 12)
                    if idx != i { break }
                    let val = (nxt & 0x4000_0000 != 0 && off + 20 <= b.count) ? u32(off + 16) : nil
                    recs.append(Record(flags: fl, sec: sec, tick: cnt & 0x3FFF_FFFF, value: val))
                    off = nxt & 0x3FFF_FFFF
                    guardCount += 1
                }
                chains[key] = recs
            }
            return (h, chains)
        }
        guard let parsed else { return nil }
        header = parsed.header
        chains = parsed.chains
    }

    /// Zeit der Einträge (`SporadicClock.mapper`): über den Zähler (30 bit) gegen den letzten Sekundenpuls des Blocks
    /// (= Blockende); Einträge, deren VDR-Sekunde vor dem Blockbeginn liegt, sind der Stand bei Blockbeginn.
    func clock(tBlock: Double, prevTick: Int?) -> (Int, Int) -> Double {
        let hb = [Key(112, 10, 1), Key(112, 12, 1)].lazy.compactMap { chains[$0] }.first { !$0.isEmpty } ?? []
        var rate = VDRData.ticksPerSecond
        if hb.count >= 4 {
            let span = Py.mod(hb[hb.count - 1].tick - hb[1].tick, 1 << 30)
            if span != 0 {
                let r = Double(span) / Double(hb.count - 2)
                if r > 150_000 && r < 250_000 { rate = r }
            }
        }
        let frozen = prevTick != nil && tickEnd == prevTick
        let tEnd = tBlock + Double(VDR.blockSeconds)
        let secStart = self.secStart
        let tickEnd = self.tickEnd
        return { sec, tick in
            if frozen || ((secStart - sec) > 2 && (secStart - sec) < (1 << 31)) { return tBlock }
            let dt = Double(Py.mod(tickEnd - tick, 1 << 30)) / rate
            return min(tEnd, max(tBlock, tEnd - dt))
        }
    }
}

// MARK: - AIS

/// VDM (andere Schiffe) und VDO (eigenes Schiff), Typen 1/2/3/5/18/19/24/27 wie `vdr.Ais`; Spur höchstens alle 10 s ein
/// Punkt.
final class VDRAIS {
    private var parts: [String: [String?]] = [:]
    private var targetOrder: [String] = []
    private var targets: [String: JSONObject] = [:]
    private(set) var own: JSONObject
    private(set) var counts = JSONObject()
    private(set) var errors = 0
    private var ownStatus: Int?
    private let de: Bool

    init(ownMMSI: String, de: Bool) {
        own = JSONObject(["mmsi": ownMMSI, "track": [Any]()])
        self.de = de
    }

    var targetCount: Int { targetOrder.count }
    var targetsJSON: JSONObject {
        var o = JSONObject()
        for k in targetOrder { o.set(k, targets[k]!) }
        return o
    }

    private func L(_ d: String, _ e: String) -> String { de ? d : e }

    static let six = Array("@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?")

    /// Nutzdaten als Bitfolge (`_Bits`)
    struct Bits {
        var six: [UInt8] = []
        var n: Int

        init?(_ payload: String, fill: Int) {
            guard fill >= 0 else { return nil }    // Python: negative Verschiebung → ValueError
            for ch in payload.unicodeScalars {
                var c = Int(ch.value) - 48
                if c > 40 { c -= 8 }
                guard c >= 0 && c <= 63 else { return nil }
                six.append(UInt8(c))
            }
            n = 6 * six.count - fill
        }

        func u(_ start: Int, _ len: Int) -> Int? {
            guard start >= 0, start + len <= n else { return nil }
            var v = 0
            for i in start..<(start + len) { v = (v << 1) | Int((six[i / 6] >> (5 - i % 6)) & 1) }
            return v
        }

        func s(_ start: Int, _ len: Int) -> Int? {
            guard let x = u(start, len) else { return nil }
            return x & (1 << (len - 1)) != 0 ? x - (1 << len) : x
        }

        func text(_ start: Int, _ len: Int) -> String {
            var out = ""
            for k in stride(from: start, to: start + len, by: 6) {
                guard let c = u(k, 6) else { break }
                out.append(VDRAIS.six[c])
            }
            let head = out.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return Py.strip(head)
        }
    }

    static func shipType(_ code: Int?) -> String {
        guard let code, code != 0 else { return "" }
        let groups: [(Int, Int, String)] = [(20, 29, "WIG"), (30, 30, "fishing"), (31, 32, "towing"), (33, 33, "dredging"),
                                            (34, 34, "diving"), (35, 35, "military"), (36, 36, "sailing"), (37, 37, "pleasure craft"),
                                            (40, 49, "high-speed craft"), (50, 50, "pilot"), (51, 51, "search and rescue"),
                                            (52, 52, "tug"), (53, 53, "port tender"), (54, 54, "anti-pollution"),
                                            (55, 55, "law enforcement"), (58, 58, "medical"), (60, 69, "passenger"), (70, 79, "cargo"),
                                            (80, 89, "tanker"), (90, 99, "other")]
        return groups.first { $0.0 <= code && code <= $0.1 }?.2 ?? ""
    }

    func feed(_ t: Double, _ chan: Int?, _ f: [String], own isOwn: Bool, ev: VDREvents) {
        // !AIVDM,anzahl,nummer,folge-id,kanal,nutzdaten,füllbits
        guard f.count >= 7 else { errors += 1; return }
        guard let total = Py.int(f[1]), let num = Py.int(f[2]), let fill = f[6].isEmpty ? 0 : Py.int(f[6]) else {
            errors += 1
            return
        }
        var payload: String
        if total == 1 {
            payload = f[5]
        } else {
            let key = "\(chan.map(String.init) ?? "None")|\(isOwn)|\(f[3])|\(f[4])|\(total)"
            if parts[key] == nil || num == 1 { parts[key] = [String?](repeating: nil, count: max(0, min(total, 10_000))) }
            guard num >= 1 && num <= total, num <= parts[key]!.count else { errors += 1; return }
            parts[key]![num - 1] = f[5]
            let lst = parts[key]!
            if lst.contains(where: { $0 == nil }) { return }
            payload = lst.compactMap { $0 }.joined()
            parts[key] = nil
        }
        guard let bits = Bits(payload, fill: fill) else { errors += 1; return }
        guard let mt = bits.u(0, 6), let mmsi = bits.u(8, 30) else { errors += 1; return }
        counts.set(String(mt), (counts[String(mt)] as? Int ?? 0) + 1)
        let mm = String(format: "%09d", mmsi)
        let tr1 = Py.round(t, 1)
        var tgt: JSONObject
        if isOwn {
            tgt = own
            if (own["mmsi"] as? String ?? "").isEmpty { tgt.set("mmsi", mm) }
        } else if let x = targets[mm] {
            tgt = x
        } else {
            tgt = JSONObject(["name": "", "type": nil, "type_text": "", "class": "", "first": tr1, "last": tr1, "n": 0, "track": [Any]()])
            targetOrder.append(mm)
        }
        defer { if isOwn { own = tgt } else { targets[mm] = tgt } }
        tgt.set("last", tr1)
        tgt.set("n", (tgt["n"] as? Int ?? 0) + 1)
        var pos: (Int?, Int?, Int?, Int?)?
        switch mt {
        case 1, 2, 3:
            tgt.set("class", "A")
            let lon = bits.s(61, 28), lat = bits.s(89, 27)
            let sog = bits.u(50, 10), cog = bits.u(116, 12), hdg = bits.u(128, 9)
            let status = bits.u(38, 4)
            pos = (lat, lon, sog, cog)
            if let hdg, hdg != 511 { tgt.set("heading", hdg) }
            if let status { tgt.set("status", VDRData.navStatus[status]) }
            if isOwn, let status, status != ownStatus {
                let prev = ownStatus
                let label = L("Eigenes Schiff: Navigationsstatus", "Own ship: navigational status")
                    + L(" „\(VDRData.navStatus[status])“", " \"\(VDRData.navStatus[status])\"")
                let detail = prev.map { L("vorher", "was") + L(" „\(VDRData.navStatus[$0])“", " \"\(VDRData.navStatus[$0])\"") }
                    ?? L("Stand bei Aufnahmebeginn", "state at start of recording")
                ev.point(t, "ais", label, detail, "AIS")
                ownStatus = status
            }
        case 18, 19:
            tgt.set("class", "B")
            pos = (bits.s(85, 27), bits.s(57, 28), bits.u(46, 10), bits.u(112, 12))
            if mt == 19 {
                let name = bits.text(143, 120)
                tgt.set("name", name.isEmpty ? (tgt["name"] as? String ?? "") : name)
                let ty = bits.u(263, 8)
                tgt.set("type", ty)
                tgt.set("type_text", Self.shipType(ty))
            }
        case 5:
            tgt.set("class", "A")
            tgt.set("imo", bits.u(40, 30))
            tgt.set("callsign", bits.text(70, 42))
            let name = bits.text(112, 120)
            tgt.set("name", name.isEmpty ? (tgt["name"] as? String ?? "") : name)
            let ty = bits.u(232, 8)
            tgt.set("type", ty)
            tgt.set("type_text", Self.shipType(ty))
            if let a = bits.u(240, 9), let b2 = bits.u(249, 9), let c = bits.u(258, 6), let d = bits.u(264, 6) {
                tgt.set("length", a + b2)
                tgt.set("beam", c + d)
            }
            if let dr = bits.u(294, 8), dr != 0 { tgt.set("draught", Double(dr) / 10) }
            tgt.set("destination", bits.text(302, 120))
        case 27:
            // Langstrecken-Meldung: Lage in 1/10 Minute, Geschwindigkeit in kn, Kurs in Grad
            let lon = bits.s(44, 18), lat = bits.s(62, 17)
            let sog = bits.u(79, 6), cog = bits.u(85, 9)
            if let lon, let lat {
                pos = (lat * 1000, lon * 1000, sog == nil || sog == 63 ? nil : sog! * 10, cog == nil || cog! >= 360 ? nil : cog! * 10)
            }
        case 24:
            let part = bits.u(38, 2)
            if part == 0 {
                let name = bits.text(40, 120)
                tgt.set("name", name.isEmpty ? (tgt["name"] as? String ?? "") : name)
            } else if part == 1 {
                let ty = bits.u(40, 8)
                tgt.set("type", ty)
                tgt.set("type_text", Self.shipType(ty))
                tgt.set("callsign", bits.text(90, 42))
            }
        default:
            break
        }
        guard let (lat0, lon0, sog, cog) = pos, let lat = lat0, let lon = lon0,
              abs(lat) <= 90 * 600_000, abs(lon) <= 180 * 600_000 else { return }
        var track = tgt["track"] as? [Any] ?? []
        if let last = track.last as? [Any], let lt = last.first as? Double, t - lt < 10 { return }
        track.append([tr1, Py.round(Double(lat) / 600_000, 6), Py.round(Double(lon) / 600_000, 6),
                      sog == nil || sog == 1023 ? NSNull() : Double(sog!) / 10 as Any,
                      cog == nil || cog! >= 3600 ? NSNull() : Double(cog!) / 10 as Any] as [Any])
        tgt.set("track", track)
    }
}

extension Py {
    /// Python `a % b` für ganze Zahlen (Ergebnis mit dem Vorzeichen von b)
    static func mod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return r != 0 && (r < 0) != (b < 0) ? r + b : r
    }

    /// Python `a % b` für Gleitkommazahlen
    static func mod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 {
            if (b < 0) != (m < 0) { m += b }
        } else {
            m = b < 0 ? -0.0 : 0.0
        }
        return m
    }
}
