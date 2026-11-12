import AppKit
import Foundation
import Network
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
    /// Process holding the local port when the last start failed because of it.
    var portOwner: PortOwner?

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

    let store: TunnelStore
    /// Demo instances (screenshots) never touch disk or processes.
    private let isDemo: Bool
    /// Demo only: draw this row as hovered.
    private(set) var demoHoverID: UUID?
    private var runners: [UUID: Runner] = [:]
    /// Running ssh children, mirrored to children.json for orphan cleanup.
    private let registry: ChildRegistry
    private var children: [UUID: ChildRecord] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var pendingTriggers: Set<String> = []
    private var reconnectTask: Task<Void, Never>?
    /// Wait after wake / network change before restarting, to merge bursts.
    static let reconnectDelay: TimeInterval = 2

    /// Mutable per-tunnel process bookkeeping.
    private final class Runner {
        var process: Process?
        var launchedAt: Date?
        var attempt = 0
        var manualStop = false
        var restartAfterExit = false
        /// Restart right after the current process exits (wake / network change).
        var relaunchAfterExit = false
        /// Why the next launch happens: "start", "retry", "wake", "network change".
        var trigger = "start"
        var stderrTail = ""
        var retryTask: Task<Void, Never>?
        var checkTask: Task<Void, Never>?
    }

    static let maxBackoff: Double = 30

    init() {
        store = TunnelStore()
        registry = ChildRegistry()
        isDemo = false
        loadTunnels()
        reloadSSHHosts()
        cleanupOrphans()
        watchWakeAndNetwork()
    }

    init(demoTunnels: [Tunnel], states: [UUID: TunnelState], hosts: [String], storeURL: URL, hoverID: UUID? = nil) {
        store = TunnelStore(url: storeURL)
        registry = ChildRegistry(url: storeURL.deletingLastPathComponent().appendingPathComponent("children.json"))
        isDemo = true
        tunnels = demoTunnels
        self.states = states
        sshHosts = hosts
        demoHoverID = hoverID
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
        guard !isDemo else { return }
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
        // A tunnel that failed on a busy port is retried with its new settings.
        if changed, state(for: t.id).isActive || state(for: t.id).portOwner != nil { restart(t.id) }
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
        r.relaunchAfterExit = false
        r.attempt = 0
        r.trigger = "start"
        r.retryTask?.cancel()
        launch(id)
    }

    func stop(_ id: UUID) {
        cancelOpen(id)
        guard let r = runners[id] else { return }
        if state(for: id).isActive { log(id, "Stopped") }
        r.manualStop = true
        r.restartAfterExit = false
        r.relaunchAfterExit = false
        r.retryTask?.cancel()
        r.checkTask?.cancel()
        if let p = r.process, p.isRunning { p.terminate() }
        var s = state(for: id)
        s.status = .stopped
        s.pid = nil
        s.portOwner = nil
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

        if let busy = portBusy(t) {
            let reason = busy.reason
            states[id, default: TunnelState()].portOwner = busy.owner
            log(id, "Port busy: \(reason)" + (busy.owner.map { " [\($0.kindDescription)] \($0.args)" } ?? ""))
            if r.attempt == 0 && r.trigger == "start" {
                // The row offers "End & Connect" / "Use Another Port"; no silent retry.
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
            let bySignal = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.handleExit(id, proc, code: code, bySignal: bySignal) }
        }

        do { try p.run() } catch {
            setState(id, .error, error: "Could not run ssh: \(error.localizedDescription)")
            r.manualStop = true
            return
        }

        r.process = p
        r.launchedAt = Date()
        r.stderrTail = ""
        log(id, "Start (\(r.trigger)), pid \(p.processIdentifier): ssh \(ShellWords.join(args))")
        children[id] = ChildRecord(tunnelID: id, pid: p.processIdentifier, argv: [SSHCommand.executable] + args)
        persistChildren()
        var s = state(for: id)
        s.status = r.attempt == 0 ? .starting : .reconnecting
        s.pid = p.processIdentifier
        s.portOwner = nil
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
                    self.log(id, "Connected: listening on port \(t.localPort)")
                    return
                }
            }
        }
    }

    private func appendStderr(_ id: UUID, _ text: String, from p: Process) {
        guard let r = runners[id], r.process === p else { return }
        r.stderrTail = String((r.stderrTail + text).suffix(2000))
        log(id, text)
    }

    private func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private func handleExit(_ id: UUID, _ p: Process, code: Int32, bySignal: Bool) {
        if children[id]?.pid == p.processIdentifier {
            children[id] = nil
            persistChildren()
        }
        guard let r = runners[id], r.process === p else { return }
        r.process = nil
        r.checkTask?.cancel()
        log(id, "ssh exited (" + (bySignal ? "signal \(code)" : "status \(code)") + ")")
        let message = lastLine(r.stderrTail) ?? "ssh exited with status \(code)"

        if r.manualStop {
            if r.restartAfterExit { start(id) }
            return
        }
        if r.relaunchAfterExit {
            r.relaunchAfterExit = false
            launch(id)
            return
        }
        // A connection that held for a while resets the backoff.
        if let launched = r.launchedAt, Date().timeIntervalSince(launched) > 30 { r.attempt = 0 }
        scheduleRetry(id, reason: message)
    }

    private func scheduleRetry(_ id: UUID, reason: String) {
        guard let r = runners[id] else { return }
        r.attempt += 1
        r.trigger = "retry"
        let delay = min(Self.maxBackoff, pow(2, Double(r.attempt - 1)))
        log(id, "Retry in \(Int(delay)) s: \(reason)")
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

    /// Why the local port cannot be bound, and who holds it (if lsof can tell).
    private func portBusy(_ t: Tunnel) -> (reason: String, owner: PortOwner?)? {
        let addr = PortCheck.checkAddress(for: t.bindAddress)
        guard let err = PortCheck.bindError(address: addr, port: t.localPort) else { return nil }
        if let owner = PortOwners.find(tunnel: t, ownPIDs: ownPIDs) {
            return ("Port \(t.localPort) is in use by \(owner.label)", owner)
        }
        return ("Cannot bind \(addr):\(t.localPort): \(err)", nil)
    }

    private var ownPIDs: Set<Int32> {
        Set(runners.values.compactMap { $0.process?.isRunning == true ? $0.process?.processIdentifier : nil })
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
        children.removeAll()
        persistChildren()
    }

    // MARK: - Port conflicts

    /// End the process holding the local port, then start the tunnel.
    /// ssh processes are ended without asking; anything else needs a confirmation.
    func endPortOwnerAndStart(_ id: UUID) {
        guard let t = tunnels.first(where: { $0.id == id }), let owner = state(for: id).portOwner else { return }
        if owner.kind == .ownChild,
           let otherID = runners.first(where: { $0.value.process?.processIdentifier == owner.pid })?.key {
            log(id, "Stopping tunnel \(tunnels.first { $0.id == otherID }?.name ?? "") that holds port \(t.localPort)")
            stop(otherID)
            startWhenPortFree(id)
            return
        }
        if owner.needsConfirmation, !confirmEnd(owner, port: t.localPort) { return }
        states[id, default: TunnelState()].lastError = "Ending \(owner.label)…"
        log(id, "Ending \(owner.label) [\(owner.kindDescription)]: \(owner.args)")
        Task { [weak self] in
            let outcome = await Task.detached { () -> ProcessKiller.Outcome in
                // Make sure the pid still belongs to the same process before signalling it.
                guard let current = PortOwners.find(tunnel: t) else { return .alreadyGone }
                guard current.pid == owner.pid, current.args == owner.args else {
                    return .failed("the port is now held by \(current.label); try again")
                }
                return ProcessKiller.terminate(pid: owner.pid)
            }.value
            self?.finishEnding(id, owner: owner, outcome: outcome)
        }
    }

    private func finishEnding(_ id: UUID, owner: PortOwner, outcome: ProcessKiller.Outcome) {
        log(id, "End \(owner.label): \(outcome)")
        if case .failed(let why) = outcome {
            setState(id, .error, error: "Could not end \(owner.label): \(why)")
            return
        }
        startWhenPortFree(id)
    }

    /// Start once the local port can be bound (up to 3 s), so a just-ended
    /// listener does not make the start fail again.
    private func startWhenPortFree(_ id: UUID) {
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let t = self?.tunnels.first(where: { $0.id == id }) else { return }
                if PortCheck.isFree(bindAddress: t.bindAddress, port: t.localPort) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.start(id)
        }
    }

    private func confirmEnd(_ owner: PortOwner, port: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "End \(owner.label)?"
        alert.informativeText = "It is listening on port \(port) and is not an ssh process.\n\n"
            + (owner.args.isEmpty ? owner.name : owner.args)
        alert.addButton(withTitle: "End Process and Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Open the edit form with a free local port filled in.
    func useAnotherPort(_ id: UUID) {
        guard let t = tunnels.first(where: { $0.id == id }) else { return }
        let taken = Set(tunnels.map(\.localPort))
        let port = PortCheck.suggestFreePort(after: t.localPort, bindAddress: t.bindAddress, avoiding: taken)
        Windows.shared.openForm(editing: t, localPort: port)
    }

    // MARK: - Wake and network changes

    private func watchWakeAndNetwork() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconnect("wake") }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(of: path)
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(signature: signature, satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.jessezhang97.tunnels.path"))
        pathMonitor = monitor
    }

    /// Status, interfaces and gateways: a change means existing TCP connections may be dead.
    nonisolated private static func signature(of path: NWPath) -> String {
        "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            + "|" + path.gateways.map { "\($0)" }.joined(separator: ",")
    }

    private func networkChanged(signature: String, satisfied: Bool) {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature, satisfied else { return }
        scheduleReconnect("network change")
    }

    private func scheduleReconnect(_ trigger: String) {
        pendingTriggers.insert(trigger)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let why = self.pendingTriggers.sorted().joined(separator: " + ")
            self.pendingTriggers = []
            self.reconnectActive(trigger: why)
        }
    }

    /// Restart every running or retrying tunnel now: cancel the backoff and
    /// start over, since the old TCP connection may be dead without ssh knowing yet.
    func reconnectActive(trigger: String) {
        for t in tunnels {
            guard let r = runners[t.id], !r.manualStop, state(for: t.id).isActive else { continue }
            log(t.id, "\(trigger.capitalized): restarting")
            r.retryTask?.cancel()
            r.attempt = 0
            r.trigger = trigger
            if let p = r.process, p.isRunning {
                r.relaunchAfterExit = true
                p.terminate()
            } else {
                launch(t.id)
            }
        }
    }

    // MARK: - Logs and child registry

    func logURL(for t: Tunnel) -> URL { TunnelLog(tunnelName: t.name).url }

    private func log(_ id: UUID, _ text: String) {
        guard !isDemo, let t = tunnels.first(where: { $0.id == id }) else { return }
        TunnelLog(tunnelName: t.name).append(text)
    }

    /// Open the tunnel's log (Console), or the log folder if there is none yet.
    func showLog(_ t: Tunnel) {
        let url = logURL(for: t)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            try? FileManager.default.createDirectory(at: TunnelLog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(TunnelLog.directory)
        }
    }

    private func persistChildren() {
        guard !isDemo else { return }
        try? registry.save(children.values.sorted { $0.startedAt < $1.startedAt })
    }

    /// End ssh processes a previous run left behind (crash, force-quit): only
    /// recorded pids now owned by launchd whose command line is unchanged.
    private func cleanupOrphans() {
        let records = registry.load()
        guard !records.isEmpty else { return }
        Task { [weak self] in
            let lines = await Task.detached { () -> [(UUID, String)] in
                var lines: [(UUID, String)] = []
                for rec in records {
                    guard let info = PortOwners.processInfo(pid: rec.pid),
                          ChildRegistry.isOrphan(rec, ppid: info.ppid, args: info.args) else { continue }
                    let outcome = ProcessKiller.terminate(pid: rec.pid)
                    lines.append((rec.tunnelID, "Launch cleanup: orphaned ssh pid \(rec.pid): \(outcome)"))
                }
                return lines
            }.value
            guard let self else { return }
            lines.forEach { self.log($0.0, $0.1) }
            self.persistChildren()
        }
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
