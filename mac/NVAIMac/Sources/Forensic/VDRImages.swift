import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

/// Radar- und ECDIS-Bilder eines VDR-Exports (seit 0.5.11), wie `task_images` in `server/nvai/vdr.py`: je Quelle nach
/// images/<quelle>/<block>.<png|jpg>. PNG und JPEG bleiben unverändert (der Schreiber legt „image/bmp“ als PNG ab); echte
/// BMP und rohe Pixel werden PNG, außer das PNG wird mehr als dreimal so groß wie ein JPEG mit Qualität 92.
enum VDRImages {
    struct Stats {
        var count = 0
        var bytes = 0
        var kinds: [String: Int] = [:]
        var kindOrder: [String] = []
        var noSignal = 0
        var converted = 0

        var json: JSONObject {
            var k = JSONObject()
            for name in kindOrder { k.set(name, kinds[name]!) }
            return JSONObject(["count": count, "bytes": bytes, "kinds": k, "no_signal": noSignal, "converted": converted])
        }
    }

    struct Frame {
        var t: Double
        var tIsInt: Bool
        var path: String
        var tRec: Int
        var json: [Any] { [tIsInt ? Int(t) as Any : t as Any, path, tRec] }
    }

    struct Result {
        var frames: [String: [Frame]] = [:]
        var stats: [String: Stats] = [:]
        var info: [String: JSONObject] = [:]
        var noSignal: [String: Set<String>] = [:]
    }

    /// Ein Abschnitt von Blöcken (mehrere laufen nebeneinander). `alsoRead`: weitere Dateien des Blocks, die `each` je Block
    /// bekommt (der Durchgang liest dabei die Schnittlage des Tons mit, so wird jeder Block nur einmal entpackt).
    static func run(blocks: ArraySlice<VDR.Block>, t0: Int, imagesDir: URL, progress: VDRProgress, key: String,
                    alsoRead: Set<String> = [], each: ((VDR.Block, [String: Data]) -> Void)? = nil) throws -> Result {
        var res = Result()
        let fm = FileManager.default
        var made = Set<String>()
        for (k, b) in blocks.enumerated() {
            if progress.cancelled { throw CancellationError() }
            let blk = (try? VDR.readBlock(b, want: { VDR.isRadar($0) || alsoRead.contains($0) })) ?? [:]
            each?(b, blk)
            for (name, data) in blk.sorted(by: { $0.key < $1.key }) where VDR.isRadar(name) {
                guard let hd = VDR.parseImage(data) else { continue }
                var payload = data.subdata(in: (data.startIndex + hd.offset)..<data.endIndex)
                var ext = hd.kind
                var st = res.stats[name] ?? Stats()
                if ["bmp", "zlib", "bin"].contains(ext) {
                    (payload, ext) = convert(payload, hd)
                    st.converted += 1
                }
                let folder = imagesDir.appendingPathComponent(name, isDirectory: true)
                if !made.contains(name) {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    made.insert(name)
                }
                let fn = "\(b.id).\(ext)"
                try payload.write(to: folder.appendingPathComponent(fn))
                let tRec = hd.t - t0
                let tCap = hd.capture.map { $0 - Double(t0) }
                let useCap = tCap != nil && abs(tCap! - Double(tRec)) < 60
                let path = "\(name)/\(fn)"
                res.frames[name, default: []].append(Frame(t: useCap ? Py.round(tCap!, 3) : Double(tRec), tIsInt: !useCap, path: path,
                                                           tRec: tRec))
                st.count += 1
                st.bytes += payload.count
                if st.kinds[ext] == nil { st.kindOrder.append(ext) }
                st.kinds[ext, default: 0] += 1
                if hd.noSignal {
                    st.noSignal += 1
                    res.noSignal[name, default: []].insert(path)
                }
                res.stats[name] = st
                if res.info[name] == nil && !hd.noSignal {
                    res.info[name] = JSONObject(["mime": hd.mime, "stored_as": ext, "width": hd.width, "height": hd.height,
                                                 "header_source": hd.head["Source"] ?? "", "location": hd.head["Location"] ?? "",
                                                 "time": useCap ? "capture" : "record"])
                }
            }
            if k % 25 == 0 { progress.set(key, Double(k + 1) / Double(blocks.count)) }
        }
        progress.set(key, 1)
        return res
    }

