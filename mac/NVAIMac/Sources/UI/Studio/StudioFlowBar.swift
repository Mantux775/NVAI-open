import SwiftUI

/// Konzept „NVAI im Fluss“, Bildschirm D (seit Mac 1.0, wie flow/studio/FlowBar.tsx unter Windows): oben im Studio eine
/// Leiste mit den Schritten Idee · Szenen · Startbilder · Videos · Schnitt · Export, daneben ein Knopf für den nächsten
/// Schritt samt Zeit, darunter die Szenen als Karten mit ihrem Zustand (zusammenklappbar). Vorher standen „Szenen
/// erzeugen“, „Übernehmen“, „Assistent“, Marker und Export gleichrangig nebeneinander; die Knöpfe oben bleiben.
///
/// Karten (Nutzer 26.11.2026: „wenn ich eine scene einfüge soll ich es auch mit rechtsklick entfernen oder mit x icon
/// rechts oben (bei mouse over) löschen, genau so für andere elemente, dann via drag and drop schieben“): × beim
/// Überfahren löscht, Rechtsklick zeigt „Entfernen“ und Schieben, Ziehen ordnet innerhalb der Bahn um (ein Rückgängig).
/// Winkel der Klappknöpfe (Leiste hinter „Exportieren“ und ihre Kartenreihe). Die Knöpfe sind umrandet wie „Exportieren“
/// und genauso hoch, der Pfeil doppelt so groß wie vorher (Nutzer 26.11.2026: „kaum zu sehen, umrande den wie einen
/// Button (gleiche höhe wie export) und mach den pfeil doppelt so gross, auch bei der Kartenleiste“), als Winkel statt
/// Dreieck („ja winkel nehmen“: ▶ sah eingeklappt aus wie der Abspielknopf). Der Rahmen hält den Winkel eine Textzeile
/// hoch, damit der Knopf nicht höher wird als „Exportieren“.
struct StudioFoldArrow: View {
    let open: Bool

    var body: some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 15, weight: .bold))
            .frame(width: 18, height: 14)
    }
}

