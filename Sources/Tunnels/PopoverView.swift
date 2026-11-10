import SwiftUI
import TunnelsCore

struct PopoverView: View {
    @EnvironmentObject var manager: TunnelManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = manager.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button { manager.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Tunnels").font(.system(size: 14, weight: .bold))
            Spacer()
            Text("All").font(.caption).foregroundStyle(.secondary)
            Toggle("All", isOn: Binding(
                get: { manager.anyActive },
                set: { $0 ? manager.startAll() : manager.stopAll() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(manager.tunnels.isEmpty)
            .help("Start or stop all tunnels")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if manager.tunnels.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("No tunnels yet").foregroundStyle(.secondary)
                Button("Add Tunnel") { Windows.shared.openForm(editing: nil) }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if manager.tunnels.count > 7 {
            ScrollView { list }.frame(height: 420)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(manager.tunnels) { t in
                TunnelRow(tunnel: t, state: manager.state(for: t.id))
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { Windows.shared.openForm(editing: nil) } label: {
                Label("Add", systemImage: "plus")
            }
            Spacer()
            Button { Windows.shared.openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
