import SwiftUI
import UniformTypeIdentifiers

/// Die zwei Zeitleisten wie studio/Timelines.tsx unter Windows: Kopfspalte 92 px (in der Linealzeile die Werkzeuge),
/// „KOMPOSITION“ (Marker, Bild, Sprecher, Musik, Klang) und „SCHNITT“ (Spuren Vn … V1, A1 …). Gummiband, Gruppen
/// ziehen, Rasten mit Linie, Rechtsklick-Menüs; jede Änderung ist ein Befehl.
struct StudioTimeline: View {
    @ObservedObject var model: StudioModel
    @State private var band: CGRect?

    enum Section { case markers, lanes, tracks }

    static let header: CGFloat = 92
    static let ruler: CGFloat = 22
    static let caption: CGFloat = 14
    static let markerRow: CGFloat = 22
    static func laneHeight(_ lane: String) -> CGFloat { lane == "video" ? 46 : 30 }
    static func trackHeight(_ id: String) -> CGFloat { id == "V1" ? 52 : id.hasPrefix("V") ? 40 : 32 }
    static let laneNames = ["video": ("Bild/Video", "Picture"), "voice": ("Sprecher", "Voice"), "music": ("Musik", "Music"),
                            "sfx": ("Klang", "Sound")]

    /// y-Positionen aller Zeilen (Inhalt, ohne Lineal) für Gummiband und Menüs.
    struct Layout {
        var markers: CGFloat = 0
        var lanes: [String: CGFloat] = [:]
        var tracks: [String: CGFloat] = [:]
        var editCaption: CGFloat = 0
        var height: CGFloat = 0
    }

    static func layout(_ p: StudioProject) -> Layout {
        var l = Layout()
        var y = caption
        l.markers = y
        y += markerRow
        for lane in Studio.lanes {
            l.lanes[lane] = y
            y += laneHeight(lane)
        }
        l.editCaption = y
        y += caption
        for tr in p.tracks {
            l.tracks[tr.id] = y
            y += trackHeight(tr.id)
        }
        l.height = y
        return l
    }

