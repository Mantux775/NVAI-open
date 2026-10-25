import Foundation

/// Foto restaurieren (`POST /api/image/restore`, seit 0.4.6): dieselben Felder wie `RestoreImageRequest` unter
/// Windows. Der Mac kann davon gründlich restaurieren und einfärben, beides mit FLUX.2 Klein. Schonend
/// (`gentle`) und Schärfen (SeedVR2) gibt es nur unter Windows; „auto“ rechnet hier gründlich, denn die Wahl
/// trifft unter Windows ein Bild-Sprachmodell, und der Text-Encoder von FLUX.2 Klein sieht keine Bilder.
struct RestoreJobRequest: Sendable {
    var imageAssetID: String
    var repair: Bool
    var repairMode: String
    var colorize: Bool
    var notes: String
    var modelID: String
    var megapixels: Double?
    var batch: Int
    var seed: UInt64?
    var params: JSONValue
    var lang: Lang = Lang.current

    /// Anweisungen wie unter Windows (`jobs.RESTORE_REPAIR`, `jobs.RESTORE_COLORIZE`); die Hinweise hängen hinten an.
    static let repairInstruction =
        "Restore this old damaged photograph: remove all scratches, dust spots, cracks, stains, creases, tears "
        + "and emulsion damage, and fill damaged areas so they blend in seamlessly. Keep the composition, every "
        + "person, their faces, expressions, poses and clothing, and the original tones of the photograph exactly "
        + "the same."
    static let colorizeInstruction =
        "Colorize this black-and-white photograph with natural, realistic colors. Keep the composition, every "
        + "person, their faces, expressions and poses and every detail exactly the same."

    /// Arbeitsgröße von FLUX.2 Klein: Gemessen auf dem M1 mit 8 GB brauchte ein Foto mit 0,75 MP 163–174 s;
    /// mehr Speicher verträgt 1 MP. Eingefärbt wird kleiner, von dort kommt nur die Farbe.
    static var repairMegapixels: Double { SystemInfo.memoryGB <= 16 ? 0.75 : 1.0 }
    static var colorizeMegapixels: Double { SystemInfo.memoryGB <= 16 ? 0.5 : 0.75 }

    static func parse(_ body: JSONValue?) throws -> RestoreJobRequest {
        guard let body, case .object(let o) = body else {
            throw APIError(422, t("Erwartet wird ein JSON-Objekt (RestoreImageRequest).", "Expected a JSON object (RestoreImageRequest)."))
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { o[key]?.boolValue ?? fallback }
        guard let image = o["image_asset_id"]?.stringValue, !image.isEmpty else {
            throw APIError(422, t("Das Feld image_asset_id fehlt.", "The field image_asset_id is missing."))
        }
        let repair = flag("repair", true), colorize = flag("colorize", false)
        if flag("sharpen", false) {
            throw APIError(422, t("Schärfen braucht SeedVR2 und gibt es nur in NVAI-open für Windows.",
                                  "Sharpening needs SeedVR2 and is only available in NVAI-open for Windows."))
        }
        guard repair || colorize else {
            throw APIError(422, t("Bitte mindestens einen Schritt wählen: Schäden entfernen oder Einfärben.",
                                  "Please choose at least one step: remove damage or colorize."))
        }
        let mode = o["repair_mode"]?.stringValue ?? "auto"
        guard ["auto", "thorough", "gentle"].contains(mode) else {
            throw APIError(422, t("repair_mode muss auto, thorough oder gentle sein.", "repair_mode must be auto, thorough or gentle."))
        }
        if repair && mode == "gentle" {
            throw APIError(422, t("Schonend restaurieren gibt es nur in NVAI-open für Windows; auf dem Mac rechnet NVAI-open "
                                  + "gründlich (repair_mode thorough oder auto).",
                                  "Gentle restoring is only available in NVAI-open for Windows; on the Mac NVAI-open restores "
                                  + "thoroughly (repair_mode thorough or auto)."))
        }
        let notes = (o["notes"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard notes.count <= 2000 else { throw APIError(422, t("notes ist zu lang (höchstens 2000 Zeichen).", "notes is too long (at most 2000 characters).")) }
        let batch = o["batch_size"]?.intValue ?? 1
        guard (1...4).contains(batch) else { throw APIError(422, t("batch_size muss zwischen 1 und 4 liegen.", "batch_size must be between 1 and 4.")) }
        var megapixels: Double?
        if let v = o["megapixels"], !v.isNull {
            guard let mp = v.doubleValue, (0.5...4).contains(mp) else {
                throw APIError(422, t("megapixels muss zwischen 0,5 und 4 liegen.", "megapixels must be between 0.5 and 4."))
            }
            megapixels = mp
        }
        let seed = o["seed"]?.intValue
        if let seed, seed < 0 { throw APIError(422, t("seed darf nicht negativ sein.", "seed must not be negative.")) }

        // Bearbeitet wird mit einem Modell, das Referenzbilder nimmt: FLUX.2 Klein (Core ML kann das nicht).
        let model: CatalogModel
        if let id = o["model_id"]?.stringValue, !id.isEmpty {
            guard let found = Models.find(id) else { throw APIError(404, t("Unbekanntes Modell: \(id)", "Unknown model: \(id)")) }
            guard case .flux(let m) = found else {
                throw APIError(422, t("„\(found.name)“ bearbeitet keine Bilder. Restaurieren und Einfärben brauchen FLUX.2 Klein.",
                                      "\"\(found.name)\" does not edit images. Restoring and colorizing need FLUX.2 Klein."))
            }
            model = m
        } else if case .flux(let m) = Models.active, ModelCatalog.status(m).installed {
            model = m
        } else if let m = Models.expansionModel {
            model = m
        } else {
            throw APIError(409, t("Restaurieren und Einfärben brauchen FLUX.2 Klein. Bitte unter „Modelle“ laden.",
                                  "Restoring and colorizing need FLUX.2 Klein. Please download it under \"Models\"."))
        }
        guard ModelCatalog.status(model).installed else {
            throw APIError(409, t("„\(model.name)“ ist nicht geladen. In NVAI-open unter „Modelle“ herunterladen.",
                                  "\"\(model.name)\" is not downloaded. Download it in NVAI-open under \"Models\"."))
        }
        return RestoreJobRequest(imageAssetID: image, repair: repair, repairMode: mode, colorize: colorize, notes: notes,
                                 modelID: model.id, megapixels: megapixels, batch: batch, seed: seed.map { UInt64($0) },
                                 params: body)
    }

    /// Arbeitsformat im Seitenverhältnis des Fotos: Vielfache von 16, höchstens das Foto selbst (mindestens
    /// 0,25 MP), je Seite höchstens 2048 – wie `jobs._restore_size` unter Windows.
    static func workingSize(_ width: Int, _ height: Int, megapixels: Double) -> (width: Int, height: Int) {
        let photo = Double(width * height) / 1_048_576
        let target = min(megapixels, max(0.25, photo)) * 1_048_576
        let k = min((target / Double(width * height)).squareRoot(), 2048 / Double(max(width, height)))
        func round16(_ v: Double) -> Int { max(256, Int((v / 16).rounded()) * 16) }
        return (round16(Double(width) * k), round16(Double(height) * k))
    }
}
