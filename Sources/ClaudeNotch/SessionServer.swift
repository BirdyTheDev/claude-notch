import Foundation

struct HookEvent {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let tool: String?
    let toolInput: [String: Any]?
    let tty: String?
    let pid: Int?
    let message: String?

    init?(json: [String: Any]) {
        guard let status = json["status"] as? String else { return nil }
        self.sessionId = json["session_id"] as? String ?? "unknown"
        self.cwd = json["cwd"] as? String ?? ""
        self.event = json["event"] as? String ?? ""
        self.status = status
        self.tool = json["tool"] as? String
        self.toolInput = json["tool_input"] as? [String: Any]
        self.tty = json["tty"] as? String
        self.pid = json["pid"] as? Int
        self.message = json["message"] as? String
    }
}

/// Listens on a Unix socket for hook events fired by Claude Code.
final class SessionServer {
    static let socketPath = "/tmp/claude-notch.sock"

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.claudenotch.socket")
    private var source: DispatchSourceRead?
    private let onEvent: (HookEvent) -> Void

    init(onEvent: @escaping (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        unlink(SessionServer.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("ClaudeNotch: socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = SessionServer.socketPath
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr, capacity - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            NSLog("ClaudeNotch: bind/listen failed on \(path)")
            close(fd)
            return
        }
        chmod(path, 0o600)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            defer { close(client) }
            guard let self else { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
                if n < buffer.count { break }
            }
            guard !data.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = HookEvent(json: obj)
            else { return }
            DispatchQueue.main.async { self.onEvent(event) }
        }
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(SessionServer.socketPath)
    }
}
