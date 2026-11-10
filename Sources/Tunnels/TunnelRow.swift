import SwiftUI
import TunnelsCore

struct TunnelRow: View {
    @EnvironmentObject var manager: TunnelManager
    let tunnel: Tunnel
    let state: TunnelState

    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            if !inside { confirmingDelete = false }
        }
    }

    private var leading: some View {
        HStack(spacing: 10) {
            Text(":\(String(tunnel.localPort))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.blue)
                .frame(minWidth: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.name).fontWeight(.medium).lineLimit(1)
                    StatusDot(status: state.status)
                    StatusText(state: state)
                }
                Text("\(tunnel.sshHost) → \(tunnel.remoteHost):\(String(tunnel.remotePort))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = visibleError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(err)
                }
            }
        }
    }

    private var isOpening: Bool { manager.opening.contains(tunnel.id) }

    /// Last error, shown while the tunnel is failing (error or retrying).
    private var visibleError: String? {
        if let e = state.openError { return e }
        guard state.status == .error || state.status == .reconnecting,
              let err = state.lastError, !err.isEmpty else { return nil }
        return err
    }

    @ViewBuilder private var trailing: some View {
        if confirmingDelete {
            HStack(spacing: 6) {
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete") { manager.delete(tunnel.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 0) {
                if hovering || isOpening {
                    if isOpening {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 22, height: 22)
                            .help("Connecting, then opening \(tunnel.browserURL?.absoluteString ?? "")")
                    } else {
                        IconButton(symbol: "arrow.up.forward.square",
                                   help: "Open \(tunnel.browserURL?.absoluteString ?? "")") { manager.openWhenReady(tunnel.id) }
                    }
                }
                if hovering {
                    IconButton(symbol: state.isActive ? "stop.fill" : "play.fill",
                               help: state.isActive ? "Stop" : "Start") { manager.toggle(tunnel.id) }
                    IconButton(symbol: "doc.on.doc", help: "Copy ssh command") { manager.copyCommand(tunnel) }
                    IconButton(symbol: "pencil", help: "Edit") { Windows.shared.openForm(editing: tunnel) }
                    IconButton(symbol: "trash", help: "Delete") { confirmingDelete = true }
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct StatusDot: View {
    let status: TunnelStatus

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .starting, .reconnecting: return .yellow
        case .stopped: return .gray
        case .error: return .red
        }
    }
}

struct StatusText: View {
    let state: TunnelState

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(state.status == .error ? Color.red : Color.secondary)
            .lineLimit(1)
    }

    private var label: String {
        switch state.status {
        case .connected: return "Connected"
        case .starting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }
}
