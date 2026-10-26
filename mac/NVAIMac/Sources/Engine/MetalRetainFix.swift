import Foundation
import Metal
import ObjectiveC

/// Gegen MLX-Fehler #3689 (seit 0.4.7): MLX legt seine GPU-Aufträge mit `commandBufferWithUnretainedReferences` an,
/// Metal hält die benutzten Puffer dann nicht fest. Räumt MLX seinen Pufferspeicher auf (Cache über dem Limit oder
/// Speicher nahe der Grenze), während ein Auftrag noch läuft, gibt es einen Puffer frei, den die GPU noch braucht, und
/// die App bricht mit „Invalid Resource (kIOGPUCommandBufferCallbackErrorInvalidResource)“ ab.
///
/// Gemessen am 25.10.2026 auf dem Mac mini M1 (8 GB): SeedVR2 direkt nach FLUX.2 (das das Cache-Limit auf 512 MB
/// setzt) stürzte dreimal beim ersten Kachel ab, allein lief es durch. Der Fix in MLX (#3688) nimmt `commandBuffer`
/// mit gehaltenen Referenzen; mlx-swift 0.31.6 bringt ihn noch nicht mit. Bis dahin leitet NVAI-open den Aufruf beim
/// Start auf `commandBuffer` um – für alle Warteschlangen dieses Prozesses, Metal hält die Puffer dann bis zum Ende.
enum MetalRetainFix {
    static func apply() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let cls = object_getClass(queue) else { return }
        let unretained = NSSelectorFromString("commandBufferWithUnretainedReferences")
        let retained = NSSelectorFromString("commandBuffer")
        guard let from = class_getInstanceMethod(cls, unretained), let to = class_getInstanceMethod(cls, retained) else {
            AppLog.error("Metal: could not redirect unretained command buffers (MLX #3689)")
            return
        }
        method_setImplementation(from, method_getImplementation(to))
        AppLog.info("Metal: command buffers keep their resources (MLX #3689 workaround, \(NSStringFromClass(cls)))")
    }
}
