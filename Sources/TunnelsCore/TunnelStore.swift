import Foundation

/// Reads and writes the tunnel list as a JSON array.
public struct TunnelStore: Sendable {
    public let url: URL

    public init(url: URL = TunnelStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunnels", isDirectory: true)
            .appendingPathComponent("tunnels.json")
    }

    /// A missing file means an empty list.
    public func load() throws -> [Tunnel] {
        try loadMigrating().tunnels
    }

    /// Load and report whether any entry was migrated (caller should save).
    public func loadMigrating() throws -> (tunnels: [Tunnel], migrated: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        return try Self.decodeMigrating(Data(contentsOf: url))
    }

    public func save(_ tunnels: [Tunnel]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(tunnels).write(to: url, options: .atomic)
    }

    /// Decode and migrate (used for both the store and imports).
    public static func decode(_ data: Data) throws -> [Tunnel] {
        try decodeMigrating(data).tunnels
    }

    /// Older files stored the default `-o` options in `ssh_options`; they are
    /// built in now, so strip them to avoid duplicates.
    public static func decodeMigrating(_ data: Data) throws -> (tunnels: [Tunnel], migrated: Bool) {
        var tunnels = try JSONDecoder().decode([Tunnel].self, from: data)
        var migrated = false
        for i in tunnels.indices {
            let stripped = SSHOptions.stripBuiltIns(tunnels[i].sshOptions)
            if stripped != tunnels[i].sshOptions {
                tunnels[i].sshOptions = stripped
                migrated = true
            }
        }
        return (tunnels, migrated)
    }

    public static func encode(_ tunnels: [Tunnel]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(tunnels)
    }
}
