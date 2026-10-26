import Foundation

/// Ein Bildmodell, gleich mit welcher Engine: FLUX.2 Klein über MLX, Stable Diffusion über Core ML oder
/// Z-Image Turbo über MLX (seit 0.4.7).
enum AnyModel: Identifiable, Equatable {
    case flux(CatalogModel)
    case coreml(CoreMLModel)
    case zimage(ZImageModel)

    var id: String {
        switch self {
        case .flux(let m): return m.id
        case .coreml(let m): return m.id
        case .zimage(let m): return m.id
        }
    }

    var name: String {
        switch self {
        case .flux(let m): return m.name
        case .coreml(let m): return m.name
        case .zimage(let m): return m.name
        }
    }

    var workflow: String {
        switch self {
        case .flux(let m): return m.workflow
        case .coreml(let m): return m.workflow
        case .zimage(let m): return m.workflow
        }
    }

    var engine: String {
        switch self {
        case .flux: return "mlx"
        case .coreml: return "coreml"
        case .zimage: return "zimage"
        }
    }

    var installed: Bool {
        switch self {
        case .flux(let m): return ModelCatalog.status(m).installed
        case .coreml(let m): return CoreMLCatalog.isInstalled(m)
        case .zimage(let m): return m.installed
        }
    }

    var partiallyInstalled: Bool {
        switch self {
        case .flux(let m): return ModelCatalog.status(m).partial
        case .coreml, .zimage: return false
        }
    }

    var fits: String {
        switch self {
        case .flux(let m): return ModelCatalog.fits(m)
        case .coreml(let m): return CoreMLCatalog.fits(m)
        case .zimage(let m): return ZImageCatalog.fits(m)
        }
    }

    var downloadGB: Double {
        switch self {
        case .flux(let m): return m.downloadGB
        case .coreml(let m): return m.sizeGb
        case .zimage(let m): return m.downloadGB
        }
    }

    var info: [String: Any] {
        switch self {
        case .flux(let m): return ModelCatalog.info(m)
        case .coreml(let m): return CoreMLCatalog.info(m)
        case .zimage(let m): return ZImageCatalog.info(m)
        }
    }

    var features: [String: Any] {
        switch self {
        case .flux(let m): return ModelCatalog.features(m)
        case .coreml(let m): return CoreMLCatalog.features(m)
        case .zimage(let m): return ZImageCatalog.features(m)
        }
    }
}

enum Models {
    static var all: [AnyModel] {
        ModelCatalog.all.map { AnyModel.flux($0) } + ZImageCatalog.all.map { AnyModel.zimage($0) }
            + CoreMLCatalog.all.map { AnyModel.coreml($0) }
    }

    static func find(_ id: String?) -> AnyModel? {
        guard let id else { return nil }
        if let m = ModelCatalog.model(id) { return .flux(m) }
        if let m = CoreMLCatalog.model(id) { return .coreml(m) }
        if let m = ZImageCatalog.model(id) { return .zimage(m) }
        return nil
    }

    /// Für „Prompt ausbauen“: das gewählte FLUX.2-Modell, sonst ein geladenes. Nil, wenn keines da ist.
    static var expansionModel: CatalogModel? {
        if case .flux(let m)? = find(Settings.activeModelID), ModelCatalog.status(m).installed { return m }
        return ModelCatalog.all.first { ModelCatalog.status($0).installed }
    }

    /// Gewähltes Modell; sonst das erste geladene (FLUX.2 vor Core ML); sonst die Empfehlung.
    static var active: AnyModel {
        if let chosen = find(Settings.activeModelID) { return chosen }
        if let flux = ModelCatalog.all.first(where: { ModelCatalog.status($0).installed }) { return .flux(flux) }
        if let sd = CoreMLCatalog.all.first(where: { CoreMLCatalog.isInstalled($0) }) { return .coreml(sd) }
        return .flux(ModelCatalog.recommended)
    }
}
