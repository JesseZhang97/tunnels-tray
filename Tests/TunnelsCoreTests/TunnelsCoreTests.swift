import Foundation
import XCTest
import Darwin
@testable import TunnelsCore

final class ShellWordsTests: XCTestCase {
    func testSplit() throws {
        XCTAssertEqual(try ShellWords.split("-o A=1  -o 'B=two words' -o \"C=\\\"q\\\"\" x\\ y"),
                       ["-o", "A=1", "-o", "B=two words", "-o", "C=\"q\"", "x y"])
        XCTAssertEqual(try ShellWords.split("   "), [])
        XCTAssertEqual(try ShellWords.split("''"), [""])
    }

    func testSplitErrors() {
        XCTAssertThrowsError(try ShellWords.split("-o 'oops"))
        XCTAssertThrowsError(try ShellWords.split("abc\\"))
    }

    func testQuoteRoundTrip() throws {
        let words = ["plain", "has space", "it's", "", "-o", "A=1"]
        XCTAssertEqual(try ShellWords.split(ShellWords.join(words)), words)
    }
}

final class SSHCommandTests: XCTestCase {
    let base = ["-N", "-T", "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=10"]

    func testDefaultCommand() throws {
        let t = Tunnel(name: "My Web App", sshHost: "my-server", localPort: 8080, remotePort: 8080)
        XCTAssertEqual(try SSHCommand.arguments(for: t),
                       base + ["-L", "127.0.0.1:8080:127.0.0.1:8080", "my-server"])
        XCTAssertEqual(SSHCommand.commandLine(for: t),
            "ssh -N -T -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -L 127.0.0.1:8080:127.0.0.1:8080 my-server")
    }

    func testEmptyBind() throws {
        let t = Tunnel(name: "Grafana", sshHost: "example-host", localPort: 3000, remotePort: 3000, bindAddress: "")
        XCTAssertEqual(try SSHCommand.arguments(for: t), base + ["-L", "3000:127.0.0.1:3000", "example-host"])
    }

    func testUserOptionOverridesDefault() throws {
        let t = Tunnel(name: "x", sshHost: "h", localPort: 1, remotePort: 2,
                       sshOptions: "-o serveraliveinterval=60 -C -o Compression=yes")
        XCTAssertEqual(try SSHCommand.arguments(for: t), [
            "-N", "-T", "-o", "BatchMode=yes",
            "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
            "-L", "127.0.0.1:1:127.0.0.1:2",
            "-o", "serveraliveinterval=60", "-C", "-o", "Compression=yes",
            "h",
        ])
    }

    func testConnectTimeoutDefaultAndOverride() throws {
        let t = Tunnel(name: "x", sshHost: "h", localPort: 1, remotePort: 2, sshOptions: "-o ConnectTimeout=30")
        let args = try SSHCommand.arguments(for: t)
        XCTAssertFalse(args.contains("ConnectTimeout=10"))
        XCTAssertTrue(args.contains("ConnectTimeout=30"))
        // The connection test keeps its own shorter timeout, once.
        let plain = Tunnel(name: "y", sshHost: "h", localPort: 1, remotePort: 2)
        XCTAssertEqual(try ConnectionTest.loginArguments(for: plain).filter { $0.hasPrefix("ConnectTimeout=") },
                       ["ConnectTimeout=8"])
    }

    func testIPv6() {
        let t = Tunnel(name: "v6", sshHost: "h", localPort: 80, remoteHost: "::1", remotePort: 8080, bindAddress: "::1")
        XCTAssertEqual(SSHCommand.forwardSpec(for: t), "[::1]:80:[::1]:8080")
        XCTAssertEqual(t.browserURL?.absoluteString, "http://[::1]:80")
    }

    func testBrowserHost() {
        var t = Tunnel(name: "a", sshHost: "h", localPort: 1, remotePort: 1, bindAddress: "0.0.0.0")
        XCTAssertEqual(t.browserURL?.absoluteString, "http://127.0.0.1:1")
        t.bindAddress = "10.0.0.7"
        XCTAssertEqual(t.browserURL?.absoluteString, "http://10.0.0.7:1")
    }
}

