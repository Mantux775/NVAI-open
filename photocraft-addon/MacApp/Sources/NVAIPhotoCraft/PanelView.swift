import AppKit
import PhotoCraftKit
import SwiftUI

/// Das Panel: Modus, Prompt, Modell, Varianten, Ergebnisse – wie panel/ der Windows-Brücke.
struct PanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Header()
                Notices()
                DocumentCard()
                Picker(t("Modus", "Mode"), selection: $model.form.mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.modeHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.modelHints, id: \.self) { hint in
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PromptEditor(text: $model.form.prompt, placeholder: model.promptPlaceholder)
                HStack(alignment: .firstTextBaseline) {
                    Text(model.promptTip).lineLimit(2).help(model.promptTip)
                    Spacer()
                    Text(wordCount)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ExpandRow()
                DownloadsRow()
                ModelRow()
                if model.form.mode == .extend { ExtendFields() }
                if model.showsStrength { StrengthSlider(value: $model.form.strength) }
                DisclosureGroup(t("Erweitert", "Advanced"), isExpanded: $model.form.advanced) {
                    AdvancedFields().padding(.top, 6)
                }
                GoButton()
                TaskProgress()
                MessageBox()
                if let item = model.shown { ResultsSection(item: item) }
                HistorySection()
                Footer()
            }
            .padding(16)
        }
        .frame(minWidth: 340, idealWidth: 390, minHeight: 560)
        .background(WindowLevel(floating: model.form.alwaysOnTop))
        .onChange(of: model.form) { _, form in form.save() }
    }

    private var wordCount: String {
        let words = model.form.prompt.split(whereSeparator: \.isWhitespace).count
        if words == 0 { return "" }
        return words == 1 ? t("1 Wort", "1 word") : t("\(words) Wörter", "\(words) words")
    }
}

