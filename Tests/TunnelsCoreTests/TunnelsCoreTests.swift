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
    func testNMcloud() throws {
        let t = Tunnel(name: "NMcloud", sshHost: "taiwan-nmcloud", localPort: 18317, remotePort: 18317)
        XCTAssertEqual(try SSHCommand.arguments(for: t), [
            "-N", "-T", "-o", "BatchMode=yes",
            "-L", "127.0.0.1:18317:127.0.0.1:18317",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
            "taiwan-nmcloud",
        ])
        XCTAssertEqual(SSHCommand.commandLine(for: t),
            "ssh -N -T -o BatchMode=yes -L 127.0.0.1:18317:127.0.0.1:18317 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes taiwan-nmcloud")
    }

    func testMagpieEmptyBindAndNoOptions() throws {
        let t = Tunnel(name: "magpie", sshHost: "contabo", localPort: 3430, remotePort: 3430,
                       bindAddress: "", sshOptions: "")
        XCTAssertEqual(try SSHCommand.arguments(for: t),
                       ["-N", "-T", "-o", "BatchMode=yes", "-L", "3430:127.0.0.1:3430", "contabo"])
    }

    func testIPv6() {
        let t = Tunnel(name: "v6", sshHost: "h", localPort: 80, remoteHost: "::1", remotePort: 8080, bindAddress: "::1")
        XCTAssertEqual(SSHCommand.forwardSpec(for: t), "[::1]:80:[::1]:8080")
        XCTAssertEqual(t.browserURL?.absoluteString, "http://[::1]:80")
    }

    func testBrowserHost() {
        var t = Tunnel(name: "a", sshHost: "h", localPort: 1, remotePort: 1, bindAddress: "0.0.0.0")
        XCTAssertEqual(t.browserURL?.absoluteString, "http://127.0.0.1:1")
        t.bindAddress = "192.168.1.5"
        XCTAssertEqual(t.browserURL?.absoluteString, "http://192.168.1.5:1")
    }
}

final class SSHConfigTests: XCTestCase {
    func testHosts() {
        let text = """
        # comment
        Include extra/*
        Host 192.168.5.172
          HostName 192.168.5.172
        Host github github.com
            HostName ssh.github.com
        Host *
            ServerAliveInterval 30
        Host *.internal !bad prod-?
        host=lower-equals
        HOST   "quoted name" contabo
        Match host foo
        Host contabo
        """
        let hosts = SSHConfig.hosts(in: text) { pattern in
            pattern == "extra/*" ? ["Host colima\n  HostName 127.0.0.1\nInclude loop"] : []
        }
        XCTAssertEqual(hosts, ["colima", "192.168.5.172", "github", "github.com",
                               "lower-equals", "quoted name", "contabo"])
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
        let json = #"[{"name":"magpie","ssh_host":"contabo","local_port":"3430","remote_port":3430}]"#
        let t = try XCTUnwrap(TunnelStore.decode(Data(json.utf8)).first)
        XCTAssertEqual(t.localPort, 3430)
        XCTAssertEqual(t.remoteHost, "127.0.0.1")
        XCTAssertEqual(t.bindAddress, "127.0.0.1")
        XCTAssertEqual(t.sshOptions, Tunnel.defaultSSHOptions)
    }

    func testEncodeUsesSnakeCaseAndRoundTrips() throws {
        let t = Tunnel(name: "NMcloud", sshHost: "taiwan-nmcloud", localPort: 18317, remotePort: 18317, note: "n")
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
        close(fd)
        XCTAssertTrue(PortCheck.isFree(bindAddress: "127.0.0.1", port: port))
    }
}
