import Foundation

/// Teile von safetensors-Dateien auf Hugging Face per HTTP-Range laden: Kopf lesen, einzelne Tensoren holen und als
/// eigene safetensors-Datei schreiben (Z-Image-Schichten in bf16, LTX-Video ohne den VAE-Encoder).
enum HFRange {
    struct Tensor {
        let key: String
        let dtype: String
        let shape: [Int]
        let start: Int64   // absolut in der entfernten Datei
        let count: Int64
    }

    /// Ein Byte-Bereich; bis zu drei Versuche. Ein Server ohne Range-Unterstützung (200 statt 206) bricht ab.
    static func data(_ url: URL, _ start: Int64, _ count: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        var lastError: Error = APIError(502, "range")
        for attempt in 0 ..< 3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 206, Int64(data.count) == count else {
                    throw APIError(502, t("Hugging Face lieferte keinen Teilbereich (HTTP \(status)).",
                                          "Hugging Face returned no partial content (HTTP \(status))."))
                }
                return data
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                if attempt < 2 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw lastError
    }

    static func littleEndian(_ bytes: Data) -> UInt64 {
        bytes.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// Alle Tensoren einer entfernten safetensors-Datei.
    static func tensors(_ url: URL) async throws -> [Tensor] {
        let n = Int64(littleEndian(try await data(url, 0, 8)))
        guard n > 0, n < 100_000_000,
              let header = try JSONSerialization.jsonObject(with: try await data(url, 8, n)) as? [String: Any]
        else { throw APIError(502, t("Kopf von \(url.lastPathComponent) unlesbar.", "Unreadable header of \(url.lastPathComponent).")) }
        return header.compactMap { key, value in
            guard key != "__metadata__", let v = value as? [String: Any], let dtype = v["dtype"] as? String,
                  let shape = v["shape"] as? [Int], let o = v["data_offsets"] as? [Int], o.count == 2 else { return nil }
            return Tensor(key: key, dtype: dtype, shape: shape, start: 8 + n + Int64(o[0]), count: Int64(o[1] - o[0]))
        }
    }

    /// `parts` (aus einer oder mehreren entfernten Dateien) als eine safetensors-Datei nach `target`; benachbarte
    /// Tensoren derselben Datei kommen in Bereichen bis 64 MB. `progress(bytes)`.
    static func write(_ parts: [(url: URL, tensor: Tensor)], to target: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let ordered = parts.sorted { $0.url.absoluteString == $1.url.absoluteString
            ? $0.tensor.start < $1.tensor.start : $0.url.absoluteString < $1.url.absoluteString }
        var header: [String: Any] = [:]
        var position = 0
        for part in ordered {
            header[part.tensor.key] = ["dtype": part.tensor.dtype, "shape": part.tensor.shape,
                                       "data_offsets": [position, position + Int(part.tensor.count)]]
            position += Int(part.tensor.count)
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = target.appendingPathExtension("part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let file = try FileHandle(forWritingTo: tmp)
        var length = UInt64(json.count).littleEndian
        try file.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try file.write(contentsOf: json)
        var done: Int64 = 0
        var i = 0
        while i < ordered.count {
            try Task.checkCancellation()
            let first = ordered[i]
            var end = first.tensor.start + first.tensor.count
            var j = i
            while j + 1 < ordered.count, ordered[j + 1].url == first.url, ordered[j + 1].tensor.start == end,
                  end - first.tensor.start < 64 << 20 {
                j += 1
                end = ordered[j].tensor.start + ordered[j].tensor.count
            }
            try file.write(contentsOf: try await data(first.url, first.tensor.start, end - first.tensor.start))
            done += end - first.tensor.start
            progress(done)
            i = j + 1
        }
        try file.close()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    /// Ist die lokale safetensors-Datei vollständig (Länge = Kopf + größtes Datenende)?
    static func complete(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              let file = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 8), head.count == 8 else { return false }
        let n = Int64(littleEndian(head))
        guard n > 0, n < 100_000_000, let json = try? file.read(upToCount: Int(n)),
              let header = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return false }
        let end = header.values.compactMap { ($0 as? [String: Any])?["data_offsets"] as? [Int] }.map { $0[1] }.max() ?? 0
        return size == 8 + n + Int64(end)
    }
}
