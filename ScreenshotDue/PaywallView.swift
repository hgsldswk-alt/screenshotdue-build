import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var commerce: StoreAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(L.t("store.title")).font(.largeTitle.bold()).accessibilityIdentifier("paywall.title")
                Text(L.t("store.introBody")).foregroundStyle(Theme.muted)
                Paper {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L.t("store.unlimited"), systemImage: "rectangle.stack")
                        Label(L.t("review.title"), systemImage: "photo.on.rectangle")
                        Label(L.t("widget.guide"), systemImage: "rectangle.grid.1x2")
                        Label(L.t("store.repeat"), systemImage: "repeat")
                    }
                    .font(.headline)
                }
                if let entitlement = model.state.entitlement {
                    if entitlement.purchasedPro {
                        Text(L.t("store.owned")).font(.headline).accessibilityIdentifier("paywall.owned")
                    } else if model.hasPro {
                        Text(L.f("store.ends", entitlement.trialEnd.formatted(date: .abbreviated, time: .omitted)))
                            .font(.subheadline).accessibilityIdentifier("paywall.ends")
                    } else {
                        Text(L.t("store.expired")).font(.subheadline).accessibilityIdentifier("paywall.expired")
                    }
                }
                if model.state.entitlement?.purchasedPro != true {
                    PrimaryButton(title: commerce.price.map { L.f("store.buy", $0) } ?? L.t("store.loadPrice"),
                                  id: "paywall.buy", disabled: commerce.working) {
                        Task {
                            if commerce.price != nil {
                                await commerce.buy(trial: false) { await model.refresh(scheduleReminders: true) }
                            } else { await commerce.loadProducts() }
                        }
                    }
                    if model.state.entitlement?.trialClaimedAt == nil && model.hasPro {
                        TextAction(title: L.t("store.claim"), id: "paywall.claim") {
                            Task { await commerce.buy(trial: true) { await model.refresh(scheduleReminders: true) } }
                        }
                        .disabled(commerce.working)
                    }
                }
                TextAction(title: L.t("store.restore"), id: "paywall.restore") {
                    Task { await commerce.restore { await model.refresh(scheduleReminders: true) } }
                }
                .disabled(commerce.working)
                if commerce.working { ProgressView(L.t("action.loading")) }
                if let status = commerce.status {
                    Text(status).font(.subheadline).accessibilityIdentifier("paywall.status")
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("store.open"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await commerce.loadProducts() }
    }
}
