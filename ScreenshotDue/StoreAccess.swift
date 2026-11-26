import StoreKit
import SwiftUI

@MainActor
final class StoreAccess: ObservableObject {
    @Published private(set) var pro: Product?
    @Published private(set) var trial: Product?
    @Published private(set) var working = false
    @Published private(set) var status: String?
    private var store: TaskStore?
    private var monitor: Task<Void, Never>?

    var price: String? { pro?.displayPrice ?? (Launch.testing ? "$2.99" : nil) }

    func start(store: TaskStore, onChange: @escaping @MainActor () async -> Void) {
        guard self.store == nil else { return }
        self.store = store
        guard !Launch.testing else { return }
        monitor = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self, case .verified(let transaction) = update,
                      [Launch.proID, Launch.trialID].contains(transaction.productID) else { continue }
                if await self.refresh(verified: transaction, onChange: onChange) { await transaction.finish() }
            }
        }
        Task { await refresh(onChange: onChange) }
    }

    func loadProducts() async {
        guard !Launch.testing, pro == nil || trial == nil else { return }
        do {
            let products = try await Product.products(for: [Launch.proID, Launch.trialID])
            pro = products.first { $0.id == Launch.proID && $0.type == .nonConsumable }
            trial = products.first { $0.id == Launch.trialID && $0.type == .nonConsumable && $0.price == .zero }
        } catch {
            self.status = L.t("store.unavailable")
        }
    }

    @discardableResult
    func refresh(verified: StoreKit.Transaction? = nil, onChange: @escaping @MainActor () async -> Void) async -> Bool {
        guard let store, !Launch.testing else { return false }
        let receipt = await Task.detached(priority: .utility) {
            let pro = await StoreKit.Transaction.latest(for: Launch.proID)
            let trial = await StoreKit.Transaction.latest(for: Launch.trialID)
            let proEvent = Self.newest(Self.valid(pro), verified?.productID == Launch.proID ? verified : nil)
            let trialEvent = Self.newest(Self.valid(trial), verified?.productID == Launch.trialID ? verified : nil)
            let purchase = proEvent.map { $0.revocationDate == nil }
            let trialDate = trialEvent.flatMap { $0.revocationDate == nil ? $0.originalPurchaseDate : nil }
            return (purchase, trialDate, proEvent.map(Self.eventDate))
        }.value
        let changed: Bool
        do {
            changed = try await Task.detached(priority: .utility) {
                try store.change { state in
                    guard var entitlement = state.entitlement else { throw StorageError.unavailable }
                    let old = entitlement
                    entitlement.reconcile(verifiedTrial: receipt.1, verifiedPurchase: receipt.0, purchaseDate: receipt.2)
                    guard old != entitlement else { return false }
                    state.entitlement = entitlement
                    state.markRemindersDirty()
                    return true
                }
            }.value
        } catch {
            self.status = L.t("error.storage")
            return false
        }
        if changed { await onChange() }
        return true
    }

    private nonisolated static func valid(_ result: VerificationResult<StoreKit.Transaction>?) -> StoreKit.Transaction? {
        guard case .verified(let transaction)? = result, transaction.productType == .nonConsumable else { return nil }
        return transaction
    }

    private nonisolated static func eventDate(_ transaction: StoreKit.Transaction) -> Date {
        transaction.revocationDate ?? transaction.purchaseDate
    }

    private nonisolated static func newest(_ first: StoreKit.Transaction?, _ second: StoreKit.Transaction?) -> StoreKit.Transaction? {
        guard let first else { return second }
        guard let second else { return first }
        return eventDate(first) >= eventDate(second) ? first : second
    }

    func buy(trial claim: Bool, onChange: @escaping @MainActor () async -> Void) async {
        guard !working, let store else { return }
        working = true
        status = nil
        defer { working = false }
        if Launch.testing {
            do {
                try await Task.detached {
                    try store.change { state in
                        state.entitlement?.reconcile(verifiedTrial: claim ? .now : nil, verifiedPurchase: claim ? nil : true)
                        state.markRemindersDirty()
                    }
                }.value
                status = L.t("store.success")
                await onChange()
            } catch {
                self.status = L.t("error.storage")
            }
            return
        }
        await loadProducts()
        guard let product = claim ? trial : pro else {
            status = L.t("store.unavailable")
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    status = L.t("store.unverified")
                    return
                }
                if await refresh(verified: transaction, onChange: onChange) {
                    await transaction.finish()
                    status = L.t("store.success")
                }
            case .pending: status = L.t("store.pending")
            case .userCancelled: break
            @unknown default: status = L.t("store.unavailable")
            }
        } catch {
            self.status = L.t("store.unavailable")
        }
    }

    func restore(onChange: @escaping @MainActor () async -> Void) async {
        guard !working else { return }
        working = true
        status = nil
        defer { working = false }
        do {
            if !Launch.testing { try await AppStore.sync() }
            if Launch.testing {
                status = L.t("store.restored")
            } else if await refresh(onChange: onChange) {
                status = L.t("store.restored")
            }
        } catch {
            self.status = L.t("store.unavailable")
        }
    }
}