    var body: some View {
        if let p = model.project {
            let layout = Self.layout(p)
            let end = [p.editDuration, p.compositionDuration, model.playhead, p.markers.map { $0.at + $0.duration }.max() ?? 0].max() ?? 0
            GeometryReader { geo in
                // Bahnen und Spuren reichen mindestens bis zum rechten Rand
                let width = max(800, geo.size.width - Self.header, CGFloat((Studio.seconds(end) + 30) * model.pxPerSecond))
                // Kopfspalte bleibt stehen (wie unter Windows), senkrecht scrollen beide zusammen
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        headerColumn(p)
                            .frame(width: Self.header)
                            .background(.bar)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                StudioRuler(model: model, width: width)
                                content(p, layout, width: width)
                            }
                        }
                    }
                }
            }
            .onScrollWheel(zoom: { factor in model.pxPerSecond = min(400, max(4, model.pxPerSecond * factor)) })
        }
    }

    // MARK: Kopfspalte

    private func headerColumn(_ p: StudioProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioTools(model: model).frame(height: Self.ruler)
            caption(t("KOMPOSITION", "COMPOSITION"))
            Text(t("Marker", "Markers")).font(.caption).foregroundStyle(.secondary).frame(height: Self.markerRow)
            ForEach(Studio.lanes, id: \.self) { lane in
                let name = Self.laneNames[lane] ?? (lane, lane)
                Text(t(name.0, name.1)).font(.caption).frame(height: Self.laneHeight(lane))
            }
            caption(t("SCHNITT", "EDIT"))
            ForEach(p.tracks, id: \.id) { tr in TrackHeader(model: model, track: tr, project: p).frame(height: Self.trackHeight(tr.id)) }
        }
        .padding(.leading, 6)
        .frame(width: Self.header, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.green).frame(height: Self.caption)
    }

    // MARK: Inhalt

    private func content(_ p: StudioProject, _ l: Layout, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.green.opacity(0.05)).frame(width: width, height: Self.caption)
            rowBackground(.markers, y: l.markers, height: Self.markerRow, width: width, p: p)
            ForEach(Studio.lanes, id: \.self) { lane in
                rowBackground(.lanes, y: l.lanes[lane]!, height: Self.laneHeight(lane), width: width, p: p, lane: lane)
            }
            Rectangle().fill(Color.green.opacity(0.05)).frame(width: width, height: Self.caption).offset(y: l.editCaption)
            ForEach(p.tracks, id: \.id) { tr in
                rowBackground(.tracks, y: l.tracks[tr.id]!, height: Self.trackHeight(tr.id), width: width, p: p, track: tr)
            }
            ForEach(p.markers) { m in
                MarkerFlag(model: model, marker: m, project: p).offset(x: CGFloat(model.x(m.at)), y: l.markers + 3)
            }
            ForEach(p.scenes) { s in
                SceneBlock(model: model, scene: s, project: p, height: Self.laneHeight(s.lane) - 6)
                    .offset(x: CGFloat(model.x(s.start)), y: (l.lanes[s.lane] ?? 0) + 3)
            }
            ForEach(p.clips) { c in
                if let y = l.tracks[c.track] {
                    ClipBlock(model: model, clip: c, project: p, height: Self.trackHeight(c.track) - 6, layout: l)
                        .offset(x: CGFloat(model.x(c.start)), y: y + 3)
                }
            }
            // Schnittlinie des Werkzeugs „Schneiden“ (mit Umschalt über alle Spuren)
            if model.tool == .razor, let track = model.hoverTrack {
                ForEach(model.shiftHeld ? p.tracks.map(\.id) : [track], id: \.self) { id in
                    if let y = l.tracks[id] {
                        Rectangle().fill(Color.white).frame(width: 1, height: Self.trackHeight(id))
                            .offset(x: CGFloat(model.x(model.hoverTicks)), y: y).allowsHitTesting(false)
                    }
                }
            }
            if let snap = model.snapLine {
                Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1, height: l.height)
                    .offset(x: CGFloat(model.x(snap))).allowsHitTesting(false)
            }
            Rectangle().fill(Color.red).frame(width: 1.5, height: l.height)
                .offset(x: CGFloat(model.x(model.playhead))).allowsHitTesting(false)
            if let band {
                Rectangle().fill(Color.accentColor.opacity(0.12)).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: band.width, height: band.height).offset(x: band.minX, y: band.minY).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: l.height, alignment: .topLeading)
        .coordinateSpace(name: "timeline")
        .onContinuousHover(coordinateSpace: .named("timeline")) { phase in
            guard case .active(let point) = phase else { model.hoverTrack = nil; return }
            model.hoverTicks = model.tool == .razor ? model.snapped(model.ticks(atX: point.x)) : model.ticks(atX: point.x)
            if model.tool != .razor { model.snapLine = nil }
            model.hoverTrack = p.tracks.first { tr in
                let y = l.tracks[tr.id] ?? -1
                return point.y >= y && point.y < y + Self.trackHeight(tr.id)
            }?.id
        }
    }

    private func rowBackground(_ section: Section, y: CGFloat, height: CGFloat, width: CGFloat, p: StudioProject,
                               lane: String? = nil, track: StudioTrack? = nil) -> some View {
        let fill: Color = track.map { $0.kind == "video" ? Color.blue.opacity($0.isHidden ? 0.10 : 0.04) : Color.green.opacity(0.04) }
            ?? Color.gray.opacity(section == .markers ? 0.06 : 0.035)
        return Rectangle().fill(fill)
            .overlay(Rectangle().stroke(Color.gray.opacity(0.15), lineWidth: 0.5))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            // Doppelklick vor dem einfachen Klick (sonst schluckt einer den anderen), das Gummiband daneben
            .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named("timeline")).onEnded { tap in
                Task { await doubleClick(section, at: tap.location, lane: lane) }
            }.exclusively(before: SpatialTapGesture(coordinateSpace: .named("timeline")).onEnded { tap in
                if model.tool == .razor, let track {
                    Task { await razor(track.id, at: tap.location) }
                } else {
                    model.clearSelection()
                }
            }))
            .simultaneousGesture(bandGesture(section, p: p))
            .dropDestination(for: String.self) { ids, location in
                guard let track, let id = ids.first else { return false }
                let start = model.snapped(model.ticks(atX: location.x))
                model.snapLine = nil
                Task {
                    if let r = await model.run("clip.add", ["track": .string(track.id), "asset_id": .string(id), "start": .int(start)]),
                       let clip = r["id"]?.stringValue {
                        model.select(.clip, clip)
                    }
                }
                return true
            }
            .contextMenu { rowMenu(section, p: p, lane: lane, track: track) }
            .help(section == .lanes ? t("Doppelklick: neue Szene · Rechtsklick: Menü", "Double-click: new scene · Right-click: menu") : "")
            .offset(y: y)
    }

    private func doubleClick(_ section: Section, at point: CGPoint, lane: String?) async {
        let at = model.snapped(model.ticks(atX: point.x))
        model.snapLine = nil
        switch section {
        case .markers: await model.addMarker("note", at: at)
        case .lanes:
            guard let lane else { return }
            await newScene(lane, kind: lane == "video" ? "video" : "audio", at: at)
        case .tracks: break
        }
    }

    private func newScene(_ lane: String, kind: String, at: Int) async {
        let seconds = lane == "video" ? 5.0 : 10.0
        if let r = await model.run("scene.add", ["lane": .string(lane), "kind": .string(kind), "start": .int(at), "duration_s": .double(seconds)]),
           let id = r["id"]?.stringValue {
            model.select(.scene, id)
        }
    }

    private func razor(_ track: String, at point: CGPoint) async {
        let at = model.snapped(model.ticks(atX: point.x))
        model.snapLine = nil
        if model.shiftHeld {
            await model.run("clip.razor", ["at": .int(at)])
        } else {
            await model.run("clip.razor", ["at": .int(at), "track": .string(track)])
        }
    }

    /// Gummiband: wählt Clips, Szenen oder Marker, je nachdem wo das Ziehen begann; Umschalt fügt hinzu.
    private func bandGesture(_ section: Section, p: StudioProject) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .onChanged { g in
                guard model.tool == .select else { return }
                band = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                              width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
            }
            .onEnded { _ in
                defer { band = nil }
                guard let rect = band else { return }
                let l = Self.layout(p)
                let from = model.ticks(atX: rect.minX), to = model.ticks(atX: rect.maxX)
                var ids = Set<String>()
                let kind: StudioModel.Kind
                switch section {
                case .markers:
                    kind = .marker
                    ids = Set(p.markers.filter { $0.at >= from && $0.at <= to }.map(\.id))
                case .lanes:
                    kind = .scene
                    ids = Set(p.scenes.filter { s in
                        let y = l.lanes[s.lane] ?? 0
                        return s.end > from && s.start < to && y + Self.laneHeight(s.lane) > rect.minY && y < rect.maxY
                    }.map(\.id))
                case .tracks:
                    kind = .clip
                    ids = Set(p.clips.filter { c in
                        let y = l.tracks[c.track] ?? 0
                        return c.end > from && c.start < to && y + Self.trackHeight(c.track) > rect.minY && y < rect.maxY
                    }.map(\.id))
                }
                if model.shiftHeld, model.kind == kind { ids.formUnion(model.selected) }
                model.select(kind, ids)
            }
    }

    // MARK: Menüs auf freien Stellen

    @ViewBuilder
    private func rowMenu(_ section: Section, p: StudioProject, lane: String?, track: StudioTrack?) -> some View {
        let at = model.roundFrame(model.hoverTicks)
        switch section {
        case .markers:
            MarkerHereMenu(model: model, at: at)
            PasteButton(model: model, at: at)
        case .lanes:
            if lane == "video" {
                Button(t("Neue Videoszene hier", "New video scene here")) { Task { await newScene("video", kind: "video", at: at) } }
                Button(t("Neues Standbild hier", "New still image here")) { Task { await newScene("video", kind: "image", at: at) } }
            } else if let lane {
                Button(t("Neue Szene hier", "New scene here")) { Task { await newScene(lane, kind: "audio", at: at) } }
            }
            PasteButton(model: model, at: at)
            MarkerHereMenu(model: model, at: at)
        case .tracks:
            PasteButton(model: model, at: at)
            if let track, let target = transitionTarget(p, track: track.id, at: at) {
                Menu(t("Übergang hier (\(target.track))", "Transition here (\(target.track))")) {
                    TransitionKinds { kind in
                        Task { await model.run("clip.update", ["id": .string(target.id), "transition": .object(["kind": .string(kind), "duration_s": .double(0.5)])]) }
                    }
                }
            } else {
                Button(t("Übergang hier (kein Schnitt in der Nähe)", "Transition here (no cut nearby)")) {}.disabled(true)
            }
            MarkerHereMenu(model: model, at: at)
            Divider()
            Button(t("Videospur hinzufügen", "Add video track")) { Task { await model.run("track.add", ["kind": .string("video")]) } }
            Button(t("Tonspur hinzufügen", "Add audio track")) { Task { await model.run("track.add", ["kind": .string("audio")]) } }
        }
    }

    /// Clip, der ±0,5 s um `at` beginnt: diese Spur zuerst, dann Videospuren von unten, dann Ton (wie unter Windows).
    private func transitionTarget(_ p: StudioProject, track: String, at: Int) -> StudioClip? {
        let half = Studio.ticks(0.5)
        let near = p.clips.filter { $0.start > 0 && abs($0.start - at) <= half }
        if let c = near.first(where: { $0.track == track }) { return c }
        let video = near.filter { $0.track.hasPrefix("V") }.sorted { StudioTrack.number($0.track) < StudioTrack.number($1.track) }
        return video.first ?? near.first
    }
}

