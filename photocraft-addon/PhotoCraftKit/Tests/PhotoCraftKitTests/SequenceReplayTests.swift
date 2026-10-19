import XCTest
@testable import PhotoCraftKit

/// Spielt die von Python mitgeschnittenen Antworten zurück und prüft, dass der Swift-Ablauf
/// dieselben Anfragen in derselben Reihenfolge sendet (golden/sequences.json).
final class ReplayPhotoCraft: PhotoCraftControlling {
    let transcript: [JSONValue]
    let exchange: URL
    var position = 0
    var mismatches: [String] = []

    init(transcript: [JSONValue], exchange: URL) {
        self.transcript = transcript
        self.exchange = exchange
    }

    func call(_ method: String, _ params: JSONValue, read: Bool) async throws -> JSONValue {
        guard position < transcript.count else {
            mismatches.append("zusätzlicher Aufruf \(method) \(params)")
            throw ControlError.rejected("Replay zu Ende")
        }
        let entry = transcript[position]
        position += 1
        let request = entry["request"]!
        if request["method"]?.stringValue != method || request["params"] != params {
            mismatches.append("Schritt \(position - 1): erwartet \(request), gesendet \(method) \(params)")
        }
        if method == "app.save", let path = params["path"]?.stringValue {
            // Wie der Python-Fake: eine lesbare Datei hinterlegen.
            let url = exchange.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Imaging.writePNG(GrayImage(width: 4, height: 4, fill: 255), to: url)
        }
        return entry["response"]?["result"] ?? .null
    }
}

final class SequenceReplayTests: XCTestCase {
    var scenarios: [String: JSONValue] = [:]
    var exchange: URL!

    override func setUpWithError() throws {
        Localization.choice = "en"  // Ebenennamen in den Mitschnitten sind englisch
        scenarios = try Golden.load("sequences")["scenarios"]?.objectValue ?? [:]
        exchange = FileManager.default.temporaryDirectory.appendingPathComponent("pck-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: exchange)
    }

    func run(_ name: String, steps: (Workflow, GenerationTask) async throws -> Void) async throws {
        let s = try XCTUnwrap(scenarios[name], "Szenario \(name) fehlt")
        let replay = ReplayPhotoCraft(transcript: s["transcript"]?.arrayValue ?? [], exchange: exchange)
        let task = s["task"]!
        let t = GenerationTask(id: task["id"]!.stringValue!, mode: task["mode"]!.stringValue!, prompt: task["prompt"]!.stringValue!,
                               params: ["mode": task["mode"]!, "margin": task["margin"]!])
        try await steps(Workflow(pc: replay, exchange: exchange), t)
        XCTAssertEqual(replay.mismatches, [], name)
        XCTAssertEqual(replay.position, replay.transcript.count, "\(name): nicht alle erwarteten Aufrufe gesendet")
        let final = s["final"]!
        XCTAssertEqual(t.region?.list, final["region"]?.rectValue?.list, "\(name): region")
        XCTAssertEqual(t.selection?.list, final["selection"]?.rectValue?.list, "\(name): selection")
        XCTAssertEqual(t.hasMask, final["has_mask"]?.boolValue, "\(name): has_mask")
        XCTAssertEqual(t.placedLayer, final["placed_layer"]?.intValue, "\(name): placed_layer")
        XCTAssertEqual(t.placedVariant, final["placed_variant"]?.intValue, "\(name): placed_variant")
    }

    static func twoVariants(_ t: GenerationTask) {
        t.variants = [Variant(index: 0, file: "jobs/\(t.id)/result-1.png"), Variant(index: 1, file: "jobs/\(t.id)/result-2.png")]
    }

    func testCaptureFillWithSelection() async throws {
        try await run("capture_fill_selection") { wf, t in _ = try await wf.capture(t) }
    }

    func testCaptureGenerateWithoutSelection() async throws {
        try await run("capture_generate_no_selection") { wf, t in _ = try await wf.capture(t) }
    }

    func testCaptureRefineInThirdTabReactivatesTarget() async throws {
        try await run("capture_refine_selection_third_tab") { wf, t in _ = try await wf.capture(t) }
    }

    func testFillPlaceAndSwap() async throws {
        try await run("fill_place_and_swap") { wf, t in
            _ = try await wf.capture(t)
            Self.twoVariants(t)
            try await wf.place(t, variant: 0, replace: false)
            try await wf.place(t, variant: 1, replace: true)
        }
    }

    func testSwapAfterSelectionChangeUsesOldLayerMask() async throws {
        try await run("fill_swap_after_selection_change") { wf, t in
            _ = try await wf.capture(t)
            Self.twoVariants(t)
            try await wf.place(t, variant: 0, replace: false)
            try await wf.place(t, variant: 1, replace: true)
            try await wf.place(t, variant: 0, replace: true)
        }
    }
}
