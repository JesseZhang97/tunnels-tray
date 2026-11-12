import AppKit
import SwiftUI
import TunnelsCore

/// Opens regular windows for the form and settings. A normal activated
/// NSWindow keeps keyboard focus, unlike sheets on a MenuBarExtra window.
@MainActor
final class Windows {
    static let shared = Windows()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ key: String, title: String, @ViewBuilder content: () -> V) {
        let window = windows[key] ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            windows[key] = w
            return w
        }()
        window.title = title
        window.contentViewController = NSHostingController(rootView: content())
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ key: String) {
        windows[key]?.close()
    }

    /// `localPort` pre-fills a different local port (e.g. a free one after a port conflict).
    func openForm(editing tunnel: Tunnel?, localPort: Int? = nil) {
        let m = TunnelManager.shared
        m.reloadSSHHosts()
        show("form", title: tunnel == nil ? "Add Tunnel" : "Edit Tunnel") {
            TunnelFormView(
                original: tunnel,
                hosts: m.sshHosts,
                others: m.tunnels.filter { $0.id != tunnel?.id },
                localPort: localPort,
                onSave: { t in
                    if tunnel == nil { m.add(t) } else { m.update(t) }
                    Windows.shared.close("form")
                },
                onCancel: { Windows.shared.close("form") }
            )
        }
    }

    func openSettings() {
        show("settings", title: "Tunnels Settings") {
            SettingsView().environmentObject(TunnelManager.shared)
        }
    }
}
