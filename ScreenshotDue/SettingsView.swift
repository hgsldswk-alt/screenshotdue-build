import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let open: (AppRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Paper {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.t("settings.notifications")).font(.headline)
                        if !Reminders.allowed(model.notifications) {
                            TextAction(title: L.t("notification.enable"), id: "settings.enableNotifications") {
                                if model.notifications == .denied, !Launch.testing {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                } else { Task { await model.askForNotifications() } }
                            }
                        }
                        Toggle(L.t("settings.preview"), isOn: setting(\.notificationPreview))
                            .accessibilityIdentifier("settings.preview")
                        Toggle(L.t("settings.summary"), isOn: setting(\.dailySummary))
                            .accessibilityIdentifier("settings.summary")
                        Text(L.t("settings.summaryHelp")).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Paper {
                    VStack(alignment: .leading, spacing: 2) {
                        action("settings.history", "settings.history", "checkmark.circle", .history)
                        action("store.open", "settings.paywall", "lock.open", .paywall)
                        action("widget.guide", "settings.widgets", "rectangle.on.rectangle", .widgets)
                        Toggle(L.t("settings.thumbnails"), isOn: setting(\.widgetThumbnails))
                            .accessibilityIdentifier("settings.thumbnails")
                            .padding(.vertical, 5)
                        Text(L.t("settings.widgetPrivacy")).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Paper {
                    VStack(alignment: .leading, spacing: 2) {
                        action("share.progress", "settings.share", "square.and.arrow.up", .progress)
                        if model.state.deletedAssets.count >= 100 {
                            action("milestone.open", "settings.milestone", "sparkles", .milestone)
                        }
                        action("template.open", "settings.template", "doc.on.clipboard", .template(nil))
                        action("settings.privacy", "settings.privacy", "hand.raised", .privacy)
                        TextAction(title: L.t("settings.rate"), id: "settings.rate", systemImage: "star") {
                            if let id = AppLinks.storeID, let url = URL(string: "https://apps.apple.com/app/id\(id)?action=write-review") {
                                openURL(url)
                            } else { model.message = L.t("store.unavailable") }
                        }
                    }
                }
                CleanerLink()
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setting(_ key: WritableKeyPath<TaskState, Bool>) -> Binding<Bool> {
        Binding(get: { model.state[keyPath: key] }, set: { value in
            Task { await model.perform({ try $0.change { $0[keyPath: key] = value; $0.markRemindersDirty() } }, reminders: true) }
        })
    }

    private func action(_ title: String, _ id: String, _ icon: String, _ route: AppRoute) -> some View {
        TextAction(title: L.t(title), id: id, systemImage: icon) { open(route) }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    let open: (AppRoute) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                let history = model.state.tasks.filter { $0.completedAt != nil }.sorted {
                    ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
                }
                if history.isEmpty { Paper { Text(L.t("history.empty")) } }
                ForEach(history) { task in
                    Paper {
                        TextAction(title: task.purpose, id: "history.task", systemImage: "checkmark.circle") {
                            open(.task(task.id))
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("settings.history"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Paper { Text(L.t("privacy.body")) }
            }
            .padding(18)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .navigationTitle(L.t("settings.privacy"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CleanerLink: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        TextAction(title: L.t("share.cleaner"), id: "share.cleaner", systemImage: "photo.on.rectangle") {
            if let url = URL(string: "https://apps.apple.com/us/app/id6835040441") { openURL(url) }
        }
    }
}