struct StudioFlowBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: StudioModel
    @ObservedObject private var flow = FlowJobs.shared
    let project: StudioProject
    /// gewählte Exportvorlage
    let preset: String
    /// Kartenreihe offen; Vorgabe zu (Nutzer 26.11.2026: „standard ausgeklappt (unterelemente zugeklappt)“)
    @AppStorage("studio.flow.cards") private var cardsOpen = false
    @State private var dropTarget: String?

    static let cardWidth: CGFloat = 150
    /// Gezogene Karte (Text statt Asset-ID, damit Material-Ziele sie nicht für ein Asset halten)
    static let dragPrefix = "nvai-scene-card:"

    var body: some View {
        let c = model.flowCtx(project, state.flowModels, jobs: state.jobs)
        let ex = model.exportInfo(preset)
        let next = StudioFlow.nextStep(c, ex)
        let rail = StudioFlow.railSteps(c, ex, next.kind)
        let scenes = StudioFlow.sceneOrder(c.p)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button { cardsOpen.toggle() } label: { StudioFoldArrow(open: cardsOpen) }
                    .buttonStyle(.bordered)
                    .help(cardsOpen ? t("Szenenreihe einklappen", "Collapse the scene row") : t("Szenenreihe zeigen", "Show the scene row"))
                railView(rail, now: next.step)
                nextButton(c, next)
            }
            if cardsOpen || scenes.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(scenes) { s in card(c, s, lane: scenes.filter { $0.lane == s.lane }.map(\.id)) }
                        addCard
                        if scenes.isEmpty {
                            Text(t("oder mit dem Assistenten ein ganzes Video anlegen (Knopf rechts oben)",
                                   "or set up a whole video with the assistant (button at the top right)"))
                                .font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    // MARK: Leiste

    private func railView(_ rail: [StudioFlow.RailStep], now: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(rail.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 1) {
                    Text((r.done && i != now ? "✓ " : "") + r.label).font(.callout.weight(.semibold))
                        .foregroundStyle(i == now || r.done ? Color.primary : Color.secondary)
                    Text(verbatim: r.small).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(i == now ? Color.secondary.opacity(0.14) : r.done ? Color.green.opacity(0.08) : Color.clear)
                .overlay(alignment: .bottom) { if i == now { Rectangle().fill(Color.green).frame(height: 2) } }
                .overlay(alignment: .trailing) { if i < rail.count - 1 { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) } }
                .help("\(r.label): \(r.small). \(r.title)")
                .accessibilityAddTraits(i == now ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Stand des Projekts", "Project progress"))
    }

    /// Zeit des nächsten Schritts: Szenen erzeugen, Startbilder, oder die Restzeit dessen, was gerade rechnet
    private func eta(_ next: StudioFlow.Next, now: Date) -> String {
        switch next.kind {
        case .generate:
            let sum = StudioFlow.sumEstimates(StudioFlow.sceneEstimates(next.scenes, model.estimates, state.flowModels))
            guard let s = sum.seconds else { return "" }
            return sum.unknown > 0 ? FlowFormat.eta(s) + " +" : FlowFormat.eta(s)
        case .start:
            let sum = StudioFlow.sumEstimates(next.scenes.map { model.startEstimates[$0.id] })
            return FlowFormat.eta(sum.seconds)
        case .busy:
            let ids = Set(next.scenes.flatMap(\.jobs) + next.scenes.compactMap { model.startRuns[$0.id]?.job })
            let left = state.jobs.filter { ids.contains($0.id) && FlowJobs.isActive($0) }.compactMap { flow.remaining($0, now: now) }
            return left.max().map { FlowFormat.left($0) } ?? ""
        default:
            return ""
        }
    }

    private func nextButton(_ c: StudioFlow.Ctx, _ next: StudioFlow.Next) -> some View {
        EverySecond(on: next.kind == .busy) { now in
            let time = eta(next, now: now)
            let second = time.isEmpty ? next.note : time
            Button {
                Task { await model.doNext(next, preset: preset) }
            } label: {
                VStack(spacing: 1) {
                    Text(next.label).fontWeight(.semibold).lineLimit(2).multilineTextAlignment(.center)
                    if !second.isEmpty { Text(second).font(.caption).monospacedDigit().opacity(0.8).lineLimit(1) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
            .disabled(next.disabled)
            .frame(width: 250)
            .help(second.isEmpty ? next.label : "\(next.label) · \(second)")
        }
    }

    // MARK: Karten

    private func card(_ c: StudioFlow.Ctx, _ s: StudioScene, lane: [String]) -> some View {
        StudioSceneCard(model: model, project: c.p, scene: s, state: StudioFlow.sceneState(c, s),
                        selected: model.kind == .scene && model.selected.contains(s.id),
                        dropping: dropTarget == s.id,
                        lane: lane,
                        onDelete: { Task { await model.deleteScene(s.id) } },
                        onMove: { to in
                            var ids = lane.filter { $0 != s.id }
                            ids.insert(s.id, at: max(0, min(ids.count, to)))
                            Task { await model.reorder(lane: s.lane, ids: ids) }
                        })
            .draggable(Self.dragPrefix + s.id)
            .dropDestination(for: String.self) { items, location in
                dropTarget = nil
                guard let item = items.first, item.hasPrefix(Self.dragPrefix) else { return false }
                let from = String(item.dropFirst(Self.dragPrefix.count))
                // nur innerhalb derselben Bahn; die Hälfte der Karte entscheidet: davor oder dahinter
                guard from != s.id, lane.contains(from) else { return false }
                var ids = lane.filter { $0 != from }
                let at = (ids.firstIndex(of: s.id) ?? ids.count) + (location.x > Self.cardWidth / 2 ? 1 : 0)
                ids.insert(from, at: min(ids.count, at))
                if ids != lane { Task { await model.reorder(lane: s.lane, ids: ids) } }
                return true
            } isTargeted: { on in
                if on { dropTarget = s.id } else if dropTarget == s.id { dropTarget = nil }
            }
    }

    private var addCard: some View {
        Button {
            Task {
                if let r = await model.run("scene.add", ["lane": .string("video"), "kind": .string("video"), "duration_s": .double(5)]),
                   let id = r["id"]?.stringValue {
                    model.focus(id, field: "prompt")
                }
            }
        } label: {
            Text("+ " + t("Szene", "Scene")).font(.callout.weight(.medium))
                .frame(width: 90, height: 118)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(t("Neue Videoszene hinten an der Bildbahn (5 s)", "New video scene at the end of the picture lane (5 s)"))
    }
}

/// Eine Szene als Karte: Bild (Take, sonst Startbild), Nummer und Titel, Zustand; × beim Überfahren
struct StudioSceneCard: View {
    @ObservedObject var model: StudioModel
    let project: StudioProject
    let scene: StudioScene
    let state: StudioFlow.SceneState
    let selected: Bool
    let dropping: Bool
    let lane: [String]
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    @State private var hover = false

    var body: some View {
        let i = lane.firstIndex(of: scene.id) ?? 0
        VStack(alignment: .leading, spacing: 0) {
            picture
                .frame(width: StudioFlowBar.cardWidth, height: StudioFlowBar.cardWidth * 9 / 16)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(StudioFlow.sceneNum(project, scene.id)) · \(StudioFlow.sceneTitle(scene))")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                FlowChip(text: state.label, tone: state.tone)
            }
            .padding(6)
        }
        .frame(width: StudioFlowBar.cardWidth, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.green : dropping ? Color.accentColor : Color.secondary.opacity(0.25),
                                                         lineWidth: selected || dropping ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(t("Szene löschen (⌘Z holt sie zurück)", "Delete the scene (⌘Z brings it back)"))
                .accessibilityLabel(t("\(StudioFlow.sceneTitle(scene)) löschen", "Delete \(StudioFlow.sceneTitle(scene))"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.focus(scene.id, field: nil) }
        .help("\(StudioFlow.sceneTitle(scene)): \(state.label). "
              + t("Ziehen ordnet innerhalb der Bahn um, Rechtsklick zeigt mehr.", "Drag to reorder within the lane, right-click for more."))
        .contextMenu {
            Button(t("Nach vorn schieben", "Move earlier")) { onMove(i - 1) }.disabled(i <= 0)
            Button(t("Nach hinten schieben", "Move later")) { onMove(i + 1) }.disabled(i >= lane.count - 1)
            Divider()
            Button(scene.take == nil ? t("Erzeugen", "Generate") : t("Neu erzeugen", "Generate again")) {
                Task { await model.generate([scene.id]) }
            }
            .disabled(!scene.jobs.isEmpty || scene.waitingFor != nil)
            Divider()
            Button(t("Entfernen", "Remove"), role: .destructive, action: onDelete)
        }
    }

    /// Bild der Karte: Take, sonst Startbild; Tonszenen ein Notenzeichen
    @ViewBuilder private var picture: some View {
        if scene.lane != "video" {
            ZStack { Color.secondary.opacity(0.12); Text("♪").font(.title2).foregroundStyle(.secondary) }
        } else if let take = scene.take {
            StudioThumb(assetID: take, symbol: scene.kind == "image" ? "photo" : "film")
        } else if let start = scene.params["image_asset_id"]?.stringValue, !start.isEmpty {
            StudioThumb(assetID: start, symbol: "photo")
        } else {
            ZStack {
                LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(t("noch kein Bild", "no picture yet")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
