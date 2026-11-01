import XCTest

/// App Store and README screenshots, captured in the demo in light and dark. Run with
/// `node Tools/screenshots/index.mjs --device "<simulator name>"`, which names and saves them; the full UI run skips it.
final class ScreenshotTests: SmokeTestCase {
    // Recording the demo again (Tools/demo/record.mjs) changes these session IDs.
    static let markdownSession = "ses_e6fa7572bffelnPtdHSgFlZpvV"
    static let finishedSession = "ses_e6fa75d6dffeEbjTkgJy8sikIq"
    static let liveSession = DemoSmokeTests.liveSession
    static let permissionSession = DemoSmokeTests.permissionSession
    static let formSession = "ses_e6fa74130ffeARafLDCE7I0vbX"

    @MainActor private var ipad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @MainActor private var scheme = "light"
    @MainActor private var count = 0

    @MainActor func testLight() throws { try capture(dark: false) }
    @MainActor func testDark() throws { try capture(dark: true) }

    @MainActor private func shot(_ screen: String) {
        // Let scrolling, streaming and sheet animations settle so the image is stable.
        Thread.sleep(forTimeInterval: 1.2)
        count += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "shot-\(scheme)-\(String(format: "%02d", count))-\(screen)"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func open(_ id: String) {
        if !ipad, app.buttons["BackButton"].isHittable { app.buttons["BackButton"].tap() }
        setHome(open: true)
        let row = homeSessionRow(id); XCTAssertTrue(row.isHittable, "Missing demo session \(id)"); row.tap()
        XCTAssertTrue(app.textViews["promptEditor"].waitForExistence(timeout: 10))
        if !ipad { setHome(open: false) }
    }
    @MainActor private func closeSheet() {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
    }

    @MainActor private func capture(dark: Bool) throws {
        scheme = dark ? "dark" : "light"
        // The detail preset comes from the launch arguments, so a preset left by an earlier run never changes a shot.
        // Everything shows each tool row the streaming and Markdown shots are built around.
        try launchFreshApp(suffix: "shots-" + scheme, dark: dark, arguments: ["--ui-testing-screenshots", "-timelineDetail", "everything"])

        app.buttons["addFirstServer"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); shot("add-server")
        app.buttons["Cancel"].tap()
        // Add server opens inside Settings; close that too.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }

        let start = app.buttons["tryDemo"]
        // The add-server sheet is still closing; wait until the button can be tapped.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); start.tap()
        XCTAssertTrue(homeSessionRow(Self.permissionSession).waitForExistence(timeout: 15))
        if !ipad { shot("home") }

        // The running session streams its reply when it is first opened, so it is captured before the longer visits below.
        open(Self.liveSession)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "validate")).firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        shot("streaming")

        open(Self.finishedSession); shot("session")

        open(Self.markdownSession)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Valibot")).firstMatch.waitForExistence(timeout: 10))
        // The session opens at its end, with the table's header row just above the transcript: drag it into view, by
        // less than the 80 points that stop the transcript following its end and bring up Jump to latest.
        let transcript = app.descendants(matching: .any)["transcriptScroll"].firstMatch
        let header = app.staticTexts["Option"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let hidden = transcript.frame.minY + 16 - header.frame.minY
        if hidden > 0 {
            let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: min(hidden + 12, 70))), withVelocity: .slow, thenHoldForDuration: 0.5)
            Thread.sleep(forTimeInterval: 1)
        }
        shot("markdown")
        // Checked after the shot: a later layout pass could have pinned the transcript back to its end.
        XCTAssertGreaterThanOrEqual(header.frame.minY, transcript.frame.minY, "The table's header row shows")
        // The top of the long session, where earlier messages load.
        for _ in 0..<12 { transcript.swipeDown(velocity: .fast) }
        shot("history")

        open(Self.permissionSession)
        let dock = app.descendants(matching: .any).matching(identifier: "approvalDock").firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 15)); shot("permission-dock")
        let reviewRequest = dock.buttons["reviewPermission"].firstMatch
        XCTAssertTrue(reviewRequest.waitForExistence(timeout: 5)); reviewRequest.tap()
        let allow = app.buttons["allowOnce"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        // The sheet is taller than an iPhone screen: scroll to its end so Reject, Allow always and Allow once show whole.
        let sheet = app.scrollViews.containing(.button, identifier: "allowOnce").firstMatch
        for _ in 0..<3 where allow.frame.maxY > sheet.frame.maxY - 20 {
            sheet.swipeUp(); Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertLessThanOrEqual(allow.frame.maxY, sheet.frame.maxY - 20, "The reply buttons show whole")
        shot("permission")
        closeSheet()

        open(Self.formSession)
        let answer = app.descendants(matching: .any).matching(identifier: "approvalDock").firstMatch.buttons["answerQuestion"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15)); answer.tap()
        XCTAssertTrue(app.buttons["formOption-q0-JSON lines"].waitForExistence(timeout: 10)); shot("question")
        closeSheet()

        let review = app.buttons[ipad ? "toggleReview" : "sessionReview"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        let file = app.buttons[ipad ? "reviewFile-src/validate.ts" : "src/validate.ts"].firstMatch
        if file.waitForExistence(timeout: 10) { file.tap() }
        XCTAssertTrue(app.collectionViews["diffCollection"].waitForExistence(timeout: 10)); shot("review")
        if !ipad { app.buttons["closeReview"].tap() } else { review.tap() }

        if ipad {
            // The README's hero: the landscape workspace with Home open beside a finished session, before the
            // keyboard comes up for the commands shot.
            rotate(to: .landscapeLeft)
            open(Self.finishedSession); setHome(open: true); shot("workspace")
            rotate(to: .portrait)
        }
        open(Self.finishedSession)
        let editor = app.textViews["promptEditor"]
        editor.tap(); editor.typeText("/")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "suggestion-")).firstMatch.waitForExistence(timeout: 10))
        shot("commands")
    }
}
