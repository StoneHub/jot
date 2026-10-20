import XCTest
@testable import JotCore

final class InstallPlacementTests: XCTestCase {
    private let target = "/Applications/Jot.app"
    private func decide(path: String = "/Users/me/Downloads/Jot.app", running: String? = "0.3.4", installed: String? = "0.3.3",
                        exists: Bool = true, installedRunning: Bool = false, declined: Bool = false) -> InstallPlacement {
        InstallPlacement.decide(runningPath: path, installPath: target, running: running.flatMap(SemanticVersion.parse),
                                installed: installed.flatMap(SemanticVersion.parse), installedExists: exists,
                                installedIsRunning: installedRunning, declinedInstall: declined)
    }

    func testInstalledCopyStays() {
        XCTAssertEqual(decide(path: target), .stay)
    }

    func testFirstDownloadOffersInstallUnlessDeclined() {
        XCTAssertEqual(decide(installed: nil, exists: false), .offerInstall)
        XCTAssertEqual(decide(installed: nil, exists: false, declined: true), .stay)
    }

    func testNewerDownloadOffersReplaceInsteadOfOpeningTheOlderCopy() {
        XCTAssertEqual(decide(), .offerReplace(installed: SemanticVersion.parse("0.3.3")!))
        XCTAssertEqual(decide(installedRunning: true), .installedRunning)
    }

    func testSameOrOlderCopyOpensTheInstalledOne() {
        XCTAssertEqual(decide(running: "0.3.3"), .openInstalled)
        XCTAssertEqual(decide(running: "0.3.2"), .openInstalled)
        XCTAssertEqual(decide(installed: nil), .openInstalled, "An unreadable installed version keeps the old hand-off")
        XCTAssertEqual(decide(declined: true), .openInstalled, "Declining a first install does not hide an installed copy")
    }
}
