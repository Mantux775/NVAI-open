import Foundation

// Die Befehle des Studios, Zeile für Zeile nach server/nvai/studio.py (Windows): gleiche Namen, Parameter und
// Wirkung, damit Oberfläche, REST und Claude auf beiden Systemen dasselbe tun. Jede Änderung ist ein Befehl.

/// Was die Befehle von außen brauchen: Medieninfo und Angaben zu Assets. Die App liefert sie aus AVFoundation und dem
/// AssetStore, der Prüfstand feste Werte; so bleibt der Kern ohne die App übersetzbar und gegen studio.py prüfbar.
struct StudioEnvironment: Sendable {
    /// Medieninfo eines Assets; wirft, wenn es das Asset nicht gibt oder die Datei nicht lesbar ist.
    var probe: @Sendable (String) throws -> StudioMedia
    /// Prompt, Dateiname und Meta eines Assets (Bezeichnungen, Latent-Kette), nil, wenn es das Asset nicht gibt.
    var asset: @Sendable (String) -> StudioAssetInfo?
}

struct StudioAssetInfo: Sendable {
    var kind: String
    var filename: String
    var prompt: String
    var meta: [String: JSONValue]
}

enum StudioCommands {
    typealias Command = (inout StudioProject, StudioParams, StudioEnvironment) throws -> JSONValue

    static let names = ["project.update", "batch", "scene.add", "scene.update", "scene.delete", "scene.take",
                        "marker.add", "marker.update", "marker.delete", "track.add", "track.delete", "track.update",
                        "clip.add", "clip.move", "clip.trim", "clip.razor", "clip.delete", "clip.update", "clip.key",
                        "edit.conform"]

    static func command(_ name: String) -> Command? {
        switch name {
        case "project.update": return projectUpdate
        case "batch": return batch
        case "scene.add": return sceneAdd
        case "scene.update": return sceneUpdate
        case "scene.delete": return sceneDelete
        case "scene.take": return sceneTake
        case "marker.add": return markerAdd
        case "marker.update": return markerUpdate
        case "marker.delete": return markerDelete
        case "track.add": return trackAdd
        case "track.delete": return trackDelete
        case "track.update": return trackUpdate
        case "clip.add": return clipAdd
        case "clip.move": return clipMove
        case "clip.trim": return clipTrim
        case "clip.razor": return clipRazor
        case "clip.delete": return clipDelete
        case "clip.update": return clipUpdate
        case "clip.key": return clipKey
        case "edit.conform": return conform
        default: return nil
        }
    }

    /// Befehl auf ein Projekt anwenden (ohne Speichern und Rückgängig; das macht StudioStore).
    static func apply(_ name: String, _ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        guard let cmd = command(name) else {
            throw StudioError(t("Unbekannter Befehl: \(name)", "Unknown command: \(name)"))
        }
        return try cmd(&p, a, env)
    }

    // MARK: Projekt

