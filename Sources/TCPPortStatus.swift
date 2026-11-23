import Darwin

enum TCPPortStatus {
    case available
    case occupied
    case unknown

    static func check(_ port: UInt16) -> Self {
        guard port != 0 else { return .unknown }
        let ipv4 = probe(port, family: AF_INET)
        if ipv4 == .occupied { return .occupied }
        let ipv6 = probe(port, family: AF_INET6)
        if ipv6 == .occupied { return .occupied }
        return ipv4 == .available && ipv6 == .available ? .available : .unknown
    }

    private static func probe(_ port: UInt16, family: Int32) -> Self {
        let status = probeAddress(port, family: family, address: nil, reuseAddress: false)
        guard status == .occupied else { return status }

        // A recently closed TCP connection can keep the non-reusable bind busy.
        // With reuse enabled, Darwin can bind a wildcard alongside an interface-specific
        // listener, so check each local address as well as the wildcard.
        let wildcard = probeAddress(port, family: family, address: nil, reuseAddress: true)
        guard wildcard == .available else { return wildcard }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return .unknown }
        defer { freeifaddrs(first) }

        var result: Self = .available
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            entry = current.pointee.ifa_next
            guard let address = current.pointee.ifa_addr, Int32(address.pointee.sa_family) == family,
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let local = probeAddress(port, family: family, address: address, reuseAddress: true)
            if local == .occupied { return .occupied }
            if local == .unknown { result = .unknown }
        }
        return result
    }

    private static func probeAddress(
        _ port: UInt16, family: Int32, address: UnsafePointer<sockaddr>?, reuseAddress: Bool
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
        if listen(descriptor, 1) != 0 { return errno == EADDRINUSE ? .occupied : .unknown }
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
