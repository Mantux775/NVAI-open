import Foundation

// Das Studio der Mac-Fassung (Auftrag 30.10.2026: „danach baue das studio in der mac app ein“). Projektformat und
// Befehle wie server/nvai/studio.py unter Windows, damit Projekte als Paket zwischen beiden wandern und Claude per
// MCP dieselben Befehle schickt. Zeit in Ticks (254 016 000 000 je Sekunde, wie FilmCraft): jede übliche Bildrate und
// Abtastrate geht darin ganzzahlig auf.

enum Studio {
    static let ticksPerSecond = 254_016_000_000
    static let undoLimit = 100
    static let version = 1

    /// Bahnen der Komposition und die Spur, auf die das Übernehmen ihre Takes legt.
    static let lanes = ["video", "voice", "music", "sfx"]
    static let laneTrack = ["video": "V1", "voice": "A1", "music": "A2", "sfx": "A2"]
    static let markerKinds = ["place", "transition", "chain", "audio", "ai", "note"]
    static let markerColors = ["place": "blue", "transition": "yellow", "chain": "green", "audio": "cyan",
                               "ai": "purple", "note": "gray"]
    static let maxTracks = 8  // je Art
    /// Klassische Übergänge, gerechnet in Vorschau und Export: Überblendung, Abblende über Schwarz bzw. Weiß,
    /// Wischblende von links. Der Ton blendet bei allen über.
    static let transitionKinds = ["dissolve", "dip_black", "dip_white", "wipe"]
    static let speedRange = 0.1...10.0  // 10 bis 1000 %
    static let scaleRange = 0.1...8.0   // 10 bis 800 %
    static let defaultImageSeconds = 5.0

    static func ticks(_ seconds: Double) -> Int { Int((seconds * Double(ticksPerSecond)).rounded(.toNearestOrEven)) }
    static func seconds(_ ticks: Int) -> Double { Double(ticks) / Double(ticksPerSecond) }

    /// Neue ID wie db.new_id unter Windows: Präfix, Unterstrich, 12 Hex-Zeichen.
    static func newID(_ prefix: String) -> String { makeID(prefix) }

    /// Austauschbar für den Prüfstand: feste IDs, damit dieselben Befehle hier und in studio.py dasselbe JSON ergeben.
    static var makeID: (String) -> String = { prefix in
        "\(prefix)_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }
}

/// Ungültiger Befehl oder Parameter; die API macht daraus 422, aus `notFound` 404.
struct StudioError: Error, LocalizedError, Equatable {
    var message: String
    var notFound = false
    var errorDescription: String? { message }

    init(_ message: String, notFound: Bool = false) {
        self.message = message
        self.notFound = notFound
    }
}

// MARK: - Projekt

struct StudioProject: Codable, Equatable, Sendable {
    var version = Studio.version
    var id: String
    var name: String
    var createdAt: Double
    var updatedAt: Double
    var settings: StudioSettings
    var scenes: [StudioScene] = []
    var markers: [StudioMarker] = []
    var tracks: [StudioTrack] = StudioTrack.defaults
    var clips: [StudioClip] = []
    /// Medieninfo je Asset (Art, Dauer in Ticks, Format), einmal gemessen.
    var media: [String: StudioMedia] = [:]
    /// Projektordner im Material (Windows seit 0.5.15); die Mac-Fassung legt noch keine Ordner an.
    var folder: String?

    enum CodingKeys: String, CodingKey {
        case version, id, name, settings, scenes, markers, tracks, clips, media, folder
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    init(id: String, name: String, settings: StudioSettings, now: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = now
        self.updatedAt = now
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Studio.version
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
        settings = try c.decode(StudioSettings.self, forKey: .settings)
        scenes = try c.decodeIfPresent([StudioScene].self, forKey: .scenes) ?? []
        markers = try c.decodeIfPresent([StudioMarker].self, forKey: .markers) ?? []
        tracks = try c.decodeIfPresent([StudioTrack].self, forKey: .tracks) ?? StudioTrack.defaults
        clips = try c.decodeIfPresent([StudioClip].self, forKey: .clips) ?? []
        media = try c.decodeIfPresent([String: StudioMedia].self, forKey: .media) ?? [:]
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(settings, forKey: .settings)
        try c.encode(scenes, forKey: .scenes)
        try c.encode(markers, forKey: .markers)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(clips, forKey: .clips)
        try c.encode(media, forKey: .media)
        try c.encode(folder, forKey: .folder)  // null wie unter Windows
    }

