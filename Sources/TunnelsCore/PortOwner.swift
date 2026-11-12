import Foundation

/// The process listening on a tunnel's local port, and how it relates to the tunnel.
public struct PortOwner: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An ssh started by this app (another tunnel on the same port).
        case ownChild
        /// An ssh with the same forward to the same host, e.g. left over from
        /// Terminal or a crashed app.
        case staleSameForward
        /// Some other ssh process.
        case otherSSH
        /// Not ssh.
        case other
    }

    public var pid: Int32
    public var ppid: Int32
    /// Short command name from lsof (e.g. "ssh").
    public var name: String
    /// Full command line from ps; empty if unknown.
    public var args: String
    public var kind: Kind

    public init(pid: Int32, ppid: Int32, name: String, args: String, kind: Kind) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.args = args
        self.kind = kind
    }

    /// ssh processes can be ended without asking; anything else needs a confirmation.
    public var needsConfirmation: Bool { kind == .other }

    /// "ssh (pid 123)"
    public var label: String { "\(name) (pid \(pid))" }

    /// Short explanation of the kind, for the row.
    public var kindDescription: String {
        switch kind {
        case .ownChild: return "another tunnel here"
        case .staleSameForward: return "old ssh, same forward"
        case .otherSSH: return "other ssh"
        case .other: return "not ssh"
        }
    }
}

public enum PortOwners {
    /// First process in `lsof -Fpc` output.
    public static func parseLsof(_ output: String) -> (pid: Int32, name: String)? {
        var pid: Int32?
        var name: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                if pid != nil { break }
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), name == nil {
                name = String(line.dropFirst())
            }
        }
        guard let pid else { return nil }
        return (pid, name ?? "process")
    }

    /// `ps -o ppid=,args=` output: "  1 /usr/bin/ssh -N ...".
    public static func parsePS(_ output: String) -> (ppid: Int32, args: String)? {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = s.firstIndex(where: \.isWhitespace) else {
            guard let ppid = Int32(s) else { return nil }
            return (ppid, "")
        }
        guard let ppid = Int32(s[..<space]) else { return nil }
        return (ppid, s[space...].trimmingCharacters(in: .whitespaces))
    }

    /// True if the command is ssh (by short name or argv[0]).
    public static func isSSH(name: String, args: String) -> Bool {
        if name == "ssh" { return true }
        let argv0 = args.split(separator: " ").first.map(String.init) ?? ""
        return (argv0 as NSString).lastPathComponent == "ssh"
    }

    /// Local port and remote "host:port" of a `-L` spec; the bind address is ignored.
    static func parseForward(_ spec: String) -> (localPort: Int, remote: String)? {
        // [bind:]port:host:hostport, host may be [v6].
        var parts: [String] = []
        var current = ""
        var inBrackets = false
        for ch in spec {
            if ch == "[" { inBrackets = true; continue }
            if ch == "]" { inBrackets = false; continue }
            if ch == ":" && !inBrackets { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        guard parts.count == 3 || parts.count == 4,
              let lp = Int(parts[parts.count - 3]), let rp = Int(parts[parts.count - 1]) else { return nil }
        return (lp, "\(normalizedHost(parts[parts.count - 2])):\(rp)")
    }

    private static func normalizedHost(_ h: String) -> String {
        ["localhost", "127.0.0.1"].contains(h.lowercased()) ? "127.0.0.1" : h.lowercased()
    }

    /// True if an ssh command line forwards the tunnel's local port to the same
    /// remote target through the same host. `ps` joins argv with spaces, so
    /// arguments are split on spaces.
    public static func matchesForward(args: String, tunnel t: Tunnel) -> Bool {
        let words = args.split(separator: " ").map(String.init)
        var specs: [String] = []
        for (i, w) in words.enumerated() where w.hasPrefix("-") && !w.hasPrefix("--") {
            // -L spec, -Lspec, or bundled flags like -fNL spec / -fNLspec.
            let flags = w.dropFirst()
            guard let l = flags.firstIndex(of: "L"), flags[..<l].allSatisfy(\.isLetter) else { continue }
            let rest = String(flags[flags.index(after: l)...])
            if !rest.isEmpty { specs.append(rest) } else if i + 1 < words.count { specs.append(words[i + 1]) }
        }
        let want = "\(normalizedHost(t.remoteHost)):\(t.remotePort)"
        let forward = specs.compactMap(parseForward).contains { $0.localPort == t.localPort && $0.remote == want }
        let host = t.sshHost.lowercased()
        let viaHost = words.dropFirst().contains { w in
            let l = w.lowercased()
            return l == host || l.hasSuffix("@" + host)
        }
        return forward && viaHost
    }

    public static func classify(pid: Int32, name: String, args: String, tunnel: Tunnel,
                                ownPIDs: Set<Int32>) -> PortOwner.Kind {
        if ownPIDs.contains(pid) { return .ownChild }
        guard isSSH(name: name, args: args) else { return .other }
        return matchesForward(args: args, tunnel: tunnel) ? .staleSameForward : .otherSSH
    }

    /// The process listening on the tunnel's local port (lsof + ps), or nil.
    public static func find(tunnel: Tunnel, ownPIDs: Set<Int32> = []) -> PortOwner? {
        guard let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(tunnel.localPort)", "-sTCP:LISTEN", "-Fpc"]),
              let listener = parseLsof(lsof) else { return nil }
        let info = processInfo(pid: listener.pid)
        let args = info?.args ?? ""
        return PortOwner(pid: listener.pid, ppid: info?.ppid ?? 0, name: listener.name, args: args,
                         kind: classify(pid: listener.pid, name: listener.name, args: args,
                                        tunnel: tunnel, ownPIDs: ownPIDs))
    }

    /// Parent pid and full command line of a running process.
    public static func processInfo(pid: Int32) -> (ppid: Int32, args: String)? {
        guard let out = run("/bin/ps", ["-ww", "-o", "ppid=,args=", "-p", String(pid)]) else { return nil }
        return parsePS(out)
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}

/// Ends a process: SIGTERM, then SIGKILL if it is still alive after a grace period.
/// Meant for processes that are not our own `Process` children (those are
/// stopped through `Process.terminate()` so Foundation can reap them).
public enum ProcessKiller {
    public enum Outcome: Equatable, Sendable {
        case ended
        case killed
        case alreadyGone
        case failed(String)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Blocking; call off the main thread.
    public static func terminate(pid: Int32, grace: TimeInterval = 1) -> Outcome {
        guard pid > 1 else { return .failed("refusing to signal pid \(pid)") }
        if kill(pid, SIGTERM) != 0 {
            let e = errno
            return e == ESRCH ? .alreadyGone : .failed(String(cString: strerror(e)))
        }
        if waitGone(pid, timeout: grace) { return .ended }
        if kill(pid, SIGKILL) != 0 {
            let e = errno
            return e == ESRCH ? .ended : .failed(String(cString: strerror(e)))
        }
        return waitGone(pid, timeout: 1) ? .killed : .failed("still running after SIGKILL")
    }

    private static func waitGone(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(50_000)
        } while Date() < deadline
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
