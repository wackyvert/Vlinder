import Foundation

/// Jellyfin LAN discovery: UDP broadcast "Who is JellyfinServer?" to port 7359
/// (Fladder's discovery_provider). Servers answer with {Address, Id, Name}.
///
/// Works on macOS out of the box. On iOS, broadcast sends require the
/// com.apple.developer.networking.multicast entitlement — without it this
/// quietly returns nothing, which the connect screen treats as "no servers
/// found" rather than an error.
enum ServerDiscovery {
    struct DiscoveredServer: Identifiable, Equatable {
        var address: String
        var id: String
        var name: String
    }

    static func discover(timeout: TimeInterval = 2.5) async -> [DiscoveredServer] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: performDiscovery(timeout: timeout))
            }
        }
    }

    private static func performDiscovery(timeout: TimeInterval) -> [DiscoveredServer] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(7359).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_BROADCAST)

        let message = Array("Who is JellyfinServer?".utf8)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, message, message.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return [] }

        var found: [DiscoveredServer] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { continue }
            let data = Data(buffer[0..<received])
            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let serverAddress = object["Address"] as? String,
                !serverAddress.isEmpty
            else { continue }
            let id = object["Id"] as? String ?? serverAddress
            guard seen.insert(id).inserted else { continue }
            found.append(DiscoveredServer(
                address: serverAddress,
                id: id,
                name: object["Name"] as? String ?? serverAddress))
        }
        return found
    }
}