    /// Abschnitte zusammenführen (in Blockfolge): Bilder nach Zeit, Zählungen addiert, Angaben vom ersten Abschnitt mit Bild.
    static func merge(_ parts: [Result], labels: [String: String]) -> (json: JSONObject, sources: [JSONObject], stats: JSONObject,
                                                                      counts: JSONObject) {
        var frames: [String: [Frame]] = [:]
        var stats: [String: Stats] = [:]
        var info: [String: JSONObject] = [:]
        var noSignal: [String: Set<String>] = [:]
        for r in parts {
            for (name, fl) in r.frames { frames[name, default: []] += fl }
            for (name, s) in r.noSignal { noSignal[name, default: []].formUnion(s) }
            for (name, st) in r.stats {
                var agg = stats[name] ?? Stats()
                agg.count += st.count
                agg.bytes += st.bytes
                agg.noSignal += st.noSignal
                agg.converted += st.converted
                for k in st.kindOrder {
                    if agg.kinds[k] == nil { agg.kindOrder.append(k) }
                    agg.kinds[k, default: 0] += st.kinds[k]!
                }
                stats[name] = agg
            }
            for (name, inf) in r.info where info[name] == nil { info[name] = inf }
        }
        var sources: [JSONObject] = []
        var framesJSON = JSONObject()
        var statsJSON = JSONObject()
        var counts = JSONObject()
        for name in frames.keys.sorted() {
            // stabil nach Zeit wie `frames[name].sort(key=lambda f: f[0])`
            let list = frames[name]!.enumerated().sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
                .map(\.element)
            frames[name] = list
            framesJSON.set(name, list.map(\.json))
            let inf = info[name] ?? JSONObject()
            let st = stats[name] ?? Stats()
            let ns = noSignal[name] ?? []
            var src = JSONObject(["id": name, "label": labels[name] ?? name, "count": list.count, "mime": inf["mime"],
                                  "stored_as": st.json["kinds"], "width": inf["width"], "height": inf["height"]])
            src.set("time", inf["time"] ?? "record")
            src.set("location", inf["location"] ?? "")
            src.set("no_signal", list.enumerated().filter { ns.contains($0.element.path) }.map(\.offset))
            src.set("bytes", st.bytes)
            sources.append(src)
            counts.set(name, list.count)
        }
        for name in stats.keys.sorted() { statsJSON.set(name, stats[name]!.json) }
        return (JSONObject(["sources": sources, "frames": framesJSON]), sources, statsJSON, counts)
    }

    /// Echte BMP oder rohe Pixel (zlib, BGR) → PNG, außer das PNG wird mehr als dreimal so groß wie ein JPEG (Qualität 92);
    /// Unbekanntes bleibt „bin“ (`_convert_image`).
    static func convert(_ payload: Data, _ hd: VDR.ImageHeader) -> (Data, String) {
        var image: CGImage?
        if hd.kind == "bmp" {
            if let src = CGImageSourceCreateWithData(payload as CFData, nil) { image = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        } else if hd.kind == "zlib", hd.width > 0, hd.height > 0 {
            let need = hd.width * hd.height * 3
            var raw = Data(count: need)
            var size = uLongf(need)
            let status = raw.withUnsafeMutableBytes { dst in
                payload.withUnsafeBytes { src in
                    uncompress(dst.baseAddress!.assumingMemoryBound(to: Bytef.self), &size,
                               src.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(payload.count))
                }
            }
            if status == Z_OK, Int(size) == need {
                // BGR → RGB
                raw.withUnsafeMutableBytes { p in
                    let b = p.bindMemory(to: UInt8.self)
                    var i = 0
                    while i + 2 < need { b.swapAt(i, i + 2); i += 3 }
                }
                if let provider = CGDataProvider(data: raw as CFData) {
                    image = CGImage(width: hd.width, height: hd.height, bitsPerComponent: 8, bitsPerPixel: 24,
                                    bytesPerRow: hd.width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                }
            }
        }
        guard let image, let png = encode(image, UTType.png, quality: nil), let jpg = encode(image, UTType.jpeg, quality: 0.92) else {
            return (payload, "bin")
        }
        return png.count <= 3 * jpg.count ? (png, "png") : (jpg, "jpg")
    }

    private static func encode(_ image: CGImage, _ type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
