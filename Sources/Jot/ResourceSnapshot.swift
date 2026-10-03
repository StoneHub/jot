import Foundation
import Combine
import Darwin
import JotCore

struct ResourceSnapshot: Codable {
    var valid = false
    var processCPUPercent: Double = 0
    var residentMiB: Double = 0
    var physicalFootprintMiB: Double = 0
    var systemMemoryGiB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1073741824
    var thermalState: String = "unknown"
    var uptimeSeconds: Double = 0
    var processID: Int32 = getpid()
    var sampleTimestamp: Date = Date()
    var acceleratorPolicy = "Core ML: CPU + Neural Engine requested; actual placement not measured"
}

/// Frequently changing meters have their own observation boundary. Sampling them
/// must not invalidate every view that observes the speech service.
@MainActor final class ResourceReadout: ObservableObject {
    @Published var snapshot = ResourceSnapshot()
}
