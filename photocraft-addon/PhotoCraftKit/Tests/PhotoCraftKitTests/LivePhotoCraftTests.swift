import XCTest
@testable import PhotoCraftKit

/// Ende-zu-Ende gegen eine echte PhotoCraft-Testinstanz – nur, wenn sie per Umgebung angegeben ist:
///
///     PHOTOCRAFT_LIVE_PORT=47899 PHOTOCRAFT_LIVE_TOKEN=<token-datei> PHOTOCRAFT_LIVE_EXCHANGE=<austausch> swift test
///
/// Legt ein eigenes Testdokument an und schließt es am Ende wieder; andere Dokumente bleiben unberührt.
final class LivePhotoCraftTests: XCTestCase {
    override func setUp() {
        Localization.choice = "en"
    }

    func testCaptureAndPlaceAgainstRealPhotoCraft() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PHOTOCRAFT_LIVE_PORT"].flatMap({ UInt16($0) }), let token = env["PHOTOCRAFT_LIVE_TOKEN"],
              let exchangePath = env["PHOTOCRAFT_LIVE_EXCHANGE"] else {
            throw XCTSkip("keine PhotoCraft-Testinstanz angegeben (PHOTOCRAFT_LIVE_*)")
        }
        let pc = ControlClient(port: port, tokenURL: URL(fileURLWithPath: token))
        let exchange = URL(fileURLWithPath: exchangePath)
        _ = try await pc.execute("file.new", ["width": 1200, "height": 800, "background": "white", "name": "PhotoCraftKit-Live"])
        _ = try await pc.execute("layer.new.layer", ["name": "Farbe"])
        _ = try await pc.execute("paint.stroke", ["points": [[100, 100, 1], [1100, 700, 1]], "size": 120, "color": "#2060ff"])
        _ = try await pc.execute("select.rect", ["x": 400, "y": 250, "width": 300, "height": 220, "ellipse": true, "feather": 4])
        let testDoc = try await pc.inspect()["session"]?["active"]?.intValue ?? 0

        let wf = Workflow(pc: pc, exchange: exchange)
        let t = GenerationTask(id: "live-\(UUID().uuidString.prefix(8))", mode: "fill", prompt: "Live-Test", params: ["margin": 0.35])
        let (context, mask) = try await wf.capture(t)
        XCTAssertEqual(t.selection, Rect(389, 239, 322, 242))
        let region = try XCTUnwrap(t.region)
        XCTAssertEqual(region, Geometry.contextRegion(Rect(389, 239, 322, 242), width: 1200, height: 800))
        XCTAssertEqual([context?.width, context?.height], [region.w, region.h])
        XCTAssertEqual([mask?.width, mask?.height], [region.w, region.h])
        XCTAssertGreaterThan(mask.map { Int($0[region.w / 2, region.h / 2]) } ?? 0, 200, "Maske in der Auswahlmitte weiß")

        for k in 1...2 {
            var img = RGBAImage(width: region.w, height: region.h, color: k == 1 ? [250, 220, 40, 255] : [200, 60, 200, 255])
            img.fill(0, 0, region.w / 2, region.h / 2, rgba: [30, 30, 30, 255])
            try Imaging.writePNG(img, to: exchange.appendingPathComponent("jobs/\(t.id)/result-\(k).png"))
        }
        t.variants = [Variant(index: 0, file: "jobs/\(t.id)/result-1.png"), Variant(index: 1, file: "jobs/\(t.id)/result-2.png")]
        let first = try await wf.place(t, variant: 0, replace: false)
        let second = try await wf.place(t, variant: 1, replace: true)

        let doc = try await pc.document()
        let layers = Workflow.layersByID(doc["layers"]?.arrayValue ?? [])
        XCTAssertNil(layers[first], "erste Variante ersetzt")
        XCTAssertEqual(layers[second]?["hasMask"]?.boolValue, true)
        XCTAssertEqual(layers[second]?["bounds"]?.rectValue, region)
        XCTAssertEqual(doc["hasSelection"]?.boolValue, true, "Auswahl wiederhergestellt")
        XCTAssertEqual(doc["selectionBounds"]?.rectValue, Rect(389, 239, 322, 242))
        let recent = try await pc.execute("prefs.get", ["path": "fileHandling.recentFiles"]).arrayValue ?? []
        XCTAssertFalse(recent.contains { ($0.stringValue ?? "").hasPrefix("jobs/") }, "„Zuletzt geöffnet“ bereinigt")

