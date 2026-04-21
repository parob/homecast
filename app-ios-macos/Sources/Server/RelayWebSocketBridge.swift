//
//  RelayWebSocketBridge.swift
//  Homecast
//
//  Native-side WebSocket client for the cloud relay connection. Replaces the
//  browser `WebSocket` used inside the WKWebView so we get:
//    - real WS control-frame ping/pong (URLSessionWebSocketTask.sendPing)
//    - NWPathMonitor-driven proactive teardown on connectivity loss
//    - URLSessionConfiguration.waitsForConnectivity
//    - lifecycle events in PersistentLogger / shipped to /internal/logs
//
//  Bridged into JS via webkit.messageHandlers.relayWs.postMessage(...).
//  JS sees a thin WebSocket-alike surface (NativeRelayWebSocket in
//  native-relay-ws.ts) while ServerWebSocket keeps owning reconnect/backoff/
//  token-refresh in a single place.
//

import Foundation
import WebKit
import Network

final class RelayWebSocketBridge: NSObject, WKScriptMessageHandler, URLSessionWebSocketDelegate {
    weak var webView: WKWebView?

    // MARK: - Per-socket state

    private final class SocketState {
        let socketId: String
        let task: URLSessionWebSocketTask
        let urlString: String
        var hasOpened: Bool = false
        var pingTimer: DispatchSourceTimer?
        init(socketId: String, task: URLSessionWebSocketTask, urlString: String) {
            self.socketId = socketId
            self.task = task
            self.urlString = urlString
        }
    }

    private var sockets: [String: SocketState] = [:]
    private let socketsLock = NSLock()

