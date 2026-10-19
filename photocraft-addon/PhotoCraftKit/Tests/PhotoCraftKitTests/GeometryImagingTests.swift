import XCTest
@testable import PhotoCraftKit

final class GeometryGoldenTests: XCTestCase {
    var golden: JSONValue!

    override func setUpWithError() throws { golden = try Golden.load("imaging") }

    func testConstants() {
        let c = golden["constants"]
        XCTAssertEqual(c?["TARGET_PIXELS"]?.intValue, Geometry.targetPixels)
        XCTAssertEqual(c?["MIN_SIDE"]?.intValue, Geometry.minSide)
        XCTAssertEqual(c?["MAX_SIDE"]?.intValue, Geometry.maxSide)
        XCTAssertEqual(c?["MULTIPLE"]?.intValue, Geometry.multiple)
    }

    func testWorkingSize() {
        for case_ in golden["working_size"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let (w, h) = Geometry.workingSize(i["w"]!.intValue!, i["h"]!.intValue!, target: i["target"]!.intValue!)
            XCTAssertEqual([w, h], Golden.ints(case_["out"]), "working_size \(i)")
        }
    }

    func testContextRegionAndGrowRect() {
        for case_ in golden["context_region"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let r = Geometry.contextRegion(i["sel"]!.rectValue!, width: i["width"]!.intValue!, height: i["height"]!.intValue!,
                                           marginFrac: i["margin_frac"]!.doubleValue!, minMargin: i["min_margin"]!.intValue!)
            XCTAssertEqual(r.list, Golden.ints(case_["out"]), "context_region \(i)")
        }
        for case_ in golden["grow_rect"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let r = Geometry.growRect(i["rect"]!.rectValue!, i["margin"]!.intValue!, width: i["width"]!.intValue!,
                                      height: i["height"]!.intValue!)
            XCTAssertEqual(r.list, Golden.ints(case_["out"]), "grow_rect \(i)")
        }
    }
}

final class ImagingGoldenTests: XCTestCase {
    var golden: JSONValue!

    override func setUpWithError() throws { golden = try Golden.load("imaging") }

    func testMaskBBox() {
        for case_ in golden["mask_bbox"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let m = Golden.mask(size: i["size"], rects: i["rects"])
            XCTAssertRect(Imaging.maskBBox(m, level: UInt8(i["level"]!.intValue!)), case_["out"], "mask_bbox \(i)")
        }
    }

    func testMaskFromAlpha() {
        for case_ in golden["mask_from_alpha"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let img = Golden.rgba(size: i["size"], base: i["base"], rects: i["rects"])
            let m = Imaging.maskFromAlpha(img, threshold: UInt8(i["threshold"]!.intValue!))
            XCTAssertRect(m.flatMap { Imaging.maskBBox($0) }, case_["out"], "mask_from_alpha \(i)")
        }
    }

    func testPrepareModelMask() {
        for case_ in golden["prepare_model_mask"]?.arrayValue ?? [] {
            let i = case_["in"]!, o = case_["out"]!, tol = case_["tolerance"]!
            let size = Golden.ints(i["out_size"])
            let m = Imaging.prepareModelMask(Golden.mask(size: i["size"], rects: i["rects"]), size: (size[0], size[1]),
                                             grow: i["grow"]!.intValue!, blur: i["blur"]!.doubleValue!)
            XCTAssertEqual([m.width, m.height], size)
            let bboxTol = tol["bbox"]!.intValue!
            XCTAssertRect(Imaging.maskBBox(m, level: 128), o["bbox_128"], tolerance: bboxTol, "bbox_128 \(i)")
            XCTAssertRect(Imaging.maskBBox(m, level: 8), o["bbox_8"], tolerance: bboxTol * 2 + 2, "bbox_8 \(i)")
            for s in o["samples"]?.arrayValue ?? [] {
                let v = Golden.ints(s)
                XCTAssertLessThanOrEqual(abs(Int(m[v[0], v[1]]) - v[2]), tol["value"]!.intValue!, "Pixel \(v) in \(i)")
            }
            let soft = m.pixels.contains { $0 > 0 && $0 < 255 }
            XCTAssertEqual(soft, o["has_soft_edge"]?.boolValue, "weicher Rand \(i)")
        }
    }

    func testFlattenForModel() {
        for case_ in golden["flatten_for_model"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let out = Imaging.flattenForModel(Golden.rgba(size: i["size"], base: i["base"], rects: i["rects"]))
            let tol = case_["tolerance"]!.intValue!
            for s in case_["out"]?["samples"]?.arrayValue ?? [] {
                let x = s[0]!.intValue!, y = s[1]!.intValue!, rgb = Golden.ints(s[2])
                let px = out.pixel(x, y)
                for c in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(px[c]) - rgb[c]), tol, "Pixel (\(x),\(y)) in \(i)") }
                XCTAssertEqual(px[3], 255)
            }
        }
    }

    func testBakeAlpha() {
        for case_ in golden["bake_alpha"]?.arrayValue ?? [] {
            let i = case_["in"]!
            let size = Golden.ints(i["image_size"]), rgb = Golden.ints(i["rgb"]).map { UInt8($0) }
            let img = RGBAImage(width: size[0], height: size[1], color: rgb + [255])
            let out = Imaging.bakeAlpha(img, mask: Golden.mask(size: i["mask_size"], rects: i["rects"]))
            for s in case_["out"]?["samples"]?.arrayValue ?? [] {
                let v = Golden.ints(s)
                XCTAssertLessThanOrEqual(abs(Int(out.pixel(v[0], v[1])[3]) - v[2]), case_["tolerance"]!.intValue!, "Alpha \(v)")
            }
        }
    }

    func testPNGRoundTrip() throws {
        var img = RGBAImage(width: 7, height: 5, color: [10, 20, 30, 255])
        img.fill(2, 1, 5, 4, rgba: [200, 100, 50, 0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pck-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Imaging.writePNG(img, to: url)
        let back = try Imaging.readRGBA(url)
        XCTAssertEqual(back.width, 7)
        XCTAssertEqual(back.pixel(0, 0), [10, 20, 30, 255])
        XCTAssertEqual(back.pixel(3, 2)[3], 0)
        let mask = GrayImage(width: 3, height: 2, pixels: [0, 128, 255, 255, 0, 7])
        try Imaging.writePNG(mask, to: url)
        XCTAssertEqual(try Imaging.readGray(url).pixels, mask.pixels)
    }

    func testFitHelpersKeepRequestedSize() {
        let img = RGBAImage(width: 64, height: 32, color: [1, 2, 3, 255])
        let exact = Imaging.fitExact(img, width: 100, height: 50)
        XCTAssertEqual([exact.width, exact.height], [100, 50])
        let cover = Imaging.fitCover(img, width: 40, height: 40)
        XCTAssertEqual([cover.width, cover.height], [40, 40])
        XCTAssertEqual(cover.pixel(20, 20)[0...2], [1, 2, 3])
    }
}
