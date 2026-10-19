import Foundation
import Darwin

/// Angaben zum Rechner – für die Modellwahl nach Arbeitsspeicher und für den Messbericht.
enum SystemInfo {
    static let chip: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Apple Silicon" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }()

    /// Arbeitsspeicher in GB, gerundet (8, 16, 24, 32 …).
    static let memoryGB: Int = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    static var memoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }

    static var macOS: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Speicherbedarf des Prozesses wie in der Aktivitätsanzeige (phys_footprint).
    /// Auf Apple Silicon gehören die GPU-Puffer von MLX dazu – genau die Zahl, die zählt.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Misst während eines Auftrags alle 250 ms den Speicherbedarf und merkt sich die Spitze.
final class PeakMemorySampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nvai.peak-memory")
    private var timer: DispatchSourceTimer?
    private var peak: Double = 0

    func start() {
        queue.sync {
            peak = SystemInfo.footprintMB()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.peak = max(self.peak, SystemInfo.footprintMB())
            }
            t.resume()
            timer = t
        }
    }

    /// Beendet die Messung und liefert die Spitze in MB.
    func stop() -> Double {
        queue.sync {
            timer?.cancel()
            timer = nil
            return max(peak, SystemInfo.footprintMB())
        }
    }
}
