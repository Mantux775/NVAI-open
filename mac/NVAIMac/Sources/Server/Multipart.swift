import Foundation

/// Liest ein Feld aus multipart/form-data (POST /api/upload, Feld `file`).
enum Multipart {
    struct Part {
        var name: String
        var filename: String?
        var data: Data
    }

    static func boundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for piece in contentType.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                return String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func parts(_ body: Data, boundary: String) -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data([13, 10, 13, 10])
        var result: [Part] = []
        var searchStart = body.startIndex
        var ranges: [Range<Data.Index>] = []
        while let r = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        for (i, r) in ranges.enumerated() where i + 1 < ranges.count {
            // Teil liegt zwischen diesem und dem nächsten Trenner, ohne das CRLF davor/danach.
            var start = r.upperBound
            var end = ranges[i + 1].lowerBound
            if body[start..<min(start + 2, body.endIndex)] == Data([13, 10]) { start += 2 }
            if end - start >= 2, body[(end - 2)..<end] == Data([13, 10]) { end -= 2 }
            guard start < end, let split = body.range(of: headerEnd, in: start..<end) else { continue }
            let head = String(decoding: body[start..<split.lowerBound], as: UTF8.self)
            let data = body.subdata(in: split.upperBound..<end)
            var name = ""
            var filename: String?
            for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-disposition") {
                name = value(of: "name", in: line) ?? ""
                filename = value(of: "filename", in: line)
            }
            result.append(Part(name: name, filename: filename, data: data))
        }
        return result
    }

    private static func value(of key: String, in line: String) -> String? {
        for piece in line.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq].lowercased() == key {
                return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}
