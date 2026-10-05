import XCTest

/// Placeholder until the flows are written: starts the app and photographs it.
final class T2UITests: XCTestCase {
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-t2Reset", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "launch"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
