import SwiftUI

/// Eine Auftragsleiste über alle Reiter (seit Mac 1.0, Konzept „NVAI im Fluss“, Bildschirm F; wie flow/JobDock.tsx
/// unter Windows): was läuft, was wartet (auch Anschluss-Szenen, die auf ihre Vorlage warten), mit Restzeit und Ziel;
/// „Zeigen“ führt direkt zum Ergebnis, auch aus einem anderen Reiter. Dazu ein Hinweis, wenn etwas in einem anderen
/// Reiter fertig wird. Anders als unter Windows stehen Downloads mit darin: Der Mac hat keine eigene Download-Leiste,
/// und seine Schlange rechnet Downloads, Export und Erzeugen nacheinander („GPU frei in …“ zählt sie deshalb mit).
struct JobDockHost: View {
    @EnvironmentObject var state: AppState
    @State private var estimates: [String: JobEstimate] = [:]
    @State private var projects: [String: StudioProject] = [:]
    @State private var toast: Toast?
    @State private var previous: [String: String] = [:]

    struct Toast: Equatable {
        let job: JobRecord
        let text: String
        let err: Bool

        static func == (a: Toast, b: Toast) -> Bool { a.job.id == b.job.id && a.text == b.text }
    }

    private var recent: [JobRecord] {
        let now = Date().timeIntervalSince1970
        return state.jobs.filter { $0.kind != "expand_prompt" && (FlowJobs.isActive($0) || ($0.finishedAt ?? 0) > now - 600) }
    }

