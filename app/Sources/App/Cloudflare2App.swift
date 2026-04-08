import AppKit

@MainActor
@main
enum CloudsparkApp {
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updateController: UpdateControlling = makeUpdateController()
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BuildNotificationManager.configure()
        statusController = StatusController(updateController: updateController)
        statusController?.start()
    }
}
