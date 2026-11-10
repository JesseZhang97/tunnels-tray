import AppKit
import SwiftUI

@main
struct TunnelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TunnelManager.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(manager)
        } label: {
            Image(systemName: manager.anyConnected
                ? "point.3.filled.connected.trianglepath.dotted"
                : "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Kill ssh children on SIGTERM/SIGINT/SIGHUP too, not only on Quit.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { TunnelManager.shared.shutdown() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TunnelManager.shared.shutdown() }
    }
}