final class SSHConfigTests: XCTestCase {
    func testHosts() {
        let text = """
        # comment
        Include extra/*
        Host 10.0.0.5
          HostName 10.0.0.5
        Host github github.com
            HostName ssh.github.com
        Host *
            ServerAliveInterval 30
        Host *.internal !bad prod-?
        host=lower-equals
        HOST   "quoted name" example-host
        Match host foo
        Host example-host
        """
        let hosts = SSHConfig.hosts(in: text) { pattern in
            pattern == "extra/*" ? ["Host included-host\n  HostName 127.0.0.1\nInclude loop"] : []
        }
        XCTAssertEqual(hosts, ["included-host", "10.0.0.5", "github", "github.com",
                               "lower-equals", "quoted name", "example-host"])
    }

    func testIncludeRecursionIsBounded() {
        let hosts = SSHConfig.hosts(in: "Include self\nHost a") { _ in ["Include self\nHost a"] }
        XCTAssertEqual(hosts, ["a"])
    }

    func testIncludeFilesOnDisk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ssh = home.appendingPathComponent(".ssh/conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Host b\n".write(to: ssh.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)
        try "Host a\n".write(to: ssh.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        let config = home.appendingPathComponent(".ssh/config")
        try "Include conf.d/*.conf\nInclude ~/.ssh/missing\nHost top\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHConfig.hosts(configPath: config.path, home: home.path), ["a", "b", "top"])
    }
}

final class ModelTests: XCTestCase {
    func testDecodeDefaultsAndStringPorts() throws {
        let json = #"[{"name":"Grafana","ssh_host":"example-host","local_port":"3000","remote_port":3000}]"#
        let t = try XCTUnwrap(TunnelStore.decode(Data(json.utf8)).first)
        XCTAssertEqual(t.localPort, 3000)
        XCTAssertEqual(t.remoteHost, "127.0.0.1")
        XCTAssertEqual(t.bindAddress, "127.0.0.1")
        XCTAssertEqual(t.sshOptions, "")
    }

    func testEncodeUsesSnakeCaseAndRoundTrips() throws {
        let t = Tunnel(name: "My Web App", sshHost: "my-server", localPort: 8080, remotePort: 8080, note: "n")
        let data = try TunnelStore.encode([t])
        let text = String(decoding: data, as: UTF8.self)
        for key in ["ssh_host", "local_port", "remote_host", "remote_port", "bind_address", "ssh_options", "note"] {
            XCTAssertTrue(text.contains("\"\(key)\""), key)
        }
        XCTAssertEqual(try TunnelStore.decode(data), [t])
    }

    func testStoreSaveLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tunnels.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TunnelStore(url: url)
        XCTAssertEqual(try store.load(), [])
        let t = Tunnel(name: "x", sshHost: "h", localPort: 1, remotePort: 2)
        try store.save([t])
        XCTAssertEqual(try store.load(), [t])
    }

    func testDraftValidation() {
        var d = TunnelDraft()
        XCTAssertEqual(d.errors.count, 4) // name, host, two ports
        d.name = "x"; d.sshHost = "h"; d.localPort = "70000"; d.remotePort = "0"
        XCTAssertEqual(d.errors, ["Local port must be 1–65535.", "Remote port must be 1–65535."])
        d.localPort = " 8080 "; d.remotePort = "80"; d.remoteHost = ""
        XCTAssertEqual(d.errors, [])
        XCTAssertEqual(d.tunnel()?.remoteHost, "127.0.0.1")
        d.sshOptions = "-o 'x"
        XCTAssertNil(d.tunnel())
        d.sshOptions = ""; d.sshHost = "-oProxyCommand=x"
        XCTAssertFalse(d.errors.isEmpty)
    }
}

final class PortCheckTests: XCTestCase {
    func testDetectsListeningPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        XCTAssertEqual(listen(fd, 1), 0)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertFalse(PortCheck.isFree(bindAddress: "127.0.0.1", port: port))
        XCTAssertFalse(PortCheck.isFree(bindAddress: "", port: port))
        XCTAssertTrue(PortCheck.acceptsConnection(address: "127.0.0.1", port: port))
        close(fd)
        XCTAssertTrue(PortCheck.isFree(bindAddress: "127.0.0.1", port: port))
        XCTAssertFalse(PortCheck.acceptsConnection(address: "127.0.0.1", port: port))
        XCTAssertFalse(PortCheck.acceptsConnection(address: "not-an-ip", port: port))
    }
}

