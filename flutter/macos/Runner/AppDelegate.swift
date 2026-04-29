import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      dummy_method_to_enforce_bundling()
    // https://github.com/leanflutter/window_manager/issues/214
    return false
  }
    
    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if (launched) {
            handle_applicationShouldOpenUntitledFile();
        }
        return true
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true;
        // Callmor: enforce single instance. If another copy of this bundle is
        // already running, activate it and exit this one immediately.
        if let bundleId = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { $0.processIdentifier != me }
            if let other = others.first {
                NSLog("[Callmor] Another instance is running (pid %d) — activating it and exiting this one", other.processIdentifier)
                other.activate(options: [.activateIgnoringOtherApps])
                NSApplication.shared.terminate(nil)
                return
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true);
    }

    // Callmor: when the user re-activates the app (clicks tray's Open, opens via Spotlight, etc.)
    // and there are no visible windows, bring the main window back.
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApplication.shared.windows {
                window.makeKeyAndOrderFront(nil)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        return true
    }
}
