import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var purchaseUpdatedAt: Date?

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool = Launch.freePeriod) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    func canAdd(openCount: Int, at now: Date) -> Bool {
        hasPro(at: now) || openCount < 10
    }

    mutating func reconcile(verifiedTrial: Date?, verifiedPurchase: Bool?, purchaseDate: Date? = nil) {
        if let verifiedTrial {
            trialClaimedAt = min(trialClaimedAt ?? verifiedTrial, verifiedTrial)
        }
        if let verifiedPurchase, let purchaseDate {
            guard purchaseUpdatedAt.map({ purchaseDate >= $0 }) ?? true else { return }
            purchaseUpdatedAt = purchaseDate
            purchasedPro = verifiedPurchase
        } else if let verifiedPurchase {
            purchasedPro = verifiedPurchase
        }
    }
}
