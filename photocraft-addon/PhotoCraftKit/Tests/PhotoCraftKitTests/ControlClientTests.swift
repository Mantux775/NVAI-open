import Network
import XCTest
@testable import PhotoCraftKit

/// Minimaler Steuerkanal-Server: prüft das Token in der ersten Zeile, beantwortet den Rest über `respond`.
final class FakeControlServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PhotoCraftKitTests.FakeControlServer")
    private(set) var port: UInt16 = 0
    let token: String
    let respond: (JSONValue) -> [JSONValue]

    init(token: String, respond: @escaping (JSONValue) -> [JSONValue]) throws {
        self.token = token
        self.respond = respond
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let error): once.run { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    /// Zustand einer Verbindung – nur auf `queue` benutzt.
    private final class Connection: @unchecked Sendable {
        var buffer = Data()
        var authenticated = false
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = Connection()
        @Sendable func send(_ value: JSONValue) {
            guard var data = try? value.serialized() else { return }
            data.append(0x0A)
            connection.send(content: data, completion: .idempotent)
        }
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { state.buffer.append(data) }
                while let nl = state.buffer.firstIndex(of: 0x0A) {
                    let line = Data(state.buffer[state.buffer.startIndex..<nl])
                    state.buffer.removeSubrange(state.buffer.startIndex...nl)
                    guard let request = try? JSONValue.parse(line) else { continue }
                    if !state.authenticated {
                        state.authenticated = request["params"]?["token"]?.stringValue == self.token
                        send(["id": request["id"] ?? .null, "ok": .bool(state.authenticated)])
                        if !state.authenticated { connection.cancel(); return }
                    } else {
                        self.respond(request).forEach(send)
                    }
                }
                if error == nil && !complete { receive() } else { connection.cancel() }
            }
        }
        receive()
    }
}

final class ControlClientTests: XCTestCase {
    let token = String(repeating: "ab", count: 32)
    var tokenURL: URL!

    override func setUpWithError() throws {
        Localization.choice = "en"
        tokenURL = FileManager.default.temporaryDirectory.appendingPathComponent("pck-token-\(UUID().uuidString)")
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tokenURL)
    }

    func testMissingTokenFileMeansNotConnected() async {
        let client = ControlClient(port: 1, tokenURL: URL(fileURLWithPath: "/nonexistent/token"))
        do {
            _ = try await client.inspect()
            XCTFail("Fehler erwartet")
        } catch let error as ControlError {
            guard case .notConnected = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNoServerMeansNotConnected() async throws {
        let server = try FakeControlServer(token: token) { _ in [] }
        try await server.start()
        let port = server.port
        server.stop() // Port ist danach frei – niemand lauscht
        try await Task.sleep(nanoseconds: 200_000_000)
        let client = ControlClient(port: port, tokenURL: tokenURL)
        do {
            _ = try await client.inspect()
            XCTFail("Fehler erwartet")
        } catch let error as ControlError {
            guard case .notConnected = error else { return XCTFail("\(error)") }
        }
    }

    func testAuthSkipsForeignIDsAndMapsErrors() async throws {
        let server = try FakeControlServer(token: token) { request in
            let id = request["id"] ?? .null
            switch request["method"]?.stringValue {
            case "ui.inspect":
                // Erst eine Antwort auf eine alte Anfrage, dann die richtige.
                return [["id": 9999, "ok": true, "result": "alt"], ["id": id, "ok": true, "result": ["session": ["active": 3]]]]
            case "engine.execute":
                return [["id": id, "ok": false, "error": "unknown command `nope`"]]
            default:
                return [["id": id, "ok": true, "result": .null]]
            }
        }
        try await server.start()
        defer { server.stop() }
        let client = ControlClient(port: server.port, tokenURL: tokenURL)
        let ui = try await client.inspect()
        XCTAssertEqual(ui["session"]?["active"]?.intValue, 3)
        do {
            _ = try await client.execute("nope")
            XCTFail("Fehler erwartet")
        } catch let error as ControlError {
            XCTAssertEqual(error, .rejected("unknown command `nope`"))
        }
        await client.close()
    }

    func testWrongTokenIsRejected() async throws {
        let server = try FakeControlServer(token: String(repeating: "cd", count: 32)) { _ in [] }
        try await server.start()
        defer { server.stop() }
        let client = ControlClient(port: server.port, tokenURL: tokenURL)
        do {
            _ = try await client.inspect()
            XCTFail("Fehler erwartet")
        } catch let error as ControlError {
            guard case .notConnected(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.lowercased().contains("sign-in"), message)
        }
    }
}

final class LauncherAndNVAITests: XCTestCase {
    func testLaunchArgumentsMatchPhotoCraftFlags() {
        let launch = PhotoCraftLaunch(port: 47899, tokenFile: URL(fileURLWithPath: "/b/data/photocraft-control.token"),
                                      exchange: URL(fileURLWithPath: "/b/data/exchange"),
                                      configDirectory: URL(fileURLWithPath: "/b/config"))
        XCTAssertEqual(launch.arguments, ["--control", "47899", "--control-token-file", "/b/data/photocraft-control.token",
                                          "--automation-read-root", "/b/data/exchange", "--automation-write-root", "/b/data/exchange"])
        XCTAssertEqual(launch.openCommand.prefix(6), ["open", "-n", "-a", "/Applications/PhotoCraft.app", "--env",
                                                       "PHOTOCRAFT_CONFIG_DIR=/b/config"])
        XCTAssertEqual(launch.openCommand[6], "--args")
    }

    func testVersionComparisonMatchesBridge() {
        // Dieselben Fälle wie tests/test_discovery.py::test_version_older.
        let cases: [(String, String, Bool)] = [
            ("0.7.0", "0.10.0", true), ("0.9", "0.10.0", true), ("0.10.0", "0.10.0", false),
            ("0.10.0.0", "0.10.0", false), ("0.10.1", "0.10.0", false), ("1.0", "0.10.0", false),
            ("unbekannt", "0.10.0", false),
        ]
        for (version, reference, older) in cases {
            XCTAssertEqual(PhotoCraftLaunch.isVersion(version, olderThan: reference), older, "\(version) gegen \(reference)")
        }
    }

    func testAppVersionFromInfoPlist() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCraft-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.7.0"],
                                                       format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(PhotoCraftLaunch.version(of: app), "0.7.0")
        XCTAssertNil(PhotoCraftLaunch.version(of: app.appendingPathComponent("fehlt.app")))
    }

    func testInstalledPhotoCraftIsFound() throws {
        // Auf dem Prüfstand ist PhotoCraft installiert; anderswo gibt es nichts zu prüfen.
        guard let app = PhotoCraftLaunch.installedApp() else { throw XCTSkip("PhotoCraft ist hier nicht installiert") }
        XCTAssertEqual(Bundle(url: app)?.bundleIdentifier, PhotoCraftLaunch.bundleIdentifier)
        XCTAssertNotNil(PhotoCraftLaunch.version(of: app))
    }

    func testNVAIClientLocalityAndMultipart() {
        XCTAssertTrue(NVAIClient(baseURL: URL(string: "http://127.0.0.1:8100")!).isLocal)
        XCTAssertFalse(NVAIClient(baseURL: URL(string: "http://pc-name:8100")!, token: "t").isLocal)
        let body = NVAIClient.multipartBody(boundary: "B", field: "file", filename: "x.png", mime: "image/png", data: Data([1, 2]))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x.png\"\r\nContent-Type: image/png\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }
}
