//
//  PurchaseManager.swift
//  Homecast
//
//  StoreKit 2 wrapper. Loads products, runs purchases, observes
//  Transaction.updates, and exposes restore for the iOS Restore button.
//
//  All entitlement state lives server-side on User.account_type. This
//  manager is a thin shim that forwards JWS strings to the JS bridge —
//  the React app then posts them through GraphQL for verification.
//

import Foundation
import StoreKit

@available(iOS 15.0, macCatalyst 15.0, *)
actor PurchaseManager {
    static let shared = PurchaseManager()

    static let standardProductId = "cloud.homecast.app.standard.monthly"
    static let cloudProductId = "cloud.homecast.app.cloud.monthly"

    /// Cached products loaded from StoreKit. Keyed by productId.
    private var products: [String: Product] = [:]

    /// Long-running task that listens for transaction updates from outside
    /// the app (renewals, family sharing, parent approval, etc.).
    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// Start listening for Transaction.updates. Call once at app launch.
    /// New transactions are forwarded to the WebView so the JS side can
    /// POST them to the server for re-validation.
    func start(forwarder: @escaping @Sendable (String) async -> Void) {
        updatesTask?.cancel()
        updatesTask = Task.detached(priority: .background) {
            for await result in Transaction.updates {
                let jws = result.jwsRepresentation
                guard case .verified(let transaction) = result else { continue }
                await forwarder(jws)
                await transaction.finish()
            }
        }
    }

    func loadProducts(productIds: [String]) async throws -> [Product] {
        let storeProducts = try await Product.products(for: productIds)
        for p in storeProducts { products[p.id] = p }
        return storeProducts
    }

    /// Returns the JWS string of the verified transaction, or nil if the
    /// user cancelled or the purchase is pending parent approval.
    func purchase(productId: String) async throws -> String? {
        let product: Product
        if let cached = products[productId] {
            product = cached
        } else {
            let loaded = try await Product.products(for: [productId])
            guard let first = loaded.first else {
                throw PurchaseError.productNotFound(productId)
            }
            products[productId] = first
            product = first
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let jws = verification.jwsRepresentation
            switch verification {
            case .verified:
                // Note: we deliberately do NOT call transaction.finish()
                // here — the caller finishes only after the server confirms
                // entitlement. See `finishTransaction(originalTransactionId:)`.
                return jws
            case .unverified(_, let error):
                throw PurchaseError.unverified(error)
            }
        case .userCancelled:
            return nil
        case .pending:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Finish a verified transaction once the server has acknowledged it.
    func finishTransaction(originalTransactionId: UInt64) async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.originalID == originalTransactionId {
                await transaction.finish()
                return
            }
        }
    }

    /// Refresh receipts from the App Store, then return JWS strings for all
    /// currently-owned subscriptions. The web app posts these back to the
    /// server for entitlement restoration.
    func restorePurchases() async throws -> [String] {
        try await AppStore.sync()
        var jwsStrings: [String] = []
        for await result in Transaction.currentEntitlements {
            let jws = result.jwsRepresentation
            guard case .verified = result else { continue }
            jwsStrings.append(jws)
        }
        return jwsStrings
    }
}

@available(iOS 15.0, macCatalyst 15.0, *)
enum PurchaseError: LocalizedError {
    case productNotFound(String)
    case unverified(VerificationResult<Transaction>.VerificationError)
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .productNotFound(let id):
            return "Product not found: \(id)"
        case .unverified(let err):
            return "Unverified transaction: \(err.localizedDescription)"
        case .bridgeUnavailable:
            return "Purchase bridge unavailable"
        }
    }
}

