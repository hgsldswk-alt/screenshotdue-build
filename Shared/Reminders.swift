import Darwin
import Foundation
import UserNotifications

struct ReminderPlan {
    struct Entry: Equatable {
        let id: String
        let task: UUID
        let fire: Date
        let first: Bool
        var cycle: RepeatRule = .never
        var useInterval = false
    }

    static let prefix = "screenshotdue."
    static let budget = 60
    static let summaryID = prefix + "summary"
    var entries: [Entry]
    var overflow: Bool

    static func firstID(_ task: ScreenshotTask) -> String {
        prefix + task.id.uuidString + "." + task.reminderVersion.uuidString + ".first"
    }

    static func build(state: TaskState, now: Date, calendar: Calendar,
                      repeatingMatch: (DueDate, RepeatRule) -> Date? = { _, _ in nil }) -> Self {
        var result: [Entry] = []
        let premium = state.hasPro(at: now)
        var overflow = false
        for task in state.openTasks() {
            let firstID = firstID(task)
            let initial = task.due.date(in: calendar)
            if state.scheduledFirst[firstID].map({ $0 <= now }) != true {
                result.append(Entry(id: firstID, task: task.id, fire: max(initial, now.addingTimeInterval(5)),
                                    first: true, useInterval: initial <= now.addingTimeInterval(5)))
            }
            guard premium, task.repeatRule != .never else { continue }
            let today = CivilDay(now, calendar: calendar)
            let daysAgo = calendar.dateComponents([.day], from: task.due.day.date(in: calendar), to: today.date(in: calendar)).day ?? 0
            let step = task.repeatRule.step
            let firstIndex = max(1, daysAgo / step)
            for index in firstIndex...(firstIndex + budget) {
                let day = task.due.day.adding(index * step, in: calendar)
                let due = DueDate(day: day, hour: task.due.hour, minute: task.due.minute)
                let fire = due.date(in: calendar)
                guard fire > now else { continue }
                if state.entitlement?.purchasedPro != true,
                   state.entitlement.map({ fire >= $0.trialEnd }) == true { break }
                let id = firstID + ".r" + String(index)
                if state.entitlement?.purchasedPro == true,
                   let match = repeatingMatch(due, task.repeatRule), abs(match.timeIntervalSince(fire)) < 1 {
                    result.append(Entry(id: firstID + ".cycle", task: task.id, fire: fire,
                                        first: false, cycle: task.repeatRule))
                    break
                }
                result.append(Entry(id: id, task: task.id, fire: fire, first: false))
                if index == firstIndex + budget { overflow = true }
            }
        }
        result.sort { ($0.fire, $0.id) < ($1.fire, $1.id) }
        return Self(entries: Array(result.prefix(budget)), overflow: overflow || result.count > budget)
    }
}

enum Reminders {
    private static let center = UNUserNotificationCenter.current()

