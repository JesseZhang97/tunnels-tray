import AppKit
import Foundation
import TunnelsCore

enum TunnelStatus: Equatable {
    case stopped, starting, connected, reconnecting, error
}

struct TunnelState: Equatable {
    var status: TunnelStatus = .stopped
    var pid: Int32?
    var lastError: String?
    /// Why the last "open in browser" gave up; shown in the row.
    var openError: String?

    /// Running, connecting or waiting to reconnect.
    var isActive: Bool { [.starting, .connected, .reconnecting].contains(status) }
}

/// Owns the tunnel list and one ssh child process per active tunnel.
@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var tunnels: [Tunnel] = []
    @Published private(set) var states: [UUID: TunnelState] = [:]
    @Published private(set) var sshHosts: [String] = []
    @Published var notice: String?
    /// Tunnels waiting to connect before their page is opened.
    @Published private(set) var opening: Set<UUID> = []
    private var openTasks: [UUID: Task<Void, Never>] = [:]
    static let openTimeout: TimeInterval = 15

    let store = TunnelStore()
    private var runners: [UUID: Runner] = [:]

    /// Mutable per-tunnel process bookkeeping.
    private final class Runner {
        var process: Process?
        var launchedAt: Date?
        var attempt = 0
        var manualStop = false
        var restartAfterExit = false
        var stderrTail = ""
        var retryTask: Task<Void, Never>?
        var checkTask: Task<Void, Never>?
    }

    static let maxBackoff: Double = 30

    init() {
        loadTunnels()
        reloadSSHHosts()
    }

    // MARK: - Data

    var connectedCount: Int { states.values.filter { $0.status == .connected }.count }
    var anyActive: Bool { states.values.contains { $0.isActive } }

    func state(for id: UUID) -> TunnelState { states[id] ?? TunnelState() }

    func reloadSSHHosts() {
        sshHosts = SSHConfig.hosts(configPath: SSHConfig.defaultConfigPath)
    }

    private func loadTunnels() {
        do {
            let (loaded, migrated) = try store.loadMigrating()
            tunnels = loaded
            if migrated { persist() }
        } catch {
            // Keep the unreadable file aside so a later save cannot destroy it.
            let backup = store.url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.url, to: backup)
            notice = "Could not read tunnels.json (moved to \(backup.lastPathComponent)): \(error.localizedDescription)"
            tunnels = []
        }
    }

    private func persist() {
        do { try store.save(tunnels) } catch { notice = "Save failed: \(error.localizedDescription)" }
    }

    func add(_ t: Tunnel) {
        tunnels.append(t)
        persist()
    }

    func update(_ t: Tunnel) {
        guard let i = tunnels.firstIndex(where: { $0.id == t.id }) else { return add(t) }
        let changed = tunnels[i] != t
        tunnels[i] = t
        persist()
        if changed, state(for: t.id).isActive { restart(t.id) }
    }

    func delete(_ id: UUID) {
        stop(id)
        tunnels.removeAll { $0.id == id }
        states[id] = nil
        persist()
    }

    /// Add imported tunnels; an entry with an existing id replaces it.
    func importTunnels(_ imported: [Tunnel]) {
        for t in imported {
            if tunnels.contains(where: { $0.id == t.id }) { update(t) } else { tunnels.append(t) }
        }
        persist()
    }

    // MARK: - Process control

    func toggle(_ id: UUID) {
        state(for: id).isActive ? stop(id) : start(id)
    }

    func startAll() { tunnels.forEach { if !state(for: $0.id).isActive { start($0.id) } } }
    func stopAll() { tunnels.forEach { stop($0.id) } }

    func start(_ id: UUID) {
        let r = runners[id] ?? Runner()
        runners[id] = r
        r.manualStop = false
        r.restartAfterExit = false
        r.attempt = 0
        r.retryTask?.cancel()
        launch(id)
    }

    func stop(_ id: UUID) {
        cancelOpen(id)
        guard let r = runners[id] else { return }
        r.manualStop = true
        r.restartAfterExit = false
        r.retryTask?.cancel()
        r.checkTask?.cancel()
        if let p = r.process, p.isRunning { p.terminate() }
        var s = state(for: id)
        s.status = .stopped
        s.pid = nil
        states[id] = s
    }

    private func restart(_ id: UUID) {
        guard let r = runners[id] else { return start(id) }
        let running = r.process?.isRunning == true
        stop(id)
        if running { r.restartAfterExit = true } else { start(id) }
    }

    private func launch(_ id: UUID) {
        guard let t = tunnels.first(where: { $0.id == id }), let r = runners[id], !r.manualStop else { return }
        if r.process?.isRunning == true { return }

        if let reason = portBusyReason(t) {
            if r.attempt == 0 {
                setState(id, .error, error: reason)
                r.manualStop = true
            } else {
                scheduleRetry(id, reason: reason)
            }
            return
        }

        let args: [String]
        do { args = try SSHCommand.arguments(for: t) } catch {
            setState(id, .error, error: "SSH options: \(error)")
            r.manualStop = true
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendStderr(id, text, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.handleExit(id, proc, code: code) }
        }

        do { try p.run() } catch {
            setState(id, .error, error: "Could not run ssh: \(error.localizedDescription)")
            r.manualStop = true
            return
        }

        r.process = p
        r.launchedAt = Date()
        r.stderrTail = ""
        var s = state(for: id)
        s.status = r.attempt == 0 ? .starting : .reconnecting
        s.pid = p.processIdentifier
        states[id] = s
        watchForConnect(id, process: p)
    }

    /// Connected = process alive for >2 s and the local port is listening.
    private func watchForConnect(_ id: UUID, process p: Process) {
        guard let r = runners[id] else { return }
        r.checkTask?.cancel()
        r.checkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, p.isRunning,
                      let t = self.tunnels.first(where: { $0.id == id }),
                      let launched = r.launchedAt else { return }
                if Date().timeIntervalSince(launched) >= 2,
                   !PortCheck.isFree(bindAddress: t.bindAddress, port: t.localPort) {
                    var s = self.state(for: id)
                    s.status = .connected
                    s.openError = nil
                    self.states[id] = s
                    return
                }
            }
        }
    }

    private func appendStderr(_ id: UUID, _ text: String, from p: Process) {
        guard let r = runners[id], r.process === p else { return }
        r.stderrTail = String((r.stderrTail + text).suffix(2000))
    }

    private func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private func handleExit(_ id: UUID, _ p: Process, code: Int32) {
        guard let r = runners[id], r.process === p else { return }
        r.process = nil
        r.checkTask?.cancel()
        let message = lastLine(r.stderrTail) ?? "ssh exited with status \(code)"

        if r.manualStop {
            if r.restartAfterExit { start(id) }
            return
        }
        // A connection that held for a while resets the backoff.
        if let launched = r.launchedAt, Date().timeIntervalSince(launched) > 30 { r.attempt = 0 }
        scheduleRetry(id, reason: message)
    }

    private func scheduleRetry(_ id: UUID, reason: String) {
        guard let r = runners[id] else { return }
        r.attempt += 1
        let delay = min(Self.maxBackoff, pow(2, Double(r.attempt - 1)))
        var s = state(for: id)
        s.status = .reconnecting
        s.pid = nil
        s.lastError = reason
        states[id] = s
        r.retryTask?.cancel()
        r.retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.launch(id)
        }
    }

    private func setState(_ id: UUID, _ status: TunnelStatus, error: String? = nil) {
        var s = state(for: id)
        s.status = status
        s.pid = nil
        if let error { s.lastError = error }
        states[id] = s
    }

    private func portBusyReason(_ t: Tunnel) -> String? {
        let addr = PortCheck.checkAddress(for: t.bindAddress)
        guard let err = PortCheck.bindError(address: addr, port: t.localPort) else { return nil }
        if let owner = Self.listeningProcess(port: t.localPort) {
            return "Port \(t.localPort) is in use by \(owner)"
        }
        return "Cannot bind \(addr):\(t.localPort): \(err)"
    }

    /// "name (pid N)" of the process listening on a TCP port, via lsof.
    nonisolated static func listeningProcess(port: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var pid: String?
        var name: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), name == nil { name = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return "\(name ?? "process") (pid \(pid))"
    }

    /// Stop every child before the app exits.
    func shutdown() {
        let procs = runners.values.compactMap { r -> Process? in
            r.manualStop = true
            r.retryTask?.cancel()
            r.checkTask?.cancel()
            return r.process
        }
        procs.filter(\.isRunning).forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while procs.contains(where: \.isRunning), Date() < deadline { usleep(50_000) }
        procs.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
    }

    // MARK: - Actions

    /// Open the page; start the tunnel first if needed and wait (up to 15 s)
    /// until it is connected and the local port accepts connections.
    func openWhenReady(_ id: UUID) {
        guard !opening.contains(id), let t = tunnels.first(where: { $0.id == id }) else { return }
        states[id, default: TunnelState()].openError = nil
        if state(for: id).status == .connected, accepts(t) { return openInBrowser(t) }
        if !state(for: id).isActive { start(id) }
        guard state(for: id).isActive else { return } // start failed; row shows the error
        opening.insert(id)
        openTasks[id] = Task { @MainActor [weak self] in
            await self?.waitAndOpen(id)
            self?.opening.remove(id)
            self?.openTasks[id] = nil
        }
    }

    private func waitAndOpen(_ id: UUID) async {
        let deadline = Date().addingTimeInterval(Self.openTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let t = tunnels.first(where: { $0.id == id }) else { return }
            let s = state(for: id)
            if s.status == .stopped || s.status == .error { return }
            if s.status == .connected, accepts(t) { return openInBrowser(t) }
        }
        guard !Task.isCancelled else { return }
        states[id, default: TunnelState()].openError =
            "Not connected after \(Int(Self.openTimeout)) s, page not opened"
            + (state(for: id).lastError.map { ": \($0)" } ?? "")
    }

    private func cancelOpen(_ id: UUID) {
        openTasks[id]?.cancel()
        openTasks[id] = nil
        opening.remove(id)
    }

    private func accepts(_ t: Tunnel) -> Bool {
        let addr = PortCheck.checkAddress(for: t.bindAddress)
        return PortCheck.acceptsConnection(address: addr == "0.0.0.0" ? "127.0.0.1" : addr, port: t.localPort)
    }

    func openInBrowser(_ t: Tunnel) {
        if let url = t.browserURL { NSWorkspace.shared.open(url) }
    }

    func copyCommand(_ t: Tunnel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHCommand.commandLine(for: t), forType: .string)
    }
}
