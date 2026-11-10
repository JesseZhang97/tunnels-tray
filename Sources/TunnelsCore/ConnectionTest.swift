import Foundation

/// Checks a tunnel's settings without starting it:
/// 1. the local port can be bound, 2. ssh can log in, 3. the remote target accepts a connection.
public enum ConnectionTest {
    public enum Kind: String, CaseIterable, Sendable {
        case localPort, login, remote

        public var title: String {
            switch self {
            case .localPort: return "Local port free"
            case .login: return "SSH login"
            case .remote: return "Remote target reachable"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case pending, running
        case passed(String)
        case failed(String)
        case skipped(String)
    }

    public struct Step: Identifiable, Equatable, Sendable {
        public let kind: Kind
        public var state: State
        public var id: Kind { kind }

        public init(kind: Kind, state: State) {
            self.kind = kind
            self.state = state
        }
    }

    public static let connectTimeout = 8
    /// Time the `-W` probe must stay up after its handshake to count as reachable.
    public static let settleSeconds: TimeInterval = 2
    /// Budget for the whole test.
    public static let totalBudget: TimeInterval = 12

    static let forwardFailureMarkers = ["open failed", "connect failed", "administratively prohibited",
                                        "stdio forwarding failed"]

    // MARK: - Commands

    private static func bracketIfIPv6(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// `-o BatchMode=yes -o ConnectTimeout=8 <defaults not set by user> <user extras>`.
    static func optionArguments(for t: Tunnel) throws -> [String] {
        let extras = try ShellWords.split(t.sshOptions)
        let userKeys = SSHOptions.userKeys(in: t.sshOptions)
        let ours = [("ConnectTimeout", String(connectTimeout))] + SSHOptions.defaultOptions.map { ($0.key, $0.value) }
        let defaults = ours
            .filter { !userKeys.contains($0.0.lowercased()) }
            .flatMap { ["-o", "\($0.0)=\($0.1)"] }
        return ["-o", "BatchMode=yes"] + defaults + extras
    }

    /// `ssh -T <options> host exit`
    public static func loginArguments(for t: Tunnel) throws -> [String] {
        ["-T"] + (try optionArguments(for: t)) + [t.sshHost, "exit"]
    }

    /// `ssh <options> -W remote_host:remote_port host`
    public static func reachArguments(for t: Tunnel) throws -> [String] {
        (try optionArguments(for: t)) + ["-W", "\(bracketIfIPv6(t.remoteHost)):\(t.remotePort)", t.sshHost]
    }

    // MARK: - Result interpretation

    /// Short, readable error from ssh stderr.
    public static func errorSummary(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        if let marked = lines.first(where: { l in forwardFailureMarkers.contains { l.localizedCaseInsensitiveContains($0) } }) {
            return String(marked.prefix(300))
        }
        return String((lines.last ?? "").prefix(300))
    }

    public static func hasForwardFailure(_ stderr: String) -> Bool {
        forwardFailureMarkers.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    public static func loginState(_ outcome: ProcessOutcome) -> State {
        switch outcome {
        case .exited(0, _): return .passed("Logged in")
        case .exited(let code, let err):
            let msg = errorSummary(err)
            return .failed(msg.isEmpty ? "ssh exited with status \(code)" : msg)
        case .stillRunning, .timedOut: return .failed("Timed out")
        case .cancelled: return .skipped("Cancelled")
        case .launchFailed(let e): return .failed("Could not run ssh: \(e)")
        }
    }

    public static func reachState(_ outcome: ProcessOutcome, target: String) -> State {
        switch outcome {
        case .stillRunning(let err):
            return hasForwardFailure(err) ? .failed(errorSummary(err)) : .passed("\(target) accepted the connection")
        case .exited(let code, let err):
            if hasForwardFailure(err) || code != 0 {
                let msg = errorSummary(err)
                return .failed(msg.isEmpty ? "ssh exited with status \(code)" : msg)
            }
            return .passed("\(target) accepted and closed the connection")
        case .timedOut: return .failed("Timed out")
        case .cancelled: return .skipped("Cancelled")
        case .launchFailed(let e): return .failed("Could not run ssh: \(e)")
        }
    }

    // MARK: - Running

    /// Runs all checks. `portInUseByThisTunnel`: the tunnel is running in the app on this port.
    /// `portOwner` may describe who holds a busy port. `progress` gets every intermediate state.
    public static func run(
        _ t: Tunnel,
        portInUseByThisTunnel: Bool = false,
        portOwner: @escaping @Sendable (Int) -> String? = { _ in nil },
        progress: @escaping @Sendable ([Step]) -> Void = { _ in }
    ) async -> [Step] {
        var steps = Kind.allCases.map { Step(kind: $0, state: .pending) }
        func set(_ k: Kind, _ s: State) {
            steps[Kind.allCases.firstIndex(of: k)!].state = s
            progress(steps)
        }
        let deadline = Date().addingTimeInterval(totalBudget)

        // 1. Local port
        let addr = PortCheck.checkAddress(for: t.bindAddress)
        if let err = PortCheck.bindError(address: addr, port: t.localPort) {
            if portInUseByThisTunnel {
                set(.localPort, .passed("In use by this tunnel"))
            } else {
                set(.localPort, .failed(portOwner(t.localPort).map { "Port \(t.localPort) is in use by \($0)" }
                                         ?? "Cannot bind \(addr):\(t.localPort): \(err)"))
            }
        } else {
            set(.localPort, .passed("\(addr):\(t.localPort) is free"))
        }

        // 2. Login
        guard let loginArgs = try? loginArguments(for: t), let reachArgs = try? reachArguments(for: t) else {
            set(.login, .failed("SSH options cannot be parsed"))
            set(.remote, .skipped("Needs SSH login"))
            return steps
        }
        set(.login, .running)
        let loginStart = Date()
        let login = await ProcessRunner.run(arguments: loginArgs, timeout: deadline.timeIntervalSinceNow)
        let handshake = Date().timeIntervalSince(loginStart)
        let loginResult = loginState(login)
        set(.login, loginResult)
        guard case .passed = loginResult else {
            set(.remote, .skipped(Task.isCancelled ? "Cancelled" : "Needs SSH login"))
            return steps
        }

        // 3. Remote target
        set(.remote, .running)
        // The probe must outlive its own handshake (about as long as the login
        // took) plus the settle time before it counts as reachable.
        let aliveAfter = handshake + settleSeconds
        let timeout = max(aliveAfter + 1, deadline.timeIntervalSinceNow)
        let reach = await ProcessRunner.run(arguments: reachArgs, timeout: timeout,
                                            keepStdinOpen: true, aliveAfter: aliveAfter)
        set(.remote, reachState(reach, target: "\(t.remoteHost):\(t.remotePort)"))
        return steps
    }
}

public enum ProcessOutcome: Equatable, Sendable {
    case exited(Int32, stderr: String)
    /// Still running after `aliveAfter`; it was terminated.
    case stillRunning(stderr: String)
    case timedOut(stderr: String)
    case cancelled
    case launchFailed(String)
}

/// Runs ssh once with a timeout and cancellation; collects stderr.
public enum ProcessRunner {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stderr = Data()
        var done = false
        var continuation: CheckedContinuation<ProcessOutcome, Never>?
        let process = Process()
        let stdin = Pipe()

        var stderrText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stderr, as: UTF8.self)
        }

        func finish(_ outcome: ProcessOutcome) {
            lock.lock()
            guard !done, let c = continuation else { lock.unlock(); return }
            done = true
            continuation = nil
            lock.unlock()
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
            c.resume(returning: outcome)
        }
    }

