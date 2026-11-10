import SwiftUI
import TunnelsCore

struct TunnelFormView: View {
    let original: Tunnel?
    let hosts: [String]
    let others: [Tunnel]
    let onSave: (Tunnel) -> Void
    let onCancel: () -> Void

    @State private var draft: TunnelDraft
    @State private var testSteps: [ConnectionTest.Step] = []
    @State private var testTask: Task<Void, Never>?

    init(original: Tunnel?, hosts: [String], others: [Tunnel],
         testSteps: [ConnectionTest.Step] = [],
         onSave: @escaping (Tunnel) -> Void, onCancel: @escaping () -> Void) {
        _testSteps = State(initialValue: testSteps)
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
                TextField("Name", text: $draft.name, prompt: Text("My Web App"))
                LabeledContent("SSH host") {
                    ComboField(text: $draft.sshHost, items: hosts, prompt: "my-server",
                               help: "Pick a Host from ~/.ssh/config")
                }
                TextField("Local port", text: $draft.localPort, prompt: Text("8080"))
                TextField("Remote host", text: $draft.remoteHost, prompt: Text(Tunnel.defaultRemoteHost))
                TextField("Remote port", text: $draft.remotePort, prompt: Text("8080"))
                TextField("Bind address", text: $draft.bindAddress, prompt: Text("empty = ssh default"))
                TextField("Note", text: $draft.note, axis: .vertical)
                    .lineLimit(1...4)

                Section {
                    SSHOptionsEditor(text: $draft.sshOptions, hosts: hosts)
                } header: {
                    Text("SSH options")
                } footer: {
                    Text("Always added: \(SSHOptions.baseDescription). An option set here replaces the default with the same key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let t = draft.tunnel() {
                    Section("Command") {
                        Text(SSHCommand.commandLine(for: t))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !testSteps.isEmpty {
                    Section("Connection test") {
                        ForEach(testSteps) { TestStepRow(step: $0) }
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
                Button("Test connection", action: startTest)
                    .disabled(testTask != nil || draft.tunnel() == nil)
                    .help("Check the local port, SSH login and remote target with the values above")
                if testTask != nil {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: cancelTest)
                }
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
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: draft) { _, _ in
            cancelTest()
            testSteps = []
        }
        .onDisappear(perform: cancelTest)
    }

    /// Test the current, unsaved values. Never touches running tunnels.
    private func startTest() {
        guard testTask == nil, let t = draft.tunnel(id: original?.id ?? UUID()) else { return }
        let ownPort: Bool = {
            guard let o = original, TunnelManager.shared.state(for: o.id).isActive else { return false }
            return o.localPort == t.localPort && o.bindAddress == t.bindAddress
        }()
        testSteps = ConnectionTest.Kind.allCases.map { ConnectionTest.Step(kind: $0, state: .pending) }
        testTask = Task {
            let final = await ConnectionTest.run(
                t,
                portInUseByThisTunnel: ownPort,
                portOwner: { TunnelManager.listeningProcess(port: $0) },
                progress: { steps in Task { @MainActor in if testTask != nil { testSteps = steps } } }
            )
            await MainActor.run {
                if !Task.isCancelled {
                    testSteps = final
                    testTask = nil
                }
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
    }
}

struct TestStepRow: View {
    let step: ConnectionTest.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = step.state { return true }
        return false
    }

    private var detail: String? {
        switch step.state {
        case .pending, .running: return nil
        case .passed(let m), .failed(let m), .skipped(let m): return m
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
