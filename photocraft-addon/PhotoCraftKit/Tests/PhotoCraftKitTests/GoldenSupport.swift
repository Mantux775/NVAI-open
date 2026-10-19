import Foundation
import XCTest
@testable import PhotoCraftKit

/// Golden-Daten aus tools/export_golden.py (Kopie in Tests/PhotoCraftKitTests/Golden).
enum Golden {
    static func load(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden") else {
            throw NSError(domain: "Golden", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name).json fehlt"])
        }
        return try JSONValue.parse(try Data(contentsOf: url))
    }

    static func ints(_ v: JSONValue?) -> [Int] { (v?.arrayValue ?? []).compactMap(\.intValue) }

    /// Maske aus halboffenen Rechtecken `[x0, y0, x1, y1, wert]`.
    static func mask(size: JSONValue?, rects: JSONValue?) -> GrayImage {
        let s = ints(size)
        var m = GrayImage(width: s[0], height: s[1])
        for r in rects?.arrayValue ?? [] {
            let v = ints(r)
            m.fill(v[0], v[1], v[2], v[3], value: UInt8(v[4]))
        }
        return m
    }

    /// RGBA aus Grundfarbe und halboffenen Rechtecken `[x0, y0, x1, y1, r, g, b, a]`.
    static func rgba(size: JSONValue?, base: JSONValue?, rects: JSONValue?) -> RGBAImage {
        let s = ints(size)
        var img = RGBAImage(width: s[0], height: s[1], color: ints(base).map { UInt8($0) })
        for r in rects?.arrayValue ?? [] {
            let v = ints(r)
            img.fill(v[0], v[1], v[2], v[3], rgba: v[4...7].map { UInt8($0) })
        }
        return img
    }
}

func XCTAssertRect(_ actual: Rect?, _ expected: JSONValue?, tolerance: Int = 0, _ message: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    guard let expected, !expected.isNull else {
        XCTAssertNil(actual, message, file: file, line: line)
        return
    }
    guard let actual else {
        XCTFail("\(message): nil statt \(expected)", file: file, line: line)
        return
    }
    let e = Golden.ints(expected)
    for (a, b) in zip(actual.list, e) where abs(a - b) > tolerance {
        XCTFail("\(message): \(actual) statt \(e) (±\(tolerance))", file: file, line: line)
        return
    }
}
