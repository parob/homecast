//
//  PurchaseBridge.swift
//  Homecast
//
//  Routes the WKWebView's `purchase` action messages to PurchaseManager
//  and ships JWS strings back through __purchase_callback. Mirrors the
//  HomeKitBridge / LocalNetworkBridge pattern.
//

import Foundation
import StoreKit
import WebKit
import UIKit

@available(iOS 15.0, macCatalyst 15.0, *)
@MainActor
final class PurchaseBridge {
    static let shared = PurchaseBridge()

    weak var webView: WKWebView?

    private init() {}

    func attach(webView: WKWebView) {
        self.webView = webView
        Task { @MainActor in
            await PurchaseManager.shared.start { [weak self] jws in
                // Background renewal / family-sharing transaction came in.
                // Push it to the JS side so the React app can re-validate.
                await self?.broadcastBackgroundTransaction(jws: jws)
            }
        }
    }

    func handle(method: String?, payload: [String: Any]?, callbackId: String?) {
        guard let method = method, let callbackId = callbackId else { return }

        switch method {
        case "getProducts":
            let ids = (payload?["productIds"] as? [String]) ?? [
                PurchaseManager.standardProductId,
                PurchaseManager.cloudProductId,
            ]
            Task {
                do {
                    let products = try await PurchaseManager.shared.loadProducts(productIds: ids)
                    let payloadOut: [[String: Any]] = products.map { product in
                        [
                            "productId": product.id,
                            "displayPrice": product.displayPrice,
                            "price": NSDecimalNumber(decimal: product.price).doubleValue,
                            "currencyCode": product.priceFormatStyle.currencyCode,
                            "period": Self.periodString(product),
                        ]
                    }
                    await self.respond(callbackId: callbackId, result: payloadOut)
                } catch {
                    await self.respond(callbackId: callbackId, error: error.localizedDescription)
                }
            }

        case "buy":
            guard let productId = payload?["productId"] as? String else {
                Task { await self.respond(callbackId: callbackId, error: "Missing productId") }
                return
            }
            // Optional userId — JS passes the authenticated Homecast user's
            // UUID so we can bind the StoreKit transaction to that account
            // via appAccountToken. The server then refuses any JWS whose
            // token doesn't match the JWT-authenticated user.
            let userId = (payload?["userId"] as? String).flatMap { UUID(uuidString: $0) }
            Task {
                do {
                    let jws = try await PurchaseManager.shared.purchase(productId: productId, userId: userId)
                    if let jws = jws {
                        await self.respond(callbackId: callbackId, result: ["jws": jws])
                    } else {
                        await self.respond(callbackId: callbackId, result: ["cancelled": true])
                    }
                } catch {
                    await self.respond(callbackId: callbackId, error: error.localizedDescription)
                }
            }

        case "restore":
            Task {
                do {
                    let jwsList = try await PurchaseManager.shared.restorePurchases()
                    await self.respond(callbackId: callbackId, result: ["jwsTransactions": jwsList])
                } catch {
                    await self.respond(callbackId: callbackId, error: error.localizedDescription)
                }
            }

        case "openManageSubscriptions":
            #if targetEnvironment(macCatalyst)
            // Mac Catalyst can't present the StoreKit sheet; deep-link to App Store
            if let url = URL(string: "macappstores://apps.apple.com/account/subscriptions") {
                Task { @MainActor in
                    await UIApplication.shared.open(url)
                }
            } else if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                Task { @MainActor in
                    await UIApplication.shared.open(url)
                }
            }
            Task { await self.respond(callbackId: callbackId, result: ["opened": true]) }
            #else
            // iOS: present the in-app StoreKit management sheet
            Task { @MainActor in
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }) {
                    do {
                        try await AppStore.showManageSubscriptions(in: scene)
                        await self.respond(callbackId: callbackId, result: ["opened": true])
                    } catch {
                        await self.respond(callbackId: callbackId, error: error.localizedDescription)
                    }
                } else {
                    await self.respond(callbackId: callbackId, error: "No active scene")
                }
            }
            #endif

        default:
            Task { await self.respond(callbackId: callbackId, error: "Unknown purchase method: \(method)") }
        }
    }

    // MARK: - JS callback plumbing

    private func respond(callbackId: String, result: Any) async {
        await dispatchCallback(callbackId: callbackId, payload: ["callbackId": callbackId, "result": result])
    }

    private func respond(callbackId: String, error: String) async {
        await dispatchCallback(callbackId: callbackId, payload: ["callbackId": callbackId, "error": error])
    }

    private func dispatchCallback(callbackId: String, payload: [String: Any]) async {
        guard let webView = self.webView else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        let js = "window.__purchase_callback && window.__purchase_callback(\(jsonString));"
        await MainActor.run {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func broadcastBackgroundTransaction(jws: String) async {
        // Wrap as a "background" event the JS side can listen for.
        let event: [String: Any] = ["type": "transactionUpdate", "jws": jws]
        guard let json = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        let js = "window.__purchase_event && window.__purchase_event(\(jsonString));"
        await MainActor.run {
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func periodString(_ product: Product) -> String {
        guard let sub = product.subscription else { return "" }
        switch sub.subscriptionPeriod.unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return ""
        }
    }
}
