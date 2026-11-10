import Foundation

/// Builds the ssh invocation for a tunnel:
/// `/usr/bin/ssh -N -T -o BatchMode=yes -o <defaults not set by the tunnel>
///  -L bind:local:remote_host:remote_port <extra options> ssh_host`
public enum SSHCommand {
    public static let executable = "/usr/bin/ssh"

    private static func bracketIfIPv6(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// The `-L` argument. An empty bind address leaves the choice to ssh.
    public static func forwardSpec(for t: Tunnel) -> String {
        let bind = t.bindAddress.trimmingCharacters(in: .whitespaces)
        let target = "\(t.localPort):\(bracketIfIPv6(t.remoteHost)):\(t.remotePort)"
        return bind.isEmpty ? target : "\(bracketIfIPv6(bind)):\(target)"
    }

    public static func arguments(for t: Tunnel) throws -> [String] {
        let extras = try ShellWords.split(t.sshOptions)
        let userKeys = SSHOptions.userKeys(in: t.sshOptions)
        let defaults = SSHOptions.defaultOptions
            .filter { !userKeys.contains($0.key.lowercased()) }
            .flatMap { ["-o", "\($0.key)=\($0.value)"] }
        return SSHOptions.fixedArguments + defaults + ["-L", forwardSpec(for: t)] + extras + [t.sshHost]
    }

    /// Copy-pasteable command line.
    public static func commandLine(for t: Tunnel) -> String {
        guard let args = try? arguments(for: t) else {
            return "ssh \(SSHOptions.baseDescription) -L \(forwardSpec(for: t)) \(t.sshOptions) \(t.sshHost)"
        }
        return "ssh " + ShellWords.join(args)
    }
}