    public static func run(
        executable: String = SSHCommand.executable,
        arguments: [String],
        timeout: TimeInterval,
        keepStdinOpen: Bool = false,
        aliveAfter: TimeInterval? = nil
    ) async -> ProcessOutcome {
        let box = Box()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ProcessOutcome, Never>) in
                box.continuation = c
                let p = box.process
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.standardOutput = FileHandle.nullDevice
                p.standardInput = keepStdinOpen ? box.stdin : FileHandle.nullDevice
                let err = Pipe()
                p.standardError = err
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    box.lock.lock(); box.stderr.append(d); box.lock.unlock()
                }
                p.terminationHandler = { proc in
                    let code = proc.terminationStatus
                    // Give the stderr handler a moment to drain.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        box.finish(.exited(code, stderr: box.stderrText))
                    }
                }
                if Task.isCancelled { box.finish(.cancelled); return }
                do { try p.run() } catch {
                    box.finish(.launchFailed(error.localizedDescription))
                    return
                }
                if let settle = aliveAfter {
                    DispatchQueue.global().asyncAfter(deadline: .now() + settle) {
                        if p.isRunning { box.finish(.stillRunning(stderr: box.stderrText)) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    if p.isRunning { box.finish(.timedOut(stderr: box.stderrText)) }
                }
            }
        } onCancel: {
            box.finish(.cancelled)
        }
    }
}
