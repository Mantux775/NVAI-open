import AppKit
import Observation
import PhotoCraftKit

/// Zustand und Abläufe des Panels – entspricht bridge/server.py und bridge/tasks.py der Windows-Brücke.
@MainActor
@Observable
final class AppModel {
    static let historyLimit = 20
    /// „NV-AI für Mac“: startet beim Öffnen seinen Server auf 127.0.0.1:8100.
    nonisolated static let nvaiMacBundleID = "com.noerr.nvai.mac"
    /// Für die Fehlersuche (`--snapshot … --run`) aus dem App-Delegate erreichbar.
    static weak var shared: AppModel?

    private(set) var settings: AppSettings
    @ObservationIgnored private(set) var launch: PhotoCraftLaunch
    @ObservationIgnored private var control: ControlClient
    @ObservationIgnored private var workflow: Workflow
    @ObservationIgnored private(set) var nvai: NVAIClient?

    var pc = PhotoCraftState()
    var nv = NVAIState()
    /// `false`, bis der erste Statusabgleich durch ist – vorher keine Fehlermeldungen zeigen.
    var checked = false
    var models: [ModelOption] = []
    var modelsLoaded = false
    var form: FormState
    /// Laufender bzw. zuletzt gestarteter Auftrag; `shown` ist der im Ergebnisbereich gezeigte.
    var current: TaskItem? = nil
    var shown: TaskItem? = nil
    var history: [TaskItem] = []
    /// `photocraft` bzw. `nvai`, während das Programm startet.
    var starting = ""
    var placing = false
    var message: String? = nil
    /// NV-AI für Mac, falls installiert.
    var nvaiApp: URL? = nil
    /// Installiertes PhotoCraft und seine Version. Wie `nvaiApp` alle 5 s neu nachgesehen, damit
    /// eine Installation bei laufender App ohne Neustart greift.
    @ObservationIgnored private var install: (checked: Date, app: URL?, version: String?) = (.distantPast, nil, nil)

    /// NV-AI läuft nicht, soll aber auf diesem Mac laufen, und NV-AI für Mac ist da.
    var nvaiStartable: Bool { !nv.connected && settings.isLocal && nvaiApp != nil }

    init() {
        let settings = AppSettings.load()
        Localization.choice = settings.language
        let launch = PhotoCraftLaunch.standard(port: settings.port)
        let control = ControlClient(port: settings.port, tokenURL: launch.tokenFile)
        self.settings = settings
        self.launch = launch
        self.control = control
        workflow = Workflow(pc: control, exchange: launch.exchange)
        nvai = settings.baseURL.map { NVAIClient(baseURL: $0, token: settings.token) }
        form = FormState.load()
        Log.write("App gestartet – NV-AI \(settings.nvaiURL), PhotoCraft-Port \(settings.port)")
        cleanupOldJobs()
        Self.shared = self
        Task { await poll() }
    }

    /// Fehlersuche: wartet auf PhotoCraft mit Dokument und auf NV-AI, rechnet „Generieren“ mit einer
    /// Variante (schnellstes passendes Modell) und stellt danach die Eingaben des Nutzers wieder her.
    func diagnosticRun(prompt: String) async {
        for _ in 0..<120 where !(pc.document != nil && nv.usable && modelsLoaded) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let saved = form
        form.mode = .generate
        form.prompt = prompt
        form.variants = 1
        form.autoPlace = true
        if let fast = suitableModels.first(where: { $0.workflow == "flux3_klein" }) { selectedModelID = fast.id }
        Log.write("Diagnoselauf: \(blocker ?? "startet")")
        generate()
        while isRunning { try? await Task.sleep(nanoseconds: 500_000_000) }
        Log.write("Diagnoselauf beendet: \(current?.error ?? "ok")")
        form = saved
    }