    /// Länge eines Bildes in Ticks.
    var frameTicks: Int { Studio.ticksPerSecond * settings.fps[1] / settings.fps[0] }
    var editDuration: Int { clips.map(\.end).max() ?? 0 }
    var compositionDuration: Int { scenes.map { $0.start + $0.duration }.max() ?? 0 }

    func laneEnd(_ lane: String) -> Int {
        scenes.filter { $0.lane == lane }.map { $0.start + $0.duration }.max() ?? 0
    }

    func track(_ id: String) throws -> StudioTrack {
        guard let tr = tracks.first(where: { $0.id == id }) else {
            throw StudioError(t("Spur \(id) gibt es nicht.", "No track \(id)."))
        }
        return tr
    }

    func tracks(of kind: String) -> [StudioTrack] { tracks.filter { $0.kind == kind } }

    /// Die gewünschte Spur, wenn es sie gibt, sonst die mit der höchsten Nummer dieser Art (A2 entfernt → A1).
    func trackOrHighest(_ wanted: String?, kind: String) -> String {
        let ids = tracks(of: kind).map(\.id)
        if let wanted, ids.contains(wanted) { return wanted }
        return ids.max { StudioTrack.number($0) < StudioTrack.number($1) } ?? (kind == "video" ? "V1" : "A1")
    }

    func sceneIndex(_ id: String) throws -> Int {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else {
            throw StudioError(t("Unbekannte Szene: \(id)", "Unknown scene: \(id)"), notFound: true)
        }
        return i
    }

    func markerIndex(_ id: String) throws -> Int {
        guard let i = markers.firstIndex(where: { $0.id == id }) else {
            throw StudioError(t("Unbekannter Marker: \(id)", "Unknown marker: \(id)"), notFound: true)
        }
        return i
    }

    func clipIndex(_ id: String) throws -> Int {
        guard let i = clips.firstIndex(where: { $0.id == id }) else {
            throw StudioError(t("Unbekannter Clip: \(id)", "Unknown clip: \(id)"), notFound: true)
        }
        return i
    }

    mutating func sortScenes() {
        scenes.sort { (Studio.lanes.firstIndex(of: $0.lane) ?? 9, $0.start) < (Studio.lanes.firstIndex(of: $1.lane) ?? 9, $1.start) }
    }

    mutating func sortMarkers() { markers.sort { $0.at < $1.at } }

    mutating func sortClips() { clips.sort { ($0.track, $0.start) < ($1.track, $1.start) } }
}

struct StudioSettings: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var fps: [Int]  // [Zähler, Nenner]
    var sampleRate = 48000
    var videoQuality = "dfr"

    enum CodingKeys: String, CodingKey {
        case width, height, fps
        case sampleRate = "sample_rate", videoQuality = "video_quality"
    }

    init(width: Int, height: Int, fps: [Int]) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fps = try c.decodeIfPresent([Int].self, forKey: .fps) ?? [24, 1]
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48000
        videoQuality = try c.decodeIfPresent(String.self, forKey: .videoQuality) ?? "dfr"
    }
}

struct StudioTrack: Codable, Equatable, Sendable {
    var id: String
    var kind: String  // video | audio
    var hidden: Bool?
    var muted: Bool?

    static let defaults = [StudioTrack(id: "V2", kind: "video"), StudioTrack(id: "V1", kind: "video"),
                           StudioTrack(id: "A1", kind: "audio"), StudioTrack(id: "A2", kind: "audio")]

