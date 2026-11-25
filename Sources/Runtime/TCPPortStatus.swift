import Darwin
import Dispatch

enum TCPPortStatus: Sendable {
    case available
    case occupied
    case unknown

    private static let checkQueue = DispatchQueue(
        label: "devlauncher.portcheck",
        qos: .utility,
        attributes: .concurrent
    )

    static func checkAsync(_ port: UInt16) async -> Self {
        await withCheckedContinuation { continuation in
            checkQueue.async {
                continuation.resume(returning: check(port))
            }
        }
    }

    static func check(_ port: UInt16) -> Self {
        guard port != 0 else { return .unknown }
        let ipv4 = probe(port, family: AF_INET)
        if ipv4 == .occupied { return .occupied }
        let ipv6 = probe(port, family: AF_INET6)
        if ipv6 == .occupied { return .occupied }
        return ipv4 == .available && ipv6 == .available ? .available : .unknown
    }

    private static func probe(_ port: UInt16, family: Int32) -> Self {
        // Without SO_REUSEADDR, XNU rejects bind() with EADDRINUSE whenever ANY local PCB holds
        // the port (wildcard, loopback, or interface-specific; LISTEN, ESTABLISHED, or TIME_WAIT).
        // Avoiding listen() on this fast path prevents wildcard listener registration on free ports.
        let status = probeAddress(port, family: family, address: nil, reuseAddress: false, callListen: false)
        guard status == .occupied else { return status }

        // A recently closed TCP connection in TIME_WAIT keeps non-reusable bind busy.
        // Check loopback first (where dev servers listen most often) without touching external NICs.
        let loopback = probeLoopback(port, family: family)
        if loopback == .occupied { return .occupied }

        let wildcard = probeAddress(port, family: family, address: nil, reuseAddress: true, callListen: false)
        guard wildcard == .available else { return wildcard }

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return .unknown }
        defer { freeifaddrs(first) }

        var result: Self = loopback
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            entry = current.pointee.ifa_next
            guard let address = current.pointee.ifa_addr, Int32(address.pointee.sa_family) == family,
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let local = probeAddress(port, family: family, address: address, reuseAddress: true, callListen: false)
            if local == .occupied { return .occupied }
            if local == .unknown { result = .unknown }
        }
        return result
    }

    private static func probeLoopback(_ port: UInt16, family: Int32) -> Self {
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    probeAddress(port, family: family, address: $0, reuseAddress: true, callListen: true)
                }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    probeAddress(port, family: family, address: $0, reuseAddress: true, callListen: true)
                }
            }
        }
    }

    private static func probeAddress(
        _ port: UInt16, family: Int32, address: UnsafePointer<sockaddr>?, reuseAddress: Bool, callListen: Bool
    ) -> Self {
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return .unknown }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        if reuseAddress && setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, optionSize) != 0 {
            return .unknown
        }

        let result: Int32
        if family == AF_INET {
            var local = address?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } ?? sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = port.bigEndian
            result = bindAddress(descriptor, &local)
        } else {
            guard setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, optionSize) == 0 else { return .unknown }
            var local = address?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee } ?? sockaddr_in6()
            local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            local.sin6_family = sa_family_t(AF_INET6)
            local.sin6_port = port.bigEndian
            result = bindAddress(descriptor, &local)
        }
        if result != 0 { return errno == EADDRINUSE ? .occupied : .unknown }
        if callListen && listen(descriptor, 1) != 0 {
            return errno == EADDRINUSE ? .occupied : .unknown
        }
        return .available
    }

    private static func bindAddress<Address>(_ descriptor: Int32, _ address: inout Address) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
    }
}
