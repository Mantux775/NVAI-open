import SwiftUI

/// Erster Start (seit Mac 1.0, Konzept „NVAI im Fluss“, Bildschirm A; wie flow/Welcome.tsx unter Windows): erst die
/// Absicht, dann genau die Modelle dafür, mit Größe, Lizenz und Ladezeit. Der Klick auf „Laden und loslegen“ ist die
/// Rückfrage vor dem Download. Vorher stand oben nur das Studio, und unter „Modelle“ begann die Liste mit allen Einträgen.
/// Gewählt wird, was dieser Mac kann: FLUX.2 Klein in der Fassung für seinen Speicher, das Videomodell nach
/// Arbeitsspeicher, Stable Audio 3, zum Restaurieren SeedVR2 und Qwen3.5.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("flow.welcome.intent") private var intent = "video"
    @State private var busy = false
    @State private var error: String?

    private struct Need: Identifiable {
        let model: FlowModel
        let role: String
        var id: String { model.id }
    }

    private struct Intent: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private var intents: [Intent] {
        let minutes = Int((AudioCatalog.maxSeconds / 60).rounded())
        return [
            Intent(id: "video", title: t("Ein Video mit Ton", "A video with sound"),
                   text: t("Assistent, sieben kurze Schritte", "Assistant, seven short steps")),
            Intent(id: "image", title: t("Ein Bild", "An image"), text: t("Figur, Objekt, Plakat, Schrift", "Character, object, poster, lettering")),
            Intent(id: "audio", title: t("Musik oder Geräusch", "Music or a sound"),
                   text: minutes <= 1 ? t("bis 1 Minute", "up to 1 minute") : t("bis \(minutes) Minuten", "up to \(minutes) minutes")),
            Intent(id: "photo", title: t("Ein altes Foto", "An old photo"), text: t("Schäden weg, Farbe, schärfen", "Remove damage, add color, sharpen")),
        ]
    }

    private func model(_ id: String) -> FlowModel? { state.flowModels.first { $0.id == id } }

    /// Genau die Modelle für die Absicht, in der Fassung für diesen Mac
    private var needs: [Need] {
        let video = VideoCatalog.recommended
        let picks: [(String, String)]
        switch intent {
        case "image":
            picks = [(ModelCatalog.recommended.id, t("Bilder", "Images"))]
        case "audio":
            picks = [(AudioCatalog.id, t("Musik und Geräusche", "Music and sounds"))]
        case "photo":
            picks = [(ModelCatalog.recommended.id, t("Schäden entfernen, einfärben", "Remove damage, colorize")),
                     (HelperModel.sharpen.id, t("Schärfen", "Sharpen")),
                     (HelperModel.vision.id, t("Art der Schäden erkennen", "Tell the kind of damage"))]
        default:
            picks = [(video.id, video.hasAudio ? t("Video mit Ton", "Video with sound") : t("Video", "Video")),
                     (ModelCatalog.recommended.id, t("Startbilder", "Start images")),
                     (AudioCatalog.id, t("Musik", "Music"))]
        }
        return picks.compactMap { id, role in model(id).map { Need(model: $0, role: role) } }
    }

    private func download(_ id: String) -> JobRecord? { state.jobs.first { $0.downloadModelID == id && !$0.isFinished } }

    private var deviceLine: String {
        let cores = HardwareCatalog.gpuCores.map { t(", \($0) GPU-Kerne", ", \($0) GPU cores") } ?? ""
        let mac = t("Dein Mac: \(SystemInfo.chip)\(cores), \(SystemInfo.memoryGB) GB.", "Your Mac: \(SystemInfo.chip)\(cores), \(SystemInfo.memoryGB) GB.")
        return state.anyMakerInstalled ? mac : mac + " " + t("Noch ist kein Modell geladen.", "No model is downloaded yet.")
    }

    var body: some View {
        let list = needs
        let missing = list.filter { !$0.model.installed }
        let loadable = missing.filter { !$0.model.tokenMissing && download($0.id) == nil }
        let gb = missing.reduce(0.0) { $0 + $1.model.sizeGB }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Willkommen bei NVAI-open", "Welcome to NVAI-open")).font(.title3.weight(.semibold))
                    Text(deviceLine).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UserDefaults.standard.set(true, forKey: AppState.welcomeDismissedKey)
                    state.forceWelcome = false
                    state.updateWelcome()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(t("Nicht mehr zeigen; Modelle gibt es unter „Modelle“", "Do not show again; models are under \"Models\""))
            }
            FlowLabel(text: t("Womit möchtest du anfangen?", "What would you like to start with?"))
            HStack(spacing: 8) {
                ForEach(intents) { i in
                    Button { intent = i.id } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(i.title).fontWeight(.semibold)
                            Text(i.text).font(.caption).foregroundStyle(.secondary)
                            if i.id == "video" { FlowChip(text: t("empfohlen", "recommended"), tone: .ok) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                        .padding(10)
                        .background(Color.secondary.opacity(intent == i.id ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(intent == i.id ? Color.green : Color.secondary.opacity(0.25),
                                                                         lineWidth: intent == i.id ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(intent == i.id ? .isSelected : [])
                }
            }
            FlowLabel(text: t("Dafür brauchst du", "For this you need"))
            VStack(spacing: 5) {
                ForEach(list) { n in
                    HStack {
                        (Text(n.model.short).bold() + Text(" · \(n.role) ")
                         + Text("· " + (n.model.tokenMissing
                                        ? t("Hugging-Face-Konto und Lizenz nötig, Token unter „Einstellungen“",
                                            "Hugging Face account and license needed, token under \"Settings\"")
                                        : n.model.licenseLine)).foregroundColor(.secondary))
                            .lineLimit(2)
                            .help(n.model.warning)
                        Spacer(minLength: 8)
                        if n.model.installed {
                            Text("✓ " + t("geladen", "downloaded")).foregroundStyle(.green)
                        } else if let d = download(n.id) {
                            Text(d.status == "queued" ? t("wartet", "queued") : "\(Int((d.progress * 100).rounded())) %").monospacedDigit()
                        } else {
                            Text(FlowFormat.gb(n.model.sizeGB)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.2)))
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text(summary(missing: missing.count, loadable: loadable.count, gb: gb))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(t("Selbst auswählen (\(state.flowModels.count))", "Choose yourself (\(state.flowModels.count))")) {
                    state.selectedTab = "models"
                }
                Button(missing.isEmpty || loadable.isEmpty ? t("Loslegen", "Start") : t("Laden und loslegen", "Download and start")) {
                    Task { await go(loadable.map(\.id)) }
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(busy)
                .keyboardShortcut(.defaultAction)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.45)))
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func summary(missing: Int, loadable: Int, gb: Double) -> String {
        if missing == 0 { return t("Alles da, es kann losgehen.", "Everything is there, you can start.") }
        let time = FlowFormat.span(FlowFormat.downloadSeconds(gb))
        var text = intent == "video"
            ? t("Zusammen \(FlowFormat.gb(gb)), bei 100 MBit/s rund \(time). Lädt im Hintergrund, der Assistent beginnt schon.",
                "\(FlowFormat.gb(gb)) in total, about \(time) at 100 Mbit/s. Downloads in the background, the assistant starts right away.")
            : intent == "photo"
            ? t("Zusammen \(FlowFormat.gb(gb)), bei 100 MBit/s rund \(time). Lädt im Hintergrund, du kannst schon das Foto wählen.",
                "\(FlowFormat.gb(gb)) in total, about \(time) at 100 Mbit/s. Downloads in the background, you can already pick the photo.")
            : t("Zusammen \(FlowFormat.gb(gb)), bei 100 MBit/s rund \(time). Lädt im Hintergrund, du kannst schon den Prompt schreiben.",
                "\(FlowFormat.gb(gb)) in total, about \(time) at 100 Mbit/s. Downloads in the background, you can already write the prompt.")
        if needs.contains(where: { $0.model.tokenMissing }) {
            text += " " + t("Gesperrte Modelle lädst du nach dem Token unter „Modelle“.", "Gated models: store the token, then download them under \"Models\".")
        }
        return text
    }

    /// Laden (der Server lädt nacheinander, der Fortschritt steht hier und in der Auftragsleiste), dann in den passenden
    /// Reiter: Ein Video beginnt mit dem Assistenten
    private func go(_ ids: [String]) async {
        busy = true
        error = nil
        defer { busy = false }
        for id in ids {
            if await FlowCatalog.download(id) == nil {
                error = t("Unbekanntes Modell: \(id)", "Unknown model: \(id)")
                return
            }
        }
        await state.refresh()
        state.welcomeHiddenThisSession = true
        state.forceWelcome = false
        state.updateWelcome()
        switch intent {
        case "image": state.focusGenerate("image")
        case "audio": state.focusGenerate("audio")
        case "photo": state.focusGenerate("restore")
        default:
            state.selectedTab = "studio"
            StudioModel.shared.wizardRequest += 1
        }
    }
}