    static func number(_ id: String) -> Int { Int(id.dropFirst()) ?? 0 }
    var number: Int { Self.number(id) }
    var isHidden: Bool { hidden ?? false }
    var isMuted: Bool { muted ?? false }
}

struct StudioScene: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var lane: String
    var start: Int
    var duration: Int
    var title = ""
    var prompt = ""
    var kind = "video"  // video | image | audio
    var modelID: String?
    var lyrics = ""
    var params: [String: JSONValue] = [:]
    var chainFrom: String?
    var takes: [String] = []
    var take: String?
    var jobs: [String] = []
    var error: String?
    /// Anschluss-Szene, deren Vorlage im selben Lauf entsteht: wartet auf deren Take.
    var waitingFor: String?

    enum CodingKeys: String, CodingKey {
        case id, lane, start, duration, title, prompt, kind, lyrics, params, takes, take, jobs, error
        case modelID = "model_id", chainFrom = "chain_from", waitingFor = "waiting_for"
    }

    init(id: String, lane: String, start: Int, duration: Int) {
        self.id = id
        self.lane = lane
        self.start = start
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lane = try c.decode(String.self, forKey: .lane)
        start = try c.decode(Int.self, forKey: .start)
        duration = try c.decode(Int.self, forKey: .duration)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "video"
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics) ?? ""
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
        chainFrom = try c.decodeIfPresent(String.self, forKey: .chainFrom)
        takes = try c.decodeIfPresent([String].self, forKey: .takes) ?? []
        take = try c.decodeIfPresent(String.self, forKey: .take)
        jobs = try c.decodeIfPresent([String].self, forKey: .jobs) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(lane, forKey: .lane)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode(title, forKey: .title)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(kind, forKey: .kind)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(lyrics, forKey: .lyrics)
        try c.encode(params, forKey: .params)
        try c.encode(chainFrom, forKey: .chainFrom)
        try c.encode(takes, forKey: .takes)
        try c.encode(take, forKey: .take)
        try c.encode(jobs, forKey: .jobs)
        try c.encode(error, forKey: .error)
        try c.encodeIfPresent(waitingFor, forKey: .waitingFor)  // unter Windows fehlt der Schlüssel ohne Warten
    }

    var end: Int { start + duration }
}

struct StudioMarker: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var at: Int
    var duration = 0
    var kind = "note"
    var name = ""
    var comment = ""
    var color = "gray"
    var params: [String: JSONValue] = [:]
    var done = false

    init(id: String, at: Int, kind: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.color = Studio.markerColors[kind] ?? "gray"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Int.self, forKey: .at)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "note"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? (Studio.markerColors[kind] ?? "gray")
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

struct StudioTransition: Codable, Equatable, Sendable {
    var kind: String
    var duration: Int
    /// Der Übergang-Marker, der ihn gesetzt hat (wandert mit dem Marker).
    var marker: String?
}

struct StudioScaleKey: Codable, Equatable, Sendable {
    var at: Int  // Medienzeit in Ticks
    var value: Double
}

