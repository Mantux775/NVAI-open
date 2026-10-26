import Foundation
import MLX

/// Speicherstand fürs Protokoll (seit 0.4.7): MLX aktiv, Zwischenspeicher, Spitze und der Prozess. Beim Restaurieren
/// wechseln auf 8-GB-Macs bis zu drei Modelle (Qwen3.5, FLUX.2, SeedVR2); das Protokoll zeigt, welcher Schritt eng
/// wird. Gemessen am 25.10.2026: ein GPU-Abbruch (MLX check_error) nach dem Wechsel Qwen3.5 → FLUX.2.
enum MemoryLog {
    static func line(_ label: String) {
        let mb = 1_048_576.0
        AppLog.info(String(format: "Memory %@: MLX active %.0f MB, cache %.0f MB, peak %.0f MB, process %.0f MB", label,
                           Double(Memory.activeMemory) / mb, Double(Memory.cacheMemory) / mb,
                           Double(Memory.peakMemory) / mb, SystemInfo.footprintMB()))
    }

    /// Zwischenspeicher von MLX freigeben, bevor ein anderes Modell lädt.
    static func release() {
        Memory.clearCache()
    }
}
