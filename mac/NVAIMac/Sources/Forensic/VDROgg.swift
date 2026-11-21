import Foundation
import StbVorbis

/// Ogg-Seiten der VDR-Tondateien und ein Vorbis-Dekoder, der über alle Blockdateien eines Kanalpaars durchläuft
/// (seit 0.5.11), wie `task_audio` in `server/nvai/vdr.py`.
///
/// Der VR-7000 kodiert je Datei-Nummer (audio0, audio1 …) EINEN durchlaufenden Vorbis-Strom und schneidet ihn alle 15 s an
/// einer Seitengrenze; jede Datei bekommt die drei Kopfpakete neu, die Granule-Positionen beginnen je Datei neu.
/// Einzeln dekodiert fehlen je Datei die ersten 512 Proben (das erste Paket braucht das letzte der Vordatei). Darum
/// bekommt ein Dekoder (stb_vorbis, Push-API) nur die Kopfseiten der ersten Datei und danach die Tonseiten aller
/// Folgedateien, umgeschrieben zu einem gewöhnlichen fortlaufenden Ogg-Strom: Seitennummern fortlaufend,
/// Granule-Positionen aufsummiert, Anfangs- und End-Merker (BOS/EOS) nur dort, wo der Strom wirklich beginnt, Prüfsumme
/// neu. Der EOS-Merker muss weg: stb_vorbis 1.25 kürzt am Ende einer Seite mit EOS das letzte Paket auf die
/// Granule-Position und setzt danach neu an (das erste Paket der nächsten Datei gäbe dann nichts aus).
enum VDROgg {
    struct Page {
        /// Anfang der Seite („OggS“) in den Daten
        var start: Int
        /// 27 + Anzahl der Segmente
        var headerLength: Int
        var bodyLength: Int
        var flags: UInt8
        var granule: Int64
        /// so viele Pakete enden auf dieser Seite (Segmente kürzer als 255)
        var packetsEnded: Int
        /// das letzte Segment ist 255 lang: das Paket geht auf der nächsten Seite weiter
        var openAtEnd: Bool
        var end: Int { start + headerLength + bodyLength }
    }

    private static func isCapture(_ b: UnsafeRawBufferPointer, _ p: Int) -> Bool {
        b[p] == 0x4F && b[p + 1] == 0x67 && b[p + 2] == 0x67 && b[p + 3] == 0x53
    }

    /// Nächstes „OggS“ ab `from` (wie `bytes.find(b"OggS", from)`).
    private static func find(_ b: UnsafeRawBufferPointer, from: Int) -> Int? {
        var p = max(0, from)
        while p + 4 <= b.count {
            if b[p] == 0x4F && isCapture(b, p) { return p }
            p += 1
        }
        return nil
    }

    private static func granule(_ b: UnsafeRawBufferPointer, _ p: Int) -> Int64 {
        Int64(bitPattern: b.loadUnaligned(fromByteOffset: p + 6, as: UInt64.self).littleEndian)
    }

    /// Granule-Position der letzten Seite mit gültiger Position = Probenzahl der Datei, genau wie `vdr.ogg_granule`
    /// (auch eine unvollständige letzte Seite zählt).
    static func lastGranule(_ data: Data) -> Int64? {
        data.withUnsafeBytes { b -> Int64? in
            var pos = 0
            var last: Int64?
            let n = b.count
            while pos + 27 <= n {
                if !isCapture(b, pos) {
                    guard let next = find(b, from: pos + 1) else { break }
                    pos = next
                    continue
                }
                let gp = granule(b, pos)
                let nseg = Int(b[pos + 26])
                var size = 0
                var i = pos + 27
                let segEnd = min(n, pos + 27 + nseg)
                while i < segEnd { size += Int(b[i]); i += 1 }
                if gp >= 0 { last = gp }
                pos += 27 + nseg + size
            }
            return last
        }
    }

    /// Alle vollständigen Seiten; fremde Bytes dazwischen werden übersprungen, eine abgeschnittene letzte Seite fällt weg.
    static func pages(_ b: UnsafeRawBufferPointer) -> [Page] {
        var out: [Page] = []
        var pos = 0
        let n = b.count
        while pos + 27 <= n {
            if !isCapture(b, pos) {
                guard let next = find(b, from: pos + 1) else { break }
                pos = next
                continue
            }
            let nseg = Int(b[pos + 26])
            guard pos + 27 + nseg <= n else { break }
            var size = 0
            var ended = 0
            for i in 0..<nseg {
                let s = Int(b[pos + 27 + i])
                size += s
                if s < 255 { ended += 1 }
            }
            guard pos + 27 + nseg + size <= n else { break }
            out.append(Page(start: pos, headerLength: 27 + nseg, bodyLength: size, flags: b[pos + 5], granule: granule(b, pos),
                            packetsEnded: ended, openAtEnd: nseg > 0 && b[pos + 27 + nseg - 1] == 255))
            pos += 27 + nseg + size
        }
        return out
    }