// MARK: - Lineal und Werkzeuge

/// Lineal m:ss,s; Schritte 1/5/10/30 s je Zoom; Klicken oder Ziehen setzt den Abspielkopf (gerastet) und hält an.
struct StudioRuler: View {
    @ObservedObject var model: StudioModel
    let width: CGFloat

    var body: some View {
        let px = model.pxPerSecond
        let step = px >= 120 ? 1.0 : px >= 40 ? 5.0 : px >= 12 ? 10.0 : 30.0
        let seconds = Double(width) / px
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.bar)
            ForEach(Array(stride(from: 0.0, through: seconds, by: step)), id: \.self) { s in
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: 8).offset(x: CGFloat(s * px), y: 14)
                Text(Self.label(s)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    .offset(x: CGFloat(s * px) + 3, y: 3)
            }
        }
        .frame(width: width, height: StudioTimeline.ruler)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            model.leaveSource()
            model.seek(model.snapped(model.ticks(atX: g.location.x), playhead: false))
        }.onEnded { _ in model.snapLine = nil })
    }

    static func label(_ s: Double) -> String {
        let minutes = Int(s) / 60
        let text = String(format: "%d:%04.1f", minutes, s - Double(minutes * 60))
        return Lang.current == .de ? text.replacingOccurrences(of: ".", with: ",") : text
    }
}

/// Werkzeuge links oben an der Zeitleiste wie unter Windows: Auswahl (V), Schneiden (C), Skalieren (Z), Magnet (S).
struct StudioTools: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 2) {
            tool(.select, symbol: "cursorarrow", help: t("Auswahl (V)", "Selection (V)"))
            tool(.razor, symbol: "scissors", help: t("Schneiden (C): Klick schneidet die Spur dort, mit Umschalt alle Spuren",
                                                     "Razor (C): click cuts the track there, with Shift all tracks"))
            tool(.scale, symbol: "arrow.up.left.and.arrow.down.right",
                 help: t("Skalieren (Z): im Monitor ziehen setzt einen Keyframe, Klick den Fokuspunkt",
                         "Scale (Z): drag in the monitor to set a keyframe, click to set the focus point"))
            Button { model.magnet.toggle() } label: {
                MagnetShape().stroke(model.magnet ? Color.green : Color.secondary, lineWidth: 1.6).frame(width: 11, height: 12)
                    .frame(width: 18, height: 18)
                    .background(model.magnet ? Color.green.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(t("Magnet (S): rastet an Kanten, Abspielkopf und Markern ein; ausgeschaltet rastet die Umschalttaste",
                    "Magnet (S): snaps to edges, playhead and markers; when off, hold Shift to snap"))
        }
    }