final class SSHOptionsTests: XCTestCase {
    private func pairs(_ p: SSHOptions.Parsed) -> [[String]] { p.options.map { [$0.key, $0.value] } }

    func testParseForms() throws {
        let p = try SSHOptions.parse("-o compression=yes -oConnectTimeout=5 -o 'IPQoS af21 cs1' -o \"User = bob\" -C -i ~/.ssh/k")
        XCTAssertEqual(pairs(p), [["Compression", "yes"], ["ConnectTimeout", "5"], ["IPQoS", "af21 cs1"], ["User", "bob"]])
        XCTAssertEqual(p.extras, ["-C", "-i", "~/.ssh/k"])
        XCTAssertThrowsError(try SSHOptions.parse("-o"))
    }

    func testGenerateRoundTrip() throws {
        let options = [SSHOption(key: "IPQoS", value: "af21 cs1"), SSHOption(key: "IdentityFile", value: "~/My Keys/id"),
                       SSHOption(key: "Custom", value: "it's")]
        let text = SSHOptions.generate(options, extras: ["-C"])
        XCTAssertEqual(text, "-o 'IPQoS=af21 cs1' -o 'IdentityFile=~/My Keys/id' -o 'Custom=it'\\''s' -C")
        let back = try SSHOptions.parse(text)
        XCTAssertEqual(pairs(back), options.map { [$0.key, $0.value] })
        XCTAssertEqual(back.extras, ["-C"])
        XCTAssertEqual(SSHOptions.generate(back.options, extras: back.extras), text)
        XCTAssertEqual(SSHOptions.generate([]), "")
    }

    func testErrors() {
        XCTAssertEqual(SSHOptions.errors(in: "-o ConnectTimeout=5 -o Compression=no -C"), [])
        XCTAssertEqual(SSHOptions.errors(in: "-o ConnectTimeout=abc"), ["ConnectTimeout must be a number."])
        XCTAssertEqual(SSHOptions.errors(in: "-o Compression=maybe"), ["Compression must be yes or no."])
        XCTAssertEqual(SSHOptions.errors(in: "-o User="), ["User needs a value."])
        XCTAssertEqual(SSHOptions.errors(in: "-o =x"), ["Option key is required."])
        XCTAssertEqual(SSHOptions.errors(in: "-o LogLevel=verbose"), [])
        XCTAssertFalse(SSHOptions.errors(in: "-o 'x").isEmpty)
    }

    func testStripBuiltIns() {
        XCTAssertEqual(SSHOptions.stripBuiltIns("-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"), "")
        XCTAssertEqual(SSHOptions.stripBuiltIns("-N -T -o BatchMode=yes -oserveraliveinterval=15 -o Compression=yes"),
                       "-o Compression=yes")
        // A different value is the user's choice and stays.
        XCTAssertEqual(SSHOptions.stripBuiltIns("-o ServerAliveInterval=60 -o ExitOnForwardFailure=yes"),
                       "-o ServerAliveInterval=60")
        // Nothing to strip: text is returned untouched.
        XCTAssertEqual(SSHOptions.stripBuiltIns("-C   -o User=x"), "-C   -o User=x")
        XCTAssertEqual(SSHOptions.stripBuiltIns("-o 'broken"), "-o 'broken")
    }

