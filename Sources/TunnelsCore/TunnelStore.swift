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
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decode(Data(contentsOf: url))
    }

    public func save(_ tunnels: [Tunnel]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(tunnels).write(to: url, options: .atomic)
    }

    public static func decode(_ data: Data) throws -> [Tunnel] {
        try JSONDecoder().decode([Tunnel].self, from: data)
    }

    public static func encode(_ tunnels: [Tunnel]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(tunnels)
    }
}