struct StudioClip: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var track: String
    var assetID: String
    var sceneID: String?
    var start: Int
    var inPoint: Int
    var outPoint: Int
    var speed = 1.0
    var gainDB = 0.0
    var muted = false
    var transition: StudioTransition?
    /// Skalieren (Windows seit 0.5.16): ohne Keyframes gilt `scale`; `anchor` ist der Fokuspunkt (0 bis 1 je Achse).
    var scale: Double?
    var anchor: [Double]?
    var scaleKeys: [StudioScaleKey]?

    enum CodingKeys: String, CodingKey {
        case id, track, start, speed, muted, transition, scale, anchor
        case assetID = "asset_id", sceneID = "scene_id", inPoint = "in", outPoint = "out", gainDB = "gain_db"
        case scaleKeys = "scale_keys"
    }

    init(id: String, track: String, assetID: String, sceneID: String?, start: Int, inPoint: Int, outPoint: Int,
         speed: Double = 1.0) {
        self.id = id
        self.track = track
        self.assetID = assetID
        self.sceneID = sceneID
        self.start = start
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.speed = speed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        track = try c.decode(String.self, forKey: .track)
        assetID = try c.decode(String.self, forKey: .assetID)
        sceneID = try c.decodeIfPresent(String.self, forKey: .sceneID)
        start = try c.decode(Int.self, forKey: .start)
        inPoint = try c.decode(Int.self, forKey: .inPoint)
        outPoint = try c.decode(Int.self, forKey: .outPoint)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        transition = try c.decodeIfPresent(StudioTransition.self, forKey: .transition)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        anchor = try c.decodeIfPresent([Double].self, forKey: .anchor)
        scaleKeys = try c.decodeIfPresent([StudioScaleKey].self, forKey: .scaleKeys)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(track, forKey: .track)
        try c.encode(assetID, forKey: .assetID)
        try c.encode(sceneID, forKey: .sceneID)
        try c.encode(start, forKey: .start)
        try c.encode(inPoint, forKey: .inPoint)
        try c.encode(outPoint, forKey: .outPoint)
        try c.encode(speed, forKey: .speed)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(muted, forKey: .muted)
        try c.encode(transition, forKey: .transition)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(anchor, forKey: .anchor)
        try c.encodeIfPresent(scaleKeys, forKey: .scaleKeys)
    }

    /// Länge auf der Zeitleiste: Material (Out − In) durch die Geschwindigkeit.
    var length: Int { Int((Double(outPoint - inPoint) / speed).rounded(.toNearestOrEven)) }
    var end: Int { start + length }

    /// Medienzeit, die `offset` Ticks nach dem Clipanfang auf der Zeitleiste läuft.
    func mediaAt(_ offset: Int) -> Int { inPoint + Int((Double(offset) * speed).rounded(.toNearestOrEven)) }

    /// Skalierung zur Medienzeit `media` (Ticks): linear zwischen Keyframes, sonst `scale`.
    func scaleAt(_ media: Int) -> Double {
        guard let keys = scaleKeys, let first = keys.first, let last = keys.last else { return scale ?? 1.0 }
        if media <= first.at { return first.value }
        for (a, b) in zip(keys, keys.dropFirst()) where media <= b.at {
            let f = Double(media - a.at) / Double(max(1, b.at - a.at))
            return a.value + (b.value - a.value) * f
        }
        return last.value
    }
}

/// Medieninfo eines Assets, wie probe() unter Windows: Art, Dauer in Ticks (Bilder ohne), Ton, Format.
struct StudioMedia: Codable, Equatable, Sendable {
    var kind: String  // image | video | audio
    var duration: Int?
    var audio: Bool?
    var width: Int?
    var height: Int?
    var fps: Double?
}

// MARK: - Befehlsparameter

/// Parameter eines Befehls, wie sie per REST, MCP oder aus der Oberfläche kommen.
typealias StudioParams = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    /// Zeit aus `key` (Ticks) oder `key_s` (Sekunden), wie _time() unter Windows.
    func time(_ key: String) -> Int? {
        if let v = self[key], !v.isNull, let d = v.doubleValue { return Int(d) }  // wie int(): schneidet ab
        if let v = self["\(key)_s"], !v.isNull, let d = v.doubleValue { return Studio.ticks(d) }
        return nil
    }

    func string(_ key: String) -> String? {
        guard let v = self[key], !v.isNull else { return nil }
        if let s = v.stringValue { return s }
        if let i = v.intValue { return String(i) }
        if let d = v.doubleValue { return String(d) }
        return nil
    }

    func has(_ key: String) -> Bool { self[key] != nil }

    /// Wahrheitswert wie Python bool(): fehlend, null, false, 0, "" und [] sind falsch.
    func truthy(_ key: String) -> Bool {
        guard let v = self[key] else { return false }
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}
