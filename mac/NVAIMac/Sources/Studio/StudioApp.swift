import Foundation

extension StudioStore {
    /// Die Projekte der App in ~/Library/Application Support/NV-AI/studio (wie data/studio unter Windows); vor jedem
    /// Befehl liest AVFoundation die Medieninfo der beteiligten Assets.
    static let shared = StudioStore(
        directory: directory,
        env: StudioMediaProbe.environment,
        prefetch: { params, p in await StudioMediaProbe.prefetch(StudioMediaProbe.referencedAssets(params, p)) })
}

extension StudioStore {
    /// Ablage der Projekte; für Tests beim Start überschreibbar (`-studioDirectory <Ordner>`), wie die Assets.
    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: "studioDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Settings.appSupport.appendingPathComponent("studio", isDirectory: true)
    }
}

/// Projektansichten für Oberfläche, REST und Claude, wie view() und summary() in studio.py.
enum StudioJSON {
    static func status(_ s: StudioScene) -> String {
        if !s.jobs.isEmpty { return "running" }
        if s.waitingFor != nil { return "waiting" }
        if s.error != nil { return "error" }
        return s.take != nil ? "done" : "empty"
    }

    private static func round3(_ x: Double) -> JSONValue { .double((x * 1000).rounded() / 1000) }

    /// Projekt plus abgeleitete Angaben: Status je Szene, Anschluss aus Markern (chain_marker, nicht gespeichert),
    /// Längen, Rückgängig-Stand, Adresse und Art aller verwendeten Assets, fehlende Dateien je Clip.
    static func full(_ p: StudioProject, history: (undo: Int, redo: Int)) -> JSONValue {
        guard let data = try? StudioStore.encode(p), case .object(var out)? = JSON.parse(data) else { return .null }
        let chains = StudioCommands.resolvedChains(p)
        if case .array(let scenes)? = out["scenes"] {
            out["scenes"] = .array(zip(scenes, p.scenes).map { json, s in
                guard case .object(var o) = json else { return json }
                o["status"] = .string(status(s))
                if let chain = chains[s.id] {
                    o["chain_from"] = .string(chain.from)
                    o["chain_marker"] = .string(chain.marker)
                }
                return .object(o)
            })
        }
        out["tps"] = .int(Studio.ticksPerSecond)
        out["edit_duration"] = .int(p.editDuration)
        out["composition_duration"] = .int(p.compositionDuration)
        out["history"] = .object(["undo": .int(history.undo), "redo": .int(history.redo)])
        var assets: [String: JSONValue] = [:]
        let used = Set(p.scenes.flatMap(\.takes) + p.clips.map(\.assetID))
        for id in used {
            guard let r = AssetSnapshot.shared.get(id) else { continue }
            var a: [String: JSONValue] = ["url": .string(r.url), "kind": .string(p.media[id]?.kind ?? r.kind),
                                          "prompt": .string(String(r.prompt.prefix(120)))]
            if let preview = r.meta["preview"]?.stringValue { a["preview"] = .string("/files/\(preview)") }
            assets[id] = .object(a)
        }
        out["assets"] = .object(assets)
        if case .array(let clips)? = out["clips"] {
            out["clips"] = .array(clips.map { json in
                guard case .object(var o) = json, let id = o["asset_id"]?.stringValue else { return json }
                o["missing"] = .bool(assets[id] == nil)  // Datei gelöscht: Clip rot, Export nennt ihn
                return .object(o)
            })
        }
        return .object(out)
    }

    /// Kompakt für Claude (MCP): Zeiten in Sekunden, ohne Medien-Cache.
    static func summary(_ p: StudioProject) -> JSONValue {
        let chains = StudioCommands.resolvedChains(p)
        let scenes: [JSONValue] = p.scenes.map { s in
            .object(["id": .string(s.id), "lane": .string(s.lane), "start_s": round3(Studio.seconds(s.start)),
                     "duration_s": round3(Studio.seconds(s.duration)), "title": .string(s.title),
                     "prompt": .string(s.prompt), "kind": .string(s.kind),
                     "model_id": s.modelID.map(JSONValue.string) ?? .null,
                     "chain_from": (s.chainFrom ?? chains[s.id]?.from).map(JSONValue.string) ?? .null,
                     "status": .string(status(s)), "waiting_for": s.waitingFor.map(JSONValue.string) ?? .null,
                     "take": s.take.map(JSONValue.string) ?? .null, "takes": .int(s.takes.count),
                     "error": s.error.map(JSONValue.string) ?? .null])
        }
        let markers: [JSONValue] = p.markers.map { m in
            .object(["id": .string(m.id), "at_s": round3(Studio.seconds(m.at)), "kind": .string(m.kind),
                     "name": .string(m.name), "comment": .string(m.comment), "params": .object(m.params),
                     "done": .bool(m.done)])
        }
        let tracks: [JSONValue] = p.tracks.map { tr in
            var o: [String: JSONValue] = ["id": .string(tr.id), "kind": .string(tr.kind)]
            if tr.isHidden { o["hidden"] = .bool(true) }
            if tr.isMuted { o["muted"] = .bool(true) }
            return .object(o)
        }
        let clips: [JSONValue] = p.clips.map { c in
            var o: [String: JSONValue] = ["id": .string(c.id), "track": .string(c.track),
                                          "start_s": round3(Studio.seconds(c.start)), "end_s": round3(Studio.seconds(c.end)),
                                          "asset_id": .string(c.assetID), "scene_id": c.sceneID.map(JSONValue.string) ?? .null]
            if c.speed != 1 { o["speed"] = .double(c.speed) }
            if let scale = c.scale, scale != 1 { o["scale"] = .double(scale) }
            if let anchor = c.anchor, anchor != [0.5, 0.5] { o["anchor"] = .array(anchor.map(JSONValue.double)) }
            if let keys = c.scaleKeys, !keys.isEmpty {
                o["scale_keys"] = .array(keys.map { .object(["at_s": round3(Studio.seconds($0.at)), "value": .double($0.value)]) })
            }
            o["transition"] = c.transition.map {
                .object(["kind": .string($0.kind), "seconds": round3(Studio.seconds($0.duration))])
            } ?? .null
            return .object(o)
        }
        return .object(["id": .string(p.id), "name": .string(p.name),
                        "settings": (JSON.parse((try? JSONEncoder().encode(p.settings)) ?? Data()) ?? .null),
                        "folder": .null, "scenes": .array(scenes), "markers": .array(markers),
                        "tracks": .array(tracks), "clips": .array(clips),
                        "duration_s": round3(Studio.seconds(p.editDuration))])
    }
}
