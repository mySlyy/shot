import AppKit

/// Bundle identifier (single Swift source; must match Resources/Info.plist and Resources/update_signer.req).
let appBundleID = "ai.slyy.shot"

// Menu bar only (LSUIElement + accessory policy): no Dock icon, no main window.
@main
enum SlyyShotApp {
    @MainActor
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