    // Lazy so `self` is available as URLSessionDelegate after super.init().
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 0
        let q = OperationQueue()
        q.name = "cloud.homecast.relay-ws.delegate"
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }()

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "cloud.homecast.relay-ws.path", qos: .utility)
    private var lastPathSatisfied: Bool = true

    private let pingInterval: TimeInterval = 20
    private let pingTimeout: TimeInterval = 10

    // MARK: - Init / attach

    override init() {
        super.init()
        startPathMonitor()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        Log.info("relay-ws bridge attached", category: "relay-ws")
    }

    // MARK: - Path monitoring

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let satisfied = path.status == .satisfied
            let previous = self.lastPathSatisfied
            self.lastPathSatisfied = satisfied
            if previous && !satisfied {
                Log.warning("network path unsatisfied — closing all relay sockets",
                            category: "relay-ws")
                self.forceCloseAll(code: 4100, reason: "network-unsatisfied")
            } else if !previous && satisfied {
                Log.info("network path satisfied", category: "relay-ws")
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "relayWs",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let socketId = body["socketId"] as? String else {
            return
        }

        switch action {
        case "connect":
            guard let urlString = body["url"] as? String else { return }
            connect(socketId: socketId, urlString: urlString)
        case "send":
            guard let data = body["data"] as? String else { return }
            send(socketId: socketId, text: data)
        case "close":
            let code = body["code"] as? Int ?? 1000
            let reason = body["reason"] as? String
            close(socketId: socketId, code: code, reason: reason)
        default:
            Log.warning("unknown action from JS: \(action)", category: "relay-ws")
        }
    }

    // MARK: - Socket lifecycle

    private func connect(socketId: String, urlString: String) {
        guard let url = URL(string: urlString) else {
            emitEvent(socketId: socketId, type: "error",
                      extra: ["message": "invalid URL"])
            emitClose(socketId: socketId, code: 1006,
                      reason: "invalid URL", wasClean: false)
            return
        }

        // Tear down any existing socket with this id (e.g. reconnect with same id).
        if let existing = takeSocket(socketId) {
            existing.pingTimer?.cancel()
            existing.task.cancel(with: .goingAway, reason: nil)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let task = session.webSocketTask(with: req)
        task.taskDescription = socketId
        let state = SocketState(socketId: socketId, task: task, urlString: urlString)
        putSocket(state)

        Log.info(
            "connecting host=\(url.host ?? "?")",
            category: "relay-ws",
            metadata: ["socketId": socketId]
        )

        task.resume()
        startReceive(socketId: socketId)
    }

    private func startReceive(socketId: String) {
        guard let state = getSocket(socketId) else { return }
        state.task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                self.emitEvent(socketId: socketId, type: "message",
                               extra: ["data": text])
                // Keep pumping; URLSessionWebSocketTask.receive is one-shot.
                self.startReceive(socketId: socketId)
            case .failure(let error):
                self.handleTaskFailure(socketId: socketId, error: error)
            }
        }
    }

    private func send(socketId: String, text: String) {
        guard let state = getSocket(socketId) else {
            Log.warning("send on unknown socket",
                        category: "relay-ws",
                        metadata: ["socketId": socketId])
            return
        }
        state.task.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.handleTaskFailure(socketId: socketId, error: error)
            }
        }
    }

    private func close(socketId: String, code: Int, reason: String?) {
        guard let state = takeSocket(socketId) else { return }
        state.pingTimer?.cancel()
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        let reasonData = reason?.data(using: .utf8)
        state.task.cancel(with: closeCode, reason: reasonData)
        // Emit synthetic close now — delegate callback is not guaranteed for
        // client-initiated cancels.
        emitClose(socketId: socketId, code: code, reason: reason, wasClean: true)
    }

    private func handleTaskFailure(socketId: String, error: Error) {
        guard let state = takeSocket(socketId) else { return }
        state.pingTimer?.cancel()
        Log.warning("task failed: \(error.localizedDescription)",
                    category: "relay-ws",
                    metadata: ["socketId": socketId])
        emitEvent(socketId: socketId, type: "error",
                  extra: ["message": error.localizedDescription])
        emitClose(socketId: socketId, code: 1006,
                  reason: error.localizedDescription, wasClean: false)
    }

    private func forceCloseAll(code: Int, reason: String) {
        let ids: [String] = {
            socketsLock.lock(); defer { socketsLock.unlock() }
            return Array(sockets.keys)
        }()
        for id in ids { close(socketId: id, code: code, reason: reason) }
    }

    // MARK: - Ping loop (real WS control frames)

    private func startPingLoop(socketId: String) {
        guard getSocket(socketId) != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pathQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            self?.sendPing(socketId: socketId)
        }
        updateSocket(socketId) { $0.pingTimer = timer }
        timer.resume()
    }

    private func sendPing(socketId: String) {
        guard let state = getSocket(socketId) else { return }

        let lock = NSLock()
        var completed = false

        let timeoutItem = DispatchWorkItem { [weak self] in
            lock.lock()
            if completed { lock.unlock(); return }
            completed = true
            lock.unlock()
            Log.warning("ping timeout — closing socket",
                        category: "relay-ws",
                        metadata: ["socketId": socketId])
            self?.handleTaskFailure(
                socketId: socketId,
                error: NSError(domain: "RelayWebSocketBridge", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "ping timeout"])
            )
        }
        pathQueue.asyncAfter(deadline: .now() + pingTimeout, execute: timeoutItem)

        state.task.sendPing { [weak self] error in
            lock.lock()
            if completed { lock.unlock(); return }
            completed = true
            lock.unlock()
            timeoutItem.cancel()
            if let error = error {
                Log.warning("ping failed: \(error.localizedDescription)",
                            category: "relay-ws",
                            metadata: ["socketId": socketId])
                self?.handleTaskFailure(socketId: socketId, error: error)
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        guard let socketId = webSocketTask.taskDescription else { return }
        updateSocket(socketId) { $0.hasOpened = true }
        Log.info("opened", category: "relay-ws", metadata: ["socketId": socketId])
        emitEvent(socketId: socketId, type: "open", extra: [:])
        startPingLoop(socketId: socketId)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard let socketId = webSocketTask.taskDescription else { return }
        guard let state = takeSocket(socketId) else { return }
        state.pingTimer?.cancel()
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Log.info("closed code=\(closeCode.rawValue) reason=\(reasonString)",
                 category: "relay-ws",
                 metadata: ["socketId": socketId])
        emitClose(socketId: socketId,
                  code: closeCode.rawValue,
                  reason: reasonString,
                  wasClean: true)
    }

    // MARK: - Emit events to JS

    private func emitEvent(socketId: String, type: String, extra: [String: Any]) {
        var payload: [String: Any] = ["socketId": socketId, "type": type]
        for (k, v) in extra { payload[k] = v }
        dispatchToJS(payload)
    }

    private func emitClose(socketId: String, code: Int, reason: String?, wasClean: Bool) {
        var payload: [String: Any] = [
            "socketId": socketId,
            "type": "close",
            "code": code,
            "wasClean": wasClean,
        ]
        if let r = reason { payload["reason"] = r }
        dispatchToJS(payload)
    }

    private func dispatchToJS(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let js = "window.__relay_ws_event && window.__relay_ws_event(\(json));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Socket table

    private func getSocket(_ id: String) -> SocketState? {
        socketsLock.lock(); defer { socketsLock.unlock() }
        return sockets[id]
    }

    private func putSocket(_ state: SocketState) {
        socketsLock.lock(); defer { socketsLock.unlock() }
        sockets[state.socketId] = state
    }

    private func takeSocket(_ id: String) -> SocketState? {
        socketsLock.lock(); defer { socketsLock.unlock() }
        return sockets.removeValue(forKey: id)
    }

    private func updateSocket(_ id: String, _ mutate: (SocketState) -> Void) {
        socketsLock.lock(); defer { socketsLock.unlock() }
        if let s = sockets[id] { mutate(s) }
    }
}
