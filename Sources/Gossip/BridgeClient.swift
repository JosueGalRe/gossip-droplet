import Darwin
import Foundation

/// Client for the Gossip Mac app's local API (`DroppyBridge` in the Gossip fork): newline-delimited JSON over a Unix
/// socket in Gossip's Application Support folder. Gossip only accepts processes signed by Droppy's team, so this
/// connects from inside Droppy and is refused from the harness. Retries every few seconds while Gossip is not running.
@MainActor
final class BridgeClient {
    static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Gossip/droppy.sock").path
    }

    private static let retryInterval: TimeInterval = 3
    private static let maxLineBytes = 8 * 1024 * 1024

    var onLine: ((Data) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var isConnected = false

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var retryTimer: Timer?
    private var buffer = Data()

    func start() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.connectIfNeeded() }
        }
        connectIfNeeded()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        disconnect()
    }

    func send(_ message: [String: Any]) {
        guard fd >= 0, JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        let fd = fd
        let complete = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        if !complete { disconnect() }
    }

    private func connectIfNeeded() {
        guard fd < 0 else { return }
        let path = Self.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(socketFD); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(socketFD); return }
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        fd = socketFD
        buffer.removeAll()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        readSource.setEventHandler {
            MainActor.assumeIsolated { [weak self] in self?.readAvailable() }
        }
        readSource.setCancelHandler { close(socketFD) }
        source = readSource
        readSource.resume()
        isConnected = true
        onConnectionChange?(true)
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &chunk, chunk.count)
        // 0 is Gossip closing its end (quit, or it refused us); the timer reconnects.
        guard count > 0 else { disconnect(); return }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            onLine?(line)
        }
        if buffer.count > Self.maxLineBytes { disconnect() }
    }

    private func disconnect() {
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        fd = -1
        buffer.removeAll()
        isConnected = false
        onConnectionChange?(false)
    }
}
