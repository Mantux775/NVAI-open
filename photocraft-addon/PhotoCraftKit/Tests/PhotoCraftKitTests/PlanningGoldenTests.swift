import XCTest
@testable import PhotoCraftKit

final class PlanningGoldenTests: XCTestCase {
    var golden: JSONValue!
    var models: [String: JSONValue] = [:]

    override func setUpWithError() throws {
        Localization.choice = "en"
        golden = try Golden.load("planning")
        models = golden["models"]?.objectValue ?? [:]
    }

    func testConstantsMatchPython() {
        let c = golden["constants"]!
        XCTAssertEqual(c["DEFAULT_FILL_PROMPT"]?.stringValue, Planning.defaultFillPrompt)
        XCTAssertEqual(c["DEFAULT_FILL_NEGATIVE"]?.stringValue, Planning.defaultFillNegative)
        XCTAssertEqual(c["OUTPAINT_GROW"]?.intValue, Planning.outpaintGrow)
        XCTAssertEqual(c["OUTPAINT_BLUR"]?.doubleValue, Planning.outpaintBlur)
        XCTAssertEqual(c["OUTPAINT_MARGIN"]?.doubleValue, Planning.outpaintMargin)
        XCTAssertEqual(c["REFINE_PAD"]?.intValue, Planning.refinePad)
        XCTAssertEqual(Set((c["WEAK_PROMPT_WORKFLOWS"]?.arrayValue ?? []).compactMap(\.stringValue)), Planning.weakPromptWorkflows)
        XCTAssertEqual(c["INTERACTIVE_STEPS"]?["qwen_image"]?.intValue, Planning.interactiveSteps["qwen_image"])
        for (wf, px) in c["NATIVE_PIXELS"]?.objectValue ?? [:] { XCTAssertEqual(px.intValue, Planning.nativePixels[wf], wf) }
    }

    func testCapable() {
        for c in golden["capable"]?.arrayValue ?? [] {
            let model = models[c["model"]!.stringValue!]!
            XCTAssertEqual(Planning.capable(model, c["need"]!.stringValue!, masksSupported: c["masks_supported"]!.boolValue!),
                           c["out"]!.boolValue!, "capable \(c)")
        }
    }

    func testChooseModel() {
        for c in golden["choose_model"]?.arrayValue ?? [] {
            let i = c["in"]!, o = c["out"]!
            let list = (i["models"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { models[$0] } }
            do {
                let (model, warning) = try Planning.chooseModel(mode: i["mode"]!.stringValue!, wanted: i["wanted"]?.stringValue,
                                                                active: i["active"]?.stringValue, models: list,
                                                                masksSupported: i["masks_supported"]!.boolValue!)
                XCTAssertNil(o["error"], "Fehler erwartet: \(i)")
                XCTAssertEqual(model["id"]?.stringValue, o["model"]?.stringValue, "Modell \(i)")
                XCTAssertEqual(warning?.code, o["warning"]?.stringValue, "Warnung \(i)")
            } catch let error as PlanError {
                XCTAssertEqual(error.code, o["error"]?.stringValue, "Fehler \(i)")
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testTechnique() {
        for c in golden["technique_for"]?.arrayValue ?? [] {
            let i = c["in"]!
            XCTAssertEqual(Planning.techniqueFor(mode: i["mode"]!.stringValue!, model: models[i["model"]!.stringValue!]!,
                                                 hasMask: i["has_mask"]!.boolValue!, masksSupported: i["masks_supported"]!.boolValue!),
                           c["out"]!.stringValue!, "technique \(i)")
        }
    }

    func testRegions() {
        for c in golden["region_for"]?.arrayValue ?? [] {
            let i = c["in"]!
            let r = Planning.regionFor(mode: i["mode"]!.stringValue!, selection: i["selection"]?.rectValue,
                                       width: i["width"]!.intValue!, height: i["height"]!.intValue!, margin: i["margin"]!.doubleValue!)
            XCTAssertEqual(r.list, Golden.ints(c["out"]), "region_for \(i)")
        }
        for c in golden["outpaint_region"]?.arrayValue ?? [] {
            let i = c["in"]!
            let r = Planning.outpaintRegion(i["transparent"]!.rectValue!, width: i["width"]!.intValue!,
                                            height: i["height"]!.intValue!, margin: i["margin"]!.doubleValue!)
            XCTAssertEqual(r.list, Golden.ints(c["out"]), "outpaint_region \(i)")
        }
    }

    func testPlan() {
        for c in golden["plan"]?.arrayValue ?? [] {
            let i = c["in"]!, o = c["out"]!
            let size = Golden.ints(i["region_size"])
            do {
                let p = try Planning.plan(mode: i["mode"]!.stringValue!, prompt: i["prompt"]!.stringValue!, params: i["params"]!,
                                          model: models[i["model"]!.stringValue!], regionSize: (size[0], size[1]),
                                          hasMask: i["has_mask"]!.boolValue!, alphaMask: i["alpha_mask"]!.boolValue!,
                                          masksSupported: i["masks_supported"]!.boolValue!)
                XCTAssertNil(o["error"], "Fehler erwartet: \(i)")
                XCTAssertEqual(p.modelID, o["model_id"]?.stringValue, "model_id \(i)")
                XCTAssertEqual(p.technique, o["technique"]?.stringValue, "technique \(i)")
                XCTAssertEqual([p.working.0, p.working.1], Golden.ints(o["working"]), "working \(i)")
                XCTAssertEqual(JSONValue.object(p.payload), o["payload"], "payload \(i)")
                XCTAssertEqual(p.sendImage, o["send_image"]?.boolValue, "send_image \(i)")
                XCTAssertEqual(p.sendMask, o["send_mask"]?.boolValue, "send_mask \(i)")
                XCTAssertEqual(p.maskGrow, o["mask_grow"]?.intValue, "mask_grow \(i)")
                XCTAssertEqual(p.maskBlur, o["mask_blur"]?.doubleValue, "mask_blur \(i)")
                XCTAssertEqual(p.warnings.map(\.code), (o["warnings"]?.arrayValue ?? []).compactMap(\.stringValue), "warnings \(i)")
            } catch let error as PlanError {
                XCTAssertEqual(error.code, o["error"]?.stringValue, "Fehler \(i)")
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testLayerName() {
        // Ebenennamen sind sichtbar und übersetzt – die Golden-Daten halten beide Sprachen fest.
        defer { Localization.choice = "en" }
        for c in golden["layer_name"]?.arrayValue ?? [] {
            let i = c["in"]!
            Localization.choice = i["lang"]?.stringValue ?? "en"
            XCTAssertEqual(Planning.layerName(mode: i["mode"]!.stringValue!, prompt: i["prompt"]!.stringValue!,
                                              k: i["k"]!.intValue!, n: i["n"]!.intValue!), c["out"]!.stringValue!)
        }
    }
}
