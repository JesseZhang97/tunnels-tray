import AppKit
import SwiftUI
import TunnelsCore

/// Renders the real views with neutral demo data into PNGs (2x), light and dark.
/// Uses offscreen windows, so it needs no screen-recording permission.
@MainActor
enum Snapshots {
    static func run(outputDirectory: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manager = Demo.manager()
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            render(PopoverView().environmentObject(manager), name, dir, "popover-\(suffix).png")
            render(TunnelFormView(original: Demo.formTunnel, hosts: Demo.hosts, others: [],
                                  testSteps: Demo.testSteps, onSave: { _ in }, onCancel: {}),
                   name, dir, "form-\(suffix).png")
            render(SettingsView().environmentObject(manager), name, dir, "settings-\(suffix).png")
            render(MenuBarLabel(count: 2, showCount: true)
                       .font(.system(size: 14))
                       .padding(.horizontal, 10).padding(.vertical, 4),
                   name, dir, "menubar-\(suffix).png")
        }
    }

    private static func render<V: View>(_ view: V, _ appearanceName: NSAppearance.Name, _ dir: URL, _ file: String) {
        guard let appearance = NSAppearance(named: appearanceName) else { return }
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<3 {
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let size = host.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { print("skip \(file): empty size"); return }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let url = dir.appendingPathComponent(file)
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
            print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))")
        }
        window.close()
    }
}

/// Neutral demo data for screenshots.
@MainActor
enum Demo {
    static let hosts = ["my-server", "bastion", "monitoring-host", "gpu-box", "example-host"]

    static let webApp = Tunnel(name: "My Web App", sshHost: "my-server", localPort: 8080,
                               remotePort: 8080, note: "Admin dashboard")
    static let grafana = Tunnel(name: "Grafana", sshHost: "monitoring-host", localPort: 3000, remotePort: 3000)
    static let pgAdmin = Tunnel(name: "Database Admin", sshHost: "bastion", localPort: 5050,
                                remoteHost: "10.0.0.12", remotePort: 80)
    static let jupyter = Tunnel(name: "Jupyter", sshHost: "gpu-box", localPort: 8888, remotePort: 8888)
    static let docs = Tunnel(name: "Docs Preview", sshHost: "example-host", localPort: 4000, remotePort: 4000)

    static var formTunnel: Tunnel {
        var t = webApp
        t.sshOptions = "-o User=deploy -o IdentityFile=~/.ssh/id_ed25519 -o Compression=yes -o ProxyJump=bastion"
        return t
    }

    static let testSteps: [ConnectionTest.Step] = [
        .init(kind: .localPort, state: .passed("127.0.0.1:8080 is free")),
        .init(kind: .login, state: .passed("Logged in")),
        .init(kind: .remote, state: .passed("127.0.0.1:8080 accepted the connection")),
    ]

    static func manager() -> TunnelManager {
        let tunnels = [webApp, grafana, pgAdmin, jupyter, docs]
        let states: [UUID: TunnelState] = [
            webApp.id: TunnelState(status: .connected, pid: 4101),
            grafana.id: TunnelState(status: .connected, pid: 4102),
            pgAdmin.id: TunnelState(status: .starting, pid: 4103),
            jupyter.id: TunnelState(status: .error, lastError: "Port 8888 is in use by python3 (pid 4242)"),
        ]
        return TunnelManager(demoTunnels: tunnels, states: states, hosts: hosts,
                             storeURL: URL(fileURLWithPath: "/Users/you/Library/Application Support/Tunnels/tunnels.json"),
                             hoverID: grafana.id)
    }
}