    private func tool(_ which: StudioModel.Tool, symbol: String, help: String) -> some View {
        Button { model.tool = which } label: {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 18, height: 18)
                .foregroundStyle(model.tool == which ? Color.green : Color.secondary)
                .background(model.tool == which ? Color.green.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Hufeisenmagnet wie das Symbol der Windows-Oberfläche.
struct MagnetShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.55))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + h * 0.55), radius: w / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.move(to: CGPoint(x: r.minX, y: r.minY + h * 0.25))
        p.addLine(to: CGPoint(x: r.minX + w * 0.32, y: r.minY + h * 0.25))
        p.move(to: CGPoint(x: r.maxX, y: r.minY + h * 0.25))
        p.addLine(to: CGPoint(x: r.maxX - w * 0.32, y: r.minY + h * 0.25))
        return p
    }
}

/// Schraffur (Übergänge, laufende Szenen, fehlende Dateien).
struct Stripes: Shape {
    var spacing: CGFloat = 6
    var phase: CGFloat = 0
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height + phase.truncatingRemainder(dividingBy: spacing)
        while x < r.width {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += spacing
        }
        return p
    }
}

// MARK: - Spurkopf

struct TrackHeader: View {
    @ObservedObject var model: StudioModel
    let track: StudioTrack
    let project: StudioProject

    var body: some View {
        let off = track.isHidden || track.isMuted
        HStack(spacing: 4) {
            Text(track.id).font(.caption.monospaced()).foregroundStyle(off ? .secondary : .primary)
            Spacer(minLength: 2)
            if track.kind == "video" {
                Button { Task { await model.run("track.update", ["id": .string(track.id), "hidden": .bool(!track.isHidden)]) } } label: {
                    Image(systemName: track.isHidden ? "eye.slash" : "eye").font(.system(size: 10))
                }.buttonStyle(.borderless).help(t("Bild der Spur ein/aus", "Track picture on/off"))
            }
            Button { Task { await model.run("track.update", ["id": .string(track.id), "muted": .bool(!track.isMuted)]) } } label: {
                Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 10))
            }.buttonStyle(.borderless).help(t("Ton der Spur ein/aus", "Track sound on/off"))
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(t("Videospur hinzufügen", "Add video track")) { Task { await model.run("track.add", ["kind": .string("video")]) } }
            Button(t("Tonspur hinzufügen", "Add audio track")) { Task { await model.run("track.add", ["kind": .string("audio")]) } }
            if track.kind == "video" {
                Button(track.isHidden ? t("\(track.id) einblenden", "Show \(track.id)") : t("\(track.id) ausblenden", "Hide \(track.id)")) {
                    Task { await model.run("track.update", ["id": .string(track.id), "hidden": .bool(!track.isHidden)]) }
                }
            }
            Button(track.isMuted ? t("Ton an", "Unmute") : t("Spur stumm", "Mute the track")) {
                Task { await model.run("track.update", ["id": .string(track.id), "muted": .bool(!track.isMuted)]) }
            }
            Divider()
            if track.number == 1 {
                Button(t("\(track.id) bleibt immer", "\(track.id) always stays")) {}.disabled(true)
            } else {
                let n = project.clips.filter { $0.track == track.id }.count
                Button(t("Spur \(track.id) entfernen (\(n) Clips)", "Remove track \(track.id) (\(n) clips)"), role: .destructive) {
                    Task { await model.run("track.delete", ["id": .string(track.id)]) }
                }
            }
        }
    }
}

// MARK: - Marker

struct MarkerFlag: View {
    @ObservedObject var model: StudioModel
    let marker: StudioMarker
    let project: StudioProject

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "yellow": return .yellow
        case "green": return .green
        case "cyan": return .cyan
        case "purple": return .purple
        default: return .gray
        }
    }

    var body: some View {
        let selected = model.isSelected(.marker, marker.id)
        let width = max(12, CGFloat(model.x(marker.duration)))
        let title = marker.name.isEmpty ? StudioInspector.markerName(marker.kind) : marker.name
        HStack(spacing: 2) {
            Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Self.color(marker.color))
            if !marker.name.isEmpty {
                Text(marker.name).font(.system(size: 10)).lineLimit(1).strikethrough(marker.done)
            }
        }
        .padding(.horizontal, 2)
        .frame(minWidth: width, alignment: .leading)
        .frame(height: StudioTimeline.markerRow - 6)
        .background(Self.color(marker.color).opacity(marker.duration > 0 ? 0.25 : 0), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .opacity(marker.done ? 0.45 : 1)
        .offset(x: (selected ? model.groupDrag : 0) - 5)
        .contentShape(Rectangle())
        .help(marker.comment.isEmpty ? title : "\(title): \(marker.comment)")
        .onTapGesture { model.select(.marker, marker.id, additive: model.shiftHeld || NSEvent.modifierFlags.contains(.command)) }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline")).onChanged { g in
            if !model.isSelected(.marker, marker.id) { model.select(.marker, marker.id) }
            model.groupDrag = CGFloat(model.x(delta(g.translation.width)))
        }.onEnded { g in
            let d = delta(g.translation.width)
            let group = project.markers.filter { model.selected.contains($0.id) }
            model.groupDrag = 0
            model.snapLine = nil
            Task { await model.batch(group.map { ("marker.update", ["id": .string($0.id), "at": .int($0.at + d)]) }) }
        })
        .contextMenu {
            let ids = model.targets(.marker, marker.id)
            Button(marker.done ? t("Wieder öffnen", "Reopen") : t("Erledigt", "Done")) {
                Task { await model.batch(ids.map { ("marker.update", ["id": .string($0), "done": .bool(!marker.done)]) }) }
            }
            Menu(t("Art", "Kind")) {
                ForEach(Studio.markerKinds, id: \.self) { kind in
                    Button { Task { await model.batch(ids.map { ("marker.update", ["id": .string($0), "kind": .string(kind), "color": .string("")]) }) } } label: {
                        if kind == marker.kind { Label(StudioInspector.markerName(kind), systemImage: "checkmark") } else { Text(StudioInspector.markerName(kind)) }
                    }
                }
            }
            Divider()
            Button(t("Ausschneiden", "Cut")) { model.select(.marker, Set(ids)); Task { await model.copy(cut: true) } }.keyboardShortcut("x")
            Button(t("Kopieren", "Copy")) { model.select(.marker, Set(ids)); Task { await model.copy() } }.keyboardShortcut("c")
            Divider()
            Button(t("Löschen", "Delete"), role: .destructive) { model.select(.marker, Set(ids)); Task { await model.deleteSelection() } }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private func delta(_ dx: CGFloat) -> Int {
        let group = project.markers.filter { model.selected.contains($0.id) }
        let raw = Studio.ticks(Double(dx) / model.pxPerSecond)
        return max(-(group.map(\.at).min() ?? 0), model.snappedDelta(raw, edges: group.map(\.at), excluding: Set(group.map(\.id))))
    }
}

