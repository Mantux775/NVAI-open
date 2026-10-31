import Foundation

// Übernehmen: Takes der Komposition in den Schnitt legen, nach server/nvai/studio.py (Windows), samt Latent-Kette
// (seit 0.5.17) und dem Plan, den die Oberfläche vorher zeigt.

extension StudioCommands {
    /// Wohin das Übernehmen jede Szene legt: Platzieren-Marker (Vorgabe V2, sonst die oberste Spur), sonst an den
    /// Szenenanfang auf die Spur ihrer Bahn. Audio-Marker verschieben dabei die Ton-Szene an die Marke (in `p`).
    static func conformTargets(_ p: inout StudioProject) -> [String: (start: Int, track: String)] {
        let ids = Set(p.scenes.map(\.id))
        for m in p.markers where m.kind == "audio" {
            if let sid = m.params["scene_id"]?.stringValue, ids.contains(sid), let i = p.scenes.firstIndex(where: { $0.id == sid }) {
                p.scenes[i].start = m.at
            }
        }
        var targets: [String: (start: Int, track: String)] = [:]
        for s in p.scenes {
            targets[s.id] = (s.start, p.trackOrHighest(Studio.laneTrack[s.lane], kind: s.lane == "video" ? "video" : "audio"))
        }
        for m in p.markers where m.kind == "place" {
            if let sid = m.params["scene_id"]?.stringValue, ids.contains(sid) {
                let wanted = m.params["track"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "V2"
                targets[sid] = (m.at, p.trackOrHighest(wanted, kind: "video"))
            }
        }
        return targets
    }

    /// Latent-Kette: Länge des Anfangs, den ein Take von seiner Vorlage übernommen hat (meta.carry_frames mit
    /// chain_asset_id, bei der Bildrate des Takes), sonst 0. Verlängerte Videos tragen nur carry_frames.
    static func carryTicks(_ assetID: String, _ env: StudioEnvironment) -> Int {
        guard let meta = env.asset(assetID)?.meta, let n = meta["carry_frames"]?.intValue, n > 0,
              let chain = meta["chain_asset_id"], !chain.isNull else { return 0 }
        return Studio.ticks(Double(n) / (meta["fps"]?.doubleValue ?? 24))
    }

    /// Wo ein Take beim Übernehmen beginnt, dessen Szene bei `start` liegt. Latent-Kette: Seine ersten Bilder sind
    /// die letzten seiner Vorlage. Liegt die Vorlage auf derselben Spur und läuft bis dorthin, beginnt er bildgenau,
    /// wo diese Bilder in ihr laufen (ihr Take ist mit 8n+1 Bildern meist ein Bild länger als ihre Szene), sonst um die
    /// Überlappung vor dem Szenenanfang.
    static func chainStart(_ p: inout StudioProject, track: String, assetID: String, start: Int,
                           _ env: StudioEnvironment) -> Int {
        let carry = carryTicks(assetID, env)
        guard carry > 0 else { return start }
        let source = env.asset(assetID)?.meta["chain_asset_id"]?.stringValue
        for c in p.clips where c.track == track && c.assetID == source && c.speed == 1.0 {
            let duration = (try? media(&p, c.assetID, env).duration) ?? nil
            let at = c.start - c.inPoint + (duration ?? 0) - carry
            if c.start < at && at <= c.end && abs(at - (start - carry)) <= Studio.ticks(0.5) { return at }
        }
        return start - carry
    }

    /// Liegt der Clip noch so, wie Übernehmen ihn gelegt hat: ab Medienanfang und so lang wie seine Szene.
    /// Latent-Kette: Ein Take mit übernommenem Anfang ist um die Überlappung länger, seine Vorlage endet dort, wo er
    /// beginnt.
    static func untouched(_ p: inout StudioProject, _ s: StudioScene, start: Int, _ c: StudioClip,
                          _ env: StudioEnvironment) -> Bool {
        guard c.inPoint == 0 else { return false }
        let expected = start + s.duration - chainStart(&p, track: c.track, assetID: c.assetID, start: start, env)
        if abs(c.length - expected) <= p.frameTicks { return true }
        guard let follower = p.clips.first(where: { $0.track == c.track && $0.start == c.end }),
              follower.transition?.kind == "dissolve", carryTicks(follower.assetID, env) > 0,
              c.length < expected else { return false }
        return env.asset(follower.assetID)?.meta["chain_asset_id"]?.stringValue == c.assetID
    }

    /// Komposition übernehmen: legt die gewählten Takes in den Schnitt, tauscht neu erzeugtes Material in
    /// verbundenen Clips aus und wertet die Marker aus (place, transition, audio). Wahlweise nur scenes [ids]; neue
    /// Clips, die andere überdecken würden, dann nur für die Szenen in overwrite [ids].
    static func conform(_ p: inout StudioProject, _ a: StudioParams, _ env: StudioEnvironment) throws -> JSONValue {
        var created = 0, updated = 0, transitions = 0
        let only = a["scenes"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
        let allowed = Set((a["overwrite"]?.arrayValue ?? []).compactMap(\.stringValue))
        var skipped: [JSONValue] = []
        let targets = conformTargets(&p)
        // Takes mit übernommenem Anfang (Latent-Kette) zuletzt und nach Zeit: Ihre Vorlage liegt dann schon im
        // Schnitt, und eine später gelegte Vorlage überdeckt ihren Anfang nicht
        let chained = Set(p.scenes.filter { s in s.take.map { carryTicks($0, env) > 0 } ?? false }.map(\.id))
        let order = p.scenes.enumerated().sorted { x, y in
            let kx = (chained.contains(x.element.id) ? 1 : 0, chained.contains(x.element.id) ? targets[x.element.id]!.start : 0, x.offset)
            let ky = (chained.contains(y.element.id) ? 1 : 0, chained.contains(y.element.id) ? targets[y.element.id]!.start : 0, y.offset)
            return kx < ky
        }.map(\.element.id)
        for sid in order {
            guard let s = p.scenes.first(where: { $0.id == sid }), let take = s.take else { continue }
            if let only, !only.contains(s.id) { continue }
            let (start, track) = targets[s.id]!
            let linked = p.clips.indices.filter { p.clips[$0].sceneID == s.id }
            if !linked.isEmpty {
                for i in linked where p.clips[i].assetID != take {
                    let m = try media(&p, take, env)
                    p.clips[i].assetID = take
                    if m.kind != "image", let d = m.duration, d != 0 {
                        p.clips[i].outPoint = min(p.clips[i].outPoint, d)
                        p.clips[i].inPoint = min(p.clips[i].inPoint, max(0, p.clips[i].outPoint - p.frameTicks))
                    }
                    updated += 1
                }
                continue
            }
            // Latent-Kette: Der Take beginnt mit der letzten Sekunde seiner Vorlage; er liegt um diese Bilder früher,
            // der Clip davor wird dort gekürzt und läuft unter einer Überblendung genau dieser Länge aus.
            let carry = carryTicks(take, env)
            let at = chainStart(&p, track: track, assetID: take, start: start, env)
            let clip = try newClip(&p, track: track, assetID: take, start: at, length: start + s.duration - at,
                                   inPoint: 0, sceneID: s.id, env: env)
            // Überdecken zählt erst ab dem Szenenanfang: die gewollte Überlappung ist kein Überschreiben
            let covers = p.clips.contains { $0.track == track && $0.start < clip.end && $0.end > start }
            if covers, only != nil, !allowed.contains(s.id) {
                skipped.append(.string(s.id))  // der Nutzer hat das Überschreiben hier nicht erlaubt
                continue
            }
            p.clips.append(clip)
            overwrite(&p, clip.id)
            if carry > 0, let i = p.clips.firstIndex(where: { $0.id == clip.id }),
               p.clips.contains(where: { $0.id != clip.id && $0.track == track && $0.end == p.clips[i].start }) {
                p.clips[i].transition = StudioTransition(kind: "dissolve", duration: min(carry, p.clips[i].length))
                transitions += 1
            }
            created += 1
        }
        // Übergang-Marker: Überblendung auf den Clip, der dort (± eine halbe Sekunde) beginnt
        for m in p.markers where m.kind == "transition" {
            if try applyTransitionMarker(&p, m) { transitions += 1 }
        }
        p.sortClips()
        return .object(["created": .int(created), "updated": .int(updated), "transitions": .int(transitions),
                        "skipped": .array(skipped)])
    }

    /// Was „Übernehmen“ täte, ohne etwas zu ändern. Je Szene mit Take ein Eintrag: `create` (noch kein verbundener
    /// Clip; `overlaps` nennt die Clips, die er überdecken würde, `in_edit`, wenn der Take schon als Clip im Schnitt
    /// liegt), `replace` (verbundene Clips bekommen den neuen Take; `edited`, wenn ihre Länge nicht mehr der Szene
    /// entspricht oder sie geschnitten sind) oder `same`. `default` ist der Vorschlag für das Häkchen.
    static func conformPlan(_ project: StudioProject, _ env: StudioEnvironment) -> JSONValue {
        var q = project
        let targets = conformTargets(&q)
        let inEdit = Set(q.clips.map(\.assetID))
        var items: [JSONValue] = []
        var without = 0
        for s in q.scenes {
            guard let take = s.take else {
                without += 1
                continue
            }
            let (start, track) = targets[s.id]!
            var base: [String: JSONValue] = ["scene_id": .string(s.id), "lane": .string(s.lane), "track": .string(track),
                                             "title": .string(!s.title.isEmpty ? s.title : (!s.prompt.isEmpty ? String(s.prompt.prefix(40)) : s.id))]
            let linked = q.clips.filter { $0.sceneID == s.id }
            if let first = linked.first {
                let changed = linked.contains { $0.assetID != take }
                let edited = linked.count > 1 || !untouched(&q, s, start: start, first, env)
                base["action"] = .string(changed ? "replace" : "same")
                base["clip_ids"] = .array(linked.map { .string($0.id) })
                base["track"] = .string(first.track)
                base["start_s"] = .double(round3(Studio.seconds(first.start)))
                base["length_s"] = .double(round3(Studio.seconds(linked.reduce(0) { $0 + $1.length })))
                base["scene_s"] = .double(round3(Studio.seconds(s.duration)))
                base["edited"] = .bool(edited)
                base["default"] = .bool(changed && !edited)
                items.append(.object(base))
                continue
            }
            let clip: StudioClip
            do {
                let at = chainStart(&q, track: track, assetID: take, start: start, env)
                clip = try newClip(&q, track: track, assetID: take, start: at, length: start + s.duration - at,
                                   inPoint: 0, sceneID: s.id, env: env)
            } catch {
                base["action"] = .string("error")
                base["error"] = .string(error.localizedDescription)
                base["default"] = .bool(false)
                items.append(.object(base))
                continue
            }
            // wie in conform: die gewollte Überlappung einer Latent-Kette vor dem Szenenanfang ist kein Überdecken
            let overlaps: [JSONValue] = q.clips.filter { $0.track == track && $0.start < clip.end && $0.end > start }.map { c in
                .object(["clip_id": .string(c.id), "title": .string(clipLabel(q, c, env)),
                         "seconds": .double(round3(Studio.seconds(min(c.end, clip.end) - max(c.start, start))))])
            }
            let dup = inEdit.contains(take)
            base["action"] = .string("create")
            base["start_s"] = .double(round3(Studio.seconds(start)))
            base["length_s"] = .double(round3(Studio.seconds(clip.length)))
            base["overlaps"] = .array(overlaps)
            base["in_edit"] = .bool(dup)
            base["default"] = .bool(overlaps.isEmpty && !dup)
            items.append(.object(base))
        }
        let markers = q.markers.filter { $0.kind == "transition" }.count
        return .object(["items": .array(items), "without_take": .int(without), "transition_markers": .int(markers)])
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded(.toNearestOrEven) / 1000 }

    /// Anschluss-Marker: Die Videoszene, die am Marker (± eine halbe Sekunde) beginnt, setzt die Videoszene davor
    /// fort, wenn sie nicht schon eine eigene Vorlage hat. Nur abgeleitet, nicht gespeichert: Szenen-ID →
    /// (Vorlage, Marker).
    static func resolvedChains(_ p: StudioProject) -> [String: (from: String, marker: String)] {
        let half = Studio.ticks(0.5)
        let video = p.scenes.filter { $0.lane == "video" }
        var out: [String: (from: String, marker: String)] = [:]
        for m in p.markers where m.kind == "chain" {
            guard let after = video.first(where: { abs($0.start - m.at) <= half }) else { continue }
            let before = video.filter { $0.end <= m.at + half && $0.id != after.id }
            if after.chainFrom == nil, out[after.id] == nil, after.kind == "video", let source = before.max(by: { $0.start < $1.start }) {
                out[after.id] = (source.id, m.id)
            }
        }
        return out
    }
}
