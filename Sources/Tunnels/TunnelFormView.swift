import SwiftUI
import TunnelsCore

struct TunnelFormView: View {
    let original: Tunnel?
    let hosts: [String]
    let others: [Tunnel]
    let onSave: (Tunnel) -> Void
    let onCancel: () -> Void

    @State private var draft: TunnelDraft

    init(original: Tunnel?, hosts: [String], others: [Tunnel],
         onSave: @escaping (Tunnel) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.hosts = hosts
        self.others = others
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: original.map(TunnelDraft.init) ?? TunnelDraft())
    }

    private var warnings: [String] {
        guard let port = TunnelDraft.parsePort(draft.localPort) else { return [] }
        return others.filter { $0.localPort == port }
            .map { "Local port \(port) is also used by “\($0.name)”." }
    }

    private var showErrors: Bool { draft != (original.map(TunnelDraft.init) ?? TunnelDraft()) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("NMcloud"))
                LabeledContent("SSH host") {
                    HStack(spacing: 4) {
                        TextField("SSH host", text: $draft.sshHost, prompt: Text("taiwan-nmcloud"))
                            .labelsHidden()
                        Menu {
                            if hosts.isEmpty {
                                Text("No hosts in ~/.ssh/config")
                            }
                            ForEach(hosts, id: \.self) { h in
                                Button(h) { draft.sshHost = h }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Pick a Host from ~/.ssh/config")
                    }
                }
                TextField("Local port", text: $draft.localPort, prompt: Text("18317"))
                TextField("Remote host", text: $draft.remoteHost, prompt: Text(Tunnel.defaultRemoteHost))
                TextField("Remote port", text: $draft.remotePort, prompt: Text("18317"))
                TextField("Bind address", text: $draft.bindAddress, prompt: Text("empty = ssh default"))
                TextField("SSH options", text: $draft.sshOptions, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                TextField("Note", text: $draft.note, axis: .vertical)
                    .lineLimit(1...4)

                if let t = draft.tunnel() {
                    Section("Command") {
                        Text(SSHCommand.commandLine(for: t))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if (showErrors && !draft.errors.isEmpty) || !warnings.isEmpty {
                    Section {
                        if showErrors {
                            ForEach(draft.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                        }
                        ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    }
                    .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") {
                    if let t = draft.tunnel(id: original?.id ?? UUID()) { onSave(t) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.errors.isEmpty)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
