import notify
import Darwin
import SwiftUI
import UserNotifications
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = TaskState()
    @Published private(set) var store: TaskStore?
    @Published private(set) var ready = false
    @Published private(set) var startFailed = false
    @Published private(set) var now = Date.now
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    @Published private(set) var requestingNotificationPermission = false
    @Published var message: String?
    @Published var shownForUndo: [UUID: ScreenshotTask] = [:]
    private var starting = false
    private var generation = 0
    private var schedule: Task<Void, Never>?
    private var shareObserver: Int32?
    private var undoTimers: [UUID: Task<Void, Never>] = [:]
    let commerce = StoreAccess()

    deinit {
        if let shareObserver { notify_cancel(shareObserver) }
    }

    var hasPro: Bool { state.hasPro(at: now) }
    var canAdd: Bool { state.entitlement?.canAdd(openCount: state.openCount, at: now) ?? false }

    func start() async {
        guard !starting, !ready else { return }
        starting = true
        startFailed = false
        defer { starting = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let store: TaskStore
                if Launch.testing {
                    let directory = URL.documentsDirectory.appendingPathComponent("ScreenshotDueTests", isDirectory: true)
                    if Launch.has("-reset"), FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                    store = TaskStore(directory: directory)
                } else {
                    store = try TaskStore.shared()
                }
                _ = try store.bootstrap(test: Launch.testing, expired: Launch.has("-expired"), purchased: Launch.has("-purchased"))
                if Launch.testing { try DemoData.seed(store) }
                if ScreenshotLibrary.access() == .authorized {
                    let inFlight = try store.snapshot().deletionInFlight
                    if !inFlight.isEmpty {
                        try store.finishDeletion(confirmed: Set(inFlight).subtracting(ScreenshotLibrary.stillVisible(inFlight)))
                    }
                }
                try? store.purgeUnusedFiles()
                let today = CivilDay(.now)
                let state = try store.change { state in
                    if Launch.testing {
                        if Launch.has("-review-eligible") { state.useDays.insert(today.adding(-2, in: CivilDay.calendar())) }
                        if Launch.has("-review-eligible") || Launch.has("-review-two-days") {
                            state.useDays.insert(today.adding(-1, in: CivilDay.calendar()))
                        }
                        if Launch.has("-share-notice-seen") { state.shareNoticeSeen = true }
                    }
                    state.useDays.insert(today)
                    return state
                }
                return (store, state)
            }.value
            store = loaded.0
            now = .now
            state = loaded.1
            ready = true
            observeSharedImports()
            commerce.start(store: loaded.0) { [weak self] in await self?.refresh(scheduleReminders: true) }
            await refreshPermission()
            requestScheduling()
        } catch {
            startFailed = true
            self.message = L.t("error.storage")
        }
    }

    private func observeSharedImports() {
        guard !Launch.testing, shareObserver == nil else { return }
        var token: Int32 = 0
        if notify_register_dispatch(ImportFlow.extensionDidSave, &token, .main, { [weak self] _ in
            Task { @MainActor in await self?.refresh(scheduleReminders: true) }
        }) == 0 {
            shareObserver = token
        }
    }

    func becameActive() async {
        if !ready { await start(); return }
        await clockChanged(force: true)
        await refreshPermission()
        await commerce.refresh { [weak self] in await self?.refresh(scheduleReminders: true) }
    }

    func clockChanged(force: Bool = false) async {
        let next = Date.now
        let previous = now
        let previousPro = hasPro
        now = next
        guard let store, force || CivilDay(previous) != CivilDay(next) || previousPro != hasPro else { return }
        _ = try? await Task.detached(priority: .utility) {
            try store.change { $0.useDays.insert(CivilDay(next)) }
        }.value
        await refresh(scheduleReminders: true)
    }

    func refreshPermission() async {
        if Launch.testing {
            notifications = Launch.has("-notifications-denied") ? .denied : .authorized
        } else {
            notifications = await Reminders.status()
        }
    }

    func askForNotifications() async {
        guard !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        defer { requestingNotificationPermission = false }
        if Launch.testing { notifications = .authorized; return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshPermission()
            requestScheduling()
        } catch {
            self.message = L.t("notification.permissionError")
        }
    }

    func refresh(scheduleReminders: Bool = false) async {
        guard let store else { return }
        generation += 1
        let request = generation
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
            if request == generation {
                state = snapshot
                now = .now
            }
        } catch {
            self.message = L.t("error.storage")
        }
        if scheduleReminders {
            requestScheduling()
            if !Launch.testing { WidgetCenter.shared.reloadTimelines(ofKind: "ScreenshotDueToday") }
        }
    }

    private func requestScheduling() {
        guard !Launch.testing, let store else { return }
        schedule?.cancel()
        schedule = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { await Reminders.reschedule(store: store) }
        }
    }

    @discardableResult
    func apply<T: Sendable>(_ update: @escaping @Sendable (TaskStore) throws -> T, reminders: Bool = false) async throws -> T {
        guard let store else { throw StorageError.unavailable }
        let value = try await Task.detached(priority: .userInitiated) { try update(store) }.value
        await refresh(scheduleReminders: reminders)
        return value
    }

    func perform(_ update: @escaping @Sendable (TaskStore) throws -> Void, reminders: Bool = false) async {
        do { try await apply(update, reminders: reminders) }
        catch { self.message = (error as? StorageError)?.message ?? L.t("error.storage") }
    }

    func complete(_ task: ScreenshotTask) async {
        do {
            try await apply({ try $0.complete(task.id, done: true) }, reminders: true)
            shownForUndo[task.id] = task
            undoTimers[task.id]?.cancel()
            undoTimers[task.id] = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                shownForUndo[task.id] = nil
                undoTimers[task.id] = nil
            }
        } catch {
            self.message = L.t("error.storage")
        }
    }

    func undo(_ id: UUID) async {
        do {
            try await apply({ try $0.complete(id, done: false) }, reminders: true)
            shownForUndo[id] = nil
            undoTimers[id]?.cancel()
            undoTimers[id] = nil
        } catch { self.message = L.t("error.storage") }
    }

    func save(photo: PreparedPhoto, token: UUID, purpose: String, due: DueDate, asset: String? = nil) async throws -> UUID {
        guard let store else { throw StorageError.unavailable }
        let id = try await ImportFlow.save(store: store, photo: photo, token: token, purpose: purpose, due: due, asset: asset)
        await refresh(scheduleReminders: true)
        return id
    }

    func requestReview(version: String, on day: CivilDay, ifIdle: () -> Bool, request: () -> Void) async {
        guard let store else { return }
        let claim = try? await Task.detached(priority: .utility) { try store.claimReview(version: version, on: day) }.value
        guard let claim else { return }
        if !Task.isCancelled && ifIdle() && CivilDay(.now) == day && state.hasReviewCompletion(on: day) {
            request()
        } else {
            _ = try? await Task.detached(priority: .utility) { try store.releaseReview(claim) }.value
        }
        await refresh()
    }
}
