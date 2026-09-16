// Appended to the actual bridge source by test-relay-websocket.sh. Keeping the
// test extension in the same compilation file exercises private lifecycle
// methods without exposing test-only APIs in the app.
extension RelayWebSocketBridge {
    static func testFailureCleanup() -> Bool {
        let bridge = RelayWebSocketBridge()
        // Only explicit test events may retire these tasks, not host-network changes.
        bridge.pathMonitor.pathUpdateHandler = nil
        bridge.pathMonitor.cancel()
        let session = URLSession(configuration: .ephemeral)
        defer { bridge.shutdown(); session.invalidateAndCancel() }
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        func register(_ id: String) -> URLSessionWebSocketTask {
            // Suspended real tasks make no network requests. Their lifecycle
            // state proves that cleanup reaches Foundation, not just our map.
            let task = session.webSocketTask(with: URL(string: "ws://test.invalid")!)
            bridge.putSocket(SocketState(socketId: id, task: task, urlString: "ws://test.invalid"))
            return task
        }
        func cancelled(_ task: URLSessionWebSocketTask) -> Bool {
            // Foundation completes cancellation on its own queue.
            let deadline = Date().addingTimeInterval(2)
            while task.state == .suspended && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return task.state == .canceling || task.state == .completed
        }

        let timedOut = register("ping-timeout")
        bridge.recordPingMiss(socketId: "ping-timeout", reason: "controlled test")
        bridge.recordPingMiss(socketId: "ping-timeout", reason: "controlled test")
        expect(timedOut.state == .suspended, "Two ping misses must keep the socket")
        expect(bridge.getSocket("ping-timeout") != nil, "Tolerated misses must retain tracking")
        bridge.recordPingMiss(socketId: "ping-timeout", reason: "controlled test")
        expect(bridge.getSocket("ping-timeout") == nil, "Terminal failure must remove tracking")
        expect(cancelled(timedOut), "Terminal ping failure must cancel the underlying task")

        let sendFailed = register("send-failure")
        bridge.handleTaskFailure(socketId: "send-failure", error: NSError(domain: "test", code: 1))
        expect(cancelled(sendFailed), "A send failure must also cancel the task")
        // An error callback from an already-retired task must not touch its replacement.
        let replacement = register("replacement")
        bridge.handleTaskFailure(socketId: "send-failure", error: NSError(domain: "test", code: 2))
        expect(replacement.state == .suspended, "Late failure must leave the replacement alone")

        let deliberate = register("deliberate-close")
        bridge.close(socketId: "deliberate-close", code: 1000, reason: "test")
        expect(cancelled(deliberate), "Deliberate close must still cancel the task")
        bridge.shutdown()
        expect(cancelled(replacement), "Bridge shutdown must cancel remaining tasks")
        print("Native relay cleanup: \(failures == 0 ? "passed" : "failed")")
        return failures == 0
    }
}

exit(RelayWebSocketBridge.testFailureCleanup() ? 0 : 1)