    func testStoreMigration() throws {
        let json = #"""
        [{"name":"My Web App","ssh_host":"my-server","local_port":8080,"remote_port":8080,
          "ssh_options":"-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"},
         {"name":"Grafana","ssh_host":"example-host","local_port":3000,"remote_port":3000,"ssh_options":""}]
        """#
        let (tunnels, migrated) = try TunnelStore.decodeMigrating(Data(json.utf8))
        XCTAssertTrue(migrated)
        XCTAssertEqual(tunnels.map(\.sshOptions), ["", ""])
        let (_, again) = try TunnelStore.decodeMigrating(TunnelStore.encode(tunnels))
        XCTAssertFalse(again)
    }
}

final class ConnectionTestTests: XCTestCase {
    let defaults = ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes"]

    func testLoginArguments() throws {
        let t = Tunnel(name: "My Web App", sshHost: "my-server", localPort: 8080, remotePort: 8080)
        XCTAssertEqual(try ConnectionTest.loginArguments(for: t),
                       ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] + defaults + ["my-server", "exit"])
    }

    func testReachArgumentsWithUserOverrides() throws {
        let t = Tunnel(name: "x", sshHost: "example-host", localPort: 3000, remoteHost: "::1", remotePort: 3000,
                       sshOptions: "-o connecttimeout=3 -o ServerAliveInterval=60 -C")
        XCTAssertEqual(try ConnectionTest.reachArguments(for: t), [
            "-o", "BatchMode=yes",
            "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
            "-o", "connecttimeout=3", "-o", "ServerAliveInterval=60", "-C",
            "-W", "[::1]:3000", "example-host",
        ])
    }

    func testErrorSummary() {
        XCTAssertEqual(ConnectionTest.errorSummary("Warning: Permanently added 'x' (ED25519) to the list of known hosts.\nuser@h: Permission denied (publickey).\n"),
                       "user@h: Permission denied (publickey).")
        XCTAssertEqual(ConnectionTest.errorSummary("channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed\n"),
                       "channel 0: open failed: connect failed: Connection refused")
    }

    func testOutcomeClassification() {
        XCTAssertEqual(ConnectionTest.loginState(.exited(0, stderr: "")), .passed("Logged in"))
        XCTAssertEqual(ConnectionTest.loginState(.exited(255, stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known\n")),
                       .failed("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known"))
        XCTAssertEqual(ConnectionTest.loginState(.timedOut(stderr: "")), .failed("Timed out"))
        XCTAssertEqual(ConnectionTest.reachState(.stillRunning(stderr: ""), target: "a:1"), .passed("a:1 accepted the connection"))
        XCTAssertEqual(ConnectionTest.reachState(.stillRunning(stderr: "channel 0: open failed: administratively prohibited: open failed"), target: "a:1"),
                       .failed("channel 0: open failed: administratively prohibited: open failed"))
        XCTAssertEqual(ConnectionTest.reachState(.exited(255, stderr: "channel 0: open failed: connect failed: Connection refused\nstdio forwarding failed"), target: "a:1"),
                       .failed("channel 0: open failed: connect failed: Connection refused"))
        XCTAssertEqual(ConnectionTest.reachState(.exited(0, stderr: ""), target: "a:1"), .passed("a:1 accepted and closed the connection"))
    }

    func testRunnerTimeoutAndCancel() async {
        let slow = await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.5)
        if case .timedOut = slow {} else { XCTFail("expected timeout, got \(slow)") }
        let alive = await ProcessRunner.run(executable: "/bin/cat", arguments: [], timeout: 5,
                                            keepStdinOpen: true, aliveAfter: 0.3)
        XCTAssertEqual(alive, .stillRunning(stderr: ""))
        let task = Task { await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 5) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, .cancelled)
        let ok = await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], timeout: 5)
        XCTAssertEqual(ok, .exited(3, stderr: "oops\n"))
    }
}

/// Live checks against a real host. Nothing is hard-coded; set:
///   TUNNELS_LIVE=1 TUNNELS_LIVE_HOST=<Host from ~/.ssh/config> TUNNELS_LIVE_PORT=<open remote port>
///   swift test --filter Live
private struct LiveConfig {
    let host: String
    let port: Int

    static func load() throws -> LiveConfig {
        let env = ProcessInfo.processInfo.environment
        guard env["TUNNELS_LIVE"] == "1", let host = env["TUNNELS_LIVE_HOST"], !host.isEmpty,
              let port = env["TUNNELS_LIVE_PORT"].flatMap(Int.init) else {
            throw XCTSkip("set TUNNELS_LIVE=1, TUNNELS_LIVE_HOST and TUNNELS_LIVE_PORT")
        }
        return LiveConfig(host: host, port: port)
    }
}

/// A local port that is free right now.
private func freeLocalPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}

final class LiveConnectionTests: XCTestCase {
    func testLiveConnectionTest() async throws {
        let cfg = try LiveConfig.load()
        let cases = [
            Tunnel(name: "open-port", sshHost: cfg.host, localPort: freeLocalPort(), remotePort: cfg.port),
            Tunnel(name: "closed-port", sshHost: cfg.host, localPort: freeLocalPort(), remotePort: 1),
            Tunnel(name: "bogus-host", sshHost: "no-such-host.invalid", localPort: freeLocalPort(), remotePort: 80),
        ]
        var results: [String: [ConnectionTest.Step]] = [:]
        for t in cases {
            let start = Date()
            let steps = await ConnectionTest.run(t)
            results[t.name] = steps
            print("LIVE \(t.name) (\(String(format: "%.1f", Date().timeIntervalSince(start)))s):")
            for s in steps { print("LIVE   \(s.kind.title): \(s.state)") }
        }
        func passed(_ s: ConnectionTest.Step) -> Bool { if case .passed = s.state { return true }; return false }
        XCTAssertTrue(results["open-port"]!.allSatisfy(passed))
        XCTAssertFalse(passed(results["closed-port"]![2]))
        XCTAssertFalse(passed(results["bogus-host"]![1]))
    }
}

/// Auto-connect path used by "open in browser": start the real ssh forward and
/// wait until the local port accepts connections. No browser is opened.
final class LiveAutoConnectTests: XCTestCase {
    private func startAndWait(_ t: Tunnel, timeout: TimeInterval = 15) throws -> (accepted: Bool, seconds: Double, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        p.arguments = try SSHCommand.arguments(for: t)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let start = Date()
        try p.run()
        defer {
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
        while Date().timeIntervalSince(start) < timeout {
            if PortCheck.acceptsConnection(address: "127.0.0.1", port: t.localPort) {
                return (true, Date().timeIntervalSince(start), "")
            }
            if !p.isRunning {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return (false, Date().timeIntervalSince(start), text)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return (false, timeout, "timed out")
    }

    func testLiveAutoConnect() throws {
        let cfg = try LiveConfig.load()
        let good = Tunnel(name: "live", sshHost: cfg.host, localPort: freeLocalPort(), remotePort: cfg.port)
        let ok = try startAndWait(good)
        print("LIVE auto-connect accepted=\(ok.accepted) after \(String(format: "%.1f", ok.seconds))s \(ok.stderr)")
        XCTAssertTrue(ok.accepted)

        let bogus = Tunnel(name: "bogus", sshHost: "no-such-host.invalid", localPort: freeLocalPort(), remotePort: 80)
        let bad = try startAndWait(bogus)
        print("LIVE bogus accepted=\(bad.accepted) after \(String(format: "%.1f", bad.seconds))s stderr=\(bad.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertFalse(bad.accepted)
    }
}

final class PortOwnerTests: XCTestCase {
    let t = Tunnel(name: "cpa", sshHost: "taiwan-nmcloud", localPort: 8317, remotePort: 8317)

    func testParseLsof() {
        XCTAssertEqual(PortOwners.parseLsof("p24840\ncssh\nf5\n").map { [String($0.pid), $0.name] }, ["24840", "ssh"])
        // Two listeners (v4 + v6) of different processes: the first one wins.
        XCTAssertEqual(PortOwners.parseLsof("p1\ncnc\np2\ncssh\n")?.pid, 1)
        XCTAssertNil(PortOwners.parseLsof(""))
    }

    func testParsePS() {
        let r = PortOwners.parsePS("    1 /usr/bin/ssh -N -L 8317:127.0.0.1:8317 taiwan-nmcloud\n")
        XCTAssertEqual(r?.ppid, 1)
        XCTAssertEqual(r?.args, "/usr/bin/ssh -N -L 8317:127.0.0.1:8317 taiwan-nmcloud")
        XCTAssertEqual(PortOwners.parsePS("42")?.ppid, 42)
        XCTAssertNil(PortOwners.parsePS(""))
        XCTAssertNil(PortOwners.parsePS("abc def"))
    }

    func testMatchesForward() {
        let jesse = "ssh -N -T -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -L 127.0.0.1:8317:127.0.0.1:8317 taiwan-nmcloud"
        XCTAssertTrue(PortOwners.matchesForward(args: jesse, tunnel: t))
        XCTAssertTrue(PortOwners.matchesForward(args: "ssh -fNL8317:localhost:8317 root@taiwan-nmcloud", tunnel: t))
        XCTAssertFalse(PortOwners.matchesForward(args: "ssh -L 8317:127.0.0.1:9999 taiwan-nmcloud", tunnel: t))
        XCTAssertFalse(PortOwners.matchesForward(args: "ssh -L 8317:127.0.0.1:8317 other-host", tunnel: t))
        XCTAssertFalse(PortOwners.matchesForward(args: "ssh taiwan-nmcloud", tunnel: t))
        let v6 = Tunnel(name: "v6", sshHost: "h", localPort: 80, remoteHost: "::1", remotePort: 8080, bindAddress: "::1")
        XCTAssertTrue(PortOwners.matchesForward(args: "/usr/bin/ssh -L [::1]:80:[::1]:8080 h", tunnel: v6))
    }

    func testClassify() {
        let ssh = "/usr/bin/ssh -N -L 127.0.0.1:8317:127.0.0.1:8317 taiwan-nmcloud"
        XCTAssertEqual(PortOwners.classify(pid: 5, name: "ssh", args: ssh, tunnel: t, ownPIDs: [5]), .ownChild)
        XCTAssertEqual(PortOwners.classify(pid: 5, name: "ssh", args: ssh, tunnel: t, ownPIDs: []), .staleSameForward)
        XCTAssertEqual(PortOwners.classify(pid: 5, name: "ssh", args: "ssh -D 8317 h", tunnel: t, ownPIDs: []), .otherSSH)
        XCTAssertEqual(PortOwners.classify(pid: 5, name: "nc", args: "nc -l 8317", tunnel: t, ownPIDs: []), .other)
        XCTAssertTrue(PortOwner(pid: 5, ppid: 1, name: "nc", args: "", kind: .other).needsConfirmation)
        XCTAssertFalse(PortOwner(pid: 5, ppid: 1, name: "ssh", args: "", kind: .otherSSH).needsConfirmation)
    }

    /// Real listeners on a free port: an `nc -l` and a Terminal-style orphan ssh.
    func testFindRealListeners() throws {
        let port = freeLocalPort()
        let tunnel = Tunnel(name: "probe", sshHost: "no-such-host.invalid", localPort: port, remotePort: port)

        // nc -l, detached so it is not our child.
        let ncPID = try spawnDetached("nc -l 127.0.0.1 \(port)")
        defer { _ = ProcessKiller.terminate(pid: ncPID) }
        XCTAssertTrue(waitUntil { !PortCheck.isFree(bindAddress: "127.0.0.1", port: port) })
        let nc = try XCTUnwrap(PortOwners.find(tunnel: tunnel))
        XCTAssertEqual(nc.pid, ncPID)
        XCTAssertEqual(nc.kind, .other)
        XCTAssertEqual(nc.ppid, 1)
        XCTAssertEqual(ProcessKiller.terminate(pid: ncPID), .ended)
        XCTAssertTrue(waitUntil { PortCheck.isFree(bindAddress: "127.0.0.1", port: port) })
        XCTAssertEqual(ProcessKiller.terminate(pid: ncPID), .alreadyGone)
    }

    func testKillerEscalatesToSIGKILL() throws {
        let pid = try spawnDetached("( trap '' TERM; while :; do sleep 0.1; done )")
        XCTAssertTrue(ProcessKiller.isAlive(pid))
        XCTAssertEqual(ProcessKiller.terminate(pid: pid, grace: 0.5), .killed)
        XCTAssertFalse(ProcessKiller.isAlive(pid))
        XCTAssertEqual(ProcessKiller.terminate(pid: 1), .failed("refusing to signal pid 1"))
    }

    func testSuggestFreePort() {
        let p = freeLocalPort()
        let s = PortCheck.suggestFreePort(after: p, bindAddress: "127.0.0.1", avoiding: [p + 1])
        XCTAssertNotNil(s)
        XCTAssertNotEqual(s, p + 1)
        XCTAssertGreaterThan(s ?? 0, p)
        XCTAssertNil(PortCheck.suggestFreePort(after: 65535, bindAddress: "127.0.0.1"))
    }
}

/// Start a shell command detached (re-parented to launchd, like a Terminal
/// `nohup ... &` leftover) and return its pid.
func spawnDetached(_ command: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "\(command) >/dev/null 2>&1 </dev/null & echo $!"]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return try XCTUnwrap(Int32(text), "no pid from: \(text)")
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}