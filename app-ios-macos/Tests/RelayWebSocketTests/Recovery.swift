// Compiled alongside the real bridge. Suspended Foundation tasks exercise
// cancellation and session replacement without touching the host's network.
extension RelayWebSocketBridge {
    static func testRecovery() -> Bool {
        let bridge = RelayWebSocketBridge()
        bridge.pathMonitor.pathUpdateHandler = nil
        bridge.pathMonitor.cancel()
        bridge.recoveryTimer?.cancel()
        defer { bridge.shutdown() }
        var failures = 0
        func expect(_ value: Bool, _ message: String) {
            if !value { print("FAIL: \(message)"); failures += 1 }
        }
        func drain() { bridge.pathQueue.sync {} }
        func register(_ id: String, at: TimeInterval) -> URLSessionWebSocketTask {
            if bridge.session == nil { bridge.session = bridge.makeSession() }
            let task = bridge.session!.webSocketTask(with: URL(string: "ws://test.invalid")!)
            task.taskDescription = id
            bridge.putSocket(SocketState(socketId: id, task: task,
                                         urlString: "ws://test.invalid", createdAt: at))
            return task
        }
        func cancelled(_ task: URLSessionWebSocketTask) -> Bool {
            let until = Date().addingTimeInterval(2)
            while task.state == .suspended && Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            return task.state == .canceling || task.state == .completed
        }

        let first = register("first", at: 0)
        let originalSession = bridge.session!
        bridge.checkOpeningDeadlines(now: 29)
        expect(first.state == .suspended, "Do not time out an attempt before its deadline")
        bridge.checkOpeningDeadlines(now: 30)
        expect(cancelled(first), "Native watchdog cancels a silent handshake without JS callbacks")
        expect(bridge.session === originalSession, "One failed attempt keeps the session")

        let second = register("second", at: 31)
        // The web deadline can beat the native tick: it must still count as
        // an opening failure and reset the same transport after two failures.
        bridge.close(socketId: "second", code: 4000, reason: "connect-timeout")
        expect(cancelled(second), "Web deadline cancels the actual native task")
        expect(bridge.session == nil, "Two failed openings discard the native session")

        let transient = register("transient", at: 62)
        bridge.handleTaskFailure(socketId: "transient", error: NSError(domain: "test", code: 1))
        expect(cancelled(transient), "A failed opening cancels its task")
        expect(bridge.consecutiveOpeningFailures == 1, "Failure streak records an unsuccessful opening")
        let replacement = register("reused", at: 63)
        let freshSession = bridge.session!
        expect(freshSession !== originalSession, "Next attempt gets a fresh URLSession")
        let stale = register("stale", at: 62)
        bridge.close(socketId: "stale", code: 1000, reason: "test")
        // Even a reused JS id cannot let old native callbacks affect a new task.
        stale.taskDescription = "reused"
        bridge.urlSession(originalSession, webSocketTask: stale, didOpenWithProtocol: nil)
        bridge.urlSession(originalSession, webSocketTask: stale, didCloseWith: .goingAway, reason: nil)
        bridge.urlSession(originalSession, task: stale,
                          didCompleteWithError: NSError(domain: "test", code: 1))
        drain()
        expect(bridge.getSocket("reused")?.task === replacement, "Late close/error preserves replacement")
        expect(bridge.getSocket("reused")?.hasOpened == false, "Late open cannot revive a retired task")

        bridge.urlSession(freshSession, webSocketTask: replacement, didOpenWithProtocol: nil)
        drain()
        bridge.checkOpeningDeadlines(now: 1800)
        expect(bridge.getSocket("reused")?.hasOpened == true, "Opening deadline leaves established sockets alone")
        expect(bridge.consecutiveOpeningFailures == 0, "Successful open resets failure streak")

        bridge.forceCloseAll(code: 4100, reason: "network-unsatisfied")
        expect(cancelled(replacement), "Network loss cancels the active task")
        let recovered = register("network-returned", at: 1801)
        bridge.urlSession(freshSession, webSocketTask: recovered, didOpenWithProtocol: nil)
        drain()
        expect(bridge.getSocket("network-returned")?.hasOpened == true, "A new attempt works after network return")
        bridge.shutdown()
        bridge.shutdown()
        expect(cancelled(recovered), "Shutdown cancels the recovered socket")
        expect(bridge.session == nil && bridge.recoveryTimer == nil, "Shutdown releases session and watchdog")
        print("Native relay recovery: \(failures == 0 ? "passed" : "failed")")
        return failures == 0
    }
}
