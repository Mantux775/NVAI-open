import XCTest
@testable import PhotoCraftKit

/// „Arbeitsfläche erweitern“: dieselben Fälle wie tests/test_planning.py.
final class ExtendTests: XCTestCase {
    override func setUp() { Localization.choice = "en" }

    private func steps(_ v: [Int]) -> [(Int, Int, String)] {
        Planning.extendSteps(.array(v.map { .int($0) })).map {
            ($0["width"]!.intValue!, $0["height"]!.intValue!, $0["anchor"]!.stringValue!)
        }
    }

    func testAnchorOnTheOppositeSide() {
        XCTAssertTrue(Planning.extendSteps(nil).isEmpty)
        XCTAssertTrue(steps([0, 0, 0, 0]).isEmpty)
        let s = steps([256, 0, 0, 128])
        XCTAssertEqual(s.map(\.0), [256, 0]); XCTAssertEqual(s.map(\.1), [0, 128]); XCTAssertEqual(s.map(\.2), ["right", "top"])
        let first = Planning.extendSteps(.array([.int(1), .int(0), .int(0), .int(0)]))[0]
        XCTAssertEqual(first["relative"]?.truthy, true)
        XCTAssertEqual(first["extensionColor"]?.stringValue, "transparent")
    }

    func testEqualEdgesInOneCenteredStep() {
        let s = steps([200, 64, 200, 0])
        XCTAssertEqual(s.map(\.0), [400, 0]); XCTAssertEqual(s.map(\.1), [0, 64]); XCTAssertEqual(s.map(\.2), ["center", "bottom"])
    }

    func testExtendIsItsOwnModeThatComputesLikeFill() {
        XCTAssertEqual(Planning.baseMode("extend"), "fill")
        XCTAssertEqual(Planning.baseMode("refine"), "refine")
        XCTAssertEqual(Planning.layerName(mode: "extend", prompt: "harbour", k: 0, n: 1), "NV-AI Extend: harbour")
    }

    func testClamps() {
        let s = steps([-5, 0, 99999, 0])
        XCTAssertEqual(s.map(\.0), [Planning.extendMax]); XCTAssertEqual(s.map(\.2), ["left"])
    }

    func testOutpaintEdgesScalesBoxAndEdges() {
        var img = RGBAImage(width: 400, height: 200, color: [0, 0, 0, 0])
        for y in 0..<200 { for x in 0..<300 { img.pixels[(y * 400 + x) * 4 + 3] = 255 } }
        let cut = Planning.outpaintEdges(img, working: (800, 400))!
        XCTAssertEqual(cut.box, Rect(0, 0, 300, 200))
        XCTAssertEqual([cut.size.0, cut.size.1], [600, 400])
        XCTAssertEqual(cut.edges, [0, 0, 200, 0])
        XCTAssertNil(Planning.outpaintEdges(RGBAImage(width: 10, height: 10, color: [1, 2, 3, 255]), working: (10, 10)))
    }

    func testExtendPrefersSeamlessReferenceModel() throws {
        let qwen: JSONValue = .object(["id": .string("qwen"), "name": .string("Qwen"), "workflow": .string("qwen_image"),
                                       "features": .object(["mask": .bool(true), "img2img": .bool(true), "outpaint": .string("mask")])])
        let flux: JSONValue = .object(["id": .string("flux"), "name": .string("FLUX"), "workflow": .string("flux3_klein"),
                                       "features": .object(["mask": .bool(false), "img2img": .bool(false), "references": .int(10),
                                                            "outpaint": .string("reference")])])
        var (m, w) = try Planning.chooseModel(mode: "fill", wanted: nil, active: "qwen", models: [qwen, flux],
                                              masksSupported: true, extend: true)
        XCTAssertEqual(m["id"]?.stringValue, "flux"); XCTAssertNil(w)
        (m, _) = try Planning.chooseModel(mode: "fill", wanted: "qwen", active: nil, models: [qwen, flux],
                                          masksSupported: true, extend: true)
        XCTAssertEqual(m["id"]?.stringValue, "qwen")
        (m, _) = try Planning.chooseModel(mode: "fill", wanted: nil, active: "flux", models: [qwen, flux], masksSupported: true)
        XCTAssertEqual(m["id"]?.stringValue, "qwen")
        let plan = try Planning.plan(mode: "fill", prompt: "", params: .object(["variants": .int(2)]), model: flux,
                                     regionSize: (1216, 832), hasMask: true, alphaMask: true, masksSupported: true, outpaint: true)
        XCTAssertEqual(plan.technique, "outpaint")
        XCTAssertFalse(plan.sendMask); XCTAssertTrue(plan.sendImage)
        XCTAssertNil(plan.payload["denoise"])
    }
}
