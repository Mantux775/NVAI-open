import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Startseite des Bereichs „Ton-Forensik“ (seit 0.5.11): die Fälle auf diesem Mac, „Neuer Fall …“ aus Audio- und
/// Videodateien (`ForensicImport`) und „Prüfpaket öffnen …“ für Pakete aus NVAI-open unter Windows. Ein geöffneter Fall
/// erscheint in der Prüf-App (`ReviewWebView`); ihr ←-Knopf führt hierher zurück (Nachricht `close`).
@MainActor
final class ForensicStore: ObservableObject {
    static let shared = ForensicStore()

    @Published var cases: [ForensicCaseSummary] = []
    @Published var openCase: URL?
    @Published var draft: NewCaseDraft?
    @Published var error: String?
    @Published var modelsReady = ForensicModel.whisper.installed && ForensicModel.vad.installed
    @Published var translatorReady = ForensicTranslate.installed
    /// Vorschau eines gewählten VDR-Exports läuft
    @Published var checkingVDR = false
    /// Auftrag „Neuer Fall“, dessen Ergebnis gleich geöffnet wird
    private var openWhenDone: String?
    /// ← läuft gerade (`close`)
    private var closing = false
    private var seenFinished = Set<String>()
    static let kinds: Set<String> = ["forensic_case", "forensic_transcribe", "forensic_translate"]

    struct NewCaseDraft: Identifiable {
        let id = UUID()
        var files: [URL]
        var name: String
        /// aus einem VDR-Export: die Vorschau wie „Prüfen“ unter Windows
        var vdr: VDRPreview?
    }

    func refresh() { cases = ForensicCases.list() }

    func open(_ url: URL) {
        error = nil
        ReviewBridge.shared.target = url
        openCase = url
    }

    /// Zurück zur Fallliste. Zuerst darf die Prüf-App ein offenes Textfeld speichern (sie speichert beim Verlassen des
    /// Feldes); erst dann wird die Seite geleert. Ein zweites ← in dieser Zeit tut nichts.
    func close() async {
        guard !closing else { return }
        closing = true
        defer { closing = false }
        await ReviewBridge.shared.finishEditing()
        openCase = nil
        ReviewBridge.shared.unload()
        refresh()
    }