    /// Prüfsumme einer Ogg-Seite (CRC-32, Polynom 0x04C11DB7, ohne Spiegelung, Start 0).
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc(_ p: UnsafeRawBufferPointer) -> UInt32 {
        var c: UInt32 = 0
        crcTable.withUnsafeBufferPointer { t in
            for byte in p { c = (c << 8) ^ t[Int(((c >> 24) ^ UInt32(byte)) & 0xFF)] }
        }
        return c
    }
}

/// Ergebnis einer dekodierten Tondatei: je Kanal die Proben (Stereo; eine Mono-Datei steht in beiden Kanälen).
struct VorbisBlock {
    var left: [Float] = []
    var right: [Float] = []
    var count: Int { left.count }
}

/// Ein Vorbis-Dekoder (stb_vorbis) über die Tondateien eines Kanalpaars, siehe `VDROgg`.
///
/// Zuteilung der Proben zu den Dateien wie FFmpeg unter Windows: Ein Paket liefert dort die Proben von der Mitte seines
/// Vorgänger-Fensters bis zur Mitte seines eigenen (Blockgröße davor/4 + eigene/4), die Summe einer Datei ist dann genau
/// ihre letzte Granule-Position. stb_vorbis gibt bei einem langen Block vor einem kurzen den flachen Teil bis zum Beginn
/// der Überlappung schon mit diesem Paket aus, (lang − kurz)/4 Proben zu früh (gemessen: ±128 an 42 von 3055 Nähten).
/// Endet eine Datei mit so einem Paket, gehören diese Proben zur nächsten Datei; sie werden zurückgehalten. Dafür liest
/// die Kette die Blockgrößen (Kennungskopf) und die Modi (Ende des Setup-Kopfs, rückwärts wie `av_vorbis_parse`).
final class VorbisChain {
    private var decoder: OpaquePointer?
    private var sequence: UInt32 = 0
    private var serial: UInt32 = 0
    private var granuleBase: Int64 = 0
    private var lastGranule: Int64 = 0
    /// noch nicht dekodierte Bytes (ein Paket, das über den Schnitt in die nächste Datei reicht)
    private var pending: [UInt8] = []
    /// zu früh ausgegebene Proben, die nach FFmpeg-Zählung zur nächsten Datei gehören
    private var carryLeft: [Float] = []
    private var carryRight: [Float] = []
    private var blocksizes = (0, 0)
    private var modeLong: [Bool]?
    /// Auffälligkeiten (Prüfen und Notizen): Dateien ohne lesbare Kopfpakete, Ton auf einer Kopfseite, Reste
    private(set) var anomalies: [String: Int] = [:]

    deinit { close() }

    func close() {
        if let decoder { stb_vorbis_close(decoder) }
        decoder = nil
        carryLeft = []
        carryRight = []
    }

    var isOpen: Bool { decoder != nil }

    private func note(_ key: String) { anomalies[key, default: 0] += 1 }

    /// Ende einer Folge (Lücke, fehlende Datei): ein liegengebliebener Rest gehört zu nichts mehr.
    func dropPending() {
        if !pending.isEmpty { note("rest_bytes") }
        pending = []
    }

    /// Pakete aus Seiten: Bytes jedes vollständigen Pakets (für die Kopfpakete).
    private static func packets(_ raw: UnsafeRawBufferPointer, _ pages: ArraySlice<VDROgg.Page>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var cur: [UInt8] = []
        for page in pages {
            var data = page.start + page.headerLength
            for i in 0..<(page.headerLength - 27) {
                let len = Int(raw[page.start + 27 + i])
                cur.append(contentsOf: raw[data..<(data + len)])
                data += len
                if len < 255 {
                    out.append(cur)
                    cur = []
                }
            }
        }
        return out
    }

