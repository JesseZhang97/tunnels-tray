import Foundation

/// One `-o Key=Value` option.
public struct SSHOption: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// How the form edits an option's value.
public enum SSHOptionKind: Equatable, Sendable {
    case yesNo
    case choice([String])
    case number
    case text
    case file
    case host
    case suggestions([String])
}

public struct SSHOptionSpec: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let kind: SSHOptionKind
    public let defaultValue: String

    public init(_ key: String, _ kind: SSHOptionKind, _ defaultValue: String = "") {
        self.key = key
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// Parsing, generating and checking the per-tunnel "extra options" string,
/// plus the defaults that every tunnel gets.
public enum SSHOptions {
    /// Always passed first; cannot be overridden.
    public static let fixedArguments = ["-N", "-T", "-o", "BatchMode=yes"]

    /// Added to every tunnel unless the tunnel sets the same key itself.
    public static let defaultOptions: [(key: String, value: String)] = [
        ("ServerAliveInterval", "15"),
        ("ServerAliveCountMax", "3"),
        ("ExitOnForwardFailure", "yes"),
        // Fail fast when the network is down (e.g. right after wake) so the
        // retry loop is not stuck in a long TCP connect.
        ("ConnectTimeout", "10"),
    ]

    /// Text shown read-only in the form.
    public static var baseDescription: String {
        (fixedArguments + defaultOptions.flatMap { ["-o", "\($0.key)=\($0.value)"] }).joined(separator: " ")
    }

    /// Common ssh_config keys offered in the form.
    public static let catalog: [SSHOptionSpec] = [
        SSHOptionSpec("User", .text),
        SSHOptionSpec("Port", .number, "22"),
        SSHOptionSpec("IdentityFile", .file, "~/.ssh/id_ed25519"),
        SSHOptionSpec("IdentitiesOnly", .yesNo, "yes"),
        SSHOptionSpec("ProxyJump", .host),
        SSHOptionSpec("Compression", .yesNo, "yes"),
        SSHOptionSpec("ConnectTimeout", .number, "10"),
        SSHOptionSpec("ServerAliveInterval", .number, "15"),
        SSHOptionSpec("ServerAliveCountMax", .number, "3"),
        SSHOptionSpec("ExitOnForwardFailure", .yesNo, "yes"),
        SSHOptionSpec("TCPKeepAlive", .yesNo, "yes"),
        SSHOptionSpec("StrictHostKeyChecking", .choice(["yes", "no", "accept-new", "ask"]), "accept-new"),
        SSHOptionSpec("LogLevel", .choice(["QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG", "DEBUG2", "DEBUG3"]), "ERROR"),
        SSHOptionSpec("IPQoS", .suggestions(["af21 cs1", "lowdelay", "throughput", "reliability", "none"]), "none"),
        SSHOptionSpec("AddressFamily", .choice(["any", "inet", "inet6"]), "inet"),
        SSHOptionSpec("GatewayPorts", .yesNo, "no"),
        SSHOptionSpec("ForwardAgent", .yesNo, "no"),
        SSHOptionSpec("HostKeyAlias", .text),
    ]

    public static func spec(for key: String) -> SSHOptionSpec? {
        catalog.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// ssh_config keys are case-insensitive; use the catalog spelling when known.
    public static func canonicalKey(_ key: String) -> String {
        spec(for: key)?.key ?? key
    }

    public struct Parsed: Equatable, Sendable {
        public var options: [SSHOption]
        /// Arguments that are not `-o` options (e.g. `-C`, `-i file`), kept verbatim.
        public var extras: [String]

        public init(options: [SSHOption] = [], extras: [String] = []) {
            self.options = options
            self.extras = extras
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingOptionArgument

        public var description: String { "-o needs a Key=Value argument" }
    }

    /// Split "Key=Value", "Key Value" or "Key = Value".
    static func splitKeyValue(_ arg: String) -> SSHOption {
        let s = arg.trimmingCharacters(in: .whitespaces)
        guard let sep = s.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            return SSHOption(key: canonicalKey(s), value: "")
        }
        var rest = s[sep...].drop(while: { $0.isWhitespace })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0.isWhitespace }) }
        return SSHOption(key: canonicalKey(String(s[..<sep])), value: String(rest))
    }

    public static func parse(_ text: String) throws -> Parsed {
        let words = try ShellWords.split(text)
        var result = Parsed()
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "-o" {
                guard i + 1 < words.count else { throw ParseError.missingOptionArgument }
                result.options.append(splitKeyValue(words[i + 1]))
                i += 2
                continue
            }
            if w.hasPrefix("-o"), w.count > 2 {
                result.options.append(splitKeyValue(String(w.dropFirst(2))))
            } else {
                result.extras.append(w)
            }
            i += 1
        }
        return result
    }

    public static func generate(_ options: [SSHOption], extras: [String] = []) -> String {
        let opts = options.map { "-o " + ShellWords.quote("\($0.key)=\($0.value)") }
        return (opts + extras.map(ShellWords.quote)).joined(separator: " ")
    }

    /// Problem with one value for its catalog kind, or nil.
    public static func valueError(key: String, value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return "\(key.isEmpty ? "Option" : key) needs a value." }
        guard let spec = spec(for: key) else { return nil }
        switch spec.kind {
        case .number:
            return Int(v) == nil ? "\(spec.key) must be a number." : nil
        case .yesNo:
            return ["yes", "no"].contains(v.lowercased()) ? nil : "\(spec.key) must be yes or no."
        case .choice(let values):
            return values.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
                ? nil : "\(spec.key) must be one of: \(values.joined(separator: ", "))."
        case .text, .file, .host, .suggestions:
            return nil
        }
    }

    /// Problems that block saving. Empty means valid.
    public static func errors(in text: String) -> [String] {
        let parsed: Parsed
        do { parsed = try parse(text) } catch { return ["SSH options: \(error)"] }
        var e: [String] = []
        for o in parsed.options {
            if o.key.isEmpty {
                e.append("Option key is required.")
            } else if o.key.contains(where: { $0.isWhitespace || $0 == "=" }) {
                e.append("Option key “\(o.key)” is not valid.")
            } else if let err = valueError(key: o.key, value: o.value) {
                e.append(err)
            }
        }
        return e
    }

    /// Lowercased keys of the `-o` options in `text` (unparsable text → none).
    public static func userKeys(in text: String) -> Set<String> {
        Set(((try? parse(text))?.options ?? []).map { $0.key.lowercased() })
    }

    /// Migration: remove arguments that are now built in (`-N`, `-T`, and
    /// `-o` options identical to a fixed/default one). A different value for
    /// a default key is kept, so the user's choice still wins.
    public static func stripBuiltIns(_ text: String) -> String {
        guard let words = try? ShellWords.split(text) else { return text }
        let builtIns = [("BatchMode", "yes")] + defaultOptions.map { ($0.key, $0.value) }
        func isBuiltIn(_ arg: String) -> Bool {
            let o = splitKeyValue(arg)
            return builtIns.contains {
                $0.0.caseInsensitiveCompare(o.key) == .orderedSame && $0.1.caseInsensitiveCompare(o.value) == .orderedSame
            }
        }
        var kept: [String] = []
        var removed = false
        var i = 0
        while i < words.count {
            let w = words[i]
            if ["-N", "-T", "-NT", "-TN"].contains(w) {
                removed = true
            } else if w == "-o", i + 1 < words.count {
                if isBuiltIn(words[i + 1]) { removed = true } else { kept += [w, words[i + 1]] }
                i += 1
            } else if w.hasPrefix("-o"), w.count > 2, isBuiltIn(String(w.dropFirst(2))) {
                removed = true
            } else {
                kept.append(w)
            }
            i += 1
        }
        return removed ? ShellWords.join(kept) : text
    }
}