    static func projectUpdate(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        if a.has("name") {
            let name = (a.string("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { p.name = name }
        }
        for key in ["width", "height"] where a.has(key) {
            guard let value = a[key]?.intValue, (128...7680).contains(value), value % 2 == 0 else {
                throw StudioError(t("\(key) muss gerade sein, 128 bis 7680.", "\(key) must be even, 128 to 7680."))
            }
            if key == "width" { p.settings.width = value } else { p.settings.height = value }
        }
        if let fps = a["fps"] {
            let pair = fps.arrayValue.map { $0.compactMap(\.intValue) } ?? [fps.intValue ?? 0, 1]
            guard pair.count == 2, pair[0] > 0, pair[1] > 0, (1.0...120.0).contains(Double(pair[0]) / Double(pair[1])) else {
                throw StudioError(t("Bildrate 1 bis 120.", "Frame rate 1 to 120."))
            }
            p.settings.fps = pair
        }
        if a.has("video_quality") {
            guard let q = a.string("video_quality"), ["dfr", "standard"].contains(q) else {
                throw StudioError(t("Videoqualität: dfr oder standard.", "Video quality: dfr or standard."))
            }
            p.settings.videoQuality = q
        }
        return .null
    }

    /// Mehrere Befehle als ein Schritt (ein Rückgängig); scheitert einer, bleibt alles beim Alten (StudioStore
    /// speichert nur, wenn der ganze Befehl gelingt).
    static func batch(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        var results: [JSONValue] = []
        for item in a["commands"]?.arrayValue ?? [] {
            let name = item["command"]?.stringValue ?? ""
            guard name != "batch", let cmd = command(name) else {
                throw StudioError(t("Unbekannter Befehl im Stapel: \(name)", "Unknown command in the batch: \(name)"))
            }
            results.append(try cmd(&p, item["params"]?.objectValue ?? [:], env))
        }
        return .object(["results": .array(results)])
    }

    // MARK: Szenen

    static func sceneAdd(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let lane = a.string("lane") ?? "video"
        guard Studio.lanes.contains(lane) else {
            throw StudioError(t("Bahn \(lane) gibt es nicht (\(Studio.lanes.joined(separator: ", "))).",
                                "No lane \(lane) (\(Studio.lanes.joined(separator: ", ")))."))
        }
        let duration = a.time("duration") ?? Studio.ticks(5)
        guard duration > 0 else {
            throw StudioError(t("Die Dauer muss größer als 0 sein.", "The duration must be greater than 0."))
        }
        let start = a.time("start") ?? p.laneEnd(lane)
        let kind = a.string("kind").flatMap { $0.isEmpty ? nil : $0 } ?? (lane == "video" ? "video" : "audio")
        guard ["video", "image", "audio"].contains(kind) else {
            throw StudioError(t("kind ist video, image oder audio.", "kind is video, image or audio."))
        }
        let takes = (a["takes"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
        for assetID in takes { _ = try media(&p, assetID, env) }
        var scene = StudioScene(id: Studio.newID("sc"), lane: lane, start: max(0, start), duration: duration)
        scene.title = a.string("title") ?? ""
        scene.prompt = a.string("prompt") ?? ""
        scene.kind = kind
        scene.modelID = a.string("model_id")
        scene.lyrics = a.string("lyrics") ?? ""
        scene.params = a["params"]?.objectValue ?? [:]
        scene.chainFrom = a.string("chain_from")
        scene.takes = takes
        if let take = a.string("take"), takes.contains(take) { scene.take = take } else { scene.take = takes.last }
        p.scenes.append(scene)
        p.sortScenes()
        return .object(["id": .string(scene.id)])
    }

    static func sceneUpdate(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.sceneIndex(a.string("id") ?? "")
        var s = p.scenes[i]
        if a.has("title") { s.title = a.string("title") ?? "" }
        if a.has("prompt") { s.prompt = a.string("prompt") ?? "" }
        if a.has("kind") { s.kind = a.string("kind") ?? s.kind }
        if a.has("model_id") { s.modelID = a.string("model_id") }
        if a.has("lane") { s.lane = a.string("lane") ?? "" }
        if a.has("chain_from") { s.chainFrom = a.string("chain_from") }
        if a.has("lyrics") { s.lyrics = a.string("lyrics") ?? "" }
        guard Studio.lanes.contains(s.lane) else {
            throw StudioError(t("Bahn \(s.lane) gibt es nicht.", "No lane \(s.lane)."))
        }
        if let params = a["params"]?.objectValue { s.params.merge(params) { _, new in new } }
        if let start = a.time("start") { s.start = max(0, start) }
        if let duration = a.time("duration") {
            guard duration > 0 else {
                throw StudioError(t("Die Dauer muss größer als 0 sein.", "The duration must be greater than 0."))
            }
            s.duration = duration
        }
        p.scenes[i] = s
        p.sortScenes()
        return .null
    }

    /// Szene löschen; verbundene Clips im Schnitt bleiben, verlieren nur die Verbindung.
    static func sceneDelete(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.sceneIndex(a.string("id") ?? "")
        let id = p.scenes[i].id
        p.scenes.remove(at: i)
        for c in p.clips.indices where p.clips[c].sceneID == id { p.clips[c].sceneID = nil }
        for o in p.scenes.indices {
            if p.scenes[o].chainFrom == id { p.scenes[o].chainFrom = nil }
            if p.scenes[o].waitingFor == id { p.scenes[o].waitingFor = nil }  // der wartende Auftrag sieht das und endet
        }
        return .null
    }

    /// Take wählen oder hinzufügen: ein Asset aus dem Verlauf wird zum Take.
    static func sceneTake(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.sceneIndex(a.string("id") ?? "")
        let assetID = a.string("asset_id") ?? ""
        _ = try media(&p, assetID, env)  // prüft, dass es das Asset gibt und es lesbar ist
        if !p.scenes[i].takes.contains(assetID) { p.scenes[i].takes.append(assetID) }
        p.scenes[i].take = assetID
        p.scenes[i].error = nil
        return .null
    }

    // MARK: Marker

    static func markerAdd(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let kind = a.string("kind") ?? "note"
        guard Studio.markerKinds.contains(kind) else {
            throw StudioError(t("Markerart \(kind) gibt es nicht (\(Studio.markerKinds.joined(separator: ", "))).",
                                "No marker kind \(kind) (\(Studio.markerKinds.joined(separator: ", ")))."))
        }
        var m = StudioMarker(id: Studio.newID("mk"), at: max(0, a.time("at") ?? 0), kind: kind)
        m.duration = max(0, a.time("duration") ?? 0)
        m.name = a.string("name") ?? ""
        m.comment = a.string("comment") ?? ""
        if let color = a.string("color"), !color.isEmpty { m.color = color }
        m.params = a["params"]?.objectValue ?? [:]
        p.markers.append(m)
        p.sortMarkers()
        _ = try applyTransitionMarker(&p, m)
        return .object(["id": .string(m.id)])
    }

    static func markerUpdate(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.markerIndex(a.string("id") ?? "")
        var m = p.markers[i]
        if a.has("name") { m.name = a.string("name") ?? "" }
        if a.has("comment") { m.comment = a.string("comment") ?? "" }
        if a.has("color") { m.color = a.string("color") ?? "" }
        if a.has("done") { m.done = a.truthy("done") }
        if a.has("kind") {
            guard let kind = a.string("kind"), Studio.markerKinds.contains(kind) else {
                throw StudioError(t("Markerart \(a.string("kind") ?? "") gibt es nicht.", "No marker kind \(a.string("kind") ?? "")."))
            }
            m.kind = kind
        }
        if m.color.isEmpty { m.color = Studio.markerColors[m.kind] ?? "gray" }  // neue Art ohne eigene Farbe
        if let params = a["params"]?.objectValue { m.params.merge(params) { _, new in new } }
        if let at = a.time("at") { m.at = max(0, at) }
        if let duration = a.time("duration") { m.duration = max(0, duration) }
        p.markers[i] = m
        p.sortMarkers()
        if ["at", "at_s", "duration", "duration_s", "kind", "params"].contains(where: { a.has($0) }) {
            _ = try applyTransitionMarker(&p, m)
        }
        return .null
    }

    /// Marker löschen. Eine Überblendung, die er gesetzt hat, bleibt am Clip.
    static func markerDelete(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.markerIndex(a.string("id") ?? "")
        let id = p.markers[i].id
        p.markers.remove(at: i)
        for c in p.clips.indices where p.clips[c].transition?.marker == id { p.clips[c].transition?.marker = nil }
        return .null
    }

    /// Übergang-Marker wirken sofort: auf den Videoclip, der am Marker (± eine halbe Sekunde) beginnt, untere Spur
    /// zuerst. Wandert der Marker oder ändert er Art oder Dauer, wandert die Überblendung mit; liegt dort noch kein
    /// Clip, setzt sie das Übernehmen.
    @discardableResult
    static func applyTransitionMarker(_ p: inout StudioProject, _ m: StudioMarker) throws -> Bool {
        for c in p.clips.indices where p.clips[c].transition?.marker == m.id { p.clips[c].transition = nil }
        guard m.kind == "transition" else { return false }
        let duration = m.duration != 0 ? m.duration : Studio.ticks(m.params["seconds"]?.doubleValue ?? 0.5)
        var kind = m.params["transition"]?.stringValue ?? "dissolve"
        if kind.isEmpty || !Studio.transitionKinds.contains(kind) { kind = "dissolve" }
        let half = Studio.ticks(0.5)
        let video = p.clips.indices.filter { (try? p.track(p.clips[$0].track).kind) == "video" }
        let ordered = video.sorted { (StudioTrack.number(p.clips[$0].track), p.clips[$0].start)
                                     < (StudioTrack.number(p.clips[$1].track), p.clips[$1].start) }
        for c in ordered where abs(p.clips[c].start - m.at) <= half && p.clips[c].start > 0 {
            var tr = try transition(p, p.clips[c], ["kind": .string(kind), "duration": .int(duration)])
            tr?.marker = m.id
            p.clips[c].transition = tr
            return true
        }
        return false
    }

    // MARK: Spuren

    /// Videospuren von oben nach unten (V3, V2, V1), darunter die Tonspuren (A1, A2 …), wie in der Ansicht.
    static func orderTracks(_ p: inout StudioProject) {
        p.tracks = p.tracks(of: "video").sorted { $0.number > $1.number } + p.tracks(of: "audio").sorted { $0.number < $1.number }
    }

    /// Spuren einer Art lückenlos nummerieren (V1 bleibt unten); Clips und Platzieren-Marker ziehen mit.
    static func renumber(_ p: inout StudioProject, kind: String) {
        let prefix = kind == "video" ? "V" : "A"
        let ordered = p.tracks(of: kind).sorted { $0.number < $1.number }
        var mapping: [String: String] = [:]
        for (i, tr) in ordered.enumerated() { mapping[tr.id] = "\(prefix)\(i + 1)" }
        for i in p.tracks.indices { if let new = mapping[p.tracks[i].id] { p.tracks[i].id = new } }
        for i in p.clips.indices { if let new = mapping[p.clips[i].track] { p.clips[i].track = new } }
        for i in p.markers.indices {
            if let old = p.markers[i].params["track"]?.stringValue, let new = mapping[old] {
                p.markers[i].params["track"] = .string(new)
            }
        }
    }

    static func trackAdd(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let kind = a.string("kind") ?? "video"
        guard ["video", "audio"].contains(kind) else {
            throw StudioError(t("kind ist video oder audio.", "kind is video or audio."))
        }
        let have = p.tracks(of: kind)
        guard have.count < Studio.maxTracks else {
            throw StudioError(t("Höchstens \(Studio.maxTracks) Spuren je Art.", "At most \(Studio.maxTracks) tracks of each kind."))
        }
        let track = StudioTrack(id: "\(kind == "video" ? "V" : "A")\(have.count + 1)", kind: kind, hidden: false, muted: false)
        p.tracks.append(track)
        orderTracks(&p)
        return .object(["id": .string(track.id)])
    }

    /// Spur entfernen: ihre Clips gehen mit; V1 und A1 bleiben immer. Die Spuren darüber bzw. darunter rücken nach.
    static func trackDelete(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let tr = try p.track(a.string("id") ?? "")
        guard tr.number != 1 else { throw StudioError(t("V1 und A1 bleiben immer.", "V1 and A1 always stay.")) }
        let before = p.clips.count
        p.clips.removeAll { $0.track == tr.id }
        for i in p.markers.indices where p.markers[i].params["track"]?.stringValue == tr.id {
            p.markers[i].params.removeValue(forKey: "track")  // Platzieren-Marker fällt auf die oberste Spur zurück
        }
        p.tracks.removeAll { $0.id == tr.id }
        renumber(&p, kind: tr.kind)
        orderTracks(&p)
        return .object(["clips_removed": .int(before - p.clips.count)])
    }

    /// Spur schalten: hidden (Bild der Videospur aus), muted (Ton aus). Gilt für Vorschau und Export.
    static func trackUpdate(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let id = try p.track(a.string("id") ?? "").id
        guard let i = p.tracks.firstIndex(where: { $0.id == id }) else { return .null }
        if a.has("hidden") && p.tracks[i].kind == "video" { p.tracks[i].hidden = a.truthy("hidden") }
        if a.has("muted") { p.tracks[i].muted = a.truthy("muted") }
        return .null
    }

    // MARK: Schnitt: Hilfen

    /// Medieninfo aus dem Projekt-Cache, sonst einmal gemessen.
    static func media(_ p: inout StudioProject, _ assetID: String, _ env: StudioEnvironment) throws -> StudioMedia {
        if let m = p.media[assetID] { return m }
        let m = try env.probe(assetID)
        p.media[assetID] = m
        return m
    }

    /// Wie „Überschreiben“ in jedem Schnittprogramm: Was auf derselben Spur unter dem Clip liegt, wird gekürzt,
    /// geteilt oder entfernt. `keep`: Clips, die mitverschoben werden und sich deshalb nicht gegenseitig kürzen.
    static func overwrite(_ p: inout StudioProject, _ clipID: String, keep: Set<String> = []) {
        guard let clip = p.clips.first(where: { $0.id == clipID }) else { return }
        let s = clip.start, e = clip.end
        var kept: [StudioClip] = []
        for var c in p.clips {
            if c.id == clipID || keep.contains(c.id) || c.track != clip.track || c.end <= s || c.start >= e {
                kept.append(c)
                continue
            }
            if c.start >= s && c.end <= e { continue }  // ganz verdeckt
            if c.start < s && c.end > e {  // teilen
                var tail = c
                tail.id = Studio.newID("cl")
                tail.inPoint = c.mediaAt(e - c.start)
                tail.start = e
                tail.transition = nil
                c.outPoint = c.mediaAt(s - c.start)
                kept += [c, tail]
            } else if c.start < s {  // Ende kürzen
                c.outPoint = c.mediaAt(s - c.start)
                kept.append(c)
            } else {  // Anfang kürzen
                c.inPoint = c.mediaAt(e - c.start)
                c.start = e
                c.transition = nil
                kept.append(c)
            }
        }
        p.clips = kept
        p.sortClips()
    }

    /// Projekteinstellungen beim Anlegen und Importieren mit denselben Grenzen wie project.update prüfen: Eine
    /// Bildrate mit 0 oder eine Breite 0 brächte die App beim Anzeigen zum Absturz (Division durch null, Int(inf)).
    static func checkProject(_ p: StudioProject) throws {
        let s = p.settings
        guard (128...7680).contains(s.width), s.width % 2 == 0, (128...7680).contains(s.height), s.height % 2 == 0 else {
            throw StudioError(t("Breite und Höhe müssen gerade sein, 128 bis 7680.", "Width and height must be even, 128 to 7680."))
        }
        guard s.fps.count == 2, s.fps[0] > 0, s.fps[1] > 0, (1.0...120.0).contains(Double(s.fps[0]) / Double(s.fps[1])) else {
            throw StudioError(t("Bildrate 1 bis 120.", "Frame rate 1 to 120."))
        }
        for c in p.clips where !Studio.speedRange.contains(c.speed) || c.outPoint <= c.inPoint || c.inPoint < 0 {
            throw StudioError(t("Clip \(c.id): Geschwindigkeit 10 bis 1000 %, Out nach In.", "Clip \(c.id): speed 10 to 1000 %, out after in."))
        }
    }

    static func checkSpeed(_ value: JSONValue?) throws -> Double {
        guard let speed = value?.doubleValue ?? (value == nil ? 1.0 : nil) else {
            throw StudioError(t("speed ist eine Zahl (1.0 = 100 %).", "speed is a number (1.0 = 100 %)."))
        }
        guard Studio.speedRange.contains(speed) else {
            throw StudioError(t("Geschwindigkeit 10 bis 1000 %.", "Speed 10 to 1000 %."))
        }
        return speed
    }

    static func checkScale(_ value: JSONValue?) throws -> Double {
        guard let scale = value?.doubleValue else {
            throw StudioError(t("scale ist eine Zahl (1.0 = 100 %).", "scale is a number (1.0 = 100 %)."))
        }
        guard Studio.scaleRange.contains(scale) else {
            throw StudioError(t("Skalierung 10 bis 800 %.", "Scale 10 to 800 %."))
        }
        return scale
    }

    static func checkAnchor(_ value: JSONValue?) throws -> [Double] {
        guard let pair = value?.arrayValue?.compactMap(\.doubleValue), pair.count == 2 else {
            throw StudioError(t("anchor ist [x, y] mit Werten von 0 bis 1 (0.5, 0.5 = Mitte).",
                                "anchor is [x, y] with values from 0 to 1 (0.5, 0.5 = center)."))
        }
        return pair.map { min(1.0, max(0.0, $0)) }
    }

    /// Keyframes aus einer Liste [{at: Medienzeit in Ticks oder at_s, value}], nach Zeit sortiert, ohne Doppel.
    static func checkKeys(_ value: JSONValue?) throws -> [StudioScaleKey] {
        guard let list = value?.arrayValue ?? (value?.isNull == true ? [] : nil) else {
            throw StudioError(t("scale_keys ist eine Liste [{at_s, value}].", "scale_keys is a list [{at_s, value}]."))
        }
        var keys: [Int: Double] = [:]
        for k in list {
            guard let obj = k.objectValue, let at = obj.time("at") else {
                throw StudioError(t("Jeder Keyframe braucht at oder at_s (Medienzeit).", "Each keyframe needs at or at_s (media time)."))
            }
            keys[at] = try checkScale(obj["value"])
        }
        return keys.keys.sorted().map { StudioScaleKey(at: $0, value: keys[$0]!) }
    }

    /// Neuer Clip; `length` ist die Länge auf der Zeitleiste, `outPoint` (statt length) das Ende in Medienzeit.
    static func newClip(_ p: inout StudioProject, track: String, assetID: String, start: Int, length: Int?,
                        inPoint: Int = 0, sceneID: String? = nil, speed: JSONValue? = nil, outPoint: Int? = nil,
                        env: StudioEnvironment) throws -> StudioClip {
        let tr = try p.track(track)
        let m = try media(&p, assetID, env)
        if tr.kind == "audio" && m.kind == "image" {
            throw StudioError(t("Ein Bild gehört auf eine Videospur.", "An image belongs on a video track."))
        }
        if tr.kind == "video" && m.kind == "audio" {
            throw StudioError(t("Ton gehört auf eine Tonspur.", "Audio belongs on an audio track."))
        }
        let sp = m.kind == "image" ? 1.0 : try checkSpeed(speed)
        let available: Int? = m.kind == "image" ? nil : (m.duration ?? 0) - inPoint  // Medienzeit
        var material: Int
        if let outPoint {
            material = outPoint - inPoint
        } else if let length {
            material = Int((Double(length) * sp).rounded(.toNearestOrEven))
        } else if let available, available != 0 {
            material = available
        } else {
            material = Studio.ticks(Studio.defaultImageSeconds)
        }
        if let available { material = min(material, available) }
        guard material > 0 else { throw StudioError(t("Der Clip hätte keine Länge.", "The clip would have no length.")) }
        return StudioClip(id: Studio.newID("cl"), track: track, assetID: assetID, sceneID: sceneID, start: max(0, start),
                          inPoint: inPoint, outPoint: inPoint + material, speed: sp)
    }

    /// Übergang am Anfang eines Clips: Art und Dauer (höchstens die Länge des Clips, mindestens ein Bild).
    static func transition(_ p: StudioProject, _ c: StudioClip, _ spec: StudioParams?) throws -> StudioTransition? {
        guard let spec else { return nil }
        let kind = spec.string("kind").flatMap { $0.isEmpty ? nil : $0 } ?? "dissolve"
        guard Studio.transitionKinds.contains(kind) else {
            throw StudioError(t("Übergang \(kind) gibt es nicht (\(Studio.transitionKinds.joined(separator: ", "))).",
                                "No transition \(kind) (\(Studio.transitionKinds.joined(separator: ", ")))."))
        }
        let duration = spec.time("duration") ?? Studio.ticks(0.5)
        return StudioTransition(kind: kind, duration: max(p.frameTicks, min(duration, c.length)))
    }

    /// Bezeichnung eines Clips für Meldungen: Titel der Szene, sonst Prompt oder Dateiname des Assets.
    static func clipLabel(_ p: StudioProject, _ c: StudioClip, _ env: StudioEnvironment) -> String {
        if let s = p.scenes.first(where: { $0.id == c.sceneID }), !s.title.isEmpty { return s.title }
        var label = c.assetID
        if let info = env.asset(c.assetID) {
            label = !info.prompt.isEmpty ? info.prompt : (info.meta["original_name"]?.stringValue ?? info.filename)
        }
        return label.count <= 40 ? label : String(label.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// scale, anchor und scale_keys aus einem Befehl übernehmen (nur Videospuren).
    static func applyScale(_ p: StudioProject, _ c: inout StudioClip, _ a: StudioParams) throws {
        guard ["scale", "anchor", "scale_keys"].contains(where: { a.has($0) }) else { return }
        guard try p.track(c.track).kind == "video" else {
            throw StudioError(t("Skalieren geht nur auf Videospuren.", "Scaling only works on video tracks."))
        }
        if a.has("scale") { c.scale = try checkScale(a["scale"]) }
        if a.has("anchor") { c.anchor = try checkAnchor(a["anchor"]) }
        if a.has("scale_keys") { c.scaleKeys = try checkKeys(a["scale_keys"]) }
    }

    // MARK: Clips

    /// Clip auf eine Spur legen (überschreibt Darunterliegendes).
    static func clipAdd(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        var clip = try newClip(&p, track: a.string("track") ?? "V1", assetID: a.string("asset_id") ?? "",
                               start: a.time("start") ?? p.editDuration, length: a.time("duration"),
                               inPoint: a.time("in") ?? 0, speed: a["speed"], outPoint: a.time("out"), env: env)
        if a.has("gain_db"), let g = a["gain_db"]?.doubleValue { clip.gainDB = max(-60, min(12, g)) }
        if a.has("muted") { clip.muted = a.truthy("muted") }
        try applyScale(p, &clip, a)
        if let sceneID = a.string("scene_id"), !sceneID.isEmpty, p.scenes.contains(where: { $0.id == sceneID }) {
            clip.sceneID = sceneID
        }
        if a.truthy("transition") { clip.transition = try transition(p, clip, a["transition"]?.objectValue) }
        p.clips.append(clip)
        overwrite(&p, clip.id)
        return .object(["id": .string(clip.id)])
    }

    /// Clip verschieben: id mit start und/oder track, oder mehrere zugleich mit moves. Überschreibt am Ziel, die
    /// mitverschobenen Clips kürzen sich nicht gegenseitig.
    static func clipMove(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        var moves = (a["moves"]?.arrayValue ?? []).compactMap(\.objectValue)
        if moves.isEmpty { moves = [a.filter { ["id", "start", "start_s", "track"].contains($0.key) }] }
        var plan: [(Int, Int?, String?)] = []
        for mv in moves {  // erst alles prüfen, dann verschieben
            let i = try p.clipIndex(mv.string("id") ?? "")
            let track = mv.string("track").flatMap { $0.isEmpty ? nil : $0 }
            if let track, try p.track(track).kind != p.track(p.clips[i].track).kind {
                throw StudioError(t("Video bleibt auf Video-, Ton auf Tonspuren.", "Video stays on video, audio on audio tracks."))
            }
            plan.append((i, mv.time("start"), track))
        }
        for (i, start, track) in plan {
            if let start { p.clips[i].start = max(0, start) }
            if let track { p.clips[i].track = track }
        }
        let moved = Set(plan.map { p.clips[$0.0].id })
        for id in plan.map({ p.clips[$0.0].id }) { overwrite(&p, id, keep: moved) }
        return .null
    }

    /// Clip trimmen: edge (start|end) mit to (Zeitleistenposition), oder in/out (Medienzeit).
    static func clipTrim(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.clipIndex(a.string("id") ?? "")
        var c = p.clips[i]
        let m = try media(&p, c.assetID, env)
        let limit = m.kind == "image" ? nil : m.duration
        let speed = c.speed
        let edge = a.string("edge")
        if edge == "start", let to = a.time("to") {
            c.inPoint = c.mediaAt(to - c.start)
            c.start = to
        } else if edge == "end", let to = a.time("to") {
            c.outPoint = c.mediaAt(to - c.start)
        } else {
            if let newIn = a.time("in") {
                c.start += Int((Double(newIn - c.inPoint) / speed).rounded(.toNearestOrEven))  // das Bild bleibt an seiner Stelle
                c.inPoint = newIn
            }
            if let out = a.time("out") { c.outPoint = out }
        }
        if c.inPoint < 0 {  // nicht vor den Anfang des Materials
            c.start -= Int((Double(c.inPoint) / speed).rounded(.toNearestOrEven))
            c.inPoint = 0
        }
        if let limit, c.outPoint > limit { c.outPoint = limit }
        if c.start < 0 {
            c.inPoint -= Int((Double(c.start) * speed).rounded(.toNearestOrEven))
            c.start = 0
        }
        guard c.length >= p.frameTicks else {
            throw StudioError(t("Ein Clip braucht mindestens ein Bild.", "A clip needs at least one frame."))
        }
        p.clips[i] = c
        overwrite(&p, c.id)
        return .null
    }

    /// Schneiden: at; track (sonst alle Spuren).
    static func clipRazor(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        guard let at = a.time("at") else { throw StudioError(t("at oder at_s fehlt.", "at or at_s is missing.")) }
        let only = a.string("track").flatMap { $0.isEmpty ? nil : $0 }
        var newIDs: [JSONValue] = []
        for i in p.clips.indices {
            let c = p.clips[i]
            if let only, c.track != only { continue }
            if c.start < at && at < c.end {
                var tail = c
                tail.id = Studio.newID("cl")
                tail.inPoint = c.mediaAt(at - c.start)
                tail.start = at
                tail.transition = nil
                p.clips[i].outPoint = tail.inPoint
                p.clips.append(tail)
                newIDs.append(.string(tail.id))
            }
        }
        p.sortClips()
        return .object(["ids": .array(newIDs)])
    }

    /// Clips löschen: ids (Liste) oder id; ripple schließt die Lücke auf der Spur.
    static func clipDelete(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        var ids = (a["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
        if ids.isEmpty, let id = a.string("id"), !id.isEmpty { ids = [id] }
        for id in ids {
            let i = try p.clipIndex(id)
            let c = p.clips.remove(at: i)
            if a.truthy("ripple") {
                let gap = c.length
                for o in p.clips.indices where p.clips[o].track == c.track && p.clips[o].start >= c.end {
                    p.clips[o].start -= gap
                }
            }
        }
        return .null
    }

    /// Neue Geschwindigkeit; In und Out bleiben, die Länge auf der Zeitleiste ändert sich. Stößt der längere Clip an
    /// einen späteren derselben Spur, entscheidet `overlap`: clamp, ripple oder overwrite; ohne Angabe abgelehnt.
    static func setSpeed(_ p: inout StudioProject, _ i: Int, _ value: JSONValue?, _ overlap: String?,
                         _ env: StudioEnvironment) throws {
        if try media(&p, p.clips[i].assetID, env).kind == "image" {
            throw StudioError(t("Ein Standbild hat keine Geschwindigkeit; seine Länge ändert man direkt.",
                                "A still image has no speed; change its length directly."))
        }
        let speed = try checkSpeed(value)
        let oldEnd = p.clips[i].end
        p.clips[i].speed = speed
        let c = p.clips[i]
        let newEnd = c.end
        guard newEnd > oldEnd else { return }  // kürzer: dahinter entsteht eine Lücke
        let later = p.clips.indices.filter { $0 != i && p.clips[$0].track == c.track && p.clips[$0].start >= c.start }
        let hit = later.filter { p.clips[$0].start < newEnd }
        guard !hit.isEmpty else { return }
        switch overlap {
        case "clamp":
            let nearest = hit.map { p.clips[$0].start }.min()!
            p.clips[i].outPoint = c.mediaAt(nearest - c.start)
            guard p.clips[i].length >= p.frameTicks else {
                throw StudioError(t("Bis zum nächsten Clip ist kein Platz.", "There is no room before the next clip."))
            }
        case "overwrite":
            overwrite(&p, c.id)
        case "ripple":
            for o in later { p.clips[o].start += newEnd - oldEnd }
        default:
            let names = hit.prefix(3).map { clipLabel(p, p.clips[$0], env) }.joined(separator: ", ")
            let longer = String(format: "%.2f", Studio.seconds(newEnd - oldEnd))
            let pct = String(format: "%.0f", speed * 100)
            throw StudioError(t(
                "Mit \(pct) % wird der Clip \(longer) s länger und stößt an \(hit.count) Clip(s) (\(names)). overlap "
                    + "angeben: clamp (endet am nächsten Clip), ripple (die späteren Clips der Spur rücken nach hinten) "
                    + "oder overwrite (überdecken).",
                "At \(pct) % the clip becomes \(longer) s longer and runs into \(hit.count) clip(s) (\(names)). Give "
                    + "overlap: clamp (end at the next clip), ripple (push the later clips of the track) or overwrite "
                    + "(cover them)."))
        }
    }

    static func clipUpdate(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.clipIndex(a.string("id") ?? "")
        if a.has("gain_db"), let g = a["gain_db"]?.doubleValue { p.clips[i].gainDB = max(-60, min(12, g)) }
        if a.has("muted") { p.clips[i].muted = a.truthy("muted") }
        var c = p.clips[i]
        try applyScale(p, &c, a)
        p.clips[i] = c
        let id = c.id
        if a.has("speed") { try setSpeed(&p, i, a["speed"], a.string("overlap"), env) }
        guard let j = p.clips.firstIndex(where: { $0.id == id }) else { return .null }
        if a.has("transition") {
            p.clips[j].transition = try transition(p, p.clips[j], a["transition"]?.objectValue)
        } else if p.clips[j].transition != nil {  // die Länge kann sich geändert haben
            p.clips[j].transition!.duration = min(p.clips[j].transition!.duration, p.clips[j].length)
        }
        return .null
    }

    /// Keyframe der Skalierung: at (Zeitleiste) mit value setzt oder ersetzt ihn, delete löscht ihn, clear alle.
    static func clipKey(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        let i = try p.clipIndex(a.string("id") ?? "")
        let c = p.clips[i]
        guard try p.track(c.track).kind == "video" else {
            throw StudioError(t("Skalieren geht nur auf Videospuren.", "Scaling only works on video tracks."))
        }
        if a.truthy("clear") {
            p.clips[i].scaleKeys = []
            return .object(["keys": .int(0)])
        }
        guard let at = a.time("at"), c.start <= at, at <= c.end else {
            throw StudioError(t("at oder at_s muss im Clip liegen.", "at or at_s must lie inside the clip."))
        }
        let mediaTime = c.mediaAt(at - c.start)
        let near = Int((Double(p.frameTicks) * c.speed / 2).rounded(.toNearestOrEven))  // innerhalb eines halben Bildes gilt als derselbe
        var keys = (c.scaleKeys ?? []).filter { abs($0.at - mediaTime) > near }
        if !a.truthy("delete") {
            let value = a.has("value") ? try checkScale(a["value"]) : try checkScale(.double(c.scaleAt(mediaTime)))
            keys.append(StudioScaleKey(at: mediaTime, value: value))
        }
        p.clips[i].scaleKeys = keys.sorted { $0.at < $1.at }
        return .object(["keys": .int(keys.count), "at": .int(mediaTime)])
    }
}
