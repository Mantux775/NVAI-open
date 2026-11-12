import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Eigene LoRA-Dateien in der Oberfläche (seit 0.5.5, wie LoraFile.tsx unter Windows 0.5.24): Datei wählen, NVAI-open
// liest nur den Dateikopf (Basis, passende Modelle, Trigger aus den Metadaten), der Nutzer bestätigt oder ändert die
// Zuordnung, dann kommt die Datei in den Modellordner. Statt eines Uploads über HTTP genügt hier der Dateidialog; Prüfung,
// Zuordnung und Ablage sind dieselben wie bei POST /api/loras/upload.

extension Panels {
    @MainActor
    static func chooseLoRAFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = t("LoRA-Datei hinzufügen", "Add LoRA file")
        panel.message = t("Eine LoRA-Datei (.safetensors), etwa selbst trainiert", "A LoRA file (.safetensors), for example one you trained")
        if let type = UTType(filenameExtension: "safetensors") { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Eine im Dateidialog gewählte Datei, für `.sheet(item:)`.
struct LoRAFileChoice: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Zuordnung einer LoRA, wie sie das Formular bearbeitet.
struct LoRAAssignment: Equatable {
    var family: String
    var name: String
    var trigger: String
}

/// Felder der Zuordnung: Basis samt den Modellen, die sie nehmen (auf dem Mac nur FLUX.2 Klein 4B), Name, Trigger.
struct LoRAAssignFields: View {
    @Binding var value: LoRAAssignment
    /// am Dateikopf erkannte Basis: weicht die Wahl ab, ein Hinweis
    var detected: String?

    private var models: [CatalogModel] { value.family == LoRAModel.family ? ModelCatalog.all : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(t("Gehört zu", "Belongs to"), selection: $value.family) {
                if !LoRAFiles.macBases.contains(value.family) {
                    Text(value.family.isEmpty ? t("(bitte wählen)", "(please choose)") : LoRAFiles.label(value.family)).tag(value.family)
                }
                ForEach(LoRAFiles.macBases, id: \.self) { base in
                    let n = base == LoRAModel.family ? ModelCatalog.all.count : 0
                    let k = base == LoRAModel.family ? ModelCatalog.all.filter { ModelCatalog.status($0).installed }.count : 0
                    Text(LoRAFiles.label(base) + " " + t("(\(n) Modell\(n == 1 ? "" : "e"), \(k) geladen)",
                                                          "(\(n) model\(n == 1 ? "" : "s"), \(k) downloaded)")).tag(base)
                }
            }
            if !models.isEmpty {
                Text(t("Erscheint beim Generieren mit: ", "Shows up when generating with: ")
                     + models.map { ModelCatalog.status($0).installed ? $0.name : $0.name + t(" (noch nicht geladen)", " (not downloaded yet)") }
                        .joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let detected, !value.family.isEmpty, detected != value.family {
                Text(t("Der Dateikopf passt zu \(LoRAFiles.label(detected)). Eine LoRA, die nicht zum Modell passt, wirkt meist gar nicht.",
                       "The file header fits \(LoRAFiles.label(detected)). A LoRA that does not fit the model usually has no effect at all."))
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField(t("Name", "Name"), text: $value.name)
            TextField(t("Trigger-Wörter", "Trigger words"), text: $value.trigger,
                      prompt: Text(t("z. B. ohwx person; leer, wenn es keine gibt", "e.g. ohwx person; empty if there are none")))
        }
    }
}

/// Fortschritt des Kopierens, vom Hintergrund-Task auf den Hauptthread gemeldet.
@MainActor
final class LoRACopyProgress: ObservableObject {
    @Published var value = 0.0
}

/// Blatt „LoRA-Datei hinzufügen“ für eine im Dateidialog gewählte Datei.
struct LoRAAddSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let url: URL
    /// Basis, die vorgeschlagen wird, wenn der Kopf nichts verrät (beim Generieren: die des gewählten Modells)
    var preferBase: String?
    let onDone: (LoRAUploads.Result) -> Void

    @State private var check: LoRACheck?
    @State private var form = LoRAAssignment(family: "", name: "", trigger: "")
    @State private var error: String?
    @State private var busy = false
    @State private var copyTask: Task<(part: URL, size: Int64, sha256: String), Error>?
    @StateObject private var progress = LoRACopyProgress()

    private var size: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Eigene LoRA hinzufügen", "Add your own LoRA")).font(.headline)
            Text(t("Eine LoRA-Datei (.safetensors) von diesem Rechner, etwa selbst trainiert (ai-toolkit, diffusers). NVAI-open liest "
                   + "zuerst nur den Dateikopf und erkennt daran, zu welchem Modell sie gehört; die Zuordnung lässt sich vor und nach "
                   + "dem Hinzufügen ändern. Auf dem Mac nimmt nur FLUX.2 Klein 4B LoRAs.",
                   "A LoRA file (.safetensors) from this computer, for example one you trained (ai-toolkit, diffusers). NVAI-open first "
                   + "reads only the file header and detects which model it belongs to; you can change the assignment before and after "
                   + "adding it. On the Mac, only FLUX.2 Klein 4B takes LoRAs."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(url.lastPathComponent).font(.callout.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            if let check {
                Text(check.verdict).font(.callout).foregroundStyle(check.ok ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if check.lora { LoRAAssignFields(value: $form, detected: check.family).disabled(busy) }
            } else if error == nil {
                Text(t("prüft den Dateikopf …", "checking the file header …")).font(.caption).foregroundStyle(.secondary)
            }
            if busy {
                ProgressView(value: progress.value)
                Text(progress.value < 1 ? t("kopiert … \(Int(progress.value * 100)) %", "copying … \(Int(progress.value * 100)) %")
                                        : t("prüft …", "checking …"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(t("Abbrechen", "Cancel"), role: .cancel) {
                    copyTask?.cancel()
                    dismiss()
                }
                Button(t("Hinzufügen", "Add"), action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || check?.lora != true || !LoRAFiles.macBases.contains(form.family))
                    .help(LoRAFiles.macBases.contains(form.family) ? ""
                          : t("Erst wählen, zu welchem Modell die LoRA gehört", "First choose which model the LoRA belongs to"))
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear(perform: inspect)
    }

    private func inspect() {
        do {
            _ = try LoRAFiles.fileName(url.lastPathComponent)
            let c = LoRAFiles.inspect(try LoRAFiles.readHeader(url).header, fileName: url.lastPathComponent)
            // Erkannt oder aus den Metadaten vorgeschlagen; verrät der Kopf nichts, die Basis des gewählten Modells
            let known = { (b: String?) -> String? in b.flatMap { LoRAFiles.macBases.contains($0) ? $0 : nil } }
            let family = known(c.suggested) ?? (c.family == nil ? known(preferBase) : nil) ?? ""
            form = LoRAAssignment(family: family, name: c.name, trigger: c.trigger)
            check = c
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        let family = form.family, name = form.name, trigger = form.trigger, source = url
        let box = progress
        error = nil
        busy = true
        box.value = 0
        let copy = Task.detached(priority: .userInitiated) {
            try LoRAUploads.copyFromDisk(source) { p in Task { @MainActor in box.value = p } }
        }
        copyTask = copy
        Task {
            defer { busy = false }
            do {
                let target = try LoRAFiles.fileName(source.lastPathComponent)
                let copied = try await copy.value
                box.value = 1
                let result = try await Task.detached(priority: .userInitiated) {
                    try LoRAUploads.add(part: copied.part, target: target, family: family, name: name, trigger: trigger,
                                        expert: "", size: copied.size, sha256: copied.sha256)
                }.value
                state.refreshModels()
                onDone(result)
                dismiss()
            } catch is CancellationError {
                // abgebrochen: die Teildatei hat copyFromDisk schon gelöscht
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Zuordnung einer eigenen LoRA ändern (Basis, Name, Trigger-Wörter), wie LoraAssign unter Windows.
struct LoRAAssignEditor: View {
    @EnvironmentObject var state: AppState
    let model: LoRAModel
    let onClose: (String?) -> Void
    @State private var form = LoRAAssignment(family: "", name: "", trigger: "")
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LoRAAssignFields(value: $form, detected: nil)
            HStack {
                Button(t("Speichern", "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!LoRAFiles.macBases.contains(form.family))
                Button(t("Abbrechen", "Cancel")) { onClose(nil) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { form = LoRAAssignment(family: model.base, name: model.name, trigger: model.trigger) }
    }

    private func save() {
        do {
            // Den Namen nur ändern, wenn er geändert wurde
            let updated = try LoRAUploads.update(model.id, family: form.family, trigger: form.trigger,
                                                 name: form.name.trimmingCharacters(in: .whitespaces) != model.name ? form.name : nil)
            state.refreshModels()
            onClose(t("„\(updated.name)“ gehört jetzt zu \(updated.baseLabel).", "“\(updated.name)” now belongs to \(updated.baseLabel)."))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension LoRAUploads.Result {
    /// Meldung nach dem Hinzufügen unter „Modelle“ (wie unter Windows).
    var message: String {
        let base = model.baseLabel
        return (existing
            ? t("Diese Datei ist schon da als „\(model.name)“; ihre Zuordnung ist jetzt \(base).",
                "This file is already there as “\(model.name)”; its assignment is now \(base).")
            : t("„\(model.name)“ ist hinzugefügt (\(base)). Beim Generieren erscheint sie unter „LoRAs“, sobald ein passendes Modell gewählt ist.",
                "“\(model.name)” was added (\(base)). When generating, it shows up under “LoRAs” as soon as a matching model is selected."))
            + (warning.isEmpty ? "" : " " + warning)
    }
}