// MARK: - Szene

struct SceneBlock: View {
    @ObservedObject var model: StudioModel
    let scene: StudioScene
    let project: StudioProject
    let height: CGFloat
    @State private var stretch: CGFloat = 0
    @State private var dropping = false

    var body: some View {
        let status = StudioJSON.status(scene)
        let selected = model.isSelected(.scene, scene.id)
        let w = max(4, CGFloat(model.x(scene.duration)) + stretch)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(fill(status))
            if status == "running" || status == "waiting" {
                TimelineView(.animation(minimumInterval: 0.05, paused: status == "waiting")) { context in
                    Stripes(spacing: 8, phase: CGFloat(context.date.timeIntervalSinceReferenceDate * 20))
                        .stroke(Color.white.opacity(0.18), lineWidth: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 5) {
                if scene.lane == "video", let take = scene.take {
                    StudioThumb(assetID: take, symbol: scene.kind == "image" ? "photo" : "film")
                        .frame(width: (height - 4) * 16 / 9, height: height - 4).clipShape(RoundedRectangle(cornerRadius: 3))
                } else if scene.take != nil {
                    Text("∿∿∿").font(.caption).foregroundStyle(.secondary)
                }
                if scene.chainFrom != nil || StudioCommands.resolvedChains(project)[scene.id] != nil {
                    Text("⛓").font(.system(size: 10)).help(t("Setzt die vorige Szene fort", "Continues the previous scene"))
                }
                (Text(scene.title.isEmpty ? t("Szene", "Scene") : scene.title).bold() + Text(" " + scene.prompt))
                    .font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 4)
            // rechter Rand 7 px: Länge (min 0,25 s)
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: 7).offset(x: w - 7)
                .pointerStyle(.columnResize)
                .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { g in
                    stretch = CGFloat(model.x(newDuration(g.translation.width) - scene.duration))
                }.onEnded { g in
                    let d = newDuration(g.translation.width)
                    stretch = 0
                    model.snapLine = nil
                    Task { await model.run("scene.update", ["id": .string(scene.id), "duration": .int(d)]) }
                })
        }
        .frame(width: w, height: height)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(border(status, selected: selected),
                                                                   style: StrokeStyle(lineWidth: selected || dropping ? 2 : 1,
                                                                                      dash: status == "empty" || status == "waiting" ? [4, 3] : [])))
        .offset(x: selected ? model.groupDrag : 0)
        .contentShape(Rectangle())
        .help(scene.error ?? scene.prompt)
        .onTapGesture { model.select(.scene, scene.id, additive: model.shiftHeld || NSEvent.modifierFlags.contains(.command)) }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline")).onChanged { g in
            if !model.isSelected(.scene, scene.id) { model.select(.scene, scene.id) }
            model.groupDrag = CGFloat(model.x(delta(g.translation.width)))
        }.onEnded { g in
            let d = delta(g.translation.width)
            let group = project.scenes.filter { model.selected.contains($0.id) }
            model.groupDrag = 0
            model.snapLine = nil
            Task { await model.batch(group.map { ("scene.update", ["id": .string($0.id), "start": .int($0.start + d)]) }) }
        })
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            Task {
                await model.run("scene.take", ["id": .string(scene.id), "asset_id": .string(id)])
                model.select(.scene, scene.id)
            }
            return true
        } isTargeted: { dropping = $0 }
        .contextMenu {
            let ids = model.targets(.scene, scene.id)
            let busy = !scene.jobs.isEmpty || scene.waitingFor != nil
            Button(scene.take == nil ? t("Erzeugen", "Generate") : t("Neu erzeugen", "Generate again")) {
                Task { await model.generate(ids) }
            }.disabled(busy)
            Divider()
            Button(t("Ausschneiden", "Cut")) { model.select(.scene, Set(ids)); Task { await model.copy(cut: true) } }.keyboardShortcut("x")
            Button(t("Kopieren", "Copy")) { model.select(.scene, Set(ids)); Task { await model.copy() } }.keyboardShortcut("c")
            PasteButton(model: model, at: model.playhead)
            Button(t("Marker hier", "Marker here")) { Task { await model.addMarker("note", at: model.roundFrame(model.hoverTicks)) } }
                .keyboardShortcut("m", modifiers: [])
            Divider()
            Button(t("Löschen", "Delete"), role: .destructive) { model.select(.scene, Set(ids)); Task { await model.deleteSelection() } }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private func newDuration(_ dx: CGFloat) -> Int {
        let end = model.snapped(scene.end + Studio.ticks(Double(dx) / model.pxPerSecond), excluding: [scene.id])
        return max(Studio.ticks(0.25), end - scene.start)
    }

    private func delta(_ dx: CGFloat) -> Int {
        let group = project.scenes.filter { model.selected.contains($0.id) }
        let raw = Studio.ticks(Double(dx) / model.pxPerSecond)
        return max(-(group.map(\.start).min() ?? 0),
                   model.snappedDelta(raw, edges: group.flatMap { [$0.start, $0.end] }, excluding: Set(group.map(\.id))))
    }

    private func fill(_ status: String) -> Color {
        switch status {
        case "done": return Color.green.opacity(0.32)
        case "error": return Color.red.opacity(0.28)
        case "running": return Color.green.opacity(0.18)
        default: return Color.gray.opacity(0.12)
        }
    }

    private func border(_ status: String, selected: Bool) -> Color {
        if dropping || selected { return .accentColor }
        switch status {
        case "error": return .red
        case "done": return Color.green.opacity(0.7)
        default: return Color.secondary.opacity(0.6)
        }
    }
}

