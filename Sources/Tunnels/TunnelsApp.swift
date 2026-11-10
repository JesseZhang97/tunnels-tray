import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `Tunnels --snapshot <dir>` renders README screenshots with demo data and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : "docs/screenshots"
            MainActor.assumeIsolated { Snapshots.run(outputDirectory: dir) }
            return
        }
        TunnelsApp.main()
    }
}

struct TunnelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TunnelManager.shared
    @AppStorage(Prefs.showConnectionCount) private var showConnectionCount = true

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(manager)
        } label: {
            MenuBarLabel(count: manager.connectedCount, showCount: showConnectionCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon, followed by the connected count when enabled and non-zero.
struct MenuBarLabel: View {
    let count: Int
    let showCount: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0
                ? "point.3.filled.connected.trianglepath.dotted"
                : "point.3.connected.trianglepath.dotted")
            if showCount && count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }
}

enum Prefs {
    /// Show the number of connected tunnels next to the menu bar icon.
    static let showConnectionCount = "showConnectionCount"
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