    /// Fehlersuche: nach dem ersten Abgleich „NV-AI starten“ drücken und abwarten, wie der Start ausgeht.
    func diagnosticStartNVAI() async {
        for _ in 0..<40 where !checked {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard nvaiStartable else {
            Log.write("Diagnose „NV-AI starten“: nicht möglich – verbunden \(nv.connected), lokal \(settings.isLocal), App \(nvaiApp?.path ?? "fehlt")")
            return
        }
        Log.write("Diagnose „NV-AI starten“: Knopf gedrückt")
        let pressed = Date()
        startNVAI()
        while starting == "nvai" { try? await Task.sleep(nanoseconds: 250_000_000) }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(pressed))
        Log.write("Diagnose „NV-AI starten“: \(nv.connected ? "verbunden nach \(seconds) s, NV-AI \(nv.version ?? "?")" : message ?? "nicht verbunden")")
    }

    var isRunning: Bool { current?.status == .running }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    // MARK: Status

    private func poll() async {
        var tick = 0
        while true {
            await refreshPhotoCraft()
            if tick % 2 == 0 { await refreshNVAI() }
            checked = true
            tick += 1
            try? await Task.sleep(nanoseconds: isRunning || placing ? 700_000_000 : 1_500_000_000)
        }
    }

    private func photocraftInstall() -> (app: URL?, version: String?) {
        if Date().timeIntervalSince(install.checked) > 5 {
            let app = PhotoCraftLaunch.installedApp()
            install = (Date(), app, app.flatMap(PhotoCraftLaunch.version(of:)))
            let nvai = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.nvaiMacBundleID)
            if nvaiApp != nvai { nvaiApp = nvai }
        }
        return (install.app, install.version)
    }

    func refreshPhotoCraft() async {
        // Während Erfassen/Einfügen sind kurz Hilfsdokumente aktiv – den letzten Stand zeigen.
        if workflow.busy { return }
        let found = photocraftInstall()
        do {
            let ui = try await control.inspect()
            var s = PhotoCraftState(connected: true)
            s.installed = found.app != nil
            s.version = found.version
            s.documents = ui["session"]?["documents"]?.arrayValue?.count ?? 0
            s.dialogOpen = ui["dialogs"]?.truthy ?? false
            if let doc = ui["document"], !doc.isNull {
                let selection = (doc["hasSelection"]?.truthy ?? false) ? doc["selectionBounds"]?.rectValue : nil
                s.document = DocumentInfo(name: doc["name"]?.stringValue ?? "Unbenannt", width: doc["width"]?.intValue ?? 0,
                                          height: doc["height"]?.intValue ?? 0, colorMode: doc["mode"]?.stringValue ?? "",
                                          depth: doc["depth"]?.intValue ?? 8, selection: selection)
            }
            if pc != s { pc = s }
        } catch {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: PhotoCraftLaunch.bundleIdentifier).isEmpty
            var s = PhotoCraftState(connected: false, error: error.localizedDescription, uncontrolledRunning: running)
            s.installed = found.app != nil
            s.version = found.version
            if pc != s { pc = s }
        }
    }

    func refreshNVAI() async {
        guard let nvai else {
            nv = NVAIState(connected: false, error: t("Die NV-AI-Adresse „\(settings.nvaiURL)“ ist ungültig.",
                                                     "The NV-AI address \"\(settings.nvaiURL)\" is invalid."))
            return
        }
        var s = NVAIState()
        do {
            let health = try await nvai.health()
            s.connected = true
            do {
                s.version = try await nvai.checkCompatible()?.version
            } catch NVAIError.incompatible(let problem) {
                s.problem = problem
                let info = try? await nvai.version()
                s.version = info?.version
                s.authorized = info?.authorized ?? true
            } catch {
                // /api/version kurz nicht lesbar – beim nächsten Abgleich wieder
            }
            s.masks = (try? await nvai.supportsMasks()) ?? false
            s.activeModel = health["active_models"]?["image"]?.stringValue
            s.loaded = (health["vram_loaded"]?.arrayValue ?? []).compactMap { $0["model"]?.stringValue }
            s.busy = health["current_job"]?.truthy ?? false
            s.gpu = health["gpu"]?["name"]?.stringValue.map(Self.gpuName)
        } catch {
            s = NVAIState(connected: false, error: error.localizedDescription)
        }
        if nv != s { nv = s }
        // Ohne Bildmodell (frisch installiertes NV-AI) bei jedem Abgleich nachsehen, ob eins dazukam.
        if nv.usable && (!modelsLoaded || models.isEmpty) { await loadModels() }
        if !nv.usable { modelsLoaded = false }
    }

    /// „cuda:0 NVIDIA GeForce RTX 5060 Ti : cudaMallocAsync“ → „NVIDIA GeForce RTX 5060 Ti“
    static func gpuName(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"^cuda:\d+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*:.*$"#, with: "", options: .regularExpression)
    }

    func loadModels() async {
        guard let nvai else { return }
        do {
            let masks = nv.masks
            models = try await nvai.imageModels().filter { $0["runnable"]?.truthy ?? false }.map { ModelOption($0, masks: masks) }
            modelsLoaded = true
        } catch {
            modelsLoaded = false
        }
    }

    /// „Erneut prüfen“: gemerkte Versionsangaben verwerfen und NV-AI frisch fragen.
    func recheck() {
        nvai?.forget()
        modelsLoaded = false
        Task { await refreshNVAI() }
    }

    // MARK: Modelle und Texte

    var suitableModels: [ModelOption] { models.filter { $0.suits(form.mode) } }

    /// Ohne Wahl nimmt der Ablauf das aktive Modell – oder, wenn es nicht passt, das beste passende.
    var fallbackModel: ModelOption? {
        let list = suitableModels
        return list.first { $0.id == nv.activeModel } ?? list.first { !$0.weakPrompt } ?? list.first
    }

    var selectedModelID: String {
        get {
            let saved = form.models[form.mode.rawValue] ?? ""
            return suitableModels.contains { $0.id == saved } ? saved : ""
        }
        set { form.models[form.mode.rawValue] = newValue }
    }

    var currentModel: ModelOption? { suitableModels.first { $0.id == selectedModelID } ?? fallbackModel }

    /// NV-AI antwortet, hat aber noch kein Bildmodell installiert.
    var noModels: Bool { nv.usable && modelsLoaded && models.isEmpty }

    var automaticTitle: String {
        if models.isEmpty { return noModels ? t("Kein Bildmodell installiert", "No image model installed") : t("Aktives Modell", "Active model") }
        guard let fallback = fallbackModel else {
            return form.mode == .fill && nv.usable && !nv.masks ? t("Füllen braucht Masken-Unterstützung in NV-AI", "Fill needs mask support in NV-AI")
                : t("Kein passendes Modell installiert", "No suitable model installed")
        }
        return fallback.id == nv.activeModel ? t("Aktives Modell (\(fallback.name))", "Active model (\(fallback.name))")
            : t("Automatisch (\(fallback.name))", "Automatic (\(fallback.name))")
    }

    var referenceEdit: Bool { form.mode == .refine && (currentModel?.referenceEdit ?? false) }
    var modeHint: String { referenceEdit ? Mode.editHint : form.mode.hint }

    var promptPlaceholder: String {
        if referenceEdit { return Mode.editPlaceholder }
        if form.mode == .generate, let p = currentModel?.placeholder.nonEmpty { return p }
        return form.mode.placeholder
    }

    var promptTip: String { currentModel?.promptHint.nonEmpty ?? t("Englische Prompts treffen meist genauer.", "Detailed English prompts work best.") }

    var modelHints: [String] {
        var out: [String] = []
        if form.mode == .fill && currentModel?.weakPrompt == true {
            out.append(t("Schnelle Modelle setzen beim Füllen meist nur die Umgebung fort – für neue Objekte das volle Modell wählen.",
                         "Fast models mostly just continue the surroundings when filling – choose the full model for new objects."))
        }
        if let warning = currentModel?.warning.nonEmpty { out.append(warning) }
        return out
    }

    var showsStrength: Bool { form.mode == .refine && !referenceEdit }
    var negativeWorks: Bool { currentModel?.negativePrompt ?? true }
    var hiresWorks: Bool { currentModel?.hires ?? true }

    /// Warum „Los“ gerade nicht geht – oder `nil`.
    var blocker: String? {
        if isRunning { return t("Es läuft bereits ein Auftrag", "A job is already running") }
        if !pc.connected {
            return pc.installed ? t("PhotoCraft ist nicht verbunden", "PhotoCraft is not connected")
                : t("PhotoCraft ist nicht installiert", "PhotoCraft is not installed")
        }
        if pc.document == nil { return t("In PhotoCraft ist kein Dokument geöffnet", "No document is open in PhotoCraft") }
        if !nv.connected { return t("NV-AI ist nicht erreichbar", "NV-AI is not reachable") }
        if nv.problem != nil {
            return nv.authorized ? t("NV-AI-Version passt nicht zur App", "NV-AI version does not match the app")
                : t("NV-AI verlangt einen gültigen Token", "NV-AI requires a valid token")
        }
        if noModels { return t("In NV-AI ist kein Bildmodell installiert", "No image model is installed in NV-AI") }
        if form.mode == .fill && !nv.masks { return "NV-AI kennt noch keine Masken" }
        let prompt = form.prompt.trimmed
        if form.mode == .generate && prompt.isEmpty { return t("Bitte beschreiben, was entstehen soll", "Please describe what should be created") }
        if referenceEdit && prompt.isEmpty { return t("Bitte beschreiben, was sich ändern soll", "Please describe what should change") }
        return nil
    }

    // MARK: Aufträge

    static func taskID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: Date()))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())"
    }

    /// Parameter wie `GenerateRequest` der Brücke (bridge/server.py).
    func params() -> JSONValue {
        var p: [String: JSONValue] = [
            "mode": .string(form.mode.rawValue),
            "prompt": .string(form.prompt.trimmed),
            "negative_prompt": .string(negativeWorks ? form.negative.trimmed : ""),
            "variants": .int(min(4, max(1, form.variants))),
            "strength": .double(min(1.0, max(0.05, form.strength))),
            "margin": .double(min(1.5, max(0.0, form.margin))),
            "hires": .bool(form.hires && hiresWorks),
            "native": .bool(form.native),
            "auto_place": .bool(form.autoPlace),
        ]
        p["model_id"] = selectedModelID.isEmpty ? .null : .string(selectedModelID)
        if let steps = Int(form.steps.trimmed) { p["steps"] = .int(min(150, max(1, steps))) }
        if let cfg = Double(form.cfg.trimmed.replacingOccurrences(of: ",", with: ".")) { p["cfg"] = .double(min(30, max(0, cfg))) }
        if let seed = Int(form.seed.trimmed), seed >= 0 { p["seed"] = .int(seed) }
        return .object(p)
    }

    func generate() {
        guard blocker == nil, let nvai else { return }
        message = nil
        let task = GenerationTask(id: Self.taskID(), mode: form.mode.rawValue, prompt: form.prompt, params: params())
        let item = TaskItem(task: task)
        current = item
        shown = item
        history.insert(item, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        Log.write("Auftrag \(task.id) gestartet: \(task.mode), \(task.prompt.count) Zeichen Prompt")
        let workflow = workflow
        let exchange = launch.exchange
        Task {
            do {
                try await workflow.run(task, nvai: nvai) { progress, stage in
                    Task { @MainActor in
                        item.progress = progress
                        item.stage = stage
                    }
                }
                item.status = .done
                item.progress = 1
                item.stage = t("fertig", "done")
                item.placedVariant = task.placedVariant
                item.loadImages(exchange: exchange)
                Log.write("Auftrag \(task.id) fertig: \(task.variants.count) Variante(n), \(task.modelName), \(task.technique)")
            } catch WorkflowError.cancelled {
                item.status = .cancelled
                item.stage = t("abgebrochen", "cancelled")
                Log.write("Auftrag \(task.id) abgebrochen")
            } catch {
                item.status = .error
                item.error = error.localizedDescription
                Log.write("Auftrag \(task.id) gescheitert: \(error.localizedDescription)")
            }
            item.finished = Date()
        }
    }

    func cancel() {
        guard let item = current, item.status == .running else { return }
        item.task.isCancelled = true
        item.stage = t("wird abgebrochen", "cancelling")
    }

    /// Variante `k` in PhotoCraft einfügen; `replace` tauscht die zuletzt eingefügte aus.
    func place(_ item: TaskItem, variant k: Int, replace: Bool) {
        guard !placing, !isRunning else { return }
        placing = true
        item.error = nil
        let workflow = workflow
        Task {
            do {
                try await workflow.place(item.task, variant: k, replace: replace)
                item.placedVariant = item.task.placedVariant
            } catch {
                item.error = error.localizedDescription
                Log.write("Einfügen gescheitert: \(error.localizedDescription)")
            }
            placing = false
        }
    }

    // MARK: Programme

    /// PhotoCraft mit Steuerkanal starten. Läuft es schon ohne, erst nach Rückfrage (`force`).
    func startPhotoCraft(force: Bool) {
        guard starting.isEmpty else { return }
        message = nil
        if pc.uncontrolledRunning && !force {
            message = t("PhotoCraft läuft bereits ohne NV-AI-Anbindung. Bitte dort speichern und schließen – oder „Zusätzlich starten“.",
                        "PhotoCraft is already running without the NV-AI connection. Please save and close it there – or use \"Start another one\".")
            return
        }
        guard let app = PhotoCraftLaunch.installedApp() else {
            let tested = PhotoCraftLaunch.testedVersion
            message = t("PhotoCraft ist nicht installiert. Bitte PhotoCraft \(tested) oder neuer installieren.",
                        "PhotoCraft is not installed. Please install PhotoCraft \(tested) or newer.")
            return
        }
        launch.appURL = app  // wo es gerade liegt, nicht nur /Applications
        starting = "photocraft"
        let launch = launch
        Task {
            do {
                try await launch.launch()
                Log.write("PhotoCraft mit Steuerkanal gestartet (Port \(launch.port))")
                // PhotoCraft braucht ein paar Sekunden, bis der Steuerkanal antwortet.
                for _ in 0..<30 where !pc.connected {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await refreshPhotoCraft()
                }
            } catch {
                message = t("PhotoCraft ließ sich nicht starten: \(error.localizedDescription)",
                            "PhotoCraft could not be started: \(error.localizedDescription)")
                Log.write("PhotoCraft-Start gescheitert: \(error.localizedDescription)")
            }
            starting = ""
        }
    }

    func focusPhotoCraft() {
        let control = control
        Task {
            if pc.connected, let _ = try? await control.call("ui.focus") { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: PhotoCraftLaunch.bundleIdentifier).first?.activate()
        }
    }

    func openPhotoCraftDownload() {
        NSWorkspace.shared.open(PhotoCraftLaunch.downloadURL)
    }

    /// NV-AI zeigen, etwa um ein Modell zu laden: NV-AI für Mac nach vorn holen, bei einer NV-AI auf
    /// einem anderen Rechner deren Oberfläche im Browser öffnen.
    func openNVAI() {
        if settings.isLocal, let app = nvaiApp {
            Task { _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        } else if let url = settings.baseURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// NV-AI für Mac öffnen, ohne es nach vorn zu holen. Es startet seinen Server selbst; bereit ist
    /// NV-AI, sobald `/api/version` antwortet – so lange zeigt das Panel „NV-AI startet …“.
    func startNVAI() {
        guard starting.isEmpty, let app = nvaiApp else { return }
        message = nil
        starting = "nvai"
        Task {
            do {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
                Log.write("NV-AI für Mac geöffnet: \(app.path)")
                for _ in 0..<120 where !nv.connected {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await refreshNVAI()
                }
                if !nv.connected {
                    message = t("NV-AI für Mac ist geöffnet, antwortet aber noch nicht unter \(settings.nvaiURL).",
                                "NV-AI for Mac is open but does not answer at \(settings.nvaiURL) yet.")
                }
            } catch {
                message = t("NV-AI für Mac ließ sich nicht starten: \(error.localizedDescription)",
                            "NV-AI for Mac could not be started: \(error.localizedDescription)")
                Log.write("Start von NV-AI für Mac gescheitert: \(error.localizedDescription)")
            }
            starting = ""
        }
    }

    // MARK: Einstellungen

    /// Neue Einstellungen sichern und die Verbindungen neu aufbauen.
    func apply(_ new: AppSettings) throws {
        guard !isRunning && !placing else {
            throw WorkflowError.message(t("Bitte erst den laufenden Auftrag abwarten.", "Please wait for the running job first."))
        }
        try new.save()
        let portChanged = new.port != settings.port
        settings = new
        Localization.choice = new.language  // die Oberfläche baut sich über .id(settings.language) neu auf
        if portChanged {
            launch = PhotoCraftLaunch.standard(port: new.port)
            let old = control
            Task { await old.close() }
            control = ControlClient(port: new.port, tokenURL: launch.tokenFile)
            workflow = Workflow(pc: control, exchange: launch.exchange)
        }
        nvai = new.baseURL.map { NVAIClient(baseURL: $0, token: new.token) }
        models = []
        modelsLoaded = false
        Log.write("Einstellungen geändert – NV-AI \(new.nvaiURL), Token \(new.token == nil ? "keiner" : "gesetzt")")
        Task {
            await refreshNVAI()
            await refreshPhotoCraft()
        }
    }

    /// „Verbindung prüfen“ – auch mit noch nicht gesicherten Einstellungen. Passt alles und sind es
    /// die aktuellen, wird der Status gleich neu abgefragt.
    func probe(_ draft: AppSettings) async -> ProbeResult {
        let result = await Self.probe(draft)
        if result.ok && draft == settings { recheck() }
        return result
    }

    static func probe(_ settings: AppSettings) async -> ProbeResult {
        guard let url = settings.baseURL else {
            return ProbeResult(ok: false, message: t("Die Adresse ist ungültig – Beispiel: http://127.0.0.1:8100",
                                                     "The address is invalid – example: http://127.0.0.1:8100"))
        }
        let client = NVAIClient(baseURL: url, token: settings.token)
        do {
            guard let info = try await client.version() else {
                _ = try await client.health()
                return ProbeResult(ok: true, message: t("NV-AI antwortet (Version vor 0.2.0, ohne Versionsangabe).",
                                                        "NV-AI answers (version before 0.2.0, without version info)."))
            }
            do {
                try await client.checkCompatible()
                let message = info.auth == "local"
                    ? t("Verbunden: NV-AI \(info.version), Zugriff vom eigenen Rechner erlaubt.",
                        "Connected: NV-AI \(info.version), access from this computer allowed.")
                    : t("Verbunden: NV-AI \(info.version), Zugriff mit Token erlaubt.",
                        "Connected: NV-AI \(info.version), access with token allowed.")
                return ProbeResult(ok: true, message: message)
            } catch {
                return ProbeResult(ok: false, message: error.localizedDescription)
            }
        } catch {
            let hint = settings.isLocal ? t("Läuft NV-AI auf diesem Mac?", "Is NV-AI running on this Mac?")
                : t("Läuft NV-AI dort, und ist es im Netz erreichbar?", "Is NV-AI running there, and is it reachable on the network?")
            return ProbeResult(ok: false, message: "\(error.localizedDescription) \(hint)")
        }
    }

    // MARK: Aufräumen

    /// Auftragsordner nach drei Tagen löschen (wie die Windows-Brücke).
    private func cleanupOldJobs() {
        let jobs = launch.exchange.appendingPathComponent("jobs", isDirectory: true)
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-3 * 86_400)
        let dirs = (try? fm.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for dir in dirs {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if date < limit, (try? fm.removeItem(at: dir)) != nil { removed += 1 }
        }
        if removed > 0 { Log.write("\(removed) alte Auftragsordner gelöscht") }
    }
}
