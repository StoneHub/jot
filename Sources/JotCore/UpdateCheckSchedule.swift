import Foundation

/// When the daily update check may ask GitHub again. Every answered check counts, a press of Check for updates included,
/// so Jot asks about once a day at most.
public enum UpdateCheckSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A last check in the future means the clock went back; check now instead of waiting out the difference.
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
    }

    public static func lastCheck(in defaults: UserDefaults) -> Date? {
        defaults.object(forKey: JotDefaultsKey.lastUpdateCheck) as? Date
    }

    public static func recordCheck(in defaults: UserDefaults, at date: Date) {
        defaults.set(date, forKey: JotDefaultsKey.lastUpdateCheck)
    }
}
