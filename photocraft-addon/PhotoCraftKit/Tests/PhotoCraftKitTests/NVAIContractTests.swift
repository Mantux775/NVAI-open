import Foundation
import XCTest
@testable import PhotoCraftKit

/// Der API-Vertrag von NV-AI (Golden/nvai-openapi.json, Kopie von NV-AI/server/openapi.json).
///
/// Geprüft werden die Teile von JSON Schema, die FastAPI erzeugt – plus: keine unbekannten Felder.
/// NV-AI ignoriert die nämlich still, ein Tippfehler im Request fiele sonst nie auf.
struct NVAIContract {
    let spec: JSONValue

    static func load() throws -> NVAIContract { NVAIContract(spec: try Golden.load("nvai-openapi")) }

    var apiVersion: Int? { spec["info"]?["x-api-version"]?.intValue }

    func schema(_ name: String) -> JSONValue { spec["components"]?["schemas"]?[name] ?? .null }

    func resolve(_ schema: JSONValue) -> JSONValue {
        var s = schema
        while let ref = s["$ref"]?.stringValue, let name = ref.split(separator: "/").last { s = self.schema(String(name)) }
        return s
    }

    func violations(_ value: JSONValue, _ schema: JSONValue, at path: String = "") -> [String] {
        let s = resolve(schema)
        if let options = s["anyOf"]?.arrayValue {
            let results = options.map { violations(value, $0, at: path) }
            return results.contains(where: \.isEmpty) ? [] : (results.min { $0.count < $1.count } ?? [])
        }
        if let type = s["type"]?.stringValue, !Self.matches(value, type) { return ["\(path): \(value) ist kein \(type)"] }
        var errors: [String] = []
        if let allowed = s["enum"]?.arrayValue, !allowed.contains(value) { errors.append("\(path): \(value) nicht erlaubt") }
        if let x = value.doubleValue {
            if let min = s["minimum"]?.doubleValue, x < min { errors.append("\(path): \(x) < \(min)") }
            if let max = s["maximum"]?.doubleValue, x > max { errors.append("\(path): \(x) > \(max)") }
            if let m = s["multipleOf"]?.doubleValue, x.truncatingRemainder(dividingBy: m) != 0 {
                errors.append("\(path): \(x) kein Vielfaches von \(m)")
            }
        }
        if let items = value.arrayValue {
            if let max = s["maxItems"]?.intValue, items.count > max { errors.append("\(path): mehr als \(max) Einträge") }
            for (i, item) in items.enumerated() { errors += violations(item, s["items"] ?? [:], at: "\(path)[\(i)]") }
        }
        if let object = value.objectValue, let props = s["properties"]?.objectValue {
            for key in (s["required"]?.arrayValue ?? []).compactMap(\.stringValue) where object[key] == nil {
                errors.append("\(path).\(key): fehlt")
            }
            for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                if let p = props[key] {
                    errors += violations(item, p, at: "\(path).\(key)")
                } else if s["additionalProperties"]?.boolValue != true {
                    errors.append("\(path).\(key): unbekanntes Feld – nicht im Vertrag")
                }
            }
        }
        return errors
    }

    static func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object), ("null", .null),
             ("number", .int), ("number", .double):
            return true
        case ("integer", _):
            return value.intValue != nil // auch 28.0 – JSON kennt keinen Unterschied
        default:
            return false
        }
    }

    /// Vorlage aus dem Vertrag, die zu Methode und Pfad passt – feste Pfade vor Platzhaltern.
    func operation(_ method: String, _ path: String) -> (template: String, op: JSONValue)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let templates = (spec["paths"]?.objectValue ?? [:]).keys.sorted {
            ($0.filter { $0 == "{" }.count, $0) < ($1.filter { $0 == "{" }.count, $1)
        }
        for template in templates {
            let tparts = template.split(separator: "/", omittingEmptySubsequences: false)
            guard tparts.count == parts.count else { continue }
            let fits = zip(tparts, parts).allSatisfy { t, p in t == p || (t.hasPrefix("{") && t.hasSuffix("}") && !p.isEmpty) }
            if fits, let op = spec["paths"]?[template]?[method.lowercased()] { return (template, op) }
        }
        return nil
    }

    func problems(_ r: StubRequest) -> (template: String?, problems: [String]) {
        guard let found = operation(r.method, r.path) else { return (nil, ["\(r.method) \(r.path): nicht im Vertrag"]) }
        let at = "\(r.method) \(found.template)"
        let known = Set((found.op["parameters"]?.arrayValue ?? [])
            .filter { $0["in"]?.stringValue == "query" }.compactMap { $0["name"]?.stringValue })
        var out = r.query.filter { !known.contains($0) }.map { "\(at): Query-Parameter \($0) unbekannt" }
        let content = found.op["requestBody"]?["content"]
        if r.contentType.hasPrefix("application/json") {
            if let schema = content?["application/json"]?["schema"] {
                out += violations((try? JSONValue.parse(r.body)) ?? .null, schema, at: at)
            } else {
                out.append("\(at): nimmt kein JSON")
            }
        } else if r.contentType.hasPrefix("multipart/form-data") {
            if let schema = content?["multipart/form-data"]?["schema"] {
                let s = resolve(schema)
                let fields = Set(Self.multipartNames(r.body))
                let props = Set((s["properties"]?.objectValue ?? [:]).keys)
                let required = Set((s["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                out += fields.subtracting(props).sorted().map { "\(at): Feld \($0) unbekannt" }
                out += required.subtracting(fields).sorted().map { "\(at): Feld \($0) fehlt" }
            } else {
                out.append("\(at): nimmt kein multipart/form-data")
            }
        }
        return (found.template, out)
    }

    /// Antwortet die Attrappe so, wie der Vertrag es zusagt? Sonst prüfen die Tests ins Leere.
    func responseProblems(_ r: StubRequest, _ answer: StubResponse) -> [String] {
        guard answer.status == 200, let found = operation(r.method, r.path) else { return [] }
        let at = "Antwort \(r.method) \(found.template)"
        let content = found.op["responses"]?["200"]?["content"]?.objectValue ?? [:]
        let type = answer.contentType.split(separator: ";").first.map(String.init) ?? ""
        let declared = content.keys.sorted()
        guard declared.contains(where: { $0 == type || ($0.hasSuffix("/*") && type.hasPrefix(String($0.dropLast()))) }) else {
            return ["\(at): \(type) nicht in \(declared)"]
        }
        guard type == "application/json", let schema = content["application/json"]?["schema"] else { return [] }
        return violations((try? JSONValue.parse(answer.body)) ?? .null, schema, at: at)
    }

    /// `Content-Disposition: form-data; name="file"; filename="…"` – nur `name`, nicht `filename`.
    static func multipartNames(_ body: Data) -> [String] {
        String(decoding: body, as: UTF8.self).components(separatedBy: "; name=\"").dropFirst()
            .compactMap { $0.components(separatedBy: "\"").first }
    }
}

// MARK: - NV-AI-Attrappe über URLProtocol

struct StubRequest: Sendable {
    let method: String
    let path: String
    let query: [String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    var contentType: String { header("Content-Type") ?? "" }
}

struct StubResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json(_ value: JSONValue, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: (try? value.serialized()) ?? Data())
    }
}

/// Antwortet wie NV-AI 0.2.0 laut Vertrag und merkt sich jede Anfrage. Jede Attrappe hat ihren
/// eigenen Hostnamen; ohne Attrappe für den Host gilt NV-AI als nicht erreichbar.
final class StubNVAI: @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var servers: [String: StubNVAI] = [:]
        func add(_ s: StubNVAI) { lock.withLock { servers[s.host] = s } }
        func server(for host: String?) -> StubNVAI? { lock.withLock { host.flatMap { servers[$0] } } }
    }

    static let registry = Registry()

    static func version(api: Int = 1, authorized: Bool = true,
                        features: [String] = ["model_features", "mask", "references", "upsampler", "upload"]) -> JSONValue {
        ["name": "NV-AI", "version": "0.2.0", "api": .int(api), "auth": "token", "authorized": .bool(authorized),
         "features": .array(features.map { .string($0) })]
    }

    let host = "nvai-\(UUID().uuidString.prefix(8).lowercased())"
    let spec: JSONValue
    /// `nil` = Server vor 0.2.0 (404); `versionHTML` = alter Server, der unbekannte Pfade mit HTML beantwortet.
    var version: JSONValue?
    var versionHTML = false
    private let lock = NSLock()
    private var log: [(StubRequest, StubResponse)] = []

    init(spec: JSONValue, version: JSONValue? = StubNVAI.version()) {
        self.spec = spec
        self.version = version
        Self.registry.add(self)
    }

    var requests: [StubRequest] { lock.withLock { log.map { $0.0 } } }
    var exchanges: [(StubRequest, StubResponse)] { lock.withLock { log } }

    func client(token: String? = nil) -> NVAIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return NVAIClient(baseURL: URL(string: "http://\(host):8100")!, token: token, session: URLSession(configuration: config))
    }

    func handle(_ r: StubRequest) -> StubResponse {
        let answer = respond(r)
        lock.withLock { log.append((r, answer)) }
        return answer
    }

    private func respond(_ r: StubRequest) -> StubResponse {
        let now = 1_760_000_000.0
        let asset: JSONValue = ["id": "a1", "job_id": "job-r", "kind": "image", "filename": "a1.png", "url": "/files/a1.png",
                                "thumb_url": nil, "prompt": "", "model_id": "qwen-image-2512-nvfp4",
                                "meta": ["seed": 7, "model_name": "Qwen-Image 2512"], "created_at": .double(now)]
        func job(_ id: String, _ status: String) -> JSONValue {
            ["id": .string(id), "kind": "img2img", "status": .string(status), "progress": 0.5, "stage": "", "params": [:],
             "asset_ids": ["a1"], "error": nil, "created_at": .double(now), "started_at": nil, "finished_at": nil]
        }
        let notFound = StubResponse.json(["detail": "Not Found"], status: 404)
        switch (r.method, r.path) {
        case ("GET", "/api/version"):
            if versionHTML { return StubResponse(status: 200, body: Data("<!doctype html>".utf8), contentType: "text/html") }
            return version.map { StubResponse.json($0) } ?? notFound
        case ("GET", "/openapi.json"):
            return .json(spec)
        case ("GET", "/api/health"):
            return .json(["current_job": "job-r", "active_models": ["image": "qwen-image-2512-nvfp4"]])
        case ("GET", "/api/models"):
            return .json([["id": "qwen-image-2512-nvfp4", "name": "Qwen-Image 2512", "kind": "image", "family": "qwen",
                           "workflow": "qwen_image", "size_gb": 20.0, "license": "Apache-2.0", "commercial_ok": true,
                           "runnable": true, "features": ["img2img": true, "mask": true]]])
        case ("GET", "/api/assets"):
            return .json([asset])
        case ("POST", "/api/upload"):
            var upload = asset.objectValue ?? [:]
            upload["id"] = "upload-1"; upload["kind"] = "upload"; upload["job_id"] = .null
            return .json(.object(upload))
        case ("POST", "/api/generate/image"):
            return .json(job("job-r", "running"))
        case ("POST", "/api/jobs/current/cancel"):
            return .json(["ok": true])
        case ("POST", "/api/prompt/expand"):
            return .json(["prompt": "a lighthouse", "expanded": "A tall white lighthouse on a rocky coast at dusk.",
                          "seconds": 14.2])
        case (let method, let path) where path.hasPrefix("/api/assets/"):
            return .json(method == "GET" ? asset : ["ok": true])
        case (let method, let path) where path.hasPrefix("/api/jobs/"):
            let id = String(path.split(separator: "/").last ?? "")
            guard let status = ["job-q": "queued", "job-r": "running"][id] else { return notFound }
            return .json(method == "GET" ? job(id, status) : ["ok": true])
        case ("GET", let path) where path.hasPrefix("/files/"):
            return StubResponse(status: 200, body: Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png")
        default:
            return notFound
        }
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = StubNVAI.registry.server(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        let r = StubRequest(method: request.httpMethod ?? "GET", path: url.path, query: query,
                            headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        let answer = server.handle(r)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": answer.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession reicht den Body an URLProtocol meist als Stream statt als `httpBody` weiter.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Tests

final class NVAIContractTests: XCTestCase {
    var contract: NVAIContract!

    /// Alles, was NVAIClient bei NV-AI aufruft – `testClientRequestsFollowContract` muss jede Zeile auslösen.
    static let used: Set<String> = [
        "GET /api/version", "GET /api/health", "GET /api/models", "GET /api/assets", "GET /api/assets/{asset_id}",
        "DELETE /api/assets/{asset_id}", "POST /api/upload", "POST /api/generate/image", "GET /api/jobs/{job_id}",
        "DELETE /api/jobs/{job_id}", "POST /api/jobs/current/cancel", "GET /files/{filename}",
        "POST /api/prompt/expand",
    ]

    override func setUpWithError() throws {
        Localization.choice = "en"
        contract = try NVAIContract.load()
    }

    /// NV-AI liefert Modelltexte und Fehler in der Sprache aus `Accept-Language` – der Client sendet die gewählte.
    func testAcceptLanguageFollowsChoice() async throws {
        let nv = StubNVAI(spec: contract.spec, version: StubNVAI.version())
        let client = nv.client()
        _ = try await client.health()
        Localization.choice = "de"
        defer { Localization.choice = "en" }
        XCTAssertEqual(t("Füllen", "Fill"), "Füllen")
        _ = try await client.health()
        let languages = nv.exchanges.map { request, _ in
            request.headers.first { $0.key.lowercased() == "accept-language" }?.value
        }
        XCTAssertEqual(languages, ["en", "de"])
    }

    func testContractSpeaksClientAPIVersion() {
        XCTAssertEqual(contract.apiVersion, NVAIClient.apiVersion)
    }

    /// `/api/health` ist bewusst untypisiert (Diagnose, ändert sich oft) – dessen Felder tolerant lesen.
    func testFieldsWeReadExist() {
        let read: [String: Set<String>] = [
            "VersionInfo": ["version", "api", "features", "auth", "authorized"],
            "Job": ["id", "status", "progress", "stage", "error", "asset_ids"],
            "Asset": ["id", "kind", "url", "meta", "created_at"],
            "ModelInfo": ["id", "name", "workflow", "runnable", "features", "vram_gb", "commercial_ok", "warning", "best_for"],
        ]
        for (name, fields) in read {
            let props = Set((contract.schema(name)["properties"]?.objectValue ?? [:]).keys)
            XCTAssertTrue(fields.isSubset(of: props), "\(name): \(fields.subtracting(props).sorted())")
        }
    }

    /// Was `Planning.plan` für die Golden-Fälle erzeugt – samt Upload-ids wie in `Workflow.run`.
    func testPlannerPayloadsFitRequestSchema() throws {
        let golden = try Golden.load("planning")
        let models = golden["models"]?.objectValue ?? [:]
        let schema: JSONValue = ["$ref": "#/components/schemas/GenerateImageRequest"]
        var problems = Set<String>()
        var count = 0
        for c in golden["plan"]?.arrayValue ?? [] {
            let i = c["in"]!
            let size = Golden.ints(i["region_size"])
            guard let plan = try? Planning.plan(mode: i["mode"]!.stringValue!, prompt: i["prompt"]!.stringValue!,
                                                params: i["params"]!, model: models[i["model"]!.stringValue!],
                                                regionSize: (size[0], size[1]), hasMask: i["has_mask"]!.boolValue!,
                                                alphaMask: i["alpha_mask"]!.boolValue!,
                                                masksSupported: i["masks_supported"]!.boolValue!) else { continue }
            var payload = plan.payload
            if plan.sendImage {
                if plan.technique == "reference" { payload["reference_asset_ids"] = ["upload-1"] } else { payload["image_asset_id"] = "upload-1" }
                if plan.sendMask { payload["mask_asset_id"] = "upload-2" }
            }
            // So, wie es über die Leitung geht: serialisieren und wieder lesen.
            let wire = try JSONValue.parse(try JSONValue.object(payload).serialized())
            problems.formUnion(contract.violations(wire, schema, at: "payload"))
            count += 1
        }
        XCTAssertGreaterThan(count, 200)
        XCTAssertEqual(problems.sorted(), [])
    }

    func testClientRequestsFollowContract() async throws {
        let nv = StubNVAI(spec: contract.spec)
        let client = nv.client(token: "geheim")
        let info = try await client.checkCompatible()
        XCTAssertEqual(info?.api, NVAIClient.apiVersion)
        let masks = try await client.supportsMasks()
        XCTAssertTrue(masks)
        _ = try await client.health()
        _ = try await client.imageModels()
        _ = try await client.assets(kind: "upload")
        let upload = try await client.upload(png: Data([0x89, 0x50, 0x4E, 0x47]), filename: "photocraft-test-context.png")
        _ = try await client.generateImage(["prompt": "Ein Leuchtturm im Nebel", "batch_size": 2, "width": 1024, "height": 768,
                                            "image_asset_id": upload["id"] ?? .null, "denoise": 0.5, "steps": 28])
        let asset = try await client.asset("a1")
        _ = try await client.fetch(asset["url"]?.stringValue ?? "")
        _ = try await client.job("job-r")
        try await client.cancel(jobID: "job-q") // wartend → DELETE /api/jobs/{id}
        try await client.cancel(jobID: "job-r") // läuft gerade → POST /api/jobs/current/cancel
        try await client.deleteAsset("upload-1")
        let expanded = try await client.expandPrompt("a lighthouse")
        XCTAssertEqual(expanded.seconds, 14.2)

        var used = Set<String>()
        var problems: [String] = []
        for (r, answer) in nv.exchanges {
            let (template, found) = contract.problems(r)
            used.insert("\(r.method) \(template ?? r.path)")
            problems += found + contract.responseProblems(r, answer)
        }
        XCTAssertEqual(problems, [])
        XCTAssertEqual(used, Self.used)
        XCTAssertTrue(nv.requests.allSatisfy { $0.header("X-NVAI-Token") == "geheim" })
    }

    func testCurrentServerIsCompatibleAndVersionIsCached() async throws {
        let nv = StubNVAI(spec: contract.spec)
        let client = nv.client()
        let info = try await client.checkCompatible()
        XCTAssertEqual(info?.version, "0.2.0")
        XCTAssertEqual(info?.authorized, true)
        let masks = try await client.supportsMasks()
        XCTAssertTrue(masks)
        XCTAssertEqual(nv.requests.map(\.path), ["/api/version"]) // gemerkt, kein openapi.json
        XCTAssertNil(nv.requests.first?.header("X-NVAI-Token"))
    }

    func testFeaturesWithoutMaskMeanNoMasks() async throws {
        let nv = StubNVAI(spec: contract.spec, version: StubNVAI.version(features: ["model_features", "references"]))
        let masks = try await nv.client().supportsMasks()
        XCTAssertFalse(masks)
    }

    func testExpandFollowsFeatures() async throws {
        let with = try await StubNVAI(spec: contract.spec, version: StubNVAI.version(features: ["expand_prompt"])).client().supportsExpand()
        XCTAssertTrue(with)
        let without = try await StubNVAI(spec: contract.spec).client().supportsExpand()
        XCTAssertFalse(without)
        let old = try await StubNVAI(spec: contract.spec, version: nil).client().supportsExpand()
        XCTAssertFalse(old)
    }

    func testOtherAPIVersionIsRefused() async {
        let nv = StubNVAI(spec: contract.spec, version: StubNVAI.version(api: 2))
        await assertIncompatible(nv.client(), containing: "API version 2")
    }

    func testUnauthorizedIsRefused() async {
        let nv = StubNVAI(spec: contract.spec, version: StubNVAI.version(authorized: false))
        await assertIncompatible(nv.client(), containing: "token is missing or wrong")
    }

    func testLocalOnlyServerSaysHowToOpenIt() async {
        var version = StubNVAI.version(authorized: false).objectValue ?? [:]
        version["auth"] = "local"
        let nv = StubNVAI(spec: contract.spec, version: .object(version))
        await assertIncompatible(nv.client(), containing: "-Lan")
    }

    func testServerBefore020FallsBackToOpenAPI() async throws {
        let nv = StubNVAI(spec: contract.spec, version: nil) // /api/version → 404
        let client = nv.client()
        let version = try await client.version()
        XCTAssertNil(version)
        let compatible = try await client.checkCompatible()
        XCTAssertNil(compatible)
        let masks = try await client.supportsMasks() // laut openapi.json kennt GenerateImageRequest mask_asset_id
        XCTAssertTrue(masks)
        XCTAssertTrue(nv.requests.map(\.path).contains("/openapi.json"))
    }

    func testHTMLAnswerCountsAsOldServer() async throws {
        let nv = StubNVAI(spec: contract.spec)
        nv.versionHTML = true
        let version = try await nv.client().version()
        XCTAssertNil(version)
    }

    func testUnreachableIsNotMistakenForOldServer() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = NVAIClient(baseURL: URL(string: "http://nvai-niemand:8100")!, session: URLSession(configuration: config))
        do {
            _ = try await client.version()
            XCTFail("Fehler erwartet")
        } catch let error as NVAIError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCheckerCatchesBadPayloads() {
        let schema: JSONValue = ["$ref": "#/components/schemas/GenerateImageRequest"]
        let bad: JSONValue = ["prompt": "x", "mask_asset": "m", "width": 1001, "batch_size": 9, "reference_asset_ids": .array(Array(repeating: "a", count: 11))]
        let problems = contract.violations(bad, schema, at: "p")
        XCTAssertEqual(problems.count, 4, "\(problems)")
        XCTAssertEqual(contract.violations(["negative_prompt": "x"], schema, at: "p"), ["p.prompt: fehlt"])

        let version = StubRequest(method: "GET", path: "/api/version", query: [], headers: [:], body: Data())
        var wrong = StubNVAI.version().objectValue ?? [:]
        wrong["auth"] = "offen"
        XCTAssertEqual(contract.responseProblems(version, .json(.object(wrong))).count, 1)
        let file = StubRequest(method: "GET", path: "/files/a.png", query: [], headers: [:], body: Data())
        XCTAssertEqual(contract.responseProblems(file, .json(["a": 1])).count, 1) // Bilder kommen nicht als JSON
    }

    private func assertIncompatible(_ client: NVAIClient, containing text: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await client.checkCompatible()
            XCTFail("Fehler erwartet", file: file, line: line)
        } catch let error as NVAIError {
            guard case .incompatible(let message) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(message.contains(text), message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
