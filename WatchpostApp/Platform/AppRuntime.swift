import Foundation

/// Whether unit tests are driving the app right now. Nothing that reports to the outside world
/// starts then, so a test run never sends a crash, a purchase or a screen count of its own.
enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
