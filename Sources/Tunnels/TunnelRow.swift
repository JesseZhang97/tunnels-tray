import SwiftUI
import TunnelsCore

struct TunnelRow: View {
    @EnvironmentObject var manager: TunnelManager
    let tunnel: Tunnel
    let state: TunnelState
    @Binding var isExpanded: Bool

    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                leading
                    .help("Open \(tunnel.browserURL?.absoluteString ?? "")")
                Spacer(minLength: 4)
                trailing
            }
            .contentShape(Rectangle())
            .onTapGesture { manager.openInBrowser(tunnel) }

            if isExpanded {
                details.transition(.opacity.combined(with: .move(edge: .top)))
            }
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
            }
        }
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
                if hovering {
                    IconButton(symbol: state.isActive ? "stop.fill" : "play.fill",
                               help: state.isActive ? "Stop" : "Start") { manager.toggle(tunnel.id) }
                    IconButton(symbol: "doc.on.doc", help: "Copy ssh command") { manager.copyCommand(tunnel) }
                    IconButton(symbol: "pencil", help: "Edit") { Windows.shared.openForm(editing: tunnel) }
                    IconButton(symbol: "trash", help: "Delete") { confirmingDelete = true }
                }
                IconButton(symbol: "chevron.right", help: isExpanded ? "Hide details" : "Show details") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SSHCommand.commandLine(for: tunnel))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
            DetailLine(label: "PID", value: state.pid.map { String($0) } ?? "—")
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                DetailLine(label: "Uptime", value: state.connectedAt.map { formatDuration(ctx.date.timeIntervalSince($0)) } ?? "—")
            }
            if !tunnel.note.isEmpty {
                DetailLine(label: "Note", value: tunnel.note)
            }
            if let err = state.lastError {
                DetailLine(label: "Last error", value: err, color: .red)
            }
        }
        .font(.caption)
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

struct DetailLine: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).foregroundStyle(color).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(label(now: ctx.date))
                .font(.caption2)
                .foregroundStyle(state.status == .error ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }

    private func label(now: Date) -> String {
        switch state.status {
        case .connected:
            return state.connectedAt.map { formatDuration(now.timeIntervalSince($0)) } ?? "Up"
        case .starting: return "Connecting…"
        case .reconnecting:
            if let t = state.nextRetryAt, t > now { return "Retry in \(Int(t.timeIntervalSince(now).rounded(.up)))s" }
            return "Reconnecting…"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
    return "\(s / 86400)d \(s % 86400 / 3600)h"
}
