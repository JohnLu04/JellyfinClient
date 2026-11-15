import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 (random port, loopback only) that the players fetch the adaptive
/// stream from. Supports keep-alive, GET and HEAD; each request is answered by an async handler.
final class LocalHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var contentType = "application/octet-stream"
        var body = Data()

        static func notFound() -> Response { Response(status: 404, contentType: "text/plain", body: Data("Not found".utf8)) }
    }

    typealias Handler = @Sendable (_ path: String) async -> Response

    private let handler: Handler
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { abrLog.notice("Local server released") }

    /// Starts listening and returns the port once ready.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Bound to the loopback address: nothing outside the iPhone can connect.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    continuation.resume(returning: port)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        abrLog.debug("Local server: connection from \(String(describing: connection.endpoint), privacy: .public)")
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads one request (headers only; players never send bodies here), answers it and waits for the next.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil || buffer.count > 64 * 1024 { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let rest = Data(buffer[end.upperBound...])
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { connection.cancel(); return }
            let method = String(parts[0])
            let path = String(parts[1])
            let keepAlive = !lines.contains { $0.lowercased().hasPrefix("connection:") && $0.lowercased().contains("close") }
            let handler = self.handler
            Task {
                let response = method == "GET" || method == "HEAD" ? await handler(path) : Response(status: 405)
                self.send(response, headOnly: method == "HEAD", keepAlive: keepAlive, on: connection) {
                    if keepAlive { self.receive(on: connection, buffer: rest) } else { connection.cancel() }
                }
            }
        }
    }

    private func send(_ response: Response, headOnly: Bool, keepAlive: Bool, on connection: NWConnection,
                      then next: @escaping @Sendable () -> Void) {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed", 502: "Bad Gateway"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(response.body) }
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { connection.cancel() } else { next() }
        })
    }
}
