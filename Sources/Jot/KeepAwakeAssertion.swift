import Foundation
import IOKit.pwr_mgt

/// Holds macOS's idle-sleep assertion only while Jot is actively listening.
/// Manual sleep, lid close, shutdown, and battery-critical sleep still work normally.
final class KeepAwakeAssertion {
    private var identifier: IOPMAssertionID = 0

    var isActive: Bool { identifier != 0 }

    func setActive(_ active: Bool) {
        if active { acquire() }
        else { release() }
    }

    private func acquire() {
        guard identifier == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Jot is listening" as CFString,
            &identifier
        )
        if result != kIOReturnSuccess { identifier = 0 }
    }

    private func release() {
        guard identifier != 0 else { return }
        IOPMAssertionRelease(identifier)
        identifier = 0
    }

    deinit { release() }
}
