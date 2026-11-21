import CryptoKit
import Foundation

/// JSON für die Dateien eines Falls, geschrieben wie Python `json.dumps(…, ensure_ascii=False, indent=1)` unter Windows:
/// Zahlen in kürzester Form (13.8 statt 13.800000000000001 wie bei JSONSerialization), Umlaute bleiben, Schlüssel sortiert.
enum ForensicJSON {
    /// `compact`: Trenner wie `json.dumps(…, separators=(",", ":"))` (Datendateien der VDR-Fälle).
    static func data(_ value: Any?, indent: Int? = 1, compact: Bool = false) -> Data {
        var s = ""
        write(value, into: &s, indent: compact ? nil : indent, level: 0, compact: compact)
        return Data(s.utf8)
    }

    static func read(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func object(_ url: URL) -> [String: Any]? { read(url) as? [String: Any] }

    private static func write(_ value: Any?, into s: inout String, indent: Int?, level: Int, compact: Bool) {
        let pad = { (n: Int) -> String in indent.map { "\n" + String(repeating: " ", count: $0 * n) } ?? "" }
        let sep = compact || indent != nil ? "," : ", "
        let colon = compact ? ":" : ": "
        guard let value else { s += "null"; return }
        switch value {
        case is NSNull:
            s += "null"
        // lange Zahlenreihen (series.json, levels.json) ohne Umweg über NSNumber; nur echte Swift-Felder dieses Typs
        // (ein [Any] oder NSArray mit Zahlen ließe sich sonst auch so umwandeln und verlöre int/float)
        case let list as [Double?] where type(of: value) == [Double?].self:
            numbers(list.count, into: &s, sep: sep, pad: pad, level: level) { list[$0].map(number) ?? "null" }
        case let list as [Double] where type(of: value) == [Double].self:
            numbers(list.count, into: &s, sep: sep, pad: pad, level: level) { number(list[$0]) }
        case let list as [Int?] where type(of: value) == [Int?].self:
            numbers(list.count, into: &s, sep: sep, pad: pad, level: level) { list[$0].map { "\($0)" } ?? "null" }
        case let list as [Int] where type(of: value) == [Int].self:
            numbers(list.count, into: &s, sep: sep, pad: pad, level: level) { "\(list[$0])" }
        case let n as NSNumber where !(value is String):
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                s += n.boolValue ? "true" : "false"
            } else if CFNumberIsFloatType(n) {
                s += number(n.doubleValue)
            } else {
                s += "\(n.int64Value)"
            }
        case let str as String:
            s += quote(str)
        case let obj as JSONObject:
            if obj.keys.isEmpty { s += "{}"; return }
            s += "{"
            for (i, key) in obj.keys.enumerated() {
                if i > 0 { s += sep }
                s += pad(level + 1) + quote(key) + colon
                write(obj[key], into: &s, indent: indent, level: level + 1, compact: compact)
            }
            s += pad(level) + "}"
        case let dict as [String: Any]:
            if dict.isEmpty { s += "{}"; return }
            s += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { s += sep }
                s += pad(level + 1) + quote(key) + colon
                write(dict[key], into: &s, indent: indent, level: level + 1, compact: compact)
            }
            s += pad(level) + "}"
        case let list as [Any?]:
            if list.isEmpty { s += "[]"; return }
            s += "["
            for (i, item) in list.enumerated() {
                if i > 0 { s += sep }
                s += pad(level + 1)
                write(item, into: &s, indent: indent, level: level + 1, compact: compact)
            }
            s += pad(level) + "]"
        case let list as [Any]:
            write(list.map { Optional($0) }, into: &s, indent: indent, level: level, compact: compact)
        default:
            s += quote(String(describing: value))
        }
    }

    /// kürzeste Form wie Python repr: 13.8, 180.0, 1e-05; nicht endliche Werte als null
    private static func number(_ d: Double) -> String { d.isFinite ? "\(d)" : "null" }

    private static func numbers(_ count: Int, into s: inout String, sep: String, pad: (Int) -> String, level: Int,
                                _ item: (Int) -> String) {
        if count == 0 { s += "[]"; return }
        s += "["
        for i in 0..<count {
            if i > 0 { s += sep }
            s += pad(level + 1)
            s += item(i)
        }
        s += pad(level) + "]"
    }

    static func quote(_ str: String) -> String {
        var out = "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

/// JSON-Objekt mit fester Schlüsselfolge wie ein Python-dict (ForensicJSON sortiert sonst): Die Prüf-App zeigt etwa die
/// Messreihen aus series.json in der Reihenfolge ihrer Schlüssel. `nil` wird als null gespeichert.
struct JSONObject {
    private(set) var keys: [String] = []
    private(set) var values: [String: Any] = [:]

    init(_ pairs: KeyValuePairs<String, Any?> = [:]) {
        for (k, v) in pairs { set(k, v) }
    }

    mutating func set(_ key: String, _ value: Any?) {
        if values[key] == nil { keys.append(key) }
        values[key] = value ?? NSNull()
    }

    mutating func remove(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        keys.removeAll { $0 == key }
    }

    subscript(key: String) -> Any? { values[key] }
    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }
}

/// SHA-256 einer Datei, stückweise gelesen (Originalton und Video können viele GB groß sein).
enum ForensicHash {
    static func sha256(_ url: URL, isCancelled: () -> Bool = { false }, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            progress?(done)
            if isCancelled() { throw CancellationError() }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