// MARK: - Clip

struct ClipBlock: View {
    @ObservedObject var model: StudioModel
    let clip: StudioClip
    let project: StudioProject
    let height: CGFloat
    let layout: StudioTimeline.Layout
    @State private var left: CGFloat = 0
    @State private var right: CGFloat = 0
    @State private var transitionStretch: CGFloat = 0

    private var isVideo: Bool { clip.track.hasPrefix("V") }
    private var track: StudioTrack? { project.tracks.first { $0.id == clip.track } }
    private var isImage: Bool { project.media[clip.assetID]?.kind == "image" }

    private var label: String {
        if let s = project.scenes.first(where: { $0.id == clip.sceneID }), !s.title.isEmpty { return s.title }
        if let r = AssetSnapshot.shared.get(clip.assetID) {
            return r.prompt.isEmpty ? (r.meta["original_name"]?.stringValue ?? clip.assetID) : r.prompt
        }
        return clip.assetID
    }

    var body: some View {
        let selected = model.isSelected(.clip, clip.id)
        let missing = AssetSnapshot.shared.get(clip.assetID) == nil
        let faded = clip.muted || (track?.isMuted ?? false) || (track?.isHidden ?? false)
        let w = max(4, CGFloat(model.x(clip.length)) - left + right)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill((isVideo ? Color.blue : Color.teal).opacity(0.42))
            if missing {
                Stripes(spacing: 7).stroke(Color.red.opacity(0.6), lineWidth: 2).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 4) {
                if isVideo {
                    StudioThumb(assetID: clip.assetID, symbol: isImage ? "photo" : "film")
                        .frame(width: min(w * 0.5, (height - 4) * 16 / 9), height: height - 4).clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(label).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                if clip.speed != 1 {
                    Text(verbatim: "\(Int((clip.speed * 100).rounded())) %").font(.system(size: 9).monospacedDigit()).foregroundStyle(.yellow)
                }
                if clip.gainDB != 0 { Text(String(format: "%+.0f dB", clip.gainDB)).font(.system(size: 9).monospacedDigit()) }
                if (clip.scaleKeys ?? []).isEmpty, let s = clip.scale, s != 1 {
                    Text("\(Int((s * 100).rounded())) % ⤢").font(.system(size: 9).monospacedDigit())
                }
            }
            .padding(.horizontal, 3).padding(.top, 2)
            .frame(width: w, height: height, alignment: .leading)
            transitionBlock
            keyframes
            if model.tool == .select {
                edge(leading: true)
                edge(leading: false).offset(x: w - 6)
            }
        }
        .frame(width: w, height: height, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : missing ? .red : .clear, lineWidth: 2))
        .opacity(faded ? 0.5 : 1)
        .offset(x: left + (selected ? model.groupDrag : 0), y: selected ? model.groupDragY : 0)
        .contentShape(Rectangle())
        .help(missing ? t("Datei gelöscht: Clip löschen oder ersetzen", "File deleted: delete or replace the clip") : label)
        .gesture(SpatialTapGesture().onEnded { tap in
            switch model.tool {
            case .razor:
                let at = model.snapped(clip.start + Studio.ticks(Double(tap.location.x) / model.pxPerSecond))
                model.snapLine = nil
                Task {
                    if model.shiftHeld { await model.run("clip.razor", ["at": .int(at)]) }
                    else { await model.run("clip.razor", ["at": .int(at), "track": .string(clip.track)]) }
                }
            case .scale:
                model.select(.clip, clip.id)
                model.seek(clip.start + Studio.ticks(Double(tap.location.x) / model.pxPerSecond))
            case .select:
                model.select(.clip, clip.id, additive: model.shiftHeld || NSEvent.modifierFlags.contains(.command))
            }
        })
        .gesture(moveGesture, including: model.tool == .select ? .all : .subviews)
        .contextMenu { menu }
    }

    // Übergang: schraffierter Block in den unteren 46 % am Clipanfang; anklicken wählt, rechter Rand ändert die Dauer
    @ViewBuilder private var transitionBlock: some View {
        if let tr = clip.transition {
            let tw = max(10, CGFloat(model.x(tr.duration)) + transitionStretch)
            let th = height * 0.46
            let selected = model.isSelected(.transition, clip.id)
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.black.opacity(0.35))
                Stripes(spacing: tr.kind == "wipe" ? 4 : tr.kind.hasPrefix("dip") ? 9 : 6).stroke(Color.white.opacity(0.45), lineWidth: 1)
                Text(Self.transitionName(tr.kind)).font(.system(size: 8)).lineLimit(1).padding(.leading, 2).padding(.bottom, 1)
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: 5).offset(x: tw - 5)
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { g in transitionStretch = g.translation.width }.onEnded { g in
                        transitionStretch = 0
                        let d = model.roundFrame(tr.duration + Studio.ticks(Double(g.translation.width) / model.pxPerSecond))
                        let duration = min(clip.length, max(project.frameTicks, d))
                        Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .object(["kind": .string(tr.kind), "duration": .int(duration)])]) }
                    })
            }
            .frame(width: tw, height: th)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .offset(y: height - th)
            .help("\(Self.transitionName(tr.kind)) · \(formatSeconds(tr.duration)) s"
                  + (tr.marker != nil ? t(" (vom Übergang-Marker)", " (from the transition marker)") : ""))
            .onTapGesture { if model.tool == .select { model.select(.transition, clip.id) } }
            .allowsHitTesting(model.tool != .razor)
            .contextMenu {
                TransitionKinds(current: tr.kind) { kind in
                    Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .object(["kind": .string(kind), "duration": .int(tr.duration)])]) }
                }
                Menu(t("Dauer", "Duration")) {
                    ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { s in
                        Button { Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .object(["kind": .string(tr.kind), "duration_s": .double(s)])]) } } label: {
                            let text = String(format: "%g s", s)
                            if abs(Studio.seconds(tr.duration) - s) < 0.01 { Label(text, systemImage: "checkmark") } else { Text(text) }
                        }
                    }
                }
                Button(t("Entfernen", "Remove"), role: .destructive) { Task { await model.run("clip.update", ["id": .string(clip.id), "transition": .null]) } }
                    .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }

    static func transitionName(_ kind: String) -> String {
        switch kind {
        case "dip_black": return t("Abblende Schwarz", "Dip to black")
        case "dip_white": return t("Abblende Weiß", "Dip to white")
        case "wipe": return t("Wischblende", "Wipe")
        default: return t("Überblendung", "Cross dissolve")
        }
    }

    // Keyframe-Rauten (nur innerhalb In/Out): Klick wählt den Clip und springt hin, Doppelklick löscht
    @ViewBuilder private var keyframes: some View {
        if isVideo, let keys = clip.scaleKeys {
            ForEach(keys.filter { $0.at >= clip.inPoint && $0.at <= clip.outPoint }, id: \.at) { k in
                let offset = Int(Double(k.at - clip.inPoint) / clip.speed)
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    .offset(x: CGFloat(model.x(offset)) - 4, y: height / 2 - 4)
                    .help("\(Int((k.value * 100).rounded())) %")
                    .onTapGesture(count: 2) {
                        Task { await model.run("clip.key", ["id": .string(clip.id), "at": .int(clip.start + offset), "delete": .bool(true)]) }
                    }
                    .onTapGesture {
                        model.select(.clip, clip.id)
                        model.seek(clip.start + offset)
                    }
            }
        }
    }

    /// Ziehen: Clip oder Gruppe, gerastet, nie vor 0; senkrecht auf andere Spuren derselben Art (Versatz bleibt).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline")).onChanged { g in
            if !model.isSelected(.clip, clip.id) { model.select(.clip, clip.id) }
            let (delta, rows) = plannedMove(g.translation)
            model.groupDrag = CGFloat(model.x(delta))
            model.groupDragY = rowShift(rows)
        }.onEnded { g in
            let (delta, rows) = plannedMove(g.translation)
            model.groupDrag = 0
            model.groupDragY = 0
            model.snapLine = nil
            let group = project.clips.filter { model.selected.contains($0.id) }
            let moves: [JSONValue] = group.map { c in
                var mv: [String: JSONValue] = ["id": .string(c.id), "start": .int(c.start + delta)]
                if rows != 0, let target = shifted(c.track, rows) { mv["track"] = .string(target) }
                return .object(mv)
            }
            Task { await model.run("clip.move", ["moves": .array(moves)]) }
        }
    }

    private func plannedMove(_ translation: CGSize) -> (Int, Int) {
        let group = project.clips.filter { model.selected.contains($0.id) }
        let raw = Studio.ticks(Double(translation.width) / model.pxPerSecond)
        let delta = max(-(group.map(\.start).min() ?? 0),
                        model.snappedDelta(raw, edges: group.flatMap { [$0.start, $0.end] }, excluding: Set(group.map(\.id))))
        var rows = Int((translation.height / (height + 6)).rounded())
        // nur so weit, dass jeder Clip der Gruppe auf einer Spur seiner Art landet
        while rows != 0 && group.contains(where: { shifted($0.track, rows) == nil }) { rows += rows > 0 ? -1 : 1 }
        return (delta, rows)
    }

    private func shifted(_ track: String, _ rows: Int) -> String? {
        let same = project.tracks.filter { $0.kind == (track.hasPrefix("V") ? "video" : "audio") }.map(\.id)
        guard let i = same.firstIndex(of: track), same.indices.contains(i + rows) else { return nil }
        return same[i + rows]
    }

    private func rowShift(_ rows: Int) -> CGFloat {
        guard rows != 0, let target = shifted(clip.track, rows) else { return 0 }
        return (layout.tracks[target] ?? 0) - (layout.tracks[clip.track] ?? 0)
    }

    private func edge(leading: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 6, height: height)
            .pointerStyle(.columnResize)
            // im festen Raum der Zeitleiste: Der Griff wandert beim Ziehen mit, eigene Koordinaten liefen nur halb mit
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { g in
                let to = target(leading: leading, g.translation.width)
                if leading { left = CGFloat(model.x(to - clip.start)) } else { right = CGFloat(model.x(to - clip.end)) }
            }.onEnded { g in
                let to = target(leading: leading, g.translation.width)
                left = 0
                right = 0
                model.snapLine = nil
                Task { await model.run("clip.trim", ["id": .string(clip.id), "edge": .string(leading ? "start" : "end"), "to": .int(to)]) }
            })
    }

    private func target(leading: Bool, _ dx: CGFloat) -> Int {
        model.snapped((leading ? clip.start : clip.end) + Studio.ticks(Double(dx) / model.pxPerSecond), excluding: [clip.id])
    }

    @ViewBuilder private var menu: some View {
        let ids = model.targets(.clip, clip.id)
        let at = model.roundFrame(model.hoverTicks)
        Button(t("Ausschneiden", "Cut")) { model.select(.clip, Set(ids)); Task { await model.copy(cut: true) } }.keyboardShortcut("x")
        Button(t("Kopieren", "Copy")) { model.select(.clip, Set(ids)); Task { await model.copy() } }.keyboardShortcut("c")
        PasteButton(model: model, at: model.playhead)
        Divider()
        Button(t("Hier schneiden", "Cut here")) { Task { await model.run("clip.razor", ["at": .int(at), "track": .string(clip.track)]) } }
            .disabled(!(clip.start < at && at < clip.end))
        // wie unter Windows auch auf Tonspuren (dort blendet der Ton über)
        Menu(t("Übergang am Anfang", "Transition at the start")) {
            TransitionKinds(current: clip.transition?.kind) { kind in
                Task { await model.batch(ids.map { ("clip.update", ["id": .string($0), "transition": .object(["kind": .string(kind), "duration_s": .double(0.5)])]) }) }
            }
            Button(t("Entfernen", "Remove")) { Task { await model.batch(ids.map { ("clip.update", ["id": .string($0), "transition": .null]) }) } }
                .disabled(clip.transition == nil)
        }
        Menu(t("Tempo", "Speed")) {
            ForEach([25, 50, 75, 100, 150, 200, 400], id: \.self) { pct in
                Button { Task { await model.setSpeed([clip.id], Double(pct) / 100) } } label: {
                    if Int((clip.speed * 100).rounded()) == pct { Label("\(pct) %", systemImage: "checkmark") } else { Text("\(pct) %") }
                }
            }
        }
        .disabled(isImage || ids.count > 1)
        Button(clip.muted ? t("Ton an", "Unmute") : t("Stumm", "Mute")) {
            Task { await model.batch(ids.map { ("clip.update", ["id": .string($0), "muted": .bool(!clip.muted)]) }) }
        }
        .disabled(isImage)
        Button(t("Marker hier", "Marker here")) { Task { await model.addMarker("note", at: at) } }.keyboardShortcut("m", modifiers: [])
        if let r = AssetSnapshot.shared.get(clip.assetID) {
            Button(t("Im Finder zeigen", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AssetStore.shared.fileURL(r.filename)]) }
        }
        Divider()
        Button(t("Löschen", "Delete"), role: .destructive) { model.select(.clip, Set(ids)); Task { await model.deleteSelection() } }
            .keyboardShortcut(.delete, modifiers: [])
        Button(t("Löschen, Lücke schließen", "Delete, close gap"), role: .destructive) { model.select(.clip, Set(ids)); Task { await model.deleteSelection(ripple: true) } }
            .keyboardShortcut(.delete, modifiers: .shift)
    }
}