        _ = try await pc.execute("file.close", ["document": .int(testDoc)]) // eigenes Testdokument, ohne Rückfrage
        await pc.close()
    }

    /// Ein echter Auftrag „Füllen“ mit NV-AI (eine Variante, etwa 1–2 min GPU) – zusätzlich `NVAI_LIVE_URL`
    /// (und bei entferntem NV-AI `NVAI_LIVE_TOKEN`). Prüft die ganze Kette wie die App: Erfassen, Hochladen,
    /// Inpainting, Einfügen mit Ebenenmaske – und dass die Uploads danach in NV-AI gelöscht sind.
    func testFillWithRealNVAI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["PHOTOCRAFT_LIVE_PORT"].flatMap({ UInt16($0) }), let token = env["PHOTOCRAFT_LIVE_TOKEN"],
              let exchangePath = env["PHOTOCRAFT_LIVE_EXCHANGE"], let nvaiURL = env["NVAI_LIVE_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("keine PhotoCraft-Testinstanz oder kein NV-AI angegeben (PHOTOCRAFT_LIVE_*, NVAI_LIVE_URL)")
        }
        let pc = ControlClient(port: port, tokenURL: URL(fileURLWithPath: token))
        let nvai = NVAIClient(baseURL: nvaiURL, token: env["NVAI_LIVE_TOKEN"])
        _ = try await pc.execute("file.new", ["width": 1024, "height": 768, "background": "white", "name": "PhotoCraftKit-NVAI"])
        _ = try await pc.execute("layer.new.layer", ["name": "Wiese"])
        _ = try await pc.execute("paint.stroke", ["points": [[0, 600, 1], [1024, 600, 1]], "size": 340, "color": "#3f8f3a"])
        _ = try await pc.execute("select.rect", ["x": 380, "y": 330, "width": 260, "height": 260, "ellipse": true, "feather": 2])
        let testDoc = try await pc.inspect()["session"]?["active"]?.intValue ?? 0

        let wf = Workflow(pc: pc, exchange: URL(fileURLWithPath: exchangePath))
        let t = GenerationTask(id: "live-nvai-\(UUID().uuidString.prefix(8))", mode: "fill", prompt: "a red apple lying in the grass",
                               params: ["variants": 1, "margin": 0.35, "auto_place": true])
        var stages: [String] = []
        try await wf.run(t, nvai: nvai) { _, stage in if stages.last != stage { stages.append(stage) } }

        XCTAssertEqual(t.technique, "inpaint")
        XCTAssertEqual(t.variants.count, 1)
        let region = try XCTUnwrap(t.region)
        let layerID = try XCTUnwrap(t.placedLayer)
        let doc = try await pc.document()
        let layer = Workflow.layersByID(doc["layers"]?.arrayValue ?? [])[layerID]
        XCTAssertEqual(layer?["hasMask"]?.boolValue, true, "Auswahl als Ebenenmaske")
        XCTAssertEqual(layer?["bounds"]?.rectValue, region)
        XCTAssertEqual(doc["hasSelection"]?.boolValue, true, "Auswahl wiederhergestellt")

        // Die Uploads löscht der Ablauf im Hintergrund – kurz warten, dann nachsehen.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let leftovers = try await nvai.assets(kind: "upload").filter {
            ($0["meta"]?["original_name"]?.stringValue ?? "").hasPrefix("photocraft-\(t.id)")
        }
        XCTAssertEqual(leftovers.count, 0, "Uploads in NV-AI gelöscht")
        print("NV-AI-Livetest: \(t.modelName), \(t.working.map { "\($0.0)×\($0.1)" } ?? "?"), Stufen: \(stages.joined(separator: " → "))")

        _ = try await pc.execute("file.close", ["document": .int(testDoc)]) // eigenes Testdokument, ohne Rückfrage
        await pc.close()
    }
}
