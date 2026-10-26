import SwiftUI

/// „✨ Prompt ausbauen“ mit Zurücknehmen: aus ein paar Worten eine volle Beschreibung, für Bilder und (seit 0.4.8,
/// Nutzerwunsch 26.10.2026) für Videos. Schreibt Qwen3-4B, der Text-Encoder von FLUX.2 Klein.
struct ExpandPromptRow: View {
    @EnvironmentObject var state: AppState
    @Binding var text: String
    let target: PromptTarget
    /// Fehlermeldungen landen dort, wo das Formular sie ohnehin zeigt.
    @Binding var message: String?

    @State private var expanding = false
    @State private var before: String?
    @State private var info: String?

    private var canExpand: Bool { Models.expansionModel != nil }

    private var helpText: String {
        switch target {
        case .image:
            return t("Schreibt aus ein paar Worten eine volle Bildbeschreibung (Qwen3 aus FLUX.2 Klein). "
                     + "Danach lesen und Erfundenes streichen.",
                     "Turns a few words into a full image description (Qwen3 from FLUX.2 Klein). "
                     + "Read it afterwards and delete what was invented.")
        case .video:
            return t("Schreibt aus ein paar Worten eine Videobeschreibung: Einstellung, Bewegung, eine Kamerabewegung, "
                     + "Ort und Licht, 40 bis 70 Wörter (Qwen3 aus FLUX.2 Klein). Danach lesen und Erfundenes streichen.",
                     "Turns a few words into a video description: shot, motion, one camera move, setting and light, "
                     + "40 to 70 words (Qwen3 from FLUX.2 Klein). Read it afterwards and delete what was invented.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    Task { await expand() }
                } label: {
                    Text(expanding ? t("Baut aus …", "Expanding …") : t("✨ Prompt ausbauen", "✨ Expand prompt"))
                }
                .disabled(!canExpand || expanding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(helpText)
                if expanding { ProgressView().controlSize(.small) }
                if let before, !expanding {
                    Button(t("Zurück zum eigenen Prompt", "Back to my prompt")) {
                        text = before
                        self.before = nil
                        info = nil
                    }
                }
                Spacer()
            }
            if !canExpand {
                Text(t("Prompt ausbauen braucht FLUX.2 Klein (unter „Modelle“).",
                       "Expand prompt needs FLUX.2 Klein (under \"Models\")."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let info {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func expand() async {
        message = nil
        let original = text
        expanding = true
        defer { expanding = false }
        do {
            let result = try await JobQueue.expandAndWait(original.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          target: target)
            before = original
            text = result.expanded
            let words = result.expanded.split(whereSeparator: \.isWhitespace).count
            info = t("\(words) Wörter in \(Int(result.seconds.rounded())) s. Lesen und Erfundenes streichen.",
                     "\(words) words in \(Int(result.seconds.rounded())) s. Read it and delete what was invented.")
            await state.refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
