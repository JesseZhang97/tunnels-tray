import Foundation

/// Plain-text log per tunnel in ~/Library/Logs/Tunnels/<name>.log.
/// When a file grows past `maxBytes` it is moved to `<name>.log.1` (one backup).
public struct TunnelLog: Sendable {
    public static let maxBytes = 1_000_000

    public static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tunnels", isDirectory: true)
    }

    public let url: URL
    public let maxBytes: Int

    public init(tunnelName: String, directory: URL = TunnelLog.directory, maxBytes: Int = TunnelLog.maxBytes) {
        url = directory.appendingPathComponent(Self.fileName(for: tunnelName))
        self.maxBytes = maxBytes
    }

    /// Safe file name: path separators and control characters replaced.
    public static func fileName(for name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .map { ch -> Character in
                ch == "/" || ch == ":" || ch.isNewline || ch.unicodeScalars.contains { $0.properties.generalCategory == .control }
                    ? "-" : ch
            }
        let s = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (s.isEmpty ? "tunnel" : s) + ".log"
    }

    /// Each non-empty line prefixed with a local timestamp.
    public static func format(_ text: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = f.string(from: date)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\(stamp) \($0)\n" }
            .joined()
    }

    /// Best effort; logging never fails the caller.
    public func append(_ text: String, date: Date = Date()) {
        let line = Self.format(text, date: date)
        guard !line.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes {
            let backup = url.appendingPathExtension("1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}