    static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    static func status() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }

    private static func components(for due: Date, rule: RepeatRule, calendar: Calendar) -> DateComponents {
        switch rule {
        case .never:
            return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        case .daily: return calendar.dateComponents([.hour, .minute, .second], from: due)
        case .weekly: return calendar.dateComponents([.weekday, .hour, .minute, .second], from: due)
        }
    }

    static func reschedule(store: TaskStore) async {
        let url = store.directory.appendingPathComponent("reminders.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { return }
        defer { close(fd) }
        var locked = false
        for _ in 0..<20 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard locked else { return }
        defer { flock(fd, LOCK_UN) }

        for _ in 0..<3 {
            guard let snapshot = try? store.snapshot() else { return }
            let revision = snapshot.reminderRevision
            let result = await synchronize(snapshot)
            let unchanged = (try? store.change { state in
                guard state.reminderRevision == revision else { return false }
                state.scheduledFirst = result.accepted
                state.remindersDirty = !result.complete
                return true
            }) ?? false
            if unchanged { return }
        }
    }

    private static func synchronize(_ snapshot: TaskState) async -> (accepted: [String: Date], complete: Bool) {
        var accepted = snapshot.scheduledFirst
        let activeIDs = Set(snapshot.openTasks().map(ReminderPlan.firstID))
        let now = Date.now
        let knownTaskIDs = Set(snapshot.tasks.map(ReminderPlan.firstID))
        accepted = accepted.filter { knownTaskIDs.contains($0.key) && (activeIDs.contains($0.key) || $0.value <= now) }
        let existing = await center.pendingNotificationRequests()
        let managed = existing.filter { $0.identifier.hasPrefix(ReminderPlan.prefix) }
        guard allowed(await status()) else {
            center.removePendingNotificationRequests(withIdentifiers: managed.map(\.identifier))
            return (accepted.filter { $0.value <= now }, false)
        }

        var current = snapshot
        for request in managed where activeIDs.contains(request.identifier) {
            if let calendarTrigger = request.trigger as? UNCalendarNotificationTrigger,
               let next = calendarTrigger.nextTriggerDate(), next > now {
                accepted[request.identifier] = next
            }
        }
        current.scheduledFirst = accepted
        let calendar = CivilDay.calendar()
        let plan = ReminderPlan.build(state: current, now: now, calendar: calendar) { due, rule in
            let parts = components(for: due.date(in: calendar), rule: rule, calendar: calendar)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: true).nextTriggerDate()
        }
        let byID = Dictionary(uniqueKeysWithValues: managed.map { ($0.identifier, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        var wanted = Set(plan.entries.map(\.id))
        if plan.overflow && snapshot.dailySummary { wanted.insert(ReminderPlan.summaryID) }
        center.removePendingNotificationRequests(withIdentifiers: managed.map(\.identifier).filter { !wanted.contains($0) })
        accepted = accepted.filter { $0.value <= now || wanted.contains($0.key) }

        var allAccepted = true
        for entry in plan.entries {
            let content = UNMutableNotificationContent()
            content.title = L.t("notification.title")
            content.body = snapshot.notificationPreview ? (tasks[entry.task]?.purpose ?? L.t("notification.body")) : L.t("notification.body")
            content.sound = .default
            content.userInfo = ["task": entry.task.uuidString]
            let trigger: UNNotificationTrigger
            let parts = components(for: entry.fire, rule: entry.cycle, calendar: calendar)
            if entry.useInterval {
                if let previous = byID[entry.id], previous.content.body == content.body,
                   let trigger = previous.trigger as? UNTimeIntervalNotificationTrigger,
                   let fire = trigger.nextTriggerDate() {
                    accepted[entry.id] = accepted[entry.id] ?? fire
                    continue
                }
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, entry.fire.timeIntervalSinceNow), repeats: false)
            } else {
                trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: entry.cycle != .never)
            }
            if let previous = byID[entry.id],
               let trigger = previous.trigger as? UNCalendarNotificationTrigger,
               trigger.dateComponents == parts, trigger.repeats == (entry.cycle != .never),
               previous.content.body == content.body {
                if entry.first { accepted[entry.id] = entry.fire }
                continue
            }
            do {
                try await center.add(UNNotificationRequest(identifier: entry.id, content: content, trigger: trigger))
                if entry.first { accepted[entry.id] = entry.fire }
            } catch {
                allAccepted = false
                if accepted[entry.id].map({ $0 > now }) == true { accepted[entry.id] = nil }
            }
        }
        if wanted.contains(ReminderPlan.summaryID), byID[ReminderPlan.summaryID] == nil {
            let content = UNMutableNotificationContent()
            content.title = L.t("notification.summaryTitle")
            content.body = L.t("notification.summaryBody")
            content.userInfo = ["today": true]
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 19), repeats: true)
            do {
                try await center.add(UNNotificationRequest(identifier: ReminderPlan.summaryID, content: content, trigger: trigger))
            } catch { allAccepted = false }
        }

        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        let delivered = Set(await center.deliveredNotifications().map(\.request.identifier))
        let observed = pending.union(delivered)
        accepted = accepted.filter { $0.value <= now || observed.contains($0.key) }
        return (accepted, allAccepted && wanted.isSubset(of: observed))
    }
}
