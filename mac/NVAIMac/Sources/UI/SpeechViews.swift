import SwiftUI

/// Sprecherstimme im Reiter „Erzeugen“ (seit 0.5.3): Text, Stimme beschreiben oder aus einer Aufnahme übernehmen,
/// Sprache. Wie der Reiter „Sprache“ unter Windows.
struct SpeechForm: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var fromRecording = false
    @State private var voice = ""
    @State private var recordingID: String?
    @State private var voiceText = ""
    @State private var language = "auto"
    @State private var seedText = ""
    @State private var lastJobID: String?
    @State private var message: String?

    static let languageNames: [(id: String, label: String)] = [
        ("auto", t("Automatisch", "Automatic")), ("de", "Deutsch"), ("en", "English"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"), ("zh", "中文"),
        ("ja", "日本語"), ("ko", "한국어"),
    ]

    private var currentJob: JobRecord? { lastJobID.flatMap { id in state.jobs.first { $0.id == id } } }
    /// Aufnahmen, aus denen sich eine Stimme übernehmen lässt: Ton (auch eigene Sprecherzeilen), Videos, Uploads.
    private var recordings: [AssetRecord] { state.audios + state.videos + state.mediaUploads }
    private var spoken: [AssetRecord] { state.audios.filter { $0.meta["speech"]?.boolValue == true } }

    var body: some View {
        if !state.speechInstalled {
            Text(String(format: t("Braucht Qwen3-TTS (%.1f GB).", "Needs Qwen3-TTS (%.1f GB)."), SpeechCatalog.downloadGB))
                .font(.callout).foregroundStyle(.orange)
            Button(t("Unter „Modelle“ laden …", "Download under \"Models\" …")) { state.selectedTab = "models" }
                .buttonStyle(.link)
        }
        Text("Text").font(.subheadline.bold())
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: 90)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(t("Willkommen in der alten Mühle. Hier wurde früher Korn gemahlen.",
                           "Welcome to the old mill. Grain used to be ground here."))
                        .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                }
            }
            .border(.quaternary)
        Text(t("Der Text wird so gesprochen, wie er dasteht; Satzzeichen setzen Pausen.",
               "The text is spoken as written; punctuation sets the pauses."))
            .font(.caption).foregroundStyle(.secondary)
        Text(t("Stimme", "Voice")).font(.subheadline.bold())
        Picker(t("Stimme", "Voice"), selection: $fromRecording) {
            Text(t("beschreiben", "describe")).tag(false)
            Text(t("aus einer Aufnahme", "from a recording")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if fromRecording {
            Picker(t("Aufnahme", "Recording"), selection: $recordingID) {
                Text(t("Aufnahme wählen …", "Choose a recording …")).tag(String?.none)
                ForEach(recordings) { a in
                    Text((a.kind == "video" ? "▶ " : "♪ ") + String((a.prompt.isEmpty ? a.filename : a.prompt).prefix(60)))
                        .tag(Optional(a.id))
                }
            }
            .onChange(of: recordingID) { _, id in
                // Eine eigene Sprecherzeile kennt ihren Text: dann wortgenau übernehmen
                if let id, let a = recordings.first(where: { $0.id == id }), a.meta["speech"]?.boolValue == true,
                   let spokenText = a.meta["text"]?.stringValue {
                    voiceText = spokenText
                }
            }
            TextField(t("Was in der Aufnahme gesagt wird, wortgenau (optional)", "What is said in the recording, word for word (optional)"),
                      text: $voiceText, axis: .vertical)
                .lineLimit(2...4)
            Text(t("Genutzt werden die ersten 20 s, drei Sekunden reichen. Mit dem Text übernimmt das Modell auch Sprechweise "
                   + "und Betonung, ohne ihn nur den Stimmklang. Nur Aufnahmen, deren Sprecher zugestimmt haben.",
                   "The first 20 s are used, three seconds are enough. With the text the model also takes over the way of "
                   + "speaking, without it only the sound of the voice. Only recordings whose speakers agreed."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            TextField(t("z. B. eine ruhige, tiefe Männerstimme, etwa fünfzig, warm und leicht rau",
                        "e.g. a calm, deep male voice, about fifty, warm and slightly rough"), text: $voice, axis: .vertical)
                .lineLimit(2...4)
            Text(t("Geschlecht, Alter, Tonlage, Tempo und Stimmung in einem Satz; leer wählt das Modell selbst. Jeder Seed klingt "
                   + "etwas anders: Für dieselbe Stimme in weiteren Sätzen eine gelungene Zeile unter „aus einer Aufnahme“ wählen.",
                   "Gender, age, pitch, pace and mood in one sentence; empty lets the model choose. Every seed sounds a little "
                   + "different: for the same voice in further sentences, choose a good line under \"from a recording\"."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker(t("Sprache", "Language"), selection: $language) {
            ForEach(Self.languageNames, id: \.id) { Text($0.label).tag($0.id) }
        }
        .frame(maxWidth: 260)
        HStack {
            Text("Seed")
            TextField(t("zufällig", "random"), text: $seedText).frame(width: 140)
        }
        HStack {
            Button {
                Task { await submit() }
            } label: {
                Text(t("Erzeugen", "Generate")).frame(minWidth: 120)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!state.speechInstalled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || (fromRecording && recordingID == nil))
            if let job = currentJob, !job.isFinished {
                ProgressView().controlSize(.small)
                Text(job.stage).font(.caption).foregroundStyle(.secondary)
                Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(job.id) } }
            }
        }
        if let message { Text(message).foregroundStyle(.red).font(.callout) }
        if let job = currentJob, job.status == "error", let error = job.error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
        if !spoken.isEmpty {
            Text(t("Zuletzt gesprochen", "Recently spoken")).font(.subheadline.bold()).padding(.top, 6)
            ForEach(spoken.prefix(20)) { asset in AudioRow(asset: asset) }
        }
    }

    private func submit() async {
        message = nil
        var body: [String: JSONValue] = [
            "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "language": .string(language),
            "model_id": .string(SpeechCatalog.id),
        ]
        if fromRecording, let recordingID {
            body["voice_asset_id"] = .string(recordingID)
            body["voice_text"] = .string(voiceText)
        } else {
            body["voice"] = .string(voice)
        }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { body["seed"] = .int(seed) }
        do {
            let request = try SpeechJobRequest.parse(.object(body))
            let job = await JobQueue.shared.submitSpeech(request)
            lastJobID = job.id
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}

/// Qwen3-TTS unter „Modelle“: laden, Fortschritt, löschen (wie Stable Audio 3).
struct SpeechModelCard: View {
    @EnvironmentObject var state: AppState

    private var download: JobRecord? {
        state.jobs.first { $0.downloadModelID == SpeechCatalog.id && !$0.isFinished }
    }
    private var lastError: String? {
        state.jobs.first { $0.downloadModelID == SpeechCatalog.id }.flatMap { $0.status == "error" ? $0.error : nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(SpeechCatalog.name).font(.headline)
                    FitBadges(fit: MacFit.of(needGB: MacFit.speechNeedGB),
                              recommended: MacRecommendations.isRecommended(SpeechCatalog.id))
                    Spacer()
                    Text(state.speechInstalled ? t("geladen", "downloaded") : t("nicht geladen", "not downloaded"))
                        .foregroundStyle(state.speechInstalled ? .green : .secondary)
                }
                Text(SpeechCatalog.description).font(.callout)
                Text(String(format: t("Download %.1f GB · 10 Sprachen · Apache-2.0", "Download %.1f GB · 10 languages · Apache-2.0"),
                            SpeechCatalog.downloadGB))
                    .font(.caption).foregroundStyle(.secondary)
                if let download {
                    DownloadProgressRow(download: download)
                } else if let lastError {
                    Text(lastError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if !state.speechInstalled {
                        Button(t("Herunterladen", "Download")) {
                            Task { _ = await JobQueue.shared.submitSpeechDownload() }
                        }
                        .disabled(download != nil)
                    } else {
                        Button(t("Löschen", "Delete"), role: .destructive) {
                            Task {
                                await SpeechEngine.shared.unload()
                                SpeechCatalog.delete()
                                state.refreshModels()
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