// MARK: - Bausteine der Menüs

struct TransitionKinds: View {
    var current: String? = nil
    let pick: (String) -> Void

    var body: some View {
        ForEach(Studio.transitionKinds, id: \.self) { kind in
            Button { pick(kind) } label: {
                if kind == current { Label(ClipBlock.transitionName(kind), systemImage: "checkmark") } else { Text(ClipBlock.transitionName(kind)) }
            }
        }
    }
}

struct MarkerHereMenu: View {
    @ObservedObject var model: StudioModel
    let at: Int

    var body: some View {
        Menu(t("Marker hier", "Marker here")) {
            ForEach(Studio.markerKinds, id: \.self) { kind in
                Button(StudioInspector.markerName(kind)) { Task { await model.addMarker(kind, at: at) } }
            }
        }
    }
}

struct PasteButton: View {
    @ObservedObject var model: StudioModel
    let at: Int

    var body: some View {
        Button(t("Einfügen (\(model.pasteCount))", "Paste (\(model.pasteCount))")) { Task { await model.paste(at: at) } }
            .keyboardShortcut("v")
            .disabled(model.pasteCount == 0)
    }
}

// MARK: - Mausrad mit Cmd/Strg zoomt

/// Nur über der Zeitleiste; das Mausrad zoomt je Raste ×1,25 bzw. ×0,8, das Trackpad stufenlos im selben Maß.
private struct ScrollZoom: ViewModifier {
    let zoom: (Double) -> Void
    @State private var monitor: Any?
    @State private var hover = HoverFlag()

    func body(content: Content) -> some View {
        content
            .onHover { hover.inside = $0 }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                    guard hover.inside, e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control),
                          e.scrollingDeltaY != 0 else { return e }
                    zoom(e.hasPreciseScrollingDeltas ? pow(1.25, Double(e.scrollingDeltaY) / 12) : e.scrollingDeltaY > 0 ? 1.25 : 0.8)
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func onScrollWheel(zoom: @escaping (Double) -> Void) -> some View { modifier(ScrollZoom(zoom: zoom)) }
}
