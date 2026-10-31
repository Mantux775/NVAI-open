import AppKit
import AVKit
import SwiftUI

/// Merkt sich, ob die Maus über einer Ansicht steht. Eine Klasse, damit Ereignis-Wächter (NSEvent) immer den
/// aktuellen Wert lesen.
final class HoverFlag {
    var inside = false
}

/// Monitor wie studio/Monitor.tsx unter Windows: das Programm (Schnitt) oder, nach einem Klick ins Material, die Quelle.
/// Keine eigenen Transportknöpfe (Abspielen oben oder Leertaste, Spulen im Lineal). Mit dem Werkzeug Skalieren (Z):
/// Ziehen setzt einen Keyframe am Abspielkopf, ein Klick den Fokuspunkt, das Mausrad skaliert fein.
struct StudioMonitor: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var preview: StudioPreview
    @State private var liveScale: Double?
    @State private var wheelScale: Double?
    @State private var wheelTask: Task<Void, Never>?
    @State private var wheelMonitor: Any?
    @State private var hover = HoverFlag()
    @State private var player: AVPlayer?

    init(model: StudioModel) {
        self.model = model
        self.preview = model.preview
    }

    var body: some View {
        VStack(spacing: 0) {
            if let source = model.source {
                sourceView(source)
            } else {
                program
            }
            bottomBar
        }
        .onChange(of: model.source?.id) { _, _ in startSource() }
        .onAppear { installWheel() }
        .onDisappear {
            removeWheel()
            player?.pause()  // die Quelle nicht hinter einem anderen Reiter weiterspielen
        }
    }

    // MARK: Programm

    /// Der Clip, den das Werkzeug Skalieren trifft: der gewählte, wenn er am Abspielkopf sichtbar ist, sonst der oberste.
    private var scaleTarget: StudioClip? {
        guard model.tool == .scale, !model.playing, let p = model.project else { return nil }
        let visible = p.clips.filter { c in
            c.track.hasPrefix("V") && c.start <= model.playhead && model.playhead < c.end
                && !(p.tracks.first { $0.id == c.track }?.isHidden ?? false)
        }
        if let c = model.clip, visible.contains(where: { $0.id == c.id }) { return c }
        return visible.max { StudioTrack.number($0.track) < StudioTrack.number($1.track) }
    }

    private var program: some View {
        GeometryReader { geo in
            let p = model.project
            let aspect = p.map { CGFloat($0.settings.width) / CGFloat($0.settings.height) } ?? 16 / 9
            let w = min(geo.size.width, geo.size.height * aspect)
            let h = w / aspect
            let rect = CGRect(x: (geo.size.width - w) / 2, y: (geo.size.height - h) / 2, width: w, height: h)
            let target = scaleTarget
            let current = target.map { $0.scaleAt($0.mediaAt(model.playhead - $0.start)) } ?? 1
            let anchor = target?.anchor ?? [0.5, 0.5]
            ZStack(alignment: .topLeading) {
                Color.black
                if let img = preview.image {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: w, height: h)
                        .scaleEffect((liveScale ?? wheelScale).map { $0 / current } ?? 1, anchor: UnitPoint(x: anchor[0], y: anchor[1]))
                        .clipped()
                        .offset(x: rect.minX, y: rect.minY)
                }
                if let target {
                    let shown = liveScale ?? wheelScale ?? current
                    Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 14, height: 14)
                        .overlay(Circle().fill(Color.white).frame(width: 3, height: 3))
                        .offset(x: rect.minX + CGFloat(anchor[0]) * w - 7, y: rect.minY + CGFloat(anchor[1]) * h - 7)
                        .allowsHitTesting(false)
                    Text("\(Int((shown * 100).rounded())) %  " + t("Ziehen: skalieren (Keyframe am Abspielkopf) · Klick: Fokuspunkt · Mausrad: fein",
                                                                   "Drag: scale (keyframe at the playhead) · Click: focus point · Wheel: fine"))
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                        .frame(width: w, alignment: .leading)
                        .offset(x: rect.minX, y: rect.maxY - 28)
                        .allowsHitTesting(false)
                    // Geste vor dem Verschieben anbringen: g.location zählt dann ab der Bildecke (vorher ab der Ecke des
                    // ganzen Monitors, der Fokuspunkt lag daneben, im Hochformat immer am rechten Rand)
                    Color.clear.contentShape(Rectangle()).frame(width: w, height: h)
                        .pointerStyle(.rowResize)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            if abs(g.translation.height) > 3 || abs(g.translation.width) > 3 {
                                liveScale = min(8, max(0.1, current * exp(-Double(g.translation.height) / 200)))
                            }
                        }.onEnded { g in
                            let moved = abs(g.translation.height) > 3 || abs(g.translation.width) > 3
                            if moved, let value = liveScale {
                                Task { await model.run("clip.key", ["id": .string(target.id), "at": .int(model.playhead), "value": .double(value)]) }
                            } else {
                                // Klick ohne Ziehen: Fokuspunkt an diese Stelle
                                let ax = min(1, max(0, (g.location.x) / w)), ay = min(1, max(0, (g.location.y) / h))
                                Task { await model.run("clip.update", ["id": .string(target.id), "anchor": .array([.double(ax), .double(ay)])]) }
                            }
                            liveScale = nil
                        })
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .onHover { hover.inside = $0 }
        }
    }

    /// Mausrad ±5 % je Raste; 350 ms nach der letzten Raste wird der Keyframe gesetzt. Nur über dem Monitor und nur
    /// mit dem Werkzeug Skalieren; der Wächter fragt beides bei jedem Ereignis neu ab (vorher hing er am Hover des
    /// Ziels: Wechselte das Werkzeug, während die Maus über dem Monitor stand, schluckte er danach jedes Scrollen).
    private func installWheel() {
        removeWheel()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard hover.inside, e.scrollingDeltaY != 0, model.source == nil, let target = scaleTarget else { return e }
            let base = wheelScale ?? target.scaleAt(target.mediaAt(model.playhead - target.start))
            // je Raste 5 %, auf dem Trackpad stufenlos im selben Maß
            let step = e.hasPreciseScrollingDeltas ? pow(1.05, Double(e.scrollingDeltaY) / 12) : e.scrollingDeltaY > 0 ? 1.05 : 1 / 1.05
            wheelScale = min(8, max(0.1, base * step))
            wheelTask?.cancel()
            wheelTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let value = wheelScale else { return }
                await model.run("clip.key", ["id": .string(target.id), "at": .int(model.playhead), "value": .double(value)])
                wheelScale = nil
            }
            return nil
        }
    }

    private func removeWheel() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    // MARK: Quelle

    private func startSource() {
        player?.pause()
        player = nil
        guard let r = model.source, StudioMaterial.isVideo(r) || StudioMaterial.isAudio(r) else { return }
        let p = AVPlayer(url: AssetStore.shared.fileURL(r.filename))
        player = p
        p.play()
    }

    /// Quelle wie in Monitor.tsx: das Material selbst (Video und Ton spielen sofort, mit Bedienleiste), Angaben und
    /// „Zurück zum Schnitt“ stehen in der Unterleiste.
    @ViewBuilder private func sourceView(_ r: AssetRecord) -> some View {
        ZStack {
            Color.black
            if StudioMaterial.isVideo(r), let player {
                VideoPlayer(player: player)
            } else if StudioMaterial.isAudio(r), let player {
                VStack {
                    Text("♪").font(.system(size: 48)).foregroundStyle(.secondary)
                    VideoPlayer(player: player).frame(height: 44)
                }
                .padding(.horizontal, 24)
            } else if let img = NSImage(contentsOf: AssetStore.shared.fileURL(r.filename)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            }
        }
    }

    /// „5,0 s · 1920×1088“ wie assetFacts unter Windows.
    private func facts(_ r: AssetRecord) -> String {
        let m = model.project?.media[r.id] ?? StudioMediaCache.shared.get(r.id)
        var parts: [String] = []
        if let d = m?.duration, !(m?.kind == "image") { parts.append(formatSeconds(d, digits: 1) + " s") }
        if let w = m?.width ?? r.meta["width"]?.intValue, let h = m?.height ?? r.meta["height"]?.intValue { parts.append("\(w)×\(h)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Unterleiste

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let r = model.source {
                Text(t("Quelle", "Source").uppercased()).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.black)
                Text(verbatim: StudioMaterial.label(r)).font(.callout).lineLimit(1).truncationMode(.tail).help(StudioMaterial.label(r))
                Text(verbatim: facts(r)).font(.caption).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Button(t("Zurück zum Schnitt", "Back to the edit")) { model.leaveSource() }.help("Esc").fixedSize()
            } else if let p = model.project {
                Text(timecode(model.playhead, p) + " / " + timecode(p.editDuration, p)).font(.system(.callout, design: .monospaced))
                if p.clips.isEmpty {
                    Text(t("Der Schnitt ist leer: Szenen übernehmen oder Material auf eine Spur ziehen.",
                           "The edit is empty: conform scenes or drag media onto a track.")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "\(p.settings.width) × \(p.settings.height) · \(fpsText(p)) fps").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func fpsText(_ p: StudioProject) -> String {
        let fps = Double(p.settings.fps[0]) / Double(p.settings.fps[1])
        return fps == fps.rounded() ? String(Int(fps)) : formatDecimal(fps, digits: 3)
    }

    /// HH:MM:SS:FF wie unter Windows.
    private func timecode(_ ticks: Int, _ p: StudioProject) -> String {
        let frames = Int((Double(ticks) / Double(p.frameTicks)).rounded(.down))
        let fps = max(1, Int((Double(p.settings.fps[0]) / Double(p.settings.fps[1])).rounded()))
        let s = frames / fps
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, frames % fps)
    }
}
