import AppKit
import SwiftUI
import TunnelsCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var manager: TunnelManager
    @State private var message: String?
    @AppStorage(Prefs.showConnectionCount) private var showConnectionCount = true

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("File") {
                    Text(manager.store.url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Tunnels") { Text("\(manager.tunnels.count)") }
                HStack {
                    Button("Import JSON…", action: importJSON)
                    Button("Export JSON…", action: exportJSON)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([manager.store.url])
                    }
                }
            }
            Section("Menu bar") {
                Toggle("Show connection count in menu bar", isOn: $showConnectionCount)
            }
            Section("SSH") {
                LabeledContent("Hosts in ~/.ssh/config") { Text("\(manager.sshHosts.count)") }
                Button("Reload ~/.ssh/config") { manager.reloadSSHHosts() }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let tunnels = try TunnelStore.decode(Data(contentsOf: url))
            manager.importTunnels(tunnels)
            message = "Imported \(tunnels.count) tunnel(s) from \(url.lastPathComponent)."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tunnels.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TunnelStore.encode(manager.tunnels).write(to: url, options: .atomic)
            message = "Exported \(manager.tunnels.count) tunnel(s) to \(url.path)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}
