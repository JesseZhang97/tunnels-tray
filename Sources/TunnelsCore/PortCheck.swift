import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Checks whether a TCP port can be bound on an address.
public enum PortCheck {
    /// Address that ssh would bind for this bind-address string.
    public static func checkAddress(for bindAddress: String) -> String {
        switch bindAddress.trimmingCharacters(in: .whitespaces) {
        case "", "localhost": return "127.0.0.1"
        case "*": return "0.0.0.0"
        case let b: return b.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
    }

    /// nil if free, else the errno text (e.g. "Address already in use").
    public static func bindError(address: String, port: Int) -> String? {
        var v4 = sockaddr_in()
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET, address, &v4.sin_addr) == 1 {
            #if canImport(Darwin)
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = in_port_t(UInt16(port).bigEndian)
            return tryBind(family: AF_INET, &v4)
        }
        if inet_pton(AF_INET6, address, &v6.sin6_addr) == 1 {
            #if canImport(Darwin)
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = in_port_t(UInt16(port).bigEndian)
            return tryBind(family: AF_INET6, &v6)
        }
        return nil // hostname bind address: let ssh decide
    }

    /// True if a TCP connect to address:port succeeds (meant for loopback).
    public static func acceptsConnection(address: String, port: Int) -> Bool {
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = sockaddr_in()
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            #if canImport(Darwin)
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = in_port_t(UInt16(port).bigEndian)
            return tryConnect(family: AF_INET, &v4)
        }
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            #if canImport(Darwin)
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = in_port_t(UInt16(port).bigEndian)
            return tryConnect(family: AF_INET6, &v6)
        }
        return false
    }

    private static func tryConnect<T>(family: Int32, _ addr: inout T) -> Bool {
        #if canImport(Darwin)
        let fd = socket(family, SOCK_STREAM, 0)
        #else
        let fd = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<T>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        } == 0
    }

    public static func isFree(bindAddress: String, port: Int) -> Bool {
        bindError(address: checkAddress(for: bindAddress), port: port) == nil
    }

    /// First free port after `port` (up to 200 tries) that is not in `avoiding`.
    public static func suggestFreePort(after port: Int, bindAddress: String, avoiding: Set<Int> = []) -> Int? {
        let start = max(1024, port + 1)
        guard start <= 65535 else { return nil }
        for candidate in start...min(65535, start + 199) where !avoiding.contains(candidate) {
            if isFree(bindAddress: bindAddress, port: candidate) { return candidate }
        }
        return nil
    }

    private static func tryBind<T>(family: Int32, _ addr: inout T) -> String? {
        #if canImport(Darwin)
        let fd = socket(family, SOCK_STREAM, 0)
        #else
        let fd = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<T>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        return rc == 0 ? nil : String(cString: strerror(errno))
    }
}