    func chooseFiles(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = t("Audio- oder Videodateien für den neuen Fall wählen (mehrere möglich: jede Datei, jeder Kanal wird eine Spur).",
                          "Choose audio or video files for the new case (several allowed: every file and channel becomes a track).")
        panel.prompt = t("Wählen", "Choose")
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self.draft = NewCaseDraft(files: panel.urls, name: panel.urls[0].deletingPathExtension().lastPathComponent)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Ordner eines VDR-Exports wählen; danach erst die Vorschau (unter 5 s), dann der Dialog „Neuer Fall“.
    func chooseVDR(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = t("Ordner der VDR-Daten wählen (mit block.1.….gz und Track.txt). Die Dateien werden nur gelesen, nie verändert.",
                          "Choose the folder of the VDR data (with block.1.….gz and Track.txt). The files are only read, never changed.")
        panel.prompt = t("Prüfen", "Check")
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self.inspectVDR(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    func inspectVDR(_ url: URL) {
        error = nil
        checkingVDR = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<VDRPreview, Error> in
                Result { try VDRPreview(url) }
            }.value
            checkingVDR = false
            switch result {
            case .success(let preview): draft = NewCaseDraft(files: [url], name: preview.suggestedName, vdr: preview)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func create(_ draft: NewCaseDraft) {
        self.draft = nil
        error = nil
        Task {
            let job = await JobQueue.shared.submitForensicCase(
                ForensicImport.Request(files: draft.files, name: draft.name, vdr: draft.vdr != nil))
            openWhenDone = job.id
        }
    }

    func transcribe(_ c: ForensicCaseSummary) {
        error = nil
        Task { _ = await JobQueue.shared.submitForensicTranscribe(ForensicTranscribe.Request(folder: c.folder)) }
    }

    func translate(_ c: ForensicCaseSummary) {
        error = nil
        Task { _ = await JobQueue.shared.submitForensicTranslate(ForensicTranslate.Request(folder: c.folder)) }
    }

    func downloadTranslator(window: NSWindow?) {
        let alert = NSAlert()
        let size = String(format: "%.1f", ForensicTranslate.sizeGB).replacingOccurrences(of: ".", with: Lang.ui == .de ? "," : ".")
        alert.messageText = t("Übersetzungsmodell laden?", "Download the translation model?")
        alert.informativeText = t("\(ForensicTranslate.modelName) (Alibaba, Apache-2.0) mit \(size) GB von Hugging Face, ausgewählt nach dem Speicher dieses Macs (ab 16 GB das größere 9B). Es übersetzt die Übersetzer-Spur über Englisch; jede Übersetzung bleibt Entwurf.",
                                  "\(ForensicTranslate.modelName) (Alibaba, Apache-2.0) with \(size) GB from Hugging Face, chosen by this Mac's memory (the larger 9B from 16 GB). It translates the translation track via English; every translation stays a draft.")
        alert.addButton(withTitle: t("Laden (\(size) GB)", "Download (\(size) GB)"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            Task { _ = await JobQueue.shared.submitTranslatorDownload() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    func downloadModels(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = t("Modelle für die Spracherkennung laden?", "Download the models for speech recognition?")
        alert.informativeText = t("Whisper large-v3 (OpenAI, Core ML von Argmax, MIT-Lizenz) mit 3,1 GB und der Sprachfinder Silero VAD (MIT) mit 1 MB, von Hugging Face. Danach läuft die Spracherkennung ohne Internet auf diesem Mac.",
                                  "Whisper large-v3 (OpenAI, Core ML by Argmax, MIT license) with 3.1 GB and the speech finder Silero VAD (MIT) with 1 MB, from Hugging Face. After that, speech recognition runs on this Mac without internet.")
        alert.addButton(withTitle: t("Laden (3,1 GB)", "Download (3.1 GB)"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                _ = await JobQueue.shared.submitDownload(ForensicModel.vad)
                _ = await JobQueue.shared.submitDownload(ForensicModel.whisper)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Fertige Aufträge: Liste und Modellstand auffrischen, den gerade angelegten Fall öffnen, Fehler zeigen.
    func jobsChanged(_ jobs: [JobRecord]) {
        let done = jobs.filter { $0.isFinished && (Self.kinds.contains($0.kind) || ForensicModel.find($0.downloadModelID) != nil
                                                   || $0.downloadModelID == "forensic-translator") }
        let new = done.filter { !seenFinished.contains($0.id) }
        if !new.isEmpty {
            seenFinished.formUnion(new.map(\.id))
            modelsReady = ForensicModel.whisper.installed && ForensicModel.vad.installed
            translatorReady = ForensicTranslate.installed
            refresh()
            if let failed = new.first(where: { $0.status == "error" && $0.id != openWhenDone }) { error = failed.error }
        }
        guard let id = openWhenDone, let job = jobs.first(where: { $0.id == id }), job.isFinished else { return }
        openWhenDone = nil
        refresh()
        if let started = job.startedAt, let ended = job.finishedAt {
            AppLog.info("Forensic case job \(job.status) after \(String(format: "%.1f", ended - started)) s")
        }
        if job.status == "done", let path = job.resultPath, openCase == nil {
            open(URL(fileURLWithPath: path))
        } else {
            if job.status == "error" { error = job.error }
            if ReviewTest.newCase != nil || ReviewTest.newVDR != nil { ReviewTest.finished = true }   // Prüfstand nicht 15 min warten lassen
        }
    }

    func openPackage(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = t("Ordner des Prüfpakets wählen (der Ordner, in dem NVAI-Pruefer.html liegt).",
                          "Choose the folder of the review package (the folder that contains NVAI-Pruefer.html).")
        panel.prompt = t("Öffnen", "Open")
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .OK, var url = panel.url else { return }
            if !ReviewPackages.isPackage(url), url.lastPathComponent == "fall", ReviewPackages.isPackage(url.deletingLastPathComponent()) {
                url = url.deletingLastPathComponent()
            }
            guard ReviewPackages.isPackage(url) else {
                self.error = t("Das ist kein Prüfpaket von NVAI-open (fall/manifest.json fehlt). Bitte den Ordner wählen, in dem NVAI-Pruefer.html liegt.",
                               "This is not an NVAI-open review package (fall/manifest.json missing). Please choose the folder that contains NVAI-Pruefer.html.")
                return
            }
            self.open(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    func reveal(_ c: ForensicCaseSummary) { NSWorkspace.shared.activateFileViewerSelecting([c.folder]) }

    func trash(_ c: ForensicCaseSummary, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = t("Fall „\(c.name)“ in den Papierkorb legen?", "Move case “\(c.name)” to the Trash?")
        alert.informativeText = t("Der ganze Ordner samt Originalton und Bearbeitung kommt in den Papierkorb; von dort lässt er sich zurückholen.",
                                  "The whole folder including the original audio and the edits goes to the Trash; it can be restored from there.")
        alert.addButton(withTitle: t("In den Papierkorb", "Move to Trash"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            // inzwischen ein Auftrag für diesen Fall (etwa über REST)? Dann nicht wegnehmen, er schreibt hinein
            if AppState.shared.jobs.contains(where: { !$0.isFinished && Self.kinds.contains($0.kind) && $0.resultPath == c.folder.path }) {
                self.error = t("An diesem Fall wird gerade gerechnet (Sprache erkennen oder Übersetzen); erst danach in den Papierkorb legen.",
                               "This case is being processed (speech recognition or translation); move it to the Trash afterwards.")
                return
            }
            do {
                try FileManager.default.trashItem(at: c.folder, resultingItemURL: nil)
            } catch {
                self.error = error.localizedDescription
            }
            self.refresh()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

struct ForensicHome: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: ForensicStore

    private var running: JobRecord? { state.jobs.first { ForensicStore.kinds.contains($0.kind) && !$0.isFinished } }
    private var downloading: JobRecord? { state.jobs.first { ForensicModel.find($0.downloadModelID) != nil && !$0.isFinished } }
    private var downloadingTranslator: JobRecord? { state.jobs.first { $0.downloadModelID == "forensic-translator" && !$0.isFinished } }

    private func busy(_ c: ForensicCaseSummary) -> Bool {
        state.jobs.contains { !$0.isFinished && ($0.kind == "forensic_transcribe" || $0.kind == "forensic_translate")
            && $0.resultPath == c.folder.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(t("Ton-Forensik", "Audio forensics")).font(.title2.bold())
                Spacer()
                Button(t("Prüfpaket öffnen …", "Open review package …")) { store.openPackage(window: NSApp.keyWindow) }
                if store.checkingVDR { ProgressView().controlSize(.small) }
                Button(t("VDR-Export einlesen …", "Import VDR export …")) { store.chooseVDR(window: NSApp.keyWindow) }
                    .disabled(running != nil || store.checkingVDR)
                Button(t("Neuer Fall …", "New case …")) { store.chooseFiles(window: NSApp.keyWindow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(running != nil)
            }
            Text(t("Ein Fall entsteht aus Audio- oder Videodateien: Jeder Kanal wird eine Spur, der Originalton bleibt bitgenau, dazu Wellenform, Spektrogramm und Sprachaktivität. Ein VDR-Import (Ship Blackbox, Schiffsdatenschreiber) bringt jeden Mikrofon- und Funkkanal als Spur mit, dazu Kurs, Geschwindigkeit, Alarme, AIS sowie Radar- und ECDIS-Bilder. Fälle aus NVAI-open unter Windows öffnet „Prüfpaket öffnen …“.",
                   "A case is made from audio or video files: every channel becomes a track, the original audio stays bit-exact, plus waveform, spectrogram and speech activity. A VDR import (Ship Blackbox, voyage data recorder) brings every microphone and radio channel as a track, plus heading, speed, alarms, AIS and radar and ECDIS pictures. Cases from NVAI-open on Windows open with “Open review package …”."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: store.modelsReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(store.modelsReady ? .green : .secondary)
                Text(t("Spracherkennung: Whisper large-v3 mit Sprachfinder Silero VAD, lokal auf diesem Mac",
                       "Speech recognition: Whisper large-v3 with the speech finder Silero VAD, locally on this Mac"))
                Spacer()
                if let d = downloading {
                    ProgressView(value: d.progress).frame(width: 160)
                    Text(d.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !store.modelsReady {
                    Button(t("Laden (3,1 GB) …", "Download (3.1 GB) …")) { store.downloadModels(window: NSApp.keyWindow) }
                }
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            HStack(spacing: 8) {
                Image(systemName: store.translatorReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(store.translatorReady ? .green : .secondary)
                Text(t("Übersetzung: \(ForensicTranslate.modelName) über Englisch, lokal auf diesem Mac",
                       "Translation: \(ForensicTranslate.modelName) via English, locally on this Mac"))
                Spacer()
                if let d = downloadingTranslator {
                    ProgressView(value: d.progress).frame(width: 160)
                    Text(d.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !store.translatorReady {
                    Button(t("Laden …", "Download …")) { store.downloadTranslator(window: NSApp.keyWindow) }
                }
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            if let job = running {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.kind == "forensic_transcribe" ? t("Sprache erkennen", "Speech recognition")
                             : job.kind == "forensic_translate" ? t("Übersetzen", "Translating") : t("Neuer Fall", "New case")).bold()
                        Text(job.stage).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
                    }
                    ProgressView(value: job.status == "queued" ? 0 : job.progress)
                    if job.status == "queued" {
                        Text(t("wartet, bis der laufende Auftrag fertig ist", "waiting for the running job to finish"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if store.cases.isEmpty {
                Spacer()
                Text(t("Noch keine Fälle auf diesem Mac.", "No cases on this Mac yet."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(store.cases) { c in
                    CaseRow(c: c, busy: busy(c), canTranscribe: store.modelsReady && running == nil,
                            canTranslate: store.translatorReady && running == nil && c.segments > 0,
                            transcribe: { store.transcribe(c) }, translate: { store.translate(c) }) { store.open(c.folder) }
                        .contextMenu {
                            Button(t("Öffnen", "Open")) { store.open(c.folder) }
                            Button(t("Im Finder zeigen", "Show in Finder")) { store.reveal(c) }
                            Divider()
                            // nicht, solange Erkennen oder Übersetzen in den Fall schreibt (oder dafür wartet)
                            Button(t("In den Papierkorb …", "Move to Trash …")) { store.trash(c, window: NSApp.keyWindow) }
                                .disabled(busy(c))
                        }
                }
                .listStyle(.inset)
            }
            HStack(spacing: 6) {
                Text(t("Ablage:", "Storage:")).foregroundStyle(.secondary)
                Text(ForensicCases.directory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button(t("Im Finder zeigen", "Show in Finder")) {
                    try? FileManager.default.createDirectory(at: ForensicCases.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ForensicCases.directory)
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.refresh() }
        .onReceive(state.$jobs) { store.jobsChanged($0) }
        .sheet(item: $store.draft) { draft in
            NewCaseSheet(draft: draft) { store.create($0) } cancel: { store.draft = nil }
        }
    }
}

private struct CaseRow: View {
    let c: ForensicCaseSummary
    var busy = false
    var canTranscribe = false
    var canTranslate = false
    var transcribe: () -> Void = {}
    var translate: () -> Void = {}
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: c.hasVideo ? "film" : "waveform").font(.title3).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if c.program.contains("Mac") {
                Button(c.segments > 0 ? t("Neu erkennen", "Recognise again") : t("Sprache erkennen", "Recognise speech"), action: transcribe)
                    .disabled(!canTranscribe)
                    .help(t("Whisper large-v3 hört alle Spuren dort, wo der Sprachfinder Sprache findet, und schreibt die Übersetzer-Spur (Entwurf). Geprüfte Blöcke bleiben.",
                            "Whisper large-v3 listens to all tracks where the speech finder detects speech and writes the translation track (draft). Checked blocks stay."))
                if c.segments > 0 {
                    Button(t("Übersetzen", "Translate"), action: translate)
                        .disabled(!canTranslate)
                        .help(t("Übersetzt die Blöcke ohne Übersetzung in die Zielsprache der Übersetzer-Spur (Vorgabe Deutsch), über Englisch. Jede Übersetzung bleibt Entwurf.",
                                "Translates the blocks without a translation into the target language of the translation track (default German), via English. Every translation stays a draft."))
                }
            }
            Button(t("Öffnen", "Open"), action: open).disabled(busy)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !busy { open() } }
    }

    private var details: String {
        var parts: [String] = []
        if let date = ISO8601DateFormatter().date(from: c.created) {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(Self.duration(c.duration))
        parts.append(c.tracks == 1 ? t("1 Spur", "1 track") : t("\(c.tracks) Spuren", "\(c.tracks) tracks"))
        parts.append(c.segments > 0 ? t("\(c.segments) Blöcke Text", "\(c.segments) text blocks")
                     : t("noch ohne Spracherkennung", "no speech recognition yet"))
        if !c.program.contains("Mac") { parts.append(t("aus Windows", "from Windows")) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ s: Double) -> String {
        let total = Int(s.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct NewCaseSheet: View {
    @State var draft: ForensicStore.NewCaseDraft
    let create: (ForensicStore.NewCaseDraft) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.vdr == nil ? t("Neuer Fall", "New case") : t("Neuer Fall aus einem VDR-Export", "New case from a VDR export"))
                .font(.headline)
            TextField(t("Name des Falls", "Name of the case"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
            if let v = draft.vdr {
                VStack(alignment: .leading, spacing: 3) {
                    info(t("Gerät", "Device"), v.product)
                    info(t("Beginn", "Start"), v.start.isEmpty ? "–" : "\(v.start) UTC")
                    info(t("Ende", "End"), v.end.isEmpty ? "–" : "\(v.end) UTC")
                    info(t("Dauer", "Duration"), Self.clock(v.duration))
                    info(t("Blöcke", "Blocks"), v.gaps > 0 ? "\(v.blocks) · \(v.gaps) " + t("Lücken", "gaps") : "\(v.blocks)")
                    info(t("Tonkanäle", "Audio channels"), v.channels.isEmpty ? "\(v.rates.count)" : v.channels.joined(separator: ", "))
                    info(t("Bildquellen", "Picture sources"), "\(v.images)")
                    info(t("Größe", "Size"), "\(ForensicDiskGuard.gb(v.exportBytes)) GB")
                }
                .font(.callout)
                Text(space(v)).font(.caption).foregroundStyle(v.fits ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(t("Jeder Mikrofon- und Funkkanal wird eine eigene Spur, dazu Kurs, Geschwindigkeit, Ruder, Maschine, Wind, Tiefe, Alarme, AIS sowie Radar- und ECDIS-Bilder. Die Quelldateien werden nur gelesen, nie verändert; ihre Prüfsummen werden geprüft und stehen im Fall.",
                       "Every microphone and radio channel becomes its own track, plus heading, speed, rudder, engine, wind, depth, alarms, AIS and radar and ECDIS pictures. The source files are only read, never changed; their checksums are verified and recorded in the case."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(draft.files.prefix(8), id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc").font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                    if draft.files.count > 8 {
                        Text(t("und \(draft.files.count - 8) weitere", "and \(draft.files.count - 8) more")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(t("Jeder Kanal wird eine eigene Spur (gleiche Kanäle nur einmal). Der Originalton kommt bitgenau als WAV in den Fall, ein Video als Bild zum Ton. Die Quelldateien bleiben unverändert; ihre Prüfsummen stehen im Fall.",
                       "Every channel becomes its own track (identical channels only once). The original audio goes into the case bit-exact as WAV, a video as the picture for the sound. The source files stay unchanged; their checksums are recorded in the case."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(t("Abbrechen", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(t("Anlegen", "Create")) { create(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.files.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).lineLimit(3).textSelection(.enabled)
        }
    }

    private static func clock(_ s: Int) -> String { String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }

    private func space(_ v: VDRPreview) -> String {
        let need = ForensicDiskGuard.gb(v.estimate)
        guard let free = v.free else { return t("Platzbedarf etwa \(need) GB.", "Needs about \(need) GB.") }
        let have = ForensicDiskGuard.gb(free)
        if v.fits { return t("Platzbedarf etwa \(need) GB, frei sind \(have) GB.", "Needs about \(need) GB; \(have) GB are free.") }
        let keep = ForensicDiskGuard.gb(ForensicDiskGuard.reserve)
        return t("Platzbedarf etwa \(need) GB, frei sind nur \(have) GB (\(keep) GB bleiben für macOS). Der Import bricht ab, bevor der Datenträger voll ist.",
                 "Needs about \(need) GB, only \(have) GB are free (\(keep) GB stay free for macOS). The import stops before the drive runs full.")
    }
}
