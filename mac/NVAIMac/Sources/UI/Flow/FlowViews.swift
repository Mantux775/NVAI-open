import AppKit
import SwiftUI

/// Ton eines Zustands (Chip, Punkt): ok grün, info blau, warn orange, err rot, sonst grau
enum FlowTone: String {
    case ok, info, warn, err, plain

    var color: Color {
        switch self {
        case .ok: return .green
        case .info: return .blue
        case .warn: return .orange
        case .err: return .red
        case .plain: return .secondary
        }
    }
}

/// Chip mit Zustand: „LTX-Video 2B · bereit“, „Startbild fehlt“ (wie die Abzeichen unter „Modelle“)
struct FlowChip: View {
    let text: String
    var tone: FlowTone = .plain

    var body: some View {
        Text(text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(tone.color.opacity(tone == .plain ? 0.45 : 0.8)))
            .foregroundStyle(tone.color)
    }
}

/// Kleine Überschrift wie im Konzept („WEG“, „TAKES“)
struct FlowLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// Großer Knopf, der Aktion und Zeit nennt: „Video erzeugen  ≈ 1:50“
struct FlowBigButton: View {
    let label: String
    var eta: String = ""
    var disabled = false
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).fontWeight(.semibold).lineLimit(1)
                if !eta.isEmpty { Text(eta).monospacedDigit().opacity(0.75).lineLimit(1) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
        .disabled(disabled)
        .help(help)
    }
}

/// Punkt einer Phase: erledigt grün gefüllt, läuft grüner Ring, Fehler rot, sonst grau
struct FlowDot: View {
    let state: String  // done | run | err | ""

    var body: some View {
        ZStack {
            if state == "run" { Circle().fill(Color.green.opacity(0.18)).frame(width: 18, height: 18) }
            Circle().stroke(state == "run" || state == "done" ? Color.green : state == "err" ? .red : Color.secondary.opacity(0.4),
                            lineWidth: 2)
                .frame(width: 12, height: 12)
            if state == "done" { Circle().fill(Color.green).frame(width: 12, height: 12) }
            if state == "err" { Circle().fill(Color.red).frame(width: 12, height: 12) }
        }
        .frame(width: 18, height: 18)
    }
}

