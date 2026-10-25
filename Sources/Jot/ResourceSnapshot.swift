import Foundation
import Combine
import Darwin
import JotCore

struct ResourceSnapshot: Codable {
    var valid = false
    var processCPUPercent: Double = 0
    var cpuValid = false
    var residentMiB: Double = 0
    var physicalFootprintMiB: Double = 0
    var systemMemoryGiB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1073741824
    var thermalState: String = "unknown"
    var uptimeSeconds: Double = 0
    var processID: Int32 = getpid()
    var sampleTimestamp: Date = Date()
    var acceleratorPolicy = "Core ML: CPU + Neural Engine requested; actual placement not measured"

    var cpuText: String { valid && cpuValid ? String(format: "%.1f%%", processCPUPercent) : "—" }
    var memoryText: String { valid ? String(format: "%.0f MB", residentMiB) : "—" }
}

/// Frequently changing meters have their own observation boundary. Sampling them
/// must not invalidate every view that observes the speech service.
@MainActor final class ResourceReadout: ObservableObject {
    @Published var snapshot = ResourceSnapshot()
    private let sampler = ResourceSampler()
    private var visibleReaders: Set<UUID> = []
    private var timer: Timer?
    private var timerGeneration: UInt64 = 0
    private var settling = false
    var isRefreshingVisibleMeters: Bool { !visibleReaders.isEmpty }

    /// The service's existing tick supplies background samples. Visible readers
    /// share a separate meter-only timer, leaving capture/housekeeping cadence alone.
    func refresh() {
        guard timer == nil else { return }
        snapshot = sampler.sample()
    }

    /// Memory is current immediately; CPU needs an interval wholly after the change.
    func stateChanged() {
        snapshot = sampler.sample(resetCPU: true)
        settling = true
        stopTimer()
        let generation = timerGeneration
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.finishInterval(generation: generation) }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setVisible(_ visible: Bool, reader: UUID) {
        if visible {
            let first = visibleReaders.isEmpty
            guard visibleReaders.insert(reader).inserted else { return }
            if first { stateChanged() }
        } else {
            visibleReaders.remove(reader)
            if visibleReaders.isEmpty && !settling { stopTimer() }
        }
    }

    private func finishInterval(generation: UInt64) {
        guard timer != nil, generation == timerGeneration else { return }
        snapshot = sampler.sample()
        settling = false
        if visibleReaders.isEmpty { stopTimer() }
    }

    private func stopTimer() {
        timerGeneration &+= 1
        timer?.invalidate()
        timer = nil
    }

    func shutdown() {
        stopTimer()
        visibleReaders.removeAll()
        settling = false
    }
}