// MARK: - Kopf und Status

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.title3).foregroundStyle(Color.accentColor)
            Text(verbatim: "NV-AI").font(.headline)
            Text(t("für PhotoCraft", "for PhotoCraft")).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            StatusPill(title: "PhotoCraft", color: pcColor, help: pcHelp) { model.focusPhotoCraft() }
            StatusPill(title: "NV-AI", color: nvColor, help: nvHelp)
            Toggle(isOn: $model.form.alwaysOnTop) {
                Image(systemName: model.form.alwaysOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(t("Fenster im Vordergrund halten", "Keep window on top"))
        }
    }

    private var pcColor: Color { model.pc.connected ? .green : .red }

    private var pcHelp: String {
        guard model.pc.connected else { return model.pc.error ?? t("PhotoCraft nicht verbunden", "PhotoCraft not connected") }
        let n = model.pc.documents
        return t("PhotoCraft verbunden · \(n) Dokument\(n == 1 ? "" : "e") offen. Klick holt PhotoCraft nach vorn.",
                 "PhotoCraft connected · \(n) document\(n == 1 ? "" : "s") open. Click to bring PhotoCraft to the front.")
    }

    private var nvColor: Color {
        if !model.nv.usable { return .red }
        return model.nv.busy || model.isRunning ? .orange : .green
    }

    private var nvHelp: String {
        let nv = model.nv
        if let problem = nv.problem { return problem }
        guard nv.connected else { return nv.error ?? t("NV-AI nicht erreichbar", "NV-AI not reachable") }
        let names = nv.loaded.joined(separator: ", ")
        let loaded = nv.loaded.isEmpty ? t("Kein Modell im VRAM", "No model in VRAM") : t("Geladen: \(names)", "Loaded: \(names)")
        return [nv.busy || model.isRunning ? t("NV-AI rechnet gerade", "NV-AI is busy") : t("NV-AI bereit", "NV-AI ready"),
                nv.version.map { "Version \($0)" }, loaded, nv.gpu, nv.masks ? nil : t("ohne Masken-Unterstützung", "without mask support")]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color
    let help: String
    var action: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .contentShape(Capsule())
        Group {
            if let action {
                Button(action: action) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        .help(help)
    }
}

// MARK: - Hinweise

private struct Notices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.checked {
            VStack(alignment: .leading, spacing: 8) {
                if !model.pc.connected { photocraftNotice }
                if model.pc.outdated, let version = model.pc.version {
                    let tested = PhotoCraftLaunch.testedVersion
                    NoticeBox(text: t("PhotoCraft \(version) ist älter als \(tested). Mit dieser Version ist NV-AI für PhotoCraft nicht getestet – bitte aktualisieren.",
                                      "PhotoCraft \(version) is older than \(tested). NV-AI for PhotoCraft is not tested with this version – please update.")) {
                        Button(t("PhotoCraft herunterladen", "Download PhotoCraft")) { model.openPhotoCraftDownload() }
                    }
                }
                if model.starting == "nvai" && !model.nv.connected {
                    NoticeBox(text: t("NV-AI startet … Beim ersten Start kann das etwas dauern.", "NV-AI is starting … The first start can take a while."))
                } else if model.nvaiStartable {
                    // NV-AI für Mac ist installiert: ein Klick genügt, Adresse und Token braucht es nicht.
                    NoticeBox(text: t("NV-AI läuft nicht.", "NV-AI is not running.")) {
                        Button(t("NV-AI starten", "Start NV-AI")) { model.startNVAI() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.starting.isEmpty)
                    }
                } else if !model.nv.usable {
                    SetupCard()
                } else if model.noModels {
                    NoticeBox(text: t("In NV-AI ist noch kein Bildmodell installiert. Bitte dort eines laden – danach geht es hier von selbst weiter.",
                                      "No image model is installed in NV-AI yet. Please load one there – everything continues here by itself afterwards.")) {
                        Button(t("NV-AI öffnen", "Open NV-AI")) { model.openNVAI() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if !model.nv.masks && model.form.mode == .fill {
                    NoticeBox(text: t("Die laufende NV-AI-Version kennt noch keine Masken. Für „Füllen“ NV-AI bitte neu starten, damit die Erweiterung geladen wird.",
                                      "The running NV-AI version does not know masks yet. For \"Fill\", please restart NV-AI so the extension gets loaded."))
                }
                if model.pc.connected && model.pc.dialogOpen {
                    NoticeBox(text: t("In PhotoCraft ist ein Dialog offen. Bitte erst schließen.", "A dialog is open in PhotoCraft. Please close it first."))
                }
            }
        }
    }

    @ViewBuilder private var photocraftNotice: some View {
        let label = model.starting == "photocraft" ? t("Startet …", "Starting …") : t("PhotoCraft mit NV-AI starten", "Start PhotoCraft with NV-AI")
        let tested = PhotoCraftLaunch.testedVersion
        if !model.pc.installed && !model.pc.uncontrolledRunning {
            NoticeBox(text: t("PhotoCraft ist nicht installiert. NV-AI für PhotoCraft braucht PhotoCraft \(tested) oder neuer.",
                              "PhotoCraft is not installed. NV-AI for PhotoCraft needs PhotoCraft \(tested) or newer."),
                      detail: t("Auf der Download-Seite unter „Assets“ die Datei …-macos-universal.dmg laden und PhotoCraft in den Ordner „Programme“ ziehen. Danach geht es hier von selbst weiter.",
                                "On the download page, get the file …-macos-universal.dmg under \"Assets\" and drag PhotoCraft into the Applications folder. Everything continues here by itself afterwards.")) {
                Button(t("PhotoCraft herunterladen", "Download PhotoCraft")) { model.openPhotoCraftDownload() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.pc.uncontrolledRunning {
            NoticeBox(text: t("PhotoCraft läuft ohne NV-AI-Anbindung. Bitte dort speichern und schließen – dann hier neu starten.",
                              "PhotoCraft is running without the NV-AI connection. Please save and close it there – then start it again here.")) {
                Button(label) { model.startPhotoCraft(force: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.starting.isEmpty)
                Button(t("Zusätzlich starten", "Start another one")) { model.startPhotoCraft(force: true) }
                    .disabled(!model.starting.isEmpty)
            }
        } else {
            NoticeBox(text: t("PhotoCraft ist nicht mit NV-AI verbunden.", "PhotoCraft is not connected to NV-AI.")) {
                Button(label) { model.startPhotoCraft(force: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.starting.isEmpty)
            }
        }
    }
}

struct NoticeBox<Buttons: View>: View {
    let text: String
    var detail: String? = nil
    let buttons: Buttons
    let hasButtons: Bool

    init(text: String, detail: String? = nil, @ViewBuilder buttons: () -> Buttons) {
        self.text = text
        self.detail = detail
        self.buttons = buttons()
        hasButtons = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if hasButtons {
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

extension NoticeBox where Buttons == EmptyView {
    init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
        buttons = EmptyView()
        hasButtons = false
    }
}

/// Einrichtung, wenn NV-AI nicht erreichbar ist oder den Zugriff ablehnt: Adresse, Token, „Verbindung prüfen“.
private struct SetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var result: ProbeResult?
    @State private var checking = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t("NV-AI verbinden", "Connect NV-AI"), systemImage: "network").font(.headline)
            Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(t("Normalerweise läuft „NV-AI für Mac“ auf diesem Mac unter http://127.0.0.1:8100 – dann genügt es, die App zu öffnen. Sie liegt mit dieser App zusammen in der DMG. Für eine NV-AI auf einem anderen Rechner hier deren Adresse und Token eintragen.",
                   "Normally \"NV-AI for Mac\" runs on this Mac at http://127.0.0.1:8100 – then it is enough to open that app. It comes in the same DMG as this app. For an NV-AI on another computer, enter its address and token here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(t("Adresse", "Address"), text: $draft.nvaiURL, prompt: Text(verbatim: "http://127.0.0.1:8100"))
                .textFieldStyle(.roundedBorder)
            SecureField("Token", text: $draft.nvaiToken,
                        prompt: Text(t("nur für NV-AI auf einem anderen Rechner", "only for NV-AI on another computer")))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(checking ? t("Prüft …", "Checking …") : t("Verbindung prüfen", "Check connection")) { Task { await check() } }
                    .disabled(checking)
                Button(t("Übernehmen", "Apply")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == model.settings)
                Spacer()
            }
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
        .onAppear {
            if !loaded {
                draft = model.settings
                loaded = true
            }
        }
    }

    private var status: String {
        if let problem = model.nv.problem { return problem }
        let url = model.settings.nvaiURL
        if !model.settings.isLocal { return t("NV-AI unter \(url) ist nicht erreichbar.", "NV-AI at \(url) is not reachable.") }
        return model.nvaiApp == nil
            ? t("NV-AI läuft auf diesem Mac nicht, und „NV-AI für Mac“ ist nicht installiert.",
                "NV-AI is not running on this Mac, and \"NV-AI for Mac\" is not installed.")
            : t("NV-AI läuft auf diesem Mac nicht (\(url)).", "NV-AI is not running on this Mac (\(url)).")
    }

    private func check() async {
        checking = true
        result = await model.probe(draft)
        checking = false
    }

    private func save() {
        do {
            try model.apply(draft)
            result = nil
        } catch {
            result = ProbeResult(ok: false, message: error.localizedDescription)
        }
    }
}

// MARK: - Dokument und Eingaben

private struct DocumentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                meta.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var name: String {
        model.pc.document?.name ?? (model.pc.connected ? t("Kein Dokument geöffnet", "No document open")
                                    : t("PhotoCraft nicht verbunden", "PhotoCraft not connected"))
    }

    private var meta: Text {
        guard let doc = model.pc.document else { return Text(verbatim: "–") }
        if let sel = doc.selection {
            return Text(doc.meta + " · ") + Text(t("Auswahl \(sel.w) × \(sel.h)", "Selection \(sel.w) × \(sel.h)")).foregroundStyle(Color.accentColor)
        }
        return Text(doc.meta + " · " + t("keine Auswahl", "no selection"))
    }
}

private struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 84, maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Modell", "Model")).font(.caption).foregroundStyle(.secondary)
                Picker(t("Modell", "Model"), selection: $model.selectedModelID) {
                    Text(model.automaticTitle).tag("")
                    ForEach(model.suitableModels) { m in
                        Text(m.name + (m.commercialOK == false ? t(" – nicht kommerziell", " – non-commercial") : "")).tag(m.id)
                    }
                }
                .labelsHidden()
                .help(model.currentModel.map { [$0.bestFor, $0.warning].filter { !$0.isEmpty }.joined(separator: " – ") } ?? "")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Varianten", "Variants")).font(.caption).foregroundStyle(.secondary)
                Picker(t("Varianten", "Variants"), selection: $model.form.variants) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 128)
            }
        }
    }
}

/// „Arbeitsfläche erweitern (Outpainting)“: Ränder in Pixeln, Schnellwahl, Zielgröße.
private struct ExtendFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t("Neuer Rand in Pixeln", "New border in pixels"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let target = model.extendTarget { Text(target).font(.caption.monospacedDigit()).foregroundStyle(.tint) }
            }
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([t("Links", "Left"), t("Oben", "Top"), t("Rechts", "Right"), t("Unten", "Bottom")][i])
                            .font(.caption2).foregroundStyle(.secondary)
                        TextField("0", value: $model.extend[i], format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack(spacing: 6) {
                Button(t("↔ breiter", "↔ wider")) { model.extend = [256, 0, 256, 0] }
                Button(t("↕ höher", "↕ taller")) { model.extend = [0, 256, 0, 256] }
                Button(t("↓ nach unten", "↓ downwards")) { model.extend = [0, 0, 0, 384] }
                Button(t("rundum", "all around")) { model.extend = [128, 128, 128, 128] }
            }
            .controlSize(.small)
            if let warning = model.extendWarning {
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StrengthSlider: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(t("Stärke", "Strength")).foregroundStyle(.secondary)
                Text(String(format: "%.2f", value)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: $value, in: 0.1...0.95, step: 0.05)
            HStack {
                Text(t("behutsam", "subtle"))
                Spacer()
                Text(t("deutlich", "clear"))
                Spacer()
                Text(t("fast neu", "almost new"))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct AdvancedFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Negativ-Prompt", "Negative prompt")).font(.caption).foregroundStyle(.secondary)
                TextField(t("Negativ-Prompt", "Negative prompt"), text: $model.form.negative,
                          prompt: Text(model.negativeWorks
                                       ? t("Was vermieden werden soll – leer = Standard des Modells", "What to avoid – empty = the model's default")
                                       : t("Wirkt bei diesem Modell nicht – Ausschlüsse positiv im Prompt formulieren",
                                           "Has no effect with this model – phrase exclusions positively in the prompt")),
                          axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.negativeWorks)
            }
            HStack(spacing: 8) {
                SmallField(label: t("Schritte", "Steps"), text: $model.form.steps, prompt: t("Standard", "default"))
                SmallField(label: "CFG", text: $model.form.cfg, prompt: t("Standard", "default"))
                SmallField(label: "Seed", text: $model.form.seed, prompt: t("zufällig", "random"))
            }
            if model.form.mode == .fill {
                VStack(alignment: .leading, spacing: 2) {
                    let percent = Int((model.form.margin * 100).rounded())
                    Text(t("Kontext um die Auswahl \(percent) %", "Context around the selection \(percent)%"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.form.margin, in: 0.1...1.0, step: 0.05)
                }
            }
            Toggle(t("Native Auflösung des Modells (mehr Detail, etwa doppelte Zeit)",
                     "Native model resolution (more detail, about twice the time)"), isOn: $model.form.native)
            Toggle(t("Hires-Durchgang (feinere Details, etwa 50 % länger)", "Hires pass (finer details, about 50% longer)"),
                   isOn: $model.form.hires)
                .disabled(!model.hiresWorks)
                .help(model.hiresWorks ? "" : t("Bei diesem Modell gibt es keinen zweiten Durchgang – stattdessen „Native Auflösung“",
                                                "This model has no second pass – use \"Native model resolution\" instead"))
            Toggle(t("Erste Variante sofort in PhotoCraft einfügen", "Place the first variant in PhotoCraft right away"),
                   isOn: $model.form.autoPlace)
        }
        .font(.callout)
    }
}

private struct SmallField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Auftrag

/// Laufende Modell-Downloads von NV-AI, je mit Abbrechen.
private struct DownloadsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.nv.connected && !model.nv.downloads.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.nv.downloads, id: \.job) { d in
                    HStack(spacing: 8) {
                        Text(t("NV-AI lädt \(d.name)", "NV-AI downloading \(d.name)"))
                            .lineLimit(1).truncationMode(.middle)
                        ProgressView(value: d.running ? d.progress : 0).frame(minWidth: 40)
                        Text(d.running ? "\(Int((d.progress * 100).rounded())) %" : t("wartet", "queued"))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                        Button { model.cancelDownload(d.job) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help(t("Download abbrechen (fertige Teile bleiben zum Fortsetzen)",
                                    "Cancel download (finished parts stay to resume)"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(d.stage)
                }
            }
        }
    }
}

