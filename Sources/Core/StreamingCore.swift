import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct StreamingProtocolSpec {
    static let port: UInt16 = 8765
    static let path = "/"
    static let maxJPEGBytes = 1_500_000
    static let frameInterval: TimeInterval = 1.0 / 10.0

    static func endpointURLString(lanAddress: String, port: UInt16 = StreamingProtocolSpec.port) -> String {
        "ws://\(lanAddress):\(port)\(path)"
    }
}

final class LatestFrameBuffer {
    private let lock = NSLock()
    private var latestFrame: Data?

    func replace(with frame: Data, maximumBytes: Int) {
        guard frame.count <= maximumBytes else { return }
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    func takeLatest() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let frame = latestFrame
        latestFrame = nil
        return frame
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }
}

enum LANAddressResolver {
    static func preferredIPv4Address() -> String? {
#if canImport(Darwin)
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var selected: String?
        var current = first
        while true {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp, isRunning, !isLoopback, let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        sa,
                        socklen_t(sa.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        selected = String(cString: host)
                        break
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            current = next
        }

        return selected
#else
        return nil
#endif
    }
}
