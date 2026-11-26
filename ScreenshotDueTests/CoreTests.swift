import CoreImage
import XCTest
import UIKit

final class CoreTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        CivilDay.calendar(zone: TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)!)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func photo(_ variant: Int = 0) throws -> PreparedPhoto {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 20), format: format).pngData { context in
            UIColor(red: CGFloat(variant % 255) / 255, green: 0.5, blue: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 20))
        }
        return try PreparedPhoto(data: data)
    }

    private func withStore(_ body: (TaskStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TaskStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(store)
    }

    func testDateDefaultsAndCrossMidnight() {
        let cal = calendar()
        let morning = date(2026, 11, 3, 7)
        let day = CivilDay(morning, calendar: cal)
        XCTAssertEqual(DueDate.best(on: day, now: morning, calendar: cal).hour, 9)
        XCTAssertEqual(DueDate.best(on: day, now: date(2026, 11, 3, 15, 20), calendar: cal).hour, 16)
        let late = date(2026, 11, 3, 23, 45)
        let due = DueDate.best(on: day, now: late, calendar: cal)
        XCTAssertEqual(due.day, day)
        var state = TaskState()
        state.tasks = [ScreenshotTask(purpose: "late", due: due, createdAt: late)]
        let entry = ReminderPlan.build(state: state, now: late, calendar: cal).entries.first
        XCTAssertEqual(entry?.fire, late.addingTimeInterval(5))
        XCTAssertEqual(entry?.useInterval, true)
    }

    func testCivilDateSurvivesTimeZoneChangeAndDSTGap() {
        let la = calendar("America/Los_Angeles")
        let ny = calendar("America/New_York")
        let day = CivilDay(date(2026, 3, 8, in: la), calendar: la)
        let gap = DueDate(day: day, hour: 2, minute: 30)
        XCTAssertEqual(gap.date(in: la), date(2026, 3, 8, 3, in: la))
        let ordinary = DueDate(day: day, hour: 9)
        XCTAssertEqual(ny.component(.hour, from: ordinary.date(in: ny)), 9)
        XCTAssertEqual(CivilDay(ordinary.date(in: ny), calendar: ny), day)
        XCTAssertEqual(ordinary.date(in: la).timeIntervalSince(ordinary.date(in: ny)), 3 * 3600)
    }

    func testOverdueSortAndCompletedExclusion() {
        let now = date(2026, 11, 3, 12)
        let cal = calendar()
        let today = CivilDay(now, calendar: cal)
        var state = TaskState()
        for (offset, hour, purpose) in [(4, 9, "future"), (0, 14, "later"), (-1, 20, "past"), (0, 9, "earlier")] {
            state.tasks.append(ScreenshotTask(purpose: purpose, due: DueDate(day: today.adding(offset, in: cal), hour: hour), createdAt: now))
        }
        state.tasks.append(ScreenshotTask(purpose: "closed", due: DueDate(day: today), createdAt: now, completedAt: now))
        let sections = state.sections(at: now, calendar: cal)
        XCTAssertEqual(sections.today.map(\.purpose), ["past", "earlier", "later"])
        XCTAssertEqual(sections.next.map(\.purpose), ["future"])
    }

    func testFirstReminderAndRecurringReplacementDate() {
        let now = date(2026, 11, 3)
        let cal = calendar()
        let due = DueDate(day: CivilDay(now, calendar: cal).adding(4, in: cal))
        let task = ScreenshotTask(purpose: "Weekly", due: due, repeatRule: .weekly, createdAt: now)
        var state = TaskState(entitlement: Entitlement(firstOpen: now, purchasedPro: true))
        state.tasks = [task]
        let early = ReminderPlan.build(state: state, now: now, calendar: cal) { _, _ in now.addingTimeInterval(3600) }
        XCTAssertEqual(early.entries.first?.fire, due.date(in: cal))
        XCTAssertEqual(early.entries.first?.first, true)
        XCTAssertTrue(early.entries.allSatisfy { $0.cycle == .never })
        let exact = ReminderPlan.build(state: state, now: now, calendar: cal) { date, _ in date.date(in: cal) }
        XCTAssertEqual(exact.entries.count, 2)
        XCTAssertEqual(exact.entries.last?.fire, due.date(in: cal).addingTimeInterval(7 * 86400))
        XCTAssertEqual(exact.entries.last?.cycle, .weekly)
    }

    func testRepeatLimitedByTrialAndOriginalReminderSurvives() {
        let now = date(2026, 11, 3, 12)
        let cal = calendar()
        let day = CivilDay(now, calendar: cal)
        let entitlement = Entitlement(firstOpen: now.addingTimeInterval(-29 * 86400))
        var state = TaskState(entitlement: entitlement)
        let task = ScreenshotTask(purpose: "Daily", due: DueDate(day: day, hour: 15), repeatRule: .daily, createdAt: now)
        state.tasks = [task]
        let plan = ReminderPlan.build(state: state, now: now, calendar: cal)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertTrue(plan.entries.allSatisfy { $0.fire < entitlement.trialEnd && $0.cycle == .never })
        state.tasks[0].due = DueDate(day: day.adding(4, in: cal), hour: 15)
        let after = ReminderPlan.build(state: state, now: now.addingTimeInterval(86400), calendar: cal)
        XCTAssertEqual(after.entries.count, 1)
        XCTAssertEqual(after.entries.first?.first, true)
    }

    func testFiresOnlySixtyRequestsAndSignalsOverflow() {
        let now = date(2026, 11, 3)
        let cal = calendar()
        let day = CivilDay(now, calendar: cal)
        var state = TaskState()
        state.tasks = (0..<75).reversed().map {
            ScreenshotTask(purpose: String($0), due: DueDate(day: day.adding($0, in: cal)), createdAt: now)
        }
        let plan = ReminderPlan.build(state: state, now: now, calendar: cal)
        XCTAssertEqual(plan.entries.count, 60)
        XCTAssertTrue(plan.overflow)
        XCTAssertEqual(plan.entries.first?.fire, date(2026, 11, 3, 9))
        XCTAssertEqual(plan.entries.last?.fire, DueDate(day: day.adding(59, in: cal)).date(in: cal))
    }

    func testTrialBoundariesReceiptRecoveryAndRefund() {
        let now = date(2026, 11, 3)
        var rights = Entitlement(firstOpen: now)
        XCTAssertFalse(rights.hasPro(at: now.addingTimeInterval(-1)))
        XCTAssertTrue(rights.hasPro(at: now, free: false))
        XCTAssertTrue(rights.hasPro(at: rights.trialEnd.addingTimeInterval(-1)))
        XCTAssertFalse(rights.hasPro(at: rights.trialEnd))
        XCTAssertTrue(rights.canAdd(openCount: 9, at: rights.trialEnd))
        XCTAssertFalse(rights.canAdd(openCount: 10, at: rights.trialEnd))
        rights.reconcile(verifiedTrial: now.addingTimeInterval(60), verifiedPurchase: true)
        XCTAssertEqual(rights.trialStart, now)
        XCTAssertTrue(rights.hasPro(at: rights.trialEnd))
        rights.reconcile(verifiedTrial: now.addingTimeInterval(-31 * 86400), verifiedPurchase: nil)
        XCTAssertTrue(rights.hasPro(at: now))
        rights.reconcile(verifiedTrial: nil, verifiedPurchase: false)
        XCTAssertFalse(rights.hasPro(at: now))
        XCTAssertFalse(Launch.freePeriod)
    }

    func testDuplicateSharingAndImageIntegrity() throws {
        try withStore { store in
            let now = Date.now
            _ = try store.bootstrap(now: now, test: true)
            let photo = try self.photo()
            let due = DueDate(day: CivilDay(now))
            let token = UUID()
            let first = try store.add(photo, token: token, purpose: "  Original  ", due: due, now: now)
            XCTAssertEqual(first, try store.add(photo, token: token, purpose: "Retry", due: due, now: now))
            XCTAssertEqual(first, try store.add(photo, token: UUID(), purpose: "Duplicate", due: due, now: now))
            let snapshot = try store.snapshot()
            let task = try XCTUnwrap(snapshot.tasks.first)
            let image = try XCTUnwrap(task.image)
            XCTAssertEqual(task.purpose, "Original")
            XCTAssertEqual(try Data(contentsOf: store.imageURL(image, thumbnail: false)), photo.original)
            XCTAssertEqual(try Data(contentsOf: store.imageURL(image, thumbnail: true)), photo.thumbnail)
            XCTAssertEqual(snapshot.openCount, 1)
            XCTAssertThrowsError(try PreparedPhoto(data: Data([1, 2, 3])))
        }
    }

    func testConcurrentImportsShareFreeCapacity() throws {
        try withStore { store in
            let now = Date.now
            _ = try store.bootstrap(now: now, test: true, expired: true)
            let due = DueDate(day: CivilDay(now))
            let photos = try (0..<16).map { try photo($0) }
            DispatchQueue.concurrentPerform(iterations: photos.count) { index in
                _ = try? store.add(photos[index], token: UUID(), purpose: "Test \(index)", due: due, now: now)
            }
            let state = try store.snapshot()
            XCTAssertEqual(state.openCount, 10)
            XCTAssertEqual(state.importTokens.count, 10)
            let rejected = try photo(40)
            XCTAssertThrowsError(try store.add(rejected, token: UUID(), purpose: "Full", due: due, now: now)) {
                guard case StorageError.full = $0 else { return XCTFail("Expected the free cap") }
            }
        }
    }

    func testDiskWriteFailureRollsBackAndCommitCanBeRetried() throws {
        try withStore { store in
            let now = Date.now
            _ = try store.bootstrap(now: now, test: true)
            let imageFolder = store.directory.appendingPathComponent("Images")
            try FileManager.default.removeItem(at: imageFolder)
            try Data([0]).write(to: imageFolder)
            let token = UUID()
            let photo = try self.photo()
            let due = DueDate(day: CivilDay(now))
            XCTAssertThrowsError(try store.add(photo, token: token, purpose: "Retry", due: due, now: now))
            XCTAssertTrue(try store.snapshot().tasks.isEmpty)
            try FileManager.default.removeItem(at: imageFolder)
            _ = try store.add(photo, token: token, purpose: "Retry", due: due, now: now)
            XCTAssertEqual(try store.snapshot().openCount, 1)
        }
    }

    func testRolledBackTransactionRemovesStagedFiles() throws {
        try withStore { store in
            _ = try store.bootstrap(test: true)
            let image = UUID()
            let original = store.imageURL(image, thumbnail: false)
            let thumb = store.imageURL(image, thumbnail: true)
            XCTAssertThrowsError(try store.change(staged: image) { state -> Void in
                try Data([1, 2]).write(to: original, options: .atomic)
                try Data([3, 4]).write(to: thumb, options: .atomic)
                state.tasks.append(ScreenshotTask(purpose: "Uncommitted", due: DueDate(day: CivilDay(.now)), createdAt: .now, image: image))
                throw StorageError.unavailable
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path))
            XCTAssertTrue(try store.snapshot().tasks.isEmpty)
        }
    }

    func testCompletionUndoReschedulesAndCountsOnce() throws {
        try withStore { store in
            let now = Date.now
            _ = try store.bootstrap(now: now, test: true)
            let id = try store.add(photo(), token: UUID(), purpose: "Test", due: DueDate(day: CivilDay(now)), now: now)
            let cal = CivilDay.calendar()
            try store.complete(id, done: true, now: now)
            var state = try store.snapshot()
            XCTAssertTrue(ReminderPlan.build(state: state, now: now, calendar: cal).entries.isEmpty)
            XCTAssertEqual(state.progress(at: now).done, 1)
            try store.complete(id, done: false, now: now)
            state = try store.snapshot()
            XCTAssertEqual(ReminderPlan.build(state: state, now: now, calendar: cal).entries.count, 1)
            XCTAssertEqual(state.progress(at: now).done, 0)
            try store.complete(id, done: true, now: now.addingTimeInterval(2))
            state = try store.snapshot()
            XCTAssertEqual(state.tasks.first?.firstCompletedAt, now)
            XCTAssertEqual(state.progress(at: now).done, 1)
        }
    }

    func testDowngradePreservesExistingRecordsAndCapacity() throws {
        try withStore { store in
            let now = Date.now
            let due = DueDate(day: CivilDay(now))
            _ = try store.bootstrap(now: now, test: true, purchased: true)
            for index in 0..<12 {
                _ = try store.add(photo(index), token: UUID(), purpose: "Task \(index)", due: due, now: now)
            }
            try store.change { $0.entitlement = Entitlement(firstOpen: now.addingTimeInterval(-31 * 86400)) }
            let before = try store.snapshot()
            XCTAssertEqual(before.openCount, 12)
            let first = try XCTUnwrap(before.tasks.first)
            try store.updateTask(first.id) { task, _ in task.purpose += "!" }
            let newPhoto = try photo(50)
            XCTAssertThrowsError(try store.add(newPhoto, token: UUID(), purpose: "Free limit", due: due, now: now))
            for task in before.tasks.prefix(3) { try store.complete(task.id, done: true) }
            _ = try store.add(newPhoto, token: UUID(), purpose: "Space freed", due: due, now: now)
            XCTAssertEqual(try store.snapshot().openCount, 10)
            XCTAssertEqual(try store.snapshot().tasks.count, 13)
        }
    }

    func testPhotoDeletionConfirmationStatsAndMilestone() throws {
        try withStore { store in
            let now = Date.now
            _ = try store.bootstrap(now: now, test: true)
            try store.change { state in
                for index in 0..<99 { state.deletedAssets[String(index)] = now }
                state.review["a"] = .pendingDelete
                state.review["b"] = .pendingDelete
            }
            try store.beginDeletion(["a", "b"])
            try store.finishDeletion(confirmed: [], now: now)
            XCTAssertEqual(try store.snapshot().basket, ["a", "b"])
            try store.beginDeletion(["a", "b"])
            try store.finishDeletion(confirmed: ["a"], now: now)
            let after = try store.snapshot()
            XCTAssertEqual(after.basket, ["b"])
            XCTAssertEqual(after.progress(at: now).cleared, 100)
            XCTAssertTrue(after.milestonePending)
        }
    }

    func testTemplateRoundTripAndStrictValidation() throws {
        let code = try TemplateCode.encode()
        XCTAssertTrue(code.hasPrefix("STD1:"))
        XCTAssertEqual(try TemplateCode.decode(code), TemplateCode.examples)
        XCTAssertThrowsError(try TemplateCode.decode(code.replacingOccurrences(of: "STD1:", with: "STD2:")))
        XCTAssertThrowsError(try TemplateCode.decode("STD1:!"))
        XCTAssertThrowsError(try TemplateCode.decode("STD1:" + String(repeating: "A", count: 3000)))
        XCTAssertThrowsError(try TemplateCode.encode([TemplateItem(kind: .reply, days: 31, hour: 12)]))
        XCTAssertThrowsError(try TemplateCode.encode([TemplateItem(kind: .travel, days: 1, hour: 3)]))
        let foreign = Data(#"[{"kind":"reply","days":1,"hour":9,"note":"private"}]"#.utf8).base64EncodedString()
        XCTAssertThrowsError(try TemplateCode.decode("STD1:" + foreign.replacingOccurrences(of: "=", with: "")))
        try withStore { store in
            XCTAssertTrue(try store.importTemplates(TemplateCode.examples))
            XCTAssertFalse(try store.importTemplates(TemplateCode.examples))
        }
    }

    func testRatingClaimsOnlyAfterACompletionOnAnEligibleDay() throws {
        let calendar = calendar()
        let first = date(2026, 11, 1, 12)
        let start = CivilDay(first, calendar: calendar)
        let second = start.adding(2, in: calendar)
        let third = start.adding(4, in: calendar)
        let fourth = start.adding(7, in: calendar)
        try withStore { store in
            _ = try store.bootstrap(now: first, test: true)
            let id = try store.add(photo(), token: UUID(), purpose: "Ticket", due: DueDate(day: start), now: first)
            try store.complete(id, done: true, now: first, calendar: calendar)
            try store.change { $0.useDays.formUnion([start, second, second]) }
            XCTAssertNil(try store.claimReview(version: "1.0", on: second))
            try store.change { $0.useDays.insert(third) }
            XCTAssertNil(try store.claimReview(version: "1.0", on: third), "Opening on day three is insufficient")
            try store.complete(id, done: true, now: third.date(in: calendar), calendar: calendar)
            XCTAssertNil(try store.claimReview(version: "1.0", on: third), "Repeated done requests are no-ops")

            try store.complete(id, done: false, now: third.date(in: calendar), calendar: calendar)
            try store.complete(id, done: true, now: third.date(in: calendar), calendar: calendar)
            let claim = try XCTUnwrap(store.claimReview(version: "1.0", on: third))
            XCTAssertEqual(try store.snapshot().reviewVersion, "1.0")
            XCTAssertNil(try store.claimReview(version: "1.0", on: third))
            try store.releaseReview(claim)
            XCTAssertNotNil(try store.claimReview(version: "1.0", on: third))
            XCTAssertNil(try store.claimReview(version: "1.1", on: fourth), "Yesterday’s event cannot carry forward")

            try store.complete(id, done: false, now: fourth.date(in: calendar), calendar: calendar)
            try store.complete(id, done: true, now: fourth.date(in: calendar), calendar: calendar)
            let nextVersion = try XCTUnwrap(store.claimReview(version: "1.1", on: fourth))
            try store.releaseReview(nextVersion)
            XCTAssertEqual(try store.snapshot().reviewVersion, "1.0")
            try store.complete(id, done: false, now: fourth.date(in: calendar), calendar: calendar)
            XCTAssertNil(try store.claimReview(version: "1.1", on: fourth), "Undo removes the qualifying event")
        }
    }

    func testLegacyCompletedTaskDoesNotQualifyForRating() throws {
        let now = date(2026, 11, 12)
        let calendar = calendar()
        let today = CivilDay(now, calendar: calendar)
        var state = TaskState()
        state.useDays = [today, today.adding(-1, in: calendar), today.adding(-2, in: calendar)]
        state.tasks = [ScreenshotTask(purpose: "Done", due: DueDate(day: today), createdAt: now, completedAt: now)]
        let legacy = try JSONDecoder().decode(TaskState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(legacy.tasks.first?.completedAt, now)
        XCTAssertFalse(legacy.isReviewEligible(version: "1.0", on: today))
    }

    func testShareCardSizeAndQRCodeCanBeRead() throws {
        let url = "https://hgsldswk-alt.github.io/screenshotdue-support/"
        let content = ShareCardContent(counts: .init(cleared: 214, done: 9), milestone: false,
                                       appName: L.t("app.name"), download: url, isPlaceholder: true)
        let card = ShareCard.render(content)
        let cg = try XCTUnwrap(card.cgImage)
        XCTAssertEqual(cg.width, 1080)
        XCTAssertEqual(cg.height, 1350)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(found.contains(url))
        XCTAssertNotEqual(L.t("app.name"), "app.name")
    }
}
