import Foundation

/// Ein Bildmodell, gleich mit welcher Engine: FLUX.2 Klein über MLX oder Stable Diffusion über Core ML.
enum AnyModel: Identifiable, Equatable {
    case flux(CatalogModel)
    case coreml(CoreMLModel)

    var id: String {
        switch self {
        case .flux(let m): return m.id
        case .coreml(let m): return m.id
        }
    }

    var name: String {
        switch self {
        case .flux(let m): return m.name
        case .coreml(let m): return m.name
        }
    }

    var workflow: String {
        switch self {
        case .flux(let m): return m.workflow
        case .coreml(let m): return m.workflow
        }
    }

    var engine: String {
        switch self {
        case .flux: return "mlx"
        case .coreml: return "coreml"
        }
    }

    var installed: Bool {
        switch self {
        case .flux(let m): return ModelCatalog.status(m).installed
        case .coreml(let m): return CoreMLCatalog.isInstalled(m)
        }
    }

    var partiallyInstalled: Bool {
        switch self {
        case .flux(let m): return ModelCatalog.status(m).partial
        case .coreml: return false
        }
    }

    var fits: String {
        switch self {
        case .flux(let m): return ModelCatalog.fits(m)
        case .coreml(let m): return CoreMLCatalog.fits(m)
        }
    }

    var downloadGB: Double {
        switch self {
        case .flux(let m): return m.downloadGB
        case .coreml(let m): return m.sizeGb
        }
    }

    var info: [String: Any] {
        switch self {
        case .flux(let m): return ModelCatalog.info(m)
        case .coreml(let m): return CoreMLCatalog.info(m)
        }
    }

    var features: [String: Any] {
        switch self {
        case .flux(let m): return ModelCatalog.features(m)
        case .coreml(let m): return CoreMLCatalog.features(m)
        }
    }
}

enum Models {
    static var all: [AnyModel] {
        ModelCatalog.all.map { AnyModel.flux($0) } + CoreMLCatalog.all.map { AnyModel.coreml($0) }
    }

    static func find(_ id: String?) -> AnyModel? {
        guard let id else { return nil }
        if let m = ModelCatalog.model(id) { return .flux(m) }
        if let m = CoreMLCatalog.model(id) { return .coreml(m) }
        return nil
    }

    /// Gewähltes Modell; sonst das erste geladene (FLUX.2 vor Core ML); sonst die Empfehlung.
    static var active: AnyModel {
        if let chosen = find(Settings.activeModelID) { return chosen }
        if let flux = ModelCatalog.all.first(where: { ModelCatalog.status($0).installed }) { return .flux(flux) }
        if let sd = CoreMLCatalog.all.first(where: { CoreMLCatalog.isInstalled($0) }) { return .coreml(sd) }
        return .flux(ModelCatalog.recommended)
    }
}