    /// Modi aus dem Ende des Setup-Kopfs (je Modus: Blockart 1 Bit, Fenster 16, Transformation 16, Zuordnung 8), rückwärts
    /// gelesen wie FFmpegs `parse_setup_header`; nil, wenn sich nichts Plausibles findet.
    static func modeFlags(setup: [UInt8]) -> [Bool]? {
        let rev = Array(setup.reversed())
        let total = rev.count * 8
        var pos = 0
        func bit() -> Int {
            let b = Int(rev[pos >> 3] >> (7 - UInt8(pos & 7))) & 1
            pos += 1
            return b
        }
        func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n { v = (v << 1) | bit() }
            return v
        }
        var framing = 0
        while total - pos > 97 {
            if bit() == 1 { framing = pos; break }
        }
        guard framing > 0 else { return nil }
        var count = 0
        var last = 0
        while total - pos >= 97 {
            if bits(8) > 63 || bits(16) != 0 || bits(16) != 0 { break }
            pos += 1
            count += 1
            if count > 64 { break }
            let save = pos
            if bits(6) + 1 == count { last = count }
            pos = save
        }
        guard last > 0, last <= 63 else { return nil }
        pos = framing
        var flags = [Bool](repeating: false, count: last)
        for i in stride(from: last - 1, through: 0, by: -1) {
            pos += 40
            flags[i] = bit() == 1
        }
        return flags
    }

    /// Wie viele Proben stb_vorbis nach dem letzten vollständigen Paket des Stroms zu früh ausgegeben hat: (lang − kurz)/4,
    /// wenn dieses Paket ein langer Block ist und der nächste kurz.
    private func earlySamples(_ stream: [UInt8], upTo end: Int) -> Int {
        guard let modeLong, blocksizes.1 > blocksizes.0, end > 0 else { return 0 }
        var lastStart: Int?
        var packetStart: Int?
        stream.withUnsafeBytes { raw in
            let pages = VDROgg.pages(UnsafeRawBufferPointer(rebasing: raw[0..<end]))
            for page in pages {
                var data = page.start + page.headerLength
                if page.flags & 0x01 == 0 { packetStart = nil }
                for i in 0..<(page.headerLength - 27) {
                    let len = Int(raw[page.start + 27 + i])
                    if packetStart == nil { packetStart = data }
                    data += len
                    if len < 255 {
                        if let p = packetStart, p < data { lastStart = p }
                        packetStart = nil
                    }
                }
            }
        }
        guard let p = lastStart, p + 1 < stream.count else { return 0 }
        // Bits LSB zuerst: Pakettyp, Modus (ilog(Modi − 1) Bits), bei langen Blöcken Vorgänger- und Nachfolger-Fenster
        let word = Int(stream[p]) | Int(stream[p + 1]) << 8
        guard word & 1 == 0 else { return 0 }
        let modeBits = modeLong.count > 1 ? (Int.bitWidth - (modeLong.count - 1).leadingZeroBitCount) : 0
        let mode = modeBits > 0 ? (word >> 1) & ((1 << modeBits) - 1) : 0
        guard mode < modeLong.count, modeLong[mode] else { return 0 }
        let next = (word >> (1 + modeBits + 1)) & 1
        return next == 0 ? (blocksizes.1 - blocksizes.0) / 4 : 0
    }

    /// Eine Datei dekodieren: `fresh` = neuer Dekoder mit den Kopfpaketen dieser Datei (Anfang, nach einer Lücke oder
    /// wenn der Kodierer neu anlief), sonst nur ihre Tonseiten in den laufenden Dekoder. nil: nicht dekodierbar.
    func decode(_ data: Data, fresh: Bool) -> VorbisBlock? {
        data.withUnsafeBytes { raw -> VorbisBlock? in
            let pages = VDROgg.pages(raw)
            // Kopfseiten: bis das dritte Paket endet; der Ton beginnt laut Vorbis-Spezifikation auf einer neuen Seite
            var headerPages = 0
            var ended = 0
            while headerPages < pages.count && ended < 3 {
                ended += pages[headerPages].packetsEnded
                headerPages += 1
            }
            guard ended >= 3 else {
                note("no_headers")
                return nil
            }
            let lastHeader = pages[headerPages - 1]
            if ended > 3 || lastHeader.openAtEnd { note("audio_on_header_page") }
            if fresh || decoder == nil {
                close()
                if !pending.isEmpty { note("rest_bytes") }
                pending = []
                let headerBytes = UnsafeRawBufferPointer(rebasing: raw[pages[0].start..<lastHeader.end])
                var used: Int32 = 0
                var error: Int32 = 0
                let d = stb_vorbis_open_pushdata(headerBytes.bindMemory(to: UInt8.self).baseAddress, Int32(headerBytes.count),
                                                  &used, &error, nil)
                guard let d else {
                    note("open_error_\(error)")
                    return nil
                }
                decoder = d
                serial = raw.loadUnaligned(fromByteOffset: pages[0].start + 14, as: UInt32.self).littleEndian
                sequence = UInt32(headerPages)
                granuleBase = 0
                lastGranule = 0
                let heads = Self.packets(raw, pages[0..<headerPages])
                if heads.count >= 3, heads[0].count >= 29 {
                    blocksizes = (1 << Int(heads[0][28] & 0x0F), 1 << Int(heads[0][28] >> 4))
                    modeLong = Self.modeFlags(setup: heads[2])
                } else {
                    modeLong = nil
                }
                if modeLong == nil { note("modes_unknown") }
            }
            // Tonseiten umschreiben: Nummer fortlaufend, Granule aufsummiert, ohne BOS/EOS, Prüfsumme neu
            let audio = pages[headerPages...]
            var stream = pending
            var w = stream.count
            stream.append(contentsOf: repeatElement(0, count: audio.reduce(0) { $0 + $1.headerLength + $1.bodyLength }))
            pending = []
            var fileGranule: Int64 = 0
            stream.withUnsafeMutableBytes { out in
                for page in audio {
                    let len = page.headerLength + page.bodyLength
                    out.baseAddress!.advanced(by: w).copyMemory(from: raw.baseAddress!.advanced(by: page.start), byteCount: len)
                    out[w + 5] = page.flags & 0x01
                    // stb_vorbis 1.25 lehnt die Granule −1 (kein Paket endet hier) ab: dann die letzte Position wiederholen.
                    // Granule aus der Datei: Eine beschädigte darf die Summe nicht überlaufen lassen (sonst Absturz).
                    let (sum, overflow) = granuleBase.addingReportingOverflow(page.granule)
                    let g = page.granule >= 0 && !overflow ? sum : lastGranule
                    if page.granule >= 0 { fileGranule = page.granule }
                    lastGranule = g
                    out.storeBytes(of: UInt64(bitPattern: g).littleEndian, toByteOffset: w + 6, as: UInt64.self)
                    out.storeBytes(of: serial.littleEndian, toByteOffset: w + 14, as: UInt32.self)
                    out.storeBytes(of: sequence.littleEndian, toByteOffset: w + 18, as: UInt32.self)
                    out.storeBytes(of: UInt32(0), toByteOffset: w + 22, as: UInt32.self)
                    let c = VDROgg.crc(UnsafeRawBufferPointer(rebasing: out[w..<(w + len)]))
                    out.storeBytes(of: c.littleEndian, toByteOffset: w + 22, as: UInt32.self)
                    sequence &+= 1
                    w += len
                }
            }
            let (base, wrapped) = granuleBase.addingReportingOverflow(fileGranule)
            if !wrapped { granuleBase = base }
            return feed(stream)
        }
    }

    /// Alle vollständigen Pakete dekodieren; ein Rest (Paket, das in der nächsten Datei weitergeht) bleibt für sie liegen.
    /// Ausgabe nach FFmpeg-Zählung: zurückgehaltene Proben der Vordatei vorn, zu früh ausgegebene am Ende zurückhalten.
    private func feed(_ stream: [UInt8]) -> VorbisBlock {
        var result = VorbisBlock(left: carryLeft, right: carryRight)
        carryLeft = []
        carryRight = []
        result.left.reserveCapacity(16000 * 16)
        result.right.reserveCapacity(16000 * 16)
        guard let decoder else { return result }
        var off = 0
        stream.withUnsafeBufferPointer { buf in
            while off < buf.count {
                var channels: Int32 = 0
                var output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
                var samples: Int32 = 0
                let used = stb_vorbis_decode_frame_pushdata(decoder, buf.baseAddress! + off, Int32(buf.count - off),
                                                           &channels, &output, &samples)
                if used <= 0 { break }
                off += Int(used)
                guard samples > 0, let output, channels > 0, let l = output[0] else { continue }
                let r = channels > 1 ? (output[1] ?? l) : l
                result.left.append(contentsOf: UnsafeBufferPointer(start: l, count: Int(samples)))
                result.right.append(contentsOf: UnsafeBufferPointer(start: r, count: Int(samples)))
            }
        }
        if off < stream.count { pending = Array(stream[off...]) }
        let early = min(earlySamples(stream, upTo: off), result.count)
        if early > 0 {
            carryLeft = Array(result.left.suffix(early))
            carryRight = Array(result.right.suffix(early))
            result.left.removeLast(early)
            result.right.removeLast(early)
        }
        return result
    }
}
