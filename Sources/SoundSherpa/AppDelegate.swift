import Cocoa

/// Thin lifecycle adaptor. `@NSApplicationDelegateAdaptor` instantiates this via `init()`, so
/// it reads the shared `DeviceController` directly rather than receiving one. All device I/O,
/// monitoring, and teardown live in `DeviceController`; this type only forwards the two app
/// lifecycle events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DeviceController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutDown()
    }
}