/// Fortschritt in Phasen (Konzept, Bildschirm C): wartet, bereitet vor, Modell lädt, rechnet mit Schritt und Restzeit,
/// speichert. Vorher stand beim ersten Auftrag nur „Rechnet …“ mit einem Balken.
struct JobPhasesView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var flow = FlowJobs.shared
    let job: JobRecord
    /// Name des Modells für „Modell lädt (…)“
    var modelName: String?
    /// Rechenzeit laut Schätzung vor dem Start (ohne Laden): Restzeit, solange die Rate noch unsicher ist
    var expected: Double?
    /// wer im Hinweis unten nur noch rechnet, schon übersetzt: „das nächste Bild“
    var next: String?

    private struct Row: Identifiable {
        let id: String
        let label: Text
        let right: String
        let bold: Bool
    }

    var body: some View {
        EverySecond(on: FlowJobs.isActive(job)) { now in content(now) }
    }

    private func content(_ now: Date) -> some View {
        let phase = flow.currentPhase(job)
        let order = ["queue", "prepare", "load", "run", "save"]
        let at = phase.flatMap { order.firstIndex(of: $0) } ?? order.count
        func dot(_ key: String) -> String {
            if !FlowJobs.isActive(job) { return job.status == "done" ? "done" : job.status == "error" ? "err" : "" }
            let i = order.firstIndex(of: key) ?? 0
            return i < at ? "done" : i == at ? "run" : ""
        }
        func secs(_ key: String) -> String {
            guard let s = flow.phaseSeconds(job, key, now: now), s >= 1 else { return "" }
            return FlowFormat.clock(s)
        }
        let ahead = phase == "queue"
            ? state.jobs.filter { $0.id != job.id && FlowJobs.isActive($0) && $0.createdAt <= job.createdAt }.count : 0
        var rows: [Row] = []
        if phase == "queue" || (flow.sawPhase(job, "queue") && (flow.phaseSeconds(job, "queue", now: now) ?? 0) >= 2) {
            let more = ahead == 0 ? "" : ahead == 1 ? t(" · 1 Auftrag davor", " · 1 job ahead") : t(" · \(ahead) Aufträge davor", " · \(ahead) jobs ahead")
            rows.append(Row(id: "queue", label: Text(t("Wartet auf die GPU", "Waiting for the GPU")) + Text(more).foregroundColor(.secondary),
                            right: secs("queue"), bold: false))
        }
        if flow.sawPhase(job, "prepare") && (phase == "prepare" || (flow.phaseSeconds(job, "prepare", now: now) ?? 0) >= 2) {
            let detail = phase == "prepare" && !job.stage.isEmpty ? " (\(job.stage))" : ""
            rows.append(Row(id: "prepare", label: Text(t("Bereitet vor", "Preparing")) + Text(detail).foregroundColor(.secondary),
                            right: secs("prepare"), bold: false))
        }
        if flow.sawPhase(job, "load") {
            let name = modelName.map { " (\($0))" } ?? ""
            rows.append(Row(id: "load", label: Text(t("Modell lädt", "Model loads")) + Text(name).foregroundColor(.secondary),
                            right: secs("load"), bold: false))
        }
        let running = phase == "run"
        let runLabel = running && !job.stage.isEmpty ? Text(t("Rechnet", "Computing")) + Text(" · \(job.stage)")
            : Text(t("Rechnet", "Computing"))
        rows.append(Row(id: "run", label: runLabel,
                        right: running ? FlowFormat.left(flow.remaining(job, expected: expected, now: now)) : secs("run"),
                        bold: running))
        rows.append(Row(id: "save", label: Text(t("Speichern", "Saving")).foregroundColor(dot("save").isEmpty ? .secondary : .primary),
                        right: "", bold: false))
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { r in
                HStack(alignment: .center, spacing: 8) {
                    FlowDot(state: dot(r.id)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        r.label.lineLimit(2)
                        if r.id == "run" && running {
                            ProgressView(value: max(0, min(1, (job.progress - 0.02) / 0.97))).tint(.green)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(r.right).monospacedDigit().foregroundStyle(r.bold ? .primary : .secondary)
                }
            }
            if flow.sawPhase(job, "load") {
                Text(t("Laden fällt nur beim ersten Auftrag mit diesem Modell an; \(next ?? "der nächste Auftrag") braucht nur die Rechenzeit.",
                       "Loading only happens for the first job with this model; \(next ?? "the next job") only needs the computing time."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.green.opacity(0.6)).frame(width: 3) }
            }
        }
        .font(.callout)
    }
}

/// Seed genau als Text, mit „kopieren“ (Konzept, Bildschirm C: „Der Seed wird genau angezeigt und lässt sich kopieren“)
struct SeedCopyView: View {
    let seed: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Seed")
            Text(verbatim: seed).font(.callout.monospaced()).textSelection(.enabled)
            Button(copied ? t("kopiert", "copied") : t("kopieren", "copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(seed, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            }
            .controlSize(.small)
        }
    }
}

/// Ein nächster Schritt unter einem Ergebnis: Zeichen, Wort, darunter Modell und Zeit
struct FlowNextStep: Identifiable {
    let id: String
    let icon: String
    let label: String
    let small: String
    var primary = false
    var disabled = false
    var help = ""
    let action: () -> Void
}

/// Die naheliegenden nächsten Schritte unter einem Ergebnis (Konzept, Bildschirm C: „Jedes Ergebnis führt weiter“)
struct NextStepsView<Extra: View>: View {
    let heading: String
    let steps: [FlowNextStep]
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FlowLabel(text: heading)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(steps) { s in
                        Button(action: s.action) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(s.icon) \(s.label)").fontWeight(.medium).lineLimit(1)
                                Text(s.small).font(.caption).opacity(0.75).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered)
                        .tint(s.primary ? Color.green : nil)
                        .disabled(s.disabled)
                        .help(s.help)
                    }
                }
                extra()
            }
        }
    }
}
