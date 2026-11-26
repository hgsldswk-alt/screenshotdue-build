import Darwin
import notify
import Foundation
import WidgetKit

enum ImportFlow {
    static let extensionDidSave = "com.hgsldswk.screenshotdue.extensionDidSave"

    static func save(store: TaskStore, photo: PreparedPhoto, token: UUID, purpose: String,
                     due: DueDate, asset: String? = nil, waitForReminders: Bool = false) async throws -> UUID {
        let id = try await Task.detached(priority: .userInitiated) {
            try store.add(photo, token: token, purpose: purpose, due: due, asset: asset)
        }.value
        if waitForReminders && !Launch.testing {
            notify_post(extensionDidSave)
            await Task.detached(priority: .utility) {
                await Reminders.reschedule(store: store)
            }.value
            WidgetCenter.shared.reloadTimelines(ofKind: "ScreenshotDueToday")
        }
        return id
    }
}
