import AppKit
import SwiftUI
import TunnelsCore

/// Structured editor for the extra `-o` options, bound to the options string.
struct SSHOptionsEditor: View {
    @Binding var text: String
    let hosts: [String]

    @State private var rows: [SSHOption]
    @State private var extras: [String]
    @State private var showRaw: Bool
    /// Set while rows are replaced from a raw edit, so the raw text is not rewritten.
    @State private var rowsFromRaw = false

    init(text: Binding<String>, hosts: [String]) {
        _text = text
        self.hosts = hosts
        let parsed = try? SSHOptions.parse(text.wrappedValue)
        _rows = State(initialValue: parsed?.options ?? [])
        _extras = State(initialValue: parsed?.extras ?? [])
        _showRaw = State(initialValue: parsed == nil || !(parsed?.extras.isEmpty ?? true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("No extra options.").foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                SSHOptionRow(option: $row, hosts: hosts) {
                    rows.removeAll { $0.id == row.id }
                }
            }
            if !extras.isEmpty {
                Text("Other arguments: \(ShellWords.join(extras))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(SSHOptions.catalog) { spec in
                    Button(spec.key) { rows.append(SSHOption(key: spec.key, value: spec.defaultValue)) }
                }
                Divider()
                Button("Custom…") { rows.append(SSHOption(key: "", value: "")) }
            } label: {
                Label("Add option", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            DisclosureGroup("Advanced: raw", isExpanded: $showRaw) {
                TextField("Raw", text: $text, prompt: Text("-o Key=Value -C"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...5)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .onChange(of: rows) { _, newRows in
            if rowsFromRaw { rowsFromRaw = false; return }
            text = SSHOptions.generate(newRows, extras: extras)
        }
        .onChange(of: text) { _, newText in
            guard newText != SSHOptions.generate(rows, extras: extras),
                  let parsed = try? SSHOptions.parse(newText) else { return }
            if parsed.options.map({ [$0.key, $0.value] }) != rows.map({ [$0.key, $0.value] }) {
                rowsFromRaw = true
                rows = parsed.options
            }
            extras = parsed.extras
        }
    }
}

/// One option: key picker, value control, remove button.
struct SSHOptionRow: View {
    @Binding var option: SSHOption
    let hosts: [String]
    let onRemove: () -> Void

    @State private var custom: Bool
    private static let customTag = "\u{0}custom"

    init(option: Binding<SSHOption>, hosts: [String], onRemove: @escaping () -> Void) {
        _option = option
        self.hosts = hosts
        self.onRemove = onRemove
        _custom = State(initialValue: SSHOptions.spec(for: option.wrappedValue.key) == nil)
    }

    private var spec: SSHOptionSpec? { custom ? nil : SSHOptions.spec(for: option.key) }

    private var keySelection: Binding<String> {
        Binding(
            get: { custom ? Self.customTag : (spec?.key ?? Self.customTag) },
            set: { tag in
                if tag == Self.customTag {
                    custom = true
                    return
                }
                custom = false
                option.key = tag
                if SSHOptions.valueError(key: tag, value: option.value) != nil {
                    option.value = SSHOptions.spec(for: tag)?.defaultValue ?? ""
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Option", selection: keySelection) {
                ForEach(SSHOptions.catalog) { Text($0.key).tag($0.key) }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .frame(width: 170)

            if custom {
                TextField("Key", text: $option.key, prompt: Text("Key"))
                    .labelsHidden()
                    .frame(width: 110)
            }
            valueEditor
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove option")
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch spec?.kind ?? .text {
        case .yesNo:
            Toggle(option.value.lowercased() == "yes" ? "yes" : "no", isOn: Binding(
                get: { option.value.lowercased() == "yes" },
                set: { option.value = $0 ? "yes" : "no" }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        case .choice(let values):
            Picker("Value", selection: $option.value) {
                ForEach(values.contains(option.value) || option.value.isEmpty ? values : [option.value] + values,
                        id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .number:
            TextField("Value", text: $option.value, prompt: Text(spec?.defaultValue ?? ""))
                .labelsHidden()
                .frame(width: 80)
        case .text:
            TextField("Value", text: $option.value, prompt: Text("value"))
                .labelsHidden()
        case .file:
            HStack(spacing: 4) {
                TextField("Value", text: $option.value, prompt: Text("~/.ssh/id_ed25519"))
                    .labelsHidden()
                Button { chooseFile() } label: { Image(systemName: "folder") }
                    .help("Choose a file")
            }
        case .host:
            ComboField(text: $option.value, items: hosts, prompt: "jump-host",
                       help: "Pick a Host from ~/.ssh/config")
        case .suggestions(let items):
            ComboField(text: $option.value, items: items, prompt: spec?.defaultValue ?? "", help: "Common values")
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        option.value = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Text field with a dropdown of suggestions (editable combo box).
struct ComboField: View {
    @Binding var text: String
    let items: [String]
    let prompt: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("Value", text: $text, prompt: Text(prompt))
                .labelsHidden()
            Menu {
                if items.isEmpty { Text("No suggestions") }
                ForEach(items, id: \.self) { item in
                    Button(item) { text = item }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
        }
    }
}
