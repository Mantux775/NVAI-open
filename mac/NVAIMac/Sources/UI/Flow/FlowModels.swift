import SwiftUI

/// Ein ladbares Modell, wie die Modellliste (`GET /api/models`) es beschreibt: für „Fehlendes an Ort und Stelle“ und den
/// ersten Start (seit Mac 1.0, Konzept „NVAI im Fluss“). Bilder, Video, Ton, Stimme und Zusätze in einer Form.
struct FlowModel: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let sizeGB: Double
    let license: String
    let commercial: Bool
    let installed: Bool
    let partial: Bool
    let gated: Bool
    let warning: String
    let recommended: Bool

    init?(_ info: [String: Any]) {
        guard let id = info["id"] as? String, let name = info["name"] as? String else { return nil }
        self.id = id
        self.name = name
        kind = info["kind"] as? String ?? ""
        sizeGB = info["size_gb"] as? Double ?? Double(info["size_gb"] as? Int ?? 0)
        license = info["license"] as? String ?? ""
        commercial = info["commercial_ok"] as? Bool ?? true
        installed = info["installed"] as? Bool ?? false
        partial = info["partially_installed"] as? Bool ?? false
        gated = info["gated"] as? Bool ?? false
        warning = info["warning"] as? String ?? ""
        recommended = info["recommended"] as? Bool ?? MacRecommendations.isRecommended(id)
    }

    /// Ohne Klammerzusatz: „FLUX.2 Klein 4B (4 Bit)“ → „FLUX.2 Klein 4B“
    var short: String { name.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression) }

    /// Lizenz in einer kurzen Zeile
    var licenseLine: String { commercial ? license : "\(license) · " + t("nicht kommerziell", "not commercial") }

    /// Größe, Lizenz, Ladezeit: „10,6 GB, Apache-2.0, bei 100 MBit/s rund 14 min“
    var needLine: String {
        t("\(FlowFormat.gb(sizeGB)), \(licenseLine), bei 100 MBit/s rund \(FlowFormat.span(FlowFormat.downloadSeconds(sizeGB)))",
          "\(FlowFormat.gb(sizeGB)), \(licenseLine), about \(FlowFormat.span(FlowFormat.downloadSeconds(sizeGB))) at 100 Mbit/s")
    }

    /// Gesperrtes Modell ohne gespeichertes Token: erst Konto, Lizenz und Token
    var tokenMissing: Bool { gated && !installed && Settings.hfToken == nil }
}

enum FlowCatalog {
    /// Alle Modelle wie `GET /api/models` (ohne LoRAs), in der Sprache der Oberfläche
    static func all() -> [FlowModel] { APIRouter.models(kind: nil).compactMap(FlowModel.init).filter { $0.kind != "lora" } }

    /// Den normalen Download-Auftrag der App für dieses Modell abschicken (wie die Karten unter „Modelle“)
    static func download(_ id: String) async -> JobRecord? {
        if let helper = HelperModel.find(id) { return await JobQueue.shared.submitDownload(helper) }
        if id == AudioCatalog.id { return await JobQueue.shared.submitAudioDownload() }
        if SpeechCatalog.matches(id) { return await JobQueue.shared.submitSpeechDownload() }
        if VideoCatalog.model(id) != nil { return await JobQueue.shared.submitVideoDownload(id) }
        if let m = Models.find(id) { return await JobQueue.shared.submitDownload(m) }
        return nil
    }
}

/// Fehlendes Modell an Ort und Stelle laden (wie flow/ModelNeed.tsx unter Windows; Konzept: „Fehlendes an Ort und
/// Stelle: Modell laden, Lizenz annehmen, ohne in einen anderen Reiter zu springen. Geladen wird erst nach dem Klick.“).
/// Der Klick ist die Rückfrage vor dem Download: Größe, Lizenz und Ladezeit stehen davor.
struct ModelNeedView: View {
    @EnvironmentObject var state: AppState
    let model: FlowModel
    /// wofür, schon übersetzt: „für Startbilder“
    var why: String = ""
    /// ein geladenes Modell, das es auch tut
    var alternative: FlowModel?
    var onUseAlternative: (() -> Void)?
    /// schmal (Studio-Eigenschaften): Text darunter
    var compact = false

    private var download: JobRecord? { state.jobs.first { $0.downloadModelID == model.id && !$0.isFinished } }
    private var failed: String? {
        guard let last = state.jobs.first(where: { $0.downloadModelID == model.id }), last.status == "error" else { return nil }
        return last.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(model.partial ? t("\(model.short) ist nur zum Teil geladen", "\(model.short) is only partly downloaded")
                      : t("\(model.short) fehlt", "\(model.short) is missing")).bold()
                 + Text(why.isEmpty ? "" : " \(why)."))
                Text(model.needLine + ".").foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.tokenMissing && download == nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t("Gesperrtes Modell: vorher Hugging-Face-Konto, Lizenz annehmen und Token unter „Einstellungen“ hinterlegen.",
                           "Gated model: first a Hugging Face account, accept the license and store a token under \"Settings\"."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(t("Zum Token", "To the token")) { state.selectedTab = "settings" }.buttonStyle(.link)
                }
            }
            if let download {
                HStack(spacing: 8) {
                    ProgressView(value: download.status == "queued" ? 0 : download.progress).tint(.green).frame(maxWidth: 180)
                    Text(download.status == "queued" ? t("wartet auf den Download", "waiting to download")
                         : "\(Int((download.progress * 100).rounded())) % · \(download.stage)")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button(t("Abbrechen", "Cancel")) { Task { _ = try? await JobQueue.shared.cancel(download.id) } }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button(model.partial ? t("Fortsetzen", "Resume") : t("Laden", "Download")) {
                        Task {
                            _ = await FlowCatalog.download(model.id)
                            await state.refresh()
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                    .disabled(model.tokenMissing)
                    .help(model.tokenMissing ? t("Erst die Lizenz auf Hugging Face annehmen und ein Token hinterlegen",
                                                 "First accept the license on Hugging Face and store a token") : model.warning)
                    if let alternative, let onUseAlternative {
                        Button(t("Lieber \(alternative.short) (geladen)", "Rather \(alternative.short) (downloaded)"), action: onUseAlternative)
                            .controlSize(.small)
                    }
                }
                if let failed { Text(failed).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .font(compact ? .caption : .callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { Rectangle().fill(Color.orange).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
