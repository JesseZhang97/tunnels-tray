import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads concrete `Host` names from an OpenSSH client config.
public enum SSHConfig {
    static let maxIncludeDepth = 8

    /// Parse config text. `resolveInclude` turns one Include pattern into file contents.
    public static func hosts(in text: String, resolveInclude: (String) -> [String] = { _ in [] }) -> [String] {
        var result: [String] = []
        collect(text, depth: 0, resolveInclude: resolveInclude, into: &result)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func collect(_ text: String, depth: Int, resolveInclude: (String) -> [String], into result: inout [String]) {
        guard depth <= maxIncludeDepth else { return }
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, args) = parseLine(rawLine) else { continue }
            switch keyword {
            case "host":
                for name in args where !name.isEmpty && !name.contains(where: { "*?!".contains($0) }) {
                    result.append(name)
                }
            case "include":
                for pattern in args {
                    for content in resolveInclude(pattern) {
                        collect(content, depth: depth + 1, resolveInclude: resolveInclude, into: &result)
                    }
                }
            default:
                continue
            }
        }
    }

    /// Split a config line into a lowercased keyword and its arguments.
    static func parseLine(_ raw: String) -> (String, [String])? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        guard let sep = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            return (line.lowercased(), [])
        }
        let keyword = String(line[..<sep]).lowercased()
        var rest = line[sep...].drop(while: { $0.isWhitespace })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0.isWhitespace }) }
        let args = (try? ShellWords.split(String(rest)))
            ?? rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return (keyword, args)
    }

    /// Hosts from a config file on disk, following Include lines (with globs).
    public static func hosts(configPath: String, home: String = NSHomeDirectory()) -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        return hosts(in: text) { pattern in
            expandInclude(pattern, home: home).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// Resolve an Include pattern the way ssh does for the user config.
    public static func expandInclude(_ pattern: String, home: String) -> [String] {
        var p = pattern
        if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if !p.hasPrefix("/") { p = home + "/.ssh/" + p }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, 0, nil, &g) == 0 else { return [] }
        var paths: [String] = []
        for i in 0..<Int(g.gl_pathc) {
            if let c = g.gl_pathv[i] { paths.append(String(cString: c)) }
        }
        return paths.sorted()
    }

    public static var defaultConfigPath: String { NSHomeDirectory() + "/.ssh/config" }
}
