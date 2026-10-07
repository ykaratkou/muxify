import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

public final class SimulatorServer: @unchecked Sendable {
    private let options: ServerOptions
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let clients = ClientConnections()
    private let backend: any SimulatorBackendProtocol
    private let sessions: DeviceSessions
    private var listener: Channel?

    public convenience init(options: ServerOptions) {
        self.init(options: options, backend: SimulatorBackend())
    }

    init(options: ServerOptions, backend: any SimulatorBackendProtocol) {
        self.options = options
        self.backend = backend
        self.sessions = DeviceSessions(backend: backend)
    }

    @discardableResult public func start() async throws -> Int {
        let options = self.options
        let backend = self.backend
        let sessions = self.sessions
        let clients = self.clients
        do {
            listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 32)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    guard clients.add(channel) else { return channel.close() }
                    let http = HTTPHandler()
                    let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 4096,
                        shouldUpgrade: { channel, request in
                            guard RequestPolicy.authorizes(request, options: options) else {
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        }, upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(SimulatorSocketHandler(backend: backend, sessions: sessions, clients: clients))
                        })
                    let upgrade: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { context in context.pipeline.removeHandler(http, promise: nil) }
                    )
                    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgrade)
                        .flatMap { channel.pipeline.addHandler(http) }
                }
                .bind(host: "127.0.0.1", port: options.port).get()
            return listener?.localAddress?.port ?? options.port
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func shutdown() async {
        try? await listener?.close().get()
        listener = nil
        await clients.close()
        try? await group.shutdownGracefully()
    }
}

enum RequestPolicy {
    static func authorizes(_ request: HTTPRequestHead, options: ServerOptions) -> Bool {
        guard request.method == .GET,
              let url = URLComponents(string: request.uri), url.path == "/ws",
              let supplied = url.queryItems?.first(where: { $0.name == "token" })?.value,
              constantTimeEqual(supplied, options.token) else { return false }
        // Native clients may omit Origin. A web page must come from this server or an
        // explicitly configured proxy origin; token authentication is required either way.
        guard let origin = request.headers.first(name: "origin")?.lowercased() else { return true }
        if options.origins.contains(origin) { return true }
        guard let host = request.headers.first(name: "host")?.lowercased() else { return false }
        return origin == "http://\(host)" || origin == "https://\(host)"
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// Handler state is accessed only on its channel's event loop.
private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var request: HTTPRequestHead?
    private var timeout: Scheduled<Void>?

    func handlerAdded(context: ChannelHandlerContext) {
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) { context.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { timeout?.cancel() }

    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): request = head
        case .body: break
        case .end:
            guard let request else { return }
            self.request = nil
            let asset = WebAssets.asset(path: request.uri)
            let status: HTTPResponseStatus = request.method != .GET ? .methodNotAllowed
                : request.uri.hasPrefix("/ws") ? .unauthorized : asset == nil ? .notFound : .ok
            let content = status == .ok ? asset!.body : Data("\(status.code) \(status.reasonPhrase)\n".utf8)
            var headers = HTTPHeaders([
                ("Content-Type", asset?.contentType ?? "text/plain; charset=utf-8"),
                ("Content-Length", String(content.count)),
                ("Connection", "close"),
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
                ("Referrer-Policy", "no-referrer"),
                ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src blob:; frame-ancestors 'none'; base-uri 'none'"),
            ])
            if status == .methodNotAllowed { headers.add(name: "Allow", value: "GET") }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: request.version, status: status, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: content.count)
            buffer.writeBytes(content)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// Transport state stays on the event loop; SimulatorSession owns asynchronous work.
private final class SimulatorSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let backend: any SimulatorBackendProtocol
    private let sessions: DeviceSessions
    private let clients: ClientConnections
    private var session: SimulatorSession?
    private var pinging: RepeatedTask?
    private var lastPong = Date()

    init(backend: any SimulatorBackendProtocol, sessions: DeviceSessions, clients: ClientConnections) {
        self.backend = backend
        self.sessions = sessions
        self.clients = clients
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let session = SimulatorSession(backend: backend, sessions: sessions,
                                       onOverflow: { channel.close(promise: nil) }) { message in
            var buffer = channel.allocator.buffer(capacity: 0)
            let opcode: WebSocketOpcode
            switch message {
            case .text(let data): opcode = .text; buffer.writeBytes(data)
            case .frame(let data): opcode = .binary; buffer.writeBytes(data)
            }
            try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, data: buffer)).get()
        }
        self.session = session
        session.start()
        pinging = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5)) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(lastPong) > 20 { context.close(promise: nil); return }
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .ping,
                data: context.channel.allocator.buffer(capacity: 0))), promise: nil)
        }
        // Waiting for this future during server shutdown also waits for input release and shared display cleanup.
        let cleanup = Task {
            try? await channel.closeFuture.get()
            await session.close()
        }
        clients.trackCleanup(channel: channel, task: cleanup)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        // Small commands are sent as one masked text frame. Reject unsupported fragmentation.
        switch frame.opcode {
        case .text:
            guard frame.fin, frame.maskKey != nil, let bytes = frame.unmaskedData.getBytes(at: frame.unmaskedData.readerIndex,
                length: frame.unmaskedData.readableBytes) else { context.close(promise: nil); return }
            do { session?.enqueue(try ControlMessage.decode(Data(bytes))) }
            catch {
                guard context.channel.isWritable else { context.close(promise: nil); return }
                var buffer = context.channel.allocator.buffer(capacity: 128)
                let payload = (try? JSONSerialization.data(withJSONObject: ["type": "error", "message": error.localizedDescription])) ?? Data()
                buffer.writeBytes(payload)
                context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
            }
        case .connectionClose: context.close(promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .pong: lastPong = Date()
        default: context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pinging?.cancel()
        session?.stop()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class ClientConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []
    private var closing = false
    // NIO owns handlers; keeping cleanup tasks here makes shutdown await their FIFO drains.
    private var cleanups: [ObjectIdentifier: Task<Void, Never>] = [:]

    func add(_ channel: Channel) -> Bool {
        lock.lock()
        guard !closing, channels.count < 32 else { lock.unlock(); return false }
        channels.append(channel)
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in self?.remove(channel) }
        return true
    }

    private func remove(_ channel: Channel) {
        lock.lock(); channels.removeAll { $0 === channel }; lock.unlock()
    }

    func trackCleanup(channel: Channel, task: Task<Void, Never>) {
        let key = ObjectIdentifier(channel)
        lock.lock(); cleanups[key] = task; lock.unlock()
        Task {
            await task.value
            self.removeCleanup(key)
        }
    }

    private func removeCleanup(_ key: ObjectIdentifier) {
        lock.lock(); cleanups[key] = nil; lock.unlock()
    }

    private func beginClosing() -> [Channel] {
        lock.lock(); defer { lock.unlock() }
        closing = true
        return channels
    }

    private func pendingCleanup() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }; return Array(cleanups.values)
    }

    func close() async {
        for channel in beginClosing() { try? await channel.close().get() }
        for task in pendingCleanup() { await task.value }
    }
}
