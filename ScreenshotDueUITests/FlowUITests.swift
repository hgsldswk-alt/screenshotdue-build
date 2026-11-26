import CoreGraphics
import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()
    private let uiTimeout: TimeInterval = 15

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    private func launch(_ options: [String] = [], language: String = "en", reset: Bool = true,
                        template: String? = nil, purpose: String? = nil) {
        let locales = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"]
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", locales[language] ?? "en_US"] + (reset ? ["-reset"] : []) + options
        var environment: [String: String] = [:]
        environment["STD_TEST_TEMPLATE"] = template
        environment["STD_TEST_PURPOSE"] = purpose
        app.launchEnvironment = environment
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func hittableElement(in query: XCUIElementQuery) -> XCUIElement? {
        query.allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
    }

    private func waitForAction(_ queries: [XCUIElementQuery]) -> XCUIElement? {
        func candidate() -> XCUIElement? {
            for query in queries {
                if let target = hittableElement(in: query) { return target }
            }
            return nil
        }
        if let target = candidate() { return target }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in candidate() != nil }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: uiTimeout) == .completed else { return nil }
        return candidate()
    }

    private var pageScrollView: XCUIElement {
        app.scrollViews.matching(NSPredicate(format: "identifier != %@", "detail.original")).firstMatch
    }

    private func scrollViewport(_ scrollView: XCUIElement) -> CGRect {
        guard scrollView.exists else { return .null }
        let viewport = app.frame.intersection(scrollView.frame)
        let keyboard = app.keyboards.firstMatch
        guard !viewport.isEmpty, keyboard.exists, viewport.intersects(keyboard.frame) else { return viewport }
        return CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                      height: max(0, keyboard.frame.minY - viewport.minY))
    }

    private func coordinate(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let frame = app.frame
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - frame.minX, dy: y - frame.minY))
    }

    private func dismissDetailKeyboard(using field: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        field.typeText("\n")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: uiTimeout), .completed, "Detail keyboard stayed open")
    }

    private func scrollToAction(_ matches: XCUIElementQuery, down: Bool) -> XCUIElement? {
        if let target = hittableElement(in: matches) { return target }
        let scrollView = pageScrollView
        if !scrollView.exists && !matches.firstMatch.exists {
            _ = matches.firstMatch.waitForExistence(timeout: uiTimeout)
        }
        for attempt in 0...5 {
            if let target = hittableElement(in: matches) { return target }
            guard attempt < 5 else { break }
            let viewport = scrollViewport(scrollView)
            guard !viewport.isEmpty else { break }
            let target = matches.firstMatch
            let targetFrame = target.exists ? target.frame : .null
            var towardBottom = down
            if !targetFrame.isEmpty {
                if targetFrame.midY < viewport.minY { towardBottom = false }
                if targetFrame.midY > viewport.maxY { towardBottom = true }
            }
            let x = viewport.maxX - 10
            let upper = coordinate(x: x, y: viewport.minY + viewport.height * 0.28)
            let lower = coordinate(x: x, y: viewport.minY + viewport.height * 0.78)
            (towardBottom ? lower : upper).press(forDuration: 0.01, thenDragTo: towardBottom ? upper : lower)
        }
        return waitForAction([matches])
    }

    private func tap(_ id: String, down: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let matches = app.descendants(matching: .any).matching(identifier: id)
        guard let target = scrollToAction(matches, down: down), target.isHittable else {
            let reason = matches.firstMatch.exists ? "present but not hittable or enabled" : "missing"
            return XCTFail("Cannot tap \(id): \(reason)", file: file, line: line)
        }
        target.tap()
    }

    private func tapAction(_ queries: [XCUIElementQuery], named name: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let target = waitForAction(queries), target.isHittable else {
            return XCTFail("Cannot tap \(name): missing or not hittable", file: file, line: line)
        }
        target.tap()
    }

    private func tapDialogAction(_ label: String, id: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let buttons = [app.alerts.buttons, app.sheets.buttons]
        var queries = buttons.map { $0.matching(NSPredicate(format: "label == %@", label)) }
        if let id {
            queries = buttons.map { $0.matching(NSPredicate(format: "identifier == %@", id)) } + queries
        }
        tapAction(queries, named: label, file: file, line: line)
    }

    private func tapMenuAction(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        tapAction([buttons], named: label, file: file, line: line)
    }

    private func exists(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(id).waitForExistence(timeout: uiTimeout), "Missing \(id)", file: file, line: line)
    }

    private func disappear(_ id: String) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(id))
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: uiTimeout), .completed, "Still showing \(id)")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func back() {
        tapAction([app.navigationBars.firstMatch.buttons], named: "navigation back button")
    }

    private func writePurpose(_ text: String, replacing: Bool = false, id: String = "form.purpose") {
        let matches = app.textFields.matching(identifier: id)
        guard let field = scrollToAction(matches, down: true), field.isHittable else {
            return XCTFail("Cannot edit \(id): missing or not hittable")
        }
        if replacing {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            let length = (field.value as? String)?.count ?? 0
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2))
        } else {
            field.tap()
        }
        field.typeText(text)
        field.typeText("\n")
    }

    private func openImportFixture(file: StaticString = #filePath, line: UInt = #line) {
        exists("home.add", file: file, line: line)
        let title = app.descendants(matching: .any).matching(identifier: "home.title")
        guard let target = scrollToAction(title, down: false), target.isHittable else {
            return XCTFail("Cannot open the import fixture from the home title", file: file, line: line)
        }
        target.doubleTap()
    }

    private func openImport(purpose: String) {
        openImportFixture()
        writePurpose(purpose)
        tap("form.tomorrow")
    }

    func testFirstLaunchAndShareImportSaveWithNotificationsDisabled() {
        launch(["-notifications-denied", "-trial-notice"])
        exists("home.title")
        exists("home.today")
        exists("home.next")
        tap("home.dismissTrial")
        disappear("home.dismissTrial")
        openImport(purpose: "Use my ticket")
        tap("form.save")
        disappear("form.save")
        exists("home.enableNotifications")
        tap("home.task", down: false)
        exists("detail.original")
        XCTAssertEqual(element("detail.purpose").label, "Use my ticket")
    }

    func testPhotoImportSavesDefaultTodayWithoutChoosingADate() {
        launch(["-app-photo-import"], purpose: "Use my ticket")
        openImportFixture()
        exists("form.dueSummary")
        XCTAssertTrue(element("form.dueSummary").label.hasPrefix("Today"))
        XCTAssertTrue(element("form.save").isEnabled)
        tap("form.save")
        disappear("form.save")
        tap("home.task", down: false)
        exists("detail.original")
        XCTAssertTrue(element("detail.date").label.contains("Today"))
    }

    func testPhotoImportCanScrollToAnExactDateBeforeSaving() {
        launch(["-app-photo-import"], purpose: "Use next year's ticket")
        openImportFixture()
        exists("form.dueSummary")
        let today = element("form.dueSummary").label
        let wheel = app.pickerWheels.element(boundBy: 2)
        XCTAssertTrue(wheel.waitForExistence(timeout: uiTimeout))
        if !wheel.isHittable { app.swipeUp() }
        XCTAssertTrue(wheel.isHittable)
        wheel.swipeUp()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", today),
                                                  object: element("form.dueSummary"))
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: uiTimeout), .completed)
        let due = element("form.dueSummary").label
        tap("form.save")
        disappear("form.save")
        tap("home.task", down: false)
        exists("detail.date")
        XCTAssertTrue(element("detail.date").label.contains(due))
    }

    func testHomeCompletesInOneTapUndoAndHistory() {
        launch(["-demo"])
        exists("home.complete")
        tap("home.complete")
        exists("home.undo")
        tap("home.undo")
        disappear("home.undo")
        tap("home.complete")
        exists("home.undo")
        tap("home.settings", down: false)
        tap("settings.history")
        tap("history.task")
        exists("detail.original")
        exists("detail.completed")
    }

    func testNotificationOpensExactScreenshotAndCanZoomEditAndRepeat() {
        launch(["-demo", "-notification-task"])
        exists("detail.original")
        XCTAssertEqual(element("detail.purpose").label, "Pick up museum tickets")
        element("detail.original").pinch(withScale: 1.5, velocity: 1)
        tap("detail.editPurpose")
        let updatedPurpose = "Pick up passes"
        let field = app.textFields.matching(identifier: "detail.purposeField").firstMatch
        writePurpose(updatedPurpose, replacing: true, id: "detail.purposeField")
        XCTAssertEqual(field.value as? String, updatedPurpose)
        dismissDetailKeyboard(using: field)
        exists("detail.savePurpose")
        XCTAssertTrue(element("detail.savePurpose").isEnabled, "Save Purpose is disabled after entering a purpose")
        tap("detail.savePurpose")
        disappear("detail.purposeField")
        XCTAssertEqual(element("detail.purpose").label, updatedPurpose)
        exists("detail.date")
        let date = element("detail.date")
        let originalDate = date.label
        tap("detail.date")
        tapMenuAction("Tomorrow")
        let dateUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label != %@ AND label != %@", originalDate, ""), object: date
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dateUpdated], timeout: uiTimeout), .completed)
        tap("detail.repeat")
        tapMenuAction("Every week")
        let repeatUpdated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Every week"),
                                                      object: element("detail.repeat"))
        XCTAssertEqual(XCTWaiter.wait(for: [repeatUpdated], timeout: uiTimeout), .completed)
    }

    func testReviewSingleTapLimitedAccessCloudSkipAndDeletionCancellation() {
        launch(["-limited", "-cloud-photo"])
        tap("home.review")
        exists("review.manage")
        exists("review.localOnly")
        tap("review.skip")
        exists("review.image")
        tap("review.makeTask")
        exists("review.undo")
        tap("review.markDelete")
        tap("review.basket")
        tap("basket.delete")
        tapDialogAction("Cancel")
        exists("basket.remove")
        tap("basket.delete")
        tapDialogAction("Delete")
        exists("basket.result")
        tap("basket.share")
        tap("share.image")
        exists("share.requested")
    }

    func testExpiredPreservesTasksAndCanPurchaseAndRestore() {
        launch(["-expired", "-demo-full"])
        tap("home.task")
        exists("detail.original")
        back()
        tap("home.add")
        exists("paywall.expired")
        tap("paywall.restore")
        exists("paywall.status")
        tap("paywall.buy")
        exists("paywall.owned")
    }

    func testClaimedTrialStaysClaimedAfterRelaunch() {
        launch(["-trial-notice"])
        tap("home.claimTrial")
        disappear("home.claimTrial")
        app.terminate()
        launch(["-trial-notice"], reset: false)
        exists("home.dismissTrial")
        XCTAssertFalse(element("home.claimTrial").exists)
    }

    func testWidgetPreviewEmptyAndExpired() {
        launch()
        tap("home.settings")
        tap("settings.widgets")
        exists("widget.homePreview")
        exists("widget.lockPreview")
        let emptyToday = element("widget.homePreview").staticTexts
            .matching(NSPredicate(format: "label == %@", "Nothing due today")).firstMatch
        XCTAssertTrue(emptyToday.waitForExistence(timeout: uiTimeout), "Missing the empty widget message")
        app.terminate()
        launch(["-expired"])
        tap("home.settings")
        tap("settings.widgets")
        exists("widget.locked")
    }

    private func sampleTemplateCode() -> String {
        let payload = """
            [
              {"kind":"voucher","days":1,"hour":9},
              {"kind":"reply","days":0,"hour":18}
            ]
            """
        return "STD1:" + Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testTemplatePreviewImportApplyAndFileShare() {
        launch(template: "\n" + sampleTemplateCode() + "\n")
        tap("home.templateCode")
        exists("template.import")
        XCTAssertFalse(element("template.import").isEnabled)
        tap("template.paste")
        exists("template.preview")
        tap("template.import")
        exists("template.result")
        tap("template.import")
        XCTAssertEqual(element("template.result").label, "This template is already in your list.")
        back()
        tap("home.settings", down: false)
        tap("settings.share")
        tap("share.templateFile")
        exists("share.requested")
        back()
        back()
        openImportFixture()
        tap("form.template")
        tapMenuAction("Use a voucher")
        tap("form.save")
        disappear("form.save")
        tap("home.task")
        XCTAssertEqual(element("detail.purpose").label, "Use a voucher")
    }

    func testHomeTemplateFileOpensPickerThenPreviewAndSaves() {
        launch(["-template-file-fixture"], template: sampleTemplateCode())
        tap("home.templateFile")
        tapDialogAction("Sample.stdtemplate", id: "test.templateFile")
        exists("template.preview")
        XCTAssertFalse(element("template.result").exists)
        tap("template.import")
        exists("template.result")
        XCTAssertEqual(element("template.result").label, "Template added. Use it when adding a screenshot.")
    }

    func testRatingOnlyAfterRealCompletionOnThirdDayAndOncePerVersion() {
        launch(["-demo", "-review-eligible", "-notifications-denied", "-share-notice-seen"])
        exists("home.enableNotifications")
        XCTAssertFalse(element("rating.requested").waitForExistence(timeout: uiTimeout))
        tap("home.complete")
        exists("home.undo")
        XCTAssertFalse(element("rating.requested").exists)
        exists("rating.requested")
        app.terminate()
        launch(reset: false)
        exists("home.title")
        XCTAssertFalse(element("rating.requested").waitForExistence(timeout: uiTimeout))
    }

    func testRatingDoesNotCarryAnEarlierCompletionIntoDayThree() {
        launch(["-demo", "-review-two-days", "-review-previous-completion"])
        tap("home.complete")
        exists("home.undo")
        disappear("home.undo")
        XCTAssertFalse(element("rating.requested").waitForExistence(timeout: uiTimeout))
        app.terminate()
        launch(["-review-eligible"], reset: false)
        exists("home.task")
        XCTAssertFalse(element("rating.requested").waitForExistence(timeout: uiTimeout))
    }

    func testDarkAndLargeTextKeepMainActionsAccessible() {
        launch(["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraLarge"])
        exists("home.today")
        exists("home.add")
        openImport(purpose: "Accessibility test")
        tap("form.save")
        disappear("form.save")
        _ = scrollToAction(app.buttons.matching(identifier: "home.task"), down: true)
        exists("home.task")
    }

    func testTaskActionsHaveSeparateAccessibilityLabels() {
        launch(["-demo"])
        exists("home.task")
        exists("home.complete")
        XCTAssertTrue(element("home.complete").label.contains("Pick up museum tickets"))
        XCTAssertNotEqual(element("home.task").label, element("home.complete").label)
        for id in ["home.task", "home.complete", "home.add", "home.templateCode", "home.templateFile"] {
            let buttons = app.buttons.matching(identifier: id)
            if id.hasPrefix("home.template") { _ = scrollToAction(buttons, down: true) }
            let button = buttons.firstMatch
            XCTAssertTrue(button.exists, id)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        }
        tap("home.task")
        exists("detail.original")
        XCTAssertEqual(element("detail.original").label, "Original screenshot")
    }

    func testAppStoreScreenshots() {
        let titles: [String: String] = ["en": "Use coffee voucher", "zh-Hans": "使用咖啡优惠券", "zh-Hant": "使用咖啡折價券"]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            launch(["-demo", "-demo-progress"], language: language, purpose: titles[language])
            exists("home.task")
            XCTAssertFalse(element("home.simulateImport").exists)
            screenshot("store-\(language)-01-home")

            openImportFixture()
            tap("form.tomorrow")
            exists("form.save")
            screenshot("store-\(language)-02-import")
            tap("form.cancel", down: false)

            tap("home.task", down: false)
            exists("detail.original")
            screenshot("store-\(language)-03-original")
            back()

            tap("home.review")
            exists("review.image")
            screenshot("store-\(language)-04-review")
            back()

            tap("home.settings", down: false)
            tap("settings.share")
            exists("share.preview")
            exists("share.qr")
            screenshot("store-\(language)-05-progress")

            back()
            tap("settings.widgets", down: false)
            exists("widget.homePreview")
            exists("widget.lockPreview")
            XCTAssertTrue(app.frame.contains(element("widget.homePreview").frame))
            XCTAssertTrue(app.frame.contains(element("widget.lockPreview").frame))
            screenshot("store-\(language)-06-widgets")
            app.terminate()
        }
    }

    func testPaymentScreenshot() {
        launch(["-paywall"], language: "zh-Hans")
        exists("paywall.title")
        exists("paywall.buy")
        screenshot("paid-01-paywall")
    }
}
