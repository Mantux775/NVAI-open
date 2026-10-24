import Foundation

/// Ein JSON-Wert, wie ihn der NVAI-open-Vertrag (server/openapi.json) überträgt.
///
/// Felder wie `meta` oder `params` sind im Vertrag freie Objekte mit gemischten Typen
/// (Seed als Zahl, Prompt als Text). Codable-Structs reichen dafür nicht, und nil muss
/// als `null` erscheinen statt wegzufallen – deshalb dieser Typ.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Für JSONSerialization: nil wird NSNull, damit es als `null` ankommt.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Aus JSONSerialization. NSNumber unterscheidet Bool und Zahl nur über den CF-Typ.
    static func from(_ value: Any?) -> JSONValue {
        guard let value, !(value is NSNull) else { return .null }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let type = String(cString: n.objCType)
            return (type == "d" || type == "f") ? .double(n.doubleValue) : .int(n.intValue)
        }
        if let s = value as? String { return .string(s) }
        if let a = value as? [Any] { return .array(a.map { from($0) }) }
        if let o = value as? [String: Any] { return .object(o.mapValues { from($0) }) }
        return .string(String(describing: value))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

enum JSON {
    /// Serialisiert wie FastAPI: UTF-8, Schrägstriche unmaskiert (URLs wie /files/…).
    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue.from(any)
    }
}