/// „✨ Prompt ausbauen“ mit Zurücknehmen – nur, wenn NV-AI es kann (ab 0.4).
private struct ExpandRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.nv.usable && model.nv.expand {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button { model.expandPrompt() } label: {
                        Text(model.expanding ? t("Baut aus …", "Expanding …") : t("✨ Prompt ausbauen", "✨ Expand prompt"))
                    }
                    .disabled(!model.canExpand)
                    .help(t("Schreibt aus ein paar Worten eine volle Bildbeschreibung. Danach lesen und Erfundenes streichen.",
                            "Turns a few words into a full image description. Read it afterwards and delete what was invented."))
                    if model.expanding { ProgressView().controlSize(.small) }
                    if model.promptBeforeExpand != nil, !model.expanding {
                        Button(t("Zurück zum eigenen Prompt", "Back to my prompt")) { model.undoExpand() }
                    }
                    Spacer()
                }
                if let info = model.expandInfo {
                    Text(info).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GoButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            Button { model.generate() } label: {
                HStack {
                    Spacer()
                    Text(model.isRunning ? t("Läuft …", "Running …") : model.goLabel).fontWeight(.semibold)
                    Text("⌘↩").font(.caption).opacity(0.7)
                    Spacer()
                }
                .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.blocker != nil)
            if model.checked, !model.isRunning, let why = model.blocker {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TaskProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.current, item.status == .running {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.progress)
                HStack(alignment: .firstTextBaseline) {
                    Text(item.stage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button(t("Abbrechen", "Cancel")) { model.cancel() }
                        .buttonStyle(.link)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

private struct MessageBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let texts = [model.message, model.shown?.error].compactMap { $0 }
        ForEach(texts, id: \.self) { text in
            Label(text, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
        }
    }
}

// MARK: - Ergebnisse und Verlauf

private struct ResultsSection: View {
    @Environment(AppModel.self) private var model
    let item: TaskItem
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        if !item.images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t("Ergebnis", "Result")).font(.headline)
                    Spacer()
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let warning = item.task.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(item.images.enumerated()), id: \.offset) { k, image in
                        VariantTile(image: image, number: k + 1, placed: item.placedVariant == k,
                                    disabled: model.placing || model.isRunning,
                                    choose: { model.place(item, variant: k, replace: true) },
                                    add: { model.place(item, variant: k, replace: false) })
                    }
                }
                if let caption = item.task.variants.compactMap(\.caption).first {
                    DisclosureGroup(t("Bildbeschreibung des Upsamplers", "Image description by the upsampler")) {
                        Text(caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                Text(t("Klick auf eine Variante tauscht sie in PhotoCraft aus · + legt sie zusätzlich als Ebene an.",
                       "Click a variant to swap it in PhotoCraft · + adds it as an extra layer."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meta: String {
        var parts = [item.task.modelName]
        if let w = item.task.working { parts.append("\(w.0) × \(w.1)") }
        if let d = item.duration { parts.append(d) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct VariantTile: View {
    let image: NSImage
    let number: Int
    let placed: Bool
    let disabled: Bool
    let choose: () -> Void
    let add: () -> Void

    var body: some View {
        Button(action: choose) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 170)
                .background(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(placed ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: placed ? 2.5 : 1))
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(4)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(placed ? t("In PhotoCraft eingefügt", "Placed in PhotoCraft") : t("In PhotoCraft austauschen", "Swap into PhotoCraft"))
        .overlay(alignment: .topTrailing) {
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.caption.bold())
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .disabled(disabled)
            .help(t("Zusätzlich als Ebene einfügen", "Also add as a layer"))
        }
    }
}

private struct HistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.history.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Verlauf", "History")).font(.headline)
                ForEach(model.history) { item in
                    Button { model.shown = item } label: {
                        HistoryRow(item: item, selected: item === model.shown)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: TaskItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [item.mode.label, item.created.formatted(date: .omitted, time: .shortened)]
        if !item.task.variants.isEmpty { parts.append(t("\(item.task.variants.count) Var.", "\(item.task.variants.count) var.")) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch item.status {
        case .running: return "hourglass"
        case .done: return "checkmark.circle"
        case .error: return "xmark.octagon"
        case .cancelled: return "stop.circle"
        }
    }

    private var color: Color {
        switch item.status {
        case .running: return .orange
        case .done: return .green
        case .error: return .red
        case .cancelled: return .secondary
        }
    }
}

private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            SettingsLink { Text(t("Einstellungen …", "Settings …")) }
                .buttonStyle(.link)
            Spacer()
            Text(["App \(model.version)", model.nv.version.map { "NV-AI \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

// MARK: - Fenster

/// Hält das Panel über PhotoCraft (`NSWindow.Level.floating`), wenn gewünscht.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> LevelView {
        let view = LevelView()
        view.floating = floating
        return view
    }

    func updateNSView(_ view: LevelView, context: Context) {
        view.floating = floating
    }

    final class LevelView: NSView {
        var floating = true { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.level = floating ? .floating : .normal
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}
