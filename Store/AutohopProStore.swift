import Foundation
import StoreKit

// AI CONTEXT — Store/AutohopProStore.swift
// StoreKit 2 entitlement manager for the single auto-renewable subscription,
// "Autohop Pro" (autohop_pro_monthly, AUD $2.99/mo, 7-day trial — see
// Docs/RELAY_TIER1_IMPLEMENTATION.md §4.1/§8 and Autohop.storekit for local
// testing). Owns product loading, purchase, and the entitlement flag; does NOT
// call the relay itself — AppState observes `isPro`/`latestTransactionJWS` and
// drives RelayClient.register/unregister/setFeeds (§4.2), keeping this type
// StoreKit-only and the relay wiring in one place (AppState).
//
// Local StoreKit Testing caveat: transactions signed by Xcode's local
// .storekit config use a TEST root certificate, not Apple's real
// AppleRootCA-G3. That's fine today (the relay's JWS verification is still a
// decode-only placeholder — see autohop-relay/src/appstore.ts TODO) but once
// real x5c chain verification ships server-side, local-only purchases will be
// REJECTED by the relay; Sandbox testing (a real, free Sandbox Apple ID
// tester in App Store Connect) will be required for register() to succeed.
@MainActor
final class AutohopProStore: ObservableObject {
    static let productID = "autohop_pro_monthly"

    @Published private(set) var product: Product?
    @Published private(set) var isPro: Bool = false
    @Published private(set) var expirationDate: Date?
    @Published private(set) var latestTransactionJWS: String?
    @Published private(set) var purchaseInFlight = false
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            lastError = "Couldn't load Autohop Pro: \(error.localizedDescription)"
        }
    }

    /// Starts the purchase sheet. Returns true if the transaction verified and
    /// entitlement is now active; false if the user cancelled or it's pending
    /// (e.g. Ask to Buy) — neither is an error.
    @discardableResult
    func purchase() async -> Bool {
        guard let product else {
            lastError = "Autohop Pro isn't available right now."
            return false
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await handle(transaction)
                return isPro
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    /// Re-derives `isPro`/`expirationDate`/`latestTransactionJWS` from
    /// `Transaction.currentEntitlements` — the source of truth StoreKit keeps
    /// current locally (no network call needed on the happy path).
    func refreshEntitlement() async {
        var activeJWS: String?
        var activeExpiration: Date?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result), transaction.productID == Self.productID else { continue }
            if transaction.revocationDate == nil {
                activeJWS = result.jwsRepresentation
                activeExpiration = transaction.expirationDate
            }
        }
        isPro = activeJWS != nil
        expirationDate = activeExpiration
        latestTransactionJWS = activeJWS
    }

    private func handle(_ transaction: Transaction) async {
        await refreshEntitlement()
        await transaction.finish()
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard let transaction = try? Self.checkVerified(update) else { return }
        await handle(transaction)
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value): return value
        }
    }
}