    /// Studio-Projekte der Aufträge (Szenennamen, wartende Anschlüsse): das offene aus dem Studio, andere geladen
    private var projectIDs: [String] {
        var ids = Set(recent.compactMap { $0.params["studio_project"]?.stringValue })
        ids.formUnion(recent.filter { $0.kind == "studio_export" }.compactMap { $0.params["project_id"]?.stringValue })
        if let open = StudioModel.shared.project, open.scenes.contains(where: { $0.waitingFor != nil }) { ids.insert(open.id) }
        return ids.sorted()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let toast { toastView(toast) }
            Spacer(minLength: 0)
            if state.dockOpen && (!recent.isEmpty || !waitingRows.isEmpty) { dock }
        }
        .padding(12)
        .task(id: projectIDs.joined(separator: ",") + "|\(StudioModel.shared.project?.updatedAt ?? 0)") { await loadProjects() }
        .task(id: recent.filter(FlowJobs.isActive).map(\.id).joined(separator: ",")) { await loadEstimates() }
        .onChange(of: state.jobs.map { "\($0.id)\($0.status)" }.joined()) { _, _ in noteFinished() }
        .onChange(of: toast) { _, now in
            guard let now else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if toast == now { toast = nil } }
        }
    }

    // MARK: Daten

    private func loadProjects() async {
        var out: [String: StudioProject] = [:]
        for id in projectIDs {
            if let open = StudioModel.shared.project, open.id == id { out[id] = open; continue }
            if let p = try? await StudioStore.shared.load(id) { out[id] = p }
        }
        projects = out.mapValues { StudioGenerator.withChains($0) }
    }

    /// Erwartete Rechenzeit je offenem Auftrag (einmal je Auftrag), auch für die Restzeit der Phasen
    private func loadEstimates() async {
        for j in recent where FlowJobs.isActive(j) && estimates[j.id] == nil && j.kind != "download" {
            let e = await Estimate.one(kind: j.kind, params: j.params)
            estimates[j.id] = e
            FlowJobs.shared.note(j.id, e)
        }
    }

    /// Hinweis, wenn etwas fertig wird, das nicht im offenen Reiter liegt
    private func noteFinished() {
        for j in state.jobs {
            let was = previous[j.id]
            if let was, was == "queued" || was == "running", j.status == "done" || j.status == "error",
               j.kind != "expand_prompt", FlowKinds.origin(j) != state.selectedTab {
                // Wie unter Windows: Szenenaufträge mit Szene, sonst nur die Art (der Prompt stand schon in der Leiste)
                let scene = sceneOf(j) != nil
                let what = scene || j.kind == "studio_export" ? label(j).label : FlowKinds.label(j.kind)
                toast = Toast(job: j, text: j.status == "error" ? t("\(what): Fehler", "\(what): error")
                              : scene ? t("\(what) ist fertig, ein neuer Take liegt bereit.", "\(what) is done, a new take is ready.")
                              : t("\(what) ist fertig.", "\(what) is done."), err: j.status == "error")
            }
            previous[j.id] = j.status
        }
    }

    private func project(_ j: JobRecord) -> StudioProject? {
        (j.params["studio_project"]?.stringValue ?? (j.kind == "studio_export" ? j.params["project_id"]?.stringValue : nil))
            .flatMap { projects[$0] }
    }

    private func sceneOf(_ j: JobRecord) -> (p: StudioProject, s: StudioScene)? {
        guard let p = project(j) else { return nil }
        if let id = j.params["studio_start_image"]?.stringValue, let s = p.scenes.first(where: { $0.id == id }) { return (p, s) }
        guard let s = p.scenes.first(where: { s in s.jobs.contains(j.id) || j.assetIDs.contains { s.takes.contains($0) } })
        else { return nil }
        return (p, s)
    }

    /// Wie im Studio benannt: „Szene 3 · Video“, „Sprecher 2 · Stimme“ (Titel im Tooltip)
    private func label(_ j: JobRecord) -> (label: String, title: String) {
        if let hit = sceneOf(j) {
            let what = j.params["studio_start_image"] != nil ? t("Startbild", "Start image") : FlowKinds.label(j.kind)
            return ("\(StudioFlow.sceneRef(hit.p, hit.s.id)) · \(what)", [hit.s.title, hit.p.name].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if j.kind == "studio_export" {
            return (FlowKinds.label(j.kind) + (project(j).map { " · \($0.name)" } ?? ""), "")
        }
        let d = FlowKinds.detail(j)
        return (d.isEmpty ? FlowKinds.label(j.kind) : "\(FlowKinds.label(j.kind)) · \(d)", j.params["prompt"]?.stringValue ?? "")
    }

    private struct Row: Identifiable {
        let id: String
        let state: String  // run | queue | wait | done | err | off
        let label: String
        let title: String
        let sub: String
        let job: JobRecord?
    }

    private var waitingRows: [Row] {
        projects.values.flatMap { p in
            p.scenes.filter { $0.waitingFor != nil }.map { s in
                Row(id: "wait-\(s.id)", state: "wait", label: "\(StudioFlow.sceneRef(p, s.id)) · \(FlowKinds.label(s.kind == "image" ? "txt2img" : "txt2video"))",
                    title: p.name,
                    sub: p.scenes.contains { $0.id == s.waitingFor }
                        ? t("wartet auf \(StudioFlow.sceneRef(p, s.waitingFor))", "waits for \(StudioFlow.sceneRef(p, s.waitingFor))")
                        : t("wartet auf die Vorlage", "waits for its source"), job: nil)
            }
        }
    }

    private func phaseText(_ j: JobRecord) -> String {
        switch FlowJobs.shared.currentPhase(j) {
        case "queue": return t("wartet", "queued")
        case "prepare": return t("bereitet vor", "preparing")
        case "load": return t("Modell lädt", "model loads")
        case "save": return t("speichert", "saving")
        default: return j.kind == "download" ? t("lädt herunter", "downloading") : t("rechnet", "computing")
        }
    }

    private func rows(_ now: Date) -> (rows: [Row], gpuLeft: Double) {
        var out: [Row] = []
        var gpu = 0.0
        let active = recent.filter(FlowJobs.isActive)
        for j in active.filter({ $0.status == "running" }) {
            let l = label(j)
            let est = estimates[j.id]
            let left = FlowJobs.shared.remaining(j, expected: est?.seconds, now: now)
            gpu += left ?? est?.seconds ?? 0
            let pct = Int((j.progress * 100).rounded())
            let phase = FlowJobs.shared.currentPhase(j)
            let sub = phase == "run" && pct > 2 ? ["\(pct) %", FlowFormat.left(left)] : [phaseText(j), FlowFormat.left(left)]
            out.append(Row(id: j.id, state: "run", label: l.label, title: l.title, sub: sub.filter { !$0.isEmpty }.joined(separator: " · "), job: j))
        }
        for j in active.filter({ $0.status == "queued" }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let l = label(j)
            let est = estimates[j.id]
            gpu += est?.total ?? 0
            out.append(Row(id: j.id, state: "queue", label: l.label, title: l.title,
                           sub: [t("wartet", "queued"), FlowFormat.eta(est?.total)].filter { !$0.isEmpty }.joined(separator: " · "), job: j))
        }
        out += waitingRows
        let finished = recent.filter { !FlowJobs.isActive($0) }.prefix(6)
        for j in finished {
            let l = label(j)
            let took = j.startedAt.flatMap { s in j.finishedAt.map { FlowFormat.clock($0 - s) } } ?? ""
            let p = project(j)
            let sub = j.status == "error" ? (j.error ?? t("Fehler", "Error"))
                : j.status == "cancelled" ? t("abgebrochen", "cancelled")
                : p != nil ? t("fertig · im Projekt „\(p!.name)“", "done · in the project “\(p!.name)”")
                : took.isEmpty ? t("fertig", "done") : t("fertig nach \(took)", "done after \(took)")
            out.append(Row(id: j.id, state: j.status == "done" ? "done" : j.status == "error" ? "err" : "off",
                           label: l.label, title: l.title, sub: sub, job: j))
        }
        return (out, gpu)
    }

    // MARK: Ansicht

    private var dock: some View {
        EverySecond(on: recent.contains(where: FlowJobs.isActive)) { now in
            let r = rows(now)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(t("Aufträge", "Jobs")).font(.headline)
                    Spacer()
                    if r.gpuLeft > 0 {
                        Text(t("GPU frei in \(FlowFormat.eta(r.gpuLeft))", "GPU free in \(FlowFormat.eta(r.gpuLeft))"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button { state.dockOpen = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(t("Auftragsleiste schließen", "Close the job list"))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08))
                Divider()
                // So hoch wie die Zeilen, erst ab sieben Zeilen mit Rollbalken (ein Rahmen mit Höchstmaß hätte immer die
                // volle Höhe genommen: eine Zeile stand dann mitten in einem leeren Kasten)
                let list = VStack(alignment: .leading, spacing: 2) {
                    ForEach(r.rows) { row in rowView(row) }
                }
                .padding(.vertical, 6)
                if r.rows.count <= 6 {
                    list
                } else {
                    ScrollView { list }.frame(height: 320)
                }
            }
            .frame(width: 380)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 8) {
            FlowDot(state: row.state == "run" ? "run" : row.state == "done" ? "done" : row.state == "err" ? "err" : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label).lineLimit(1)
                Text(row.sub).font(.caption).foregroundStyle(row.state == "err" ? Color.red : .secondary).lineLimit(2).monospacedDigit()
            }
            .help(row.title)
            Spacer(minLength: 6)
            if let job = row.job, row.state == "run" || row.state == "queue" {
                Button { Task { _ = try? await JobQueue.shared.cancel(job.id) } } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help(t("Abbrechen", "Cancel"))
                    .accessibilityLabel(t("\(row.label): abbrechen", "\(row.label): cancel"))
            } else if let job = row.job, row.state == "done" || row.state == "err" {
                Button(t("Zeigen", "Show")) { state.showJob(job) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            Text(toast.text).lineLimit(2)
            Button(t("Ansehen", "View")) {
                state.showJob(toast.job)
                self.toast = nil
            }
            .controlSize(.small)
            Button { self.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                .accessibilityLabel(t("Schließen", "Close"))
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background((toast.err ? Color.red : Color.green).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((toast.err ? Color.red : Color.green).opacity(0.5)))
        .frame(maxWidth: 360, alignment: .leading)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

/// „Aufträge 3 ▴“ in der Fußzeile: öffnet die Auftragsleiste
struct JobsChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let now = Date().timeIntervalSince1970
        let recent = state.jobs.filter { $0.kind != "expand_prompt" && (FlowJobs.isActive($0) || ($0.finishedAt ?? 0) > now - 600) }
        let active = recent.filter(FlowJobs.isActive).count
        if !recent.isEmpty {
            Button { state.dockOpen.toggle() } label: {
                FlowChip(text: (active > 0 ? t("Aufträge \(active)", "Jobs \(active)") : t("Aufträge ✓", "Jobs ✓"))
                         + (state.dockOpen ? " ▾" : " ▴"), tone: active > 0 ? .ok : .plain)
            }
            .buttonStyle(.plain)
            .help(t("Alle Aufträge mit Restzeit", "All jobs with time left"))
        }
    }
}
