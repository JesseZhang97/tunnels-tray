import Foundation

/// One ssh child started by the app, remembered on disk so it can be cleaned
/// up after a crash or force-quit.
public struct ChildRecord: Codable, Equatable, Sendable {
    public var tunnelID: UUID
    public var pid: Int32
    /// argv including argv[0] (the ssh path).
    public var argv: [String]
    public var startedAt: Date

    public init(tunnelID: UUID, pid: Int32, argv: [String], startedAt: Date = Date()) {
        self.tunnelID = tunnelID
        self.pid = pid
        self.argv = argv
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case tunnelID = "tunnel_id"
        case pid, argv
        case startedAt = "started_at"
    }
}

/// `children.json` next to `tunnels.json`.
public struct ChildRegistry: Sendable {
    public let url: URL

    public init(url: URL = ChildRegistry.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        TunnelStore.defaultURL.deletingLastPathComponent().appendingPathComponent("children.json")
    }

    /// Missing or unreadable file means no records.
    public func load() -> [ChildRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ChildRecord].self, from: data)) ?? []
    }

    public func save(_ records: [ChildRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(records).write(to: url, options: .atomic)
    }

    /// A recorded child is a safe-to-end orphan only if it was re-parented to
    /// launchd (ppid 1) and its command line is exactly the one we started.
    /// `ps` joins argv with single spaces.
    public static func isOrphan(_ record: ChildRecord, ppid: Int32, args: String) -> Bool {
        ppid == 1 && args.trimmingCharacters(in: .whitespacesAndNewlines) == record.argv.joined(separator: " ")
    }
}
