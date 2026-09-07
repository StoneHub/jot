import Foundation
import Darwin
import IOKit.ps
import JotCore

struct ResourceSnapshot: Codable {
    var battery = BatteryUsage()
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

final class ResourceSampler {
    private var battery = BatteryUsage()
    private var previousCPU: UInt64 = 0
    private var previousTime = ProcessInfo.processInfo.systemUptime
    private let began = ProcessInfo.processInfo.systemUptime
    private func sampleBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            battery.observe(level: nil, onBattery: nil)
            return
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0,
                  let state = description[kIOPSPowerSourceStateKey] as? String,
                  [kIOPSBatteryPowerValue, kIOPSACPowerValue].contains(state) else { continue }
            battery.observe(level: current.doubleValue / maximum.doubleValue * 100,
                            onBattery: state == kIOPSBatteryPowerValue)
            return
        }
        battery.observe(level: nil, onBattery: nil)
    }

    func sample() -> ResourceSnapshot {
        var info = rusage_info_v4()
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        var value = ResourceSnapshot()
        if code == 0 {
            let cpu = info.ri_user_time + info.ri_system_time
            if previousCPU > 0, now > previousTime { value.processCPUPercent = Double(cpu - previousCPU) / 1e9 / (now - previousTime) * 100 }
            value.residentMiB = Double(info.ri_resident_size) / 1048576
            value.physicalFootprintMiB = Double(info.ri_phys_footprint) / 1048576
            previousCPU = cpu
        }
        previousTime = now
        sampleBattery()
        value.battery = battery
        value.uptimeSeconds = now - began
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: value.thermalState = "nominal"
        case .fair: value.thermalState = "fair"
        case .serious: value.thermalState = "serious"
        case .critical: value.thermalState = "critical"
        @unknown default: value.thermalState = "unknown"
        }
        return value
    }
}
