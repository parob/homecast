//
//  MetricKitReporter.swift
//  Homecast
//
//  Apple-native crash and hang capture (no Sentry / Crashlytics — fits the
//  GCP-only constraint). Subscribes to MXMetricManager; crash/hang diagnostics
//  arrive asynchronously on the next launch after the event and are shipped
//  via LogShipper with source="mac-crash" / "mac-hang".
//
//  Call `MetricKitReporter.start()` once from HomecastApp after launch.
//

import Foundation
#if canImport(MetricKit)
import MetricKit

public final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {

    public static let shared = MetricKitReporter()

    private override init() { super.init() }
    private var started = false

    public func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        Log.info("MetricKit subscriber registered", category: "metric-kit")
    }

    // MARK: - MXMetricManagerSubscriber

    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Metric payloads (battery, CPU, etc) are low-value right now — just
        // note arrival so we can confirm the subscription is working.
        for payload in payloads {
            Log.info("MetricKit metric payload received: timeRange=\(payload.timeStampBegin)–\(payload.timeStampEnd)",
                     category: "metric-kit")
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            handlePayload(payload)
        }
    }

    // MARK: - Internals

    private func handlePayload(_ payload: MXDiagnosticPayload) {
        let begin = payload.timeStampBegin
        let end = payload.timeStampEnd

        // Crashes
        for diag in payload.crashDiagnostics ?? [] {
            let meta: [String: String] = [
                "exceptionType": diag.exceptionType?.stringValue ?? "-",
                "exceptionCode": diag.exceptionCode?.stringValue ?? "-",
                "signal": diag.signal?.stringValue ?? "-",
                "terminationReason": diag.terminationReason ?? "-",
                "appVersion": diag.metaData.applicationBuildVersion,
                "osVersion": diag.metaData.osVersion,
                "timeRange": "\(begin)..\(end)",
            ]
            let callStack = summarise(callStackTree: diag.callStackTree)
            Log.error("MetricKit crash: \(meta["exceptionType"] ?? "?") sig=\(meta["signal"] ?? "?") | \(callStack)",
                      category: "metric-kit-crash",
                      metadata: meta.merging(["callStack": callStack]) { a, _ in a })
        }

        // Hangs
        for diag in payload.hangDiagnostics ?? [] {
            let duration = diag.hangDuration.converted(to: .seconds).value
            let meta: [String: String] = [
                "hangDuration_s": String(format: "%.2f", duration),
                "appVersion": diag.metaData.applicationBuildVersion,
                "osVersion": diag.metaData.osVersion,
                "timeRange": "\(begin)..\(end)",
            ]
            let callStack = summarise(callStackTree: diag.callStackTree)
            Log.warning("MetricKit hang: \(String(format: "%.2fs", duration)) | \(callStack)",
                        category: "metric-kit-hang",
                        metadata: meta.merging(["callStack": callStack]) { a, _ in a })
        }

        // CPU exceptions (runaway loops)
        for diag in payload.cpuExceptionDiagnostics ?? [] {
            let meta: [String: String] = [
                "totalCPUTime_ms": String(format: "%.0f", diag.totalCPUTime.converted(to: .milliseconds).value),
                "totalSampledTime_ms": String(format: "%.0f", diag.totalSampledTime.converted(to: .milliseconds).value),
                "appVersion": diag.metaData.applicationBuildVersion,
                "osVersion": diag.metaData.osVersion,
            ]
            Log.warning("MetricKit cpu-exception: cpu=\(meta["totalCPUTime_ms"] ?? "?")ms",
                        category: "metric-kit-cpu",
                        metadata: meta)
        }
    }

    /// MetricKit's call-stack tree is a nested JSON blob. Keep it compact:
    /// join the first frames with " ← " so the log line stays readable.
    private func summarise(callStackTree: MXCallStackTree) -> String {
        let data = callStackTree.jsonRepresentation()
        guard let str = String(data: data, encoding: .utf8) else { return "<no stack>" }
        // Cap to 1000 chars so single huge payloads don't blow up log shipping.
        if str.count > 1000 {
            return String(str.prefix(1000)) + "…"
        }
        return str
    }
}

#else

// MetricKit is iOS 13+ / Mac Catalyst 13+; on anything unexpectedly older
// we silently degrade rather than failing to compile.
public final class MetricKitReporter {
    public static let shared = MetricKitReporter()
    public func start() {}
}

#endif
