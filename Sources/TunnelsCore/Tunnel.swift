import Foundation

/// One SSH local port forward.
public struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    public static let defaultRemoteHost = "127.0.0.1"
    public static let defaultBindAddress = "127.0.0.1"
    /// Extra options only; the built-in defaults live in `SSHOptions`.
    public static let defaultSSHOptions = ""

    public var id: UUID
    public var name: String
    public var sshHost: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var bindAddress: String
    public var sshOptions: String
    public var note: String

    public init(
        id: UUID = UUID(),
        name: String,
        sshHost: String,
        localPort: Int,
        remoteHost: String = Tunnel.defaultRemoteHost,
        remotePort: Int,
        bindAddress: String = Tunnel.defaultBindAddress,
        sshOptions: String = Tunnel.defaultSSHOptions,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.bindAddress = bindAddress
        self.sshOptions = sshOptions
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note
        case sshHost = "ssh_host"
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
        case bindAddress = "bind_address"
        case sshOptions = "ssh_options"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        sshHost = try c.decode(String.self, forKey: .sshHost)
        localPort = try Self.decodePort(c, .localPort)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? Self.defaultRemoteHost
        remotePort = try Self.decodePort(c, .remotePort)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? Self.defaultBindAddress
        sshOptions = try c.decodeIfPresent(String.self, forKey: .sshOptions) ?? Self.defaultSSHOptions
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// Accept ports as numbers or numeric strings (hand-written JSON).
    private static func decodePort(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let n = try? c.decode(Int.self, forKey: key) { return n }
        let s = try c.decode(String.self, forKey: key)
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Port is not a number: \(s)")
        }
        return n
    }

    /// Host to use in the browser URL for this tunnel.
    public var browserHost: String {
        let b = bindAddress.trimmingCharacters(in: .whitespaces)
        switch b {
        case "", "*", "0.0.0.0", "::", "localhost": return "127.0.0.1"
        default: return b.contains(":") ? "[\(b)]" : b
        }
    }

    public var browserURL: URL? {
        URL(string: "http://\(browserHost):\(localPort)")
    }
}

/// Editable string form of a tunnel, used by the add/edit form.
public struct TunnelDraft: Equatable, Sendable {
    public var name = ""
    public var sshHost = ""
    public var localPort = ""
    public var remoteHost = Tunnel.defaultRemoteHost
    public var remotePort = ""
    public var bindAddress = Tunnel.defaultBindAddress
    public var sshOptions = Tunnel.defaultSSHOptions
    public var note = ""

    public init() {}

    public init(_ t: Tunnel) {
        name = t.name
        sshHost = t.sshHost
        localPort = String(t.localPort)
        remoteHost = t.remoteHost
        remotePort = String(t.remotePort)
        bindAddress = t.bindAddress
        sshOptions = t.sshOptions
        note = t.note
    }

    public static func parsePort(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    /// Problems that block saving. Empty means valid.
    public var errors: [String] {
        var e: [String] = []
        let host = sshHost.trimmingCharacters(in: .whitespaces)
        if name.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Name is required.") }
        if host.isEmpty {
            e.append("SSH host is required.")
        } else if host.hasPrefix("-") || host.contains(where: \.isWhitespace) {
            e.append("SSH host must not start with '-' or contain spaces.")
        }
        if Self.parsePort(localPort) == nil { e.append("Local port must be 1–65535.") }
        if Self.parsePort(remotePort) == nil { e.append("Remote port must be 1–65535.") }
        if remoteHost.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) {
            e.append("Remote host must not contain spaces.")
        }
        if bindAddress.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) {
            e.append("Bind address must not contain spaces.")
        }
        e += SSHOptions.errors(in: sshOptions)
        return e
    }

    /// Build a tunnel, or nil if the draft has errors.
    public func tunnel(id: UUID = UUID()) -> Tunnel? {
        guard errors.isEmpty, let lp = Self.parsePort(localPort), let rp = Self.parsePort(remotePort) else { return nil }
        let rh = remoteHost.trimmingCharacters(in: .whitespaces)
        return Tunnel(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            sshHost: sshHost.trimmingCharacters(in: .whitespaces),
            localPort: lp,
            remoteHost: rh.isEmpty ? Tunnel.defaultRemoteHost : rh,
            remotePort: rp,
            bindAddress: bindAddress.trimmingCharacters(in: .whitespaces),
            sshOptions: sshOptions.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
