import Foundation
import XCTest
import UIKit

/// iPhone: the app's App Shortcuts in the Shortcuts app, and Send a prompt and Get session status against the sandbox
/// (through the DEBUG intent hook, since this build cannot run them from Shortcuts); Spotlight finding and opening a
/// session; the Needs you widget added to the Home Screen, opened and removed again. Findings are attached.
nonisolated final class SystemSmokeTests: SmokeTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    @MainActor private lazy var shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
    @MainActor private lazy var springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    @MainActor private lazy var spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func finding(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text); attachment.name = "finding-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// Pairs the sandbox and creates one session with a unique title; returns its ID and title.
    @MainActor private func setUpServer(_ suffix: String) async throws -> (id: String, title: String) {
        // iOS 27 keeps an App Shortcut's result over every app until Done is tapped: one an earlier test left would
        // cover this test's screens.
        if tapLabel("Done", in: [springboard, spotlight], timeout: 2) { finding("shortcut-result", "An App Shortcut's result was still showing; Done closed it.") }
        try launchFreshApp(suffix: suffix)
        app.buttons["addFirstServer"].tap()
        XCTAssertTrue(app.buttons["Use password"].waitForExistence(timeout: 5)); app.buttons["Use password"].tap()
        XCTAssertTrue(app.textFields["serverName"].waitForExistence(timeout: 5))
        app.textFields["serverName"].tap(); app.textFields["serverName"].typeText("System sandbox")
        app.textFields["serverURL"].tap(); app.textFields["serverURL"].typeText(try XCTUnwrap(env["OPENCODE_UI_URL"]))
        app.secureTextFields["serverPassword"].tap(); app.secureTextFields["serverPassword"].typeText(try XCTUnwrap(env["OPENCODE_UI_PASSWORD"]))
        connect(explainingLocalNetwork: true); waitForConnections()
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["closeSettings"].waitForNonExistence(timeout: 10))
        let title = "Shortcut target " + String(UUID().uuidString.prefix(6))
        let created = try await api("/api/session", method: "POST", body: ["title": title, "location": ["directory": try XCTUnwrap(env["OPENCODE_UI_DIRECTORY"])],
                                                                           "model": ["providerID": "mock", "id": "mock-1"]])
        let id = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(homeSessionRow(id).exists, "The session reached Home")
        return (id, title)
    }
    /// Taps the first element whose label matches, in any of the given apps.
    @MainActor @discardableResult private func tapLabel(_ label: String, in targets: [XCUIApplication], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for target in targets {
                for query in [target.buttons, target.cells, target.staticTexts, target.otherElements] {
                    let element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if element.exists && element.isHittable { element.tap(); return true }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }
    /// Runs one of the app's App Shortcuts from the Shortcuts app: its tile is a button named after its symbol.
    @MainActor private func runShortcut(_ symbol: String) -> Bool {
        shortcuts.activate()
        // iOS 27 opens Shortcuts with a one-time "What's New in Shortcuts" sheet over the library.
        let whatsNew = shortcuts.staticTexts["What’s New in Shortcuts"]
        if whatsNew.waitForExistence(timeout: 3) { tapLabel("Continue", in: [shortcuts], timeout: 5) }
        let tile = shortcuts.buttons[symbol]
        if !tile.waitForExistence(timeout: 5) {
            // Not on the app's page yet: the library lists the app's tiles under its name. iOS 27 opens on All
            // Shortcuts, which lists only the user's own shortcuts; the app is a level up, in the Library.
            if !tapLabel("Opencode", in: [shortcuts], timeout: 5) {
                let library = shortcuts.buttons["BackButton"]
                if library.exists { library.tap() }
                if !tapLabel("Opencode", in: [shortcuts], timeout: 5), tapLabel("Apps", in: [shortcuts], timeout: 5) {
                    tapLabel("Opencode", in: [shortcuts], timeout: 5)
                }
            }
        }
        guard tile.waitForExistence(timeout: 10) else { return false }
        tile.tap()
        return true
    }
    @MainActor private func text(containing fragment: String, in targets: [XCUIApplication], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for target in targets {
                let match = target.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
                if match.exists { return match.label }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    @MainActor func testShortcutsRunTheIntents() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
        let started = Date().timeIntervalSince1970 * 1_000
        let session = try await setUpServer("-shortcuts")
        _ = try await api("/admin/scenario", method: "POST", body: ["name": "plain-text"], mock: true)
        // The Shortcuts app shows the app's App Shortcuts; running one needs the system to accept the app.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(runShortcut("paperplane"), "Send a prompt is among the app's App Shortcuts in Shortcuts")
        let refused = shortcuts.alerts["Unable to run App Shortcut"]
        let blocked = refused.waitForExistence(timeout: 10)
        screenshot("system-shortcuts-send")
        finding("shortcuts", blocked
            ? "XCUITest ran Send a prompt from the app's page in the Shortcuts app; the system refused it with \"Unable to run App Shortcut\" (linkd rejects an app without a team identifier)."
            : "XCUITest ran Send a prompt from the app's page in the Shortcuts app; no refusal was seen.")
        if blocked { refused.buttons.firstMatch.tap() }
        // The same intents, built with the values a Shortcuts run passes and performed in the app process.
        let server = try serverID()
        let prompt = "Hello from Shortcuts " + String(UUID().uuidString.prefix(6))
        try runIntent("send", server: server, session: session.id, text: prompt)
        let sent = try trace(containing: "send result=")
        XCTAssertEqual(sent, "send result=Sent to “\(session.title)”.", "Send reported the prompt delivered")
        var received = 0
        for _ in 0..<100 {
            let messages = try await api("/api/session/\(session.id)/message?limit=50&order=asc")
            received = ((messages["data"] as? [[String: Any]]) ?? []).filter { item in
                item["type"] as? String == "user" && item["text"] as? String == prompt &&
                    (((item["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue ?? 0) >= started
            }.count
            if received > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(received, 1, "Exactly one prompt with the text reached the server")
        // Get session status once the run has finished: the server reports it succeeded, and the intent says Finished.
        _ = try await api("/api/experimental/session/\(session.id)/wait", method: "POST")
        let fetched = try await api("/api/session/\(session.id)")
        let info = try XCTUnwrap(fetched["data"] as? [String: Any])
        let active = try await api("/api/session/active")["data"] as? [String: Any] ?? [:]
        XCTAssertTrue(active[session.id] == nil && info["outcome"] as? String == "succeeded", "The run finished on the server")
        try runIntent("status", server: server, session: session.id)
        let status = try trace(containing: "status result=")
        screenshot("system-shortcuts-status")
        finding("shortcuts-intents", [sent, status, "server: outcome \(info["outcome"] as? String ?? "none")"].joined(separator: "\n"))
        XCTAssertTrue(status.hasPrefix("status result=\(session.title): Finished."), "The status matches the server: \(status)")
    }
    /// The paired server's ID, from the DEBUG connection diagnostics.
    @MainActor private func serverID() throws -> String {
        let probe = app.descendants(matching: .any)["connectionDiagnostics"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let value = probe.value as? String ?? ""
        let range = try XCTUnwrap(value.range(of: #"server=[0-9A-F-]{36}"#, options: .regularExpression), "No server in \(value)")
        return String(value[range].dropFirst("server=".count))
    }
    /// Performs an intent in the app through the DEBUG hook, as a Shortcuts run would with these values.
    @MainActor private func runIntent(_ name: String, server: String, session: String, text: String? = nil) throws {
        var components = URLComponents(string: "opencodeios://debug-intent/" + name)
        components?.queryItems = [.init(name: "server", value: server), .init(name: "session", value: session)] + (text.map { [.init(name: "text", value: $0)] } ?? [])
        XCUIDevice.shared.system.open(try XCTUnwrap(components?.url))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
    /// The newest line of the app's intent trace that starts with a prefix.
    @MainActor private func trace(containing prefix: String, timeout: TimeInterval = 30) throws -> String {
        let element = app.descendants(matching: .any)["intentTrace"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = (element.exists ? element.value as? String ?? "" : "").split(separator: "\n").map(String.init)
            if let line = lines.last(where: { $0.hasPrefix(prefix) }) { return line }
            if let error = lines.last(where: { $0.hasPrefix("debug-intent error=") }) { XCTFail(error) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("No \(prefix) in the intent trace")
        return ""
    }
    /// Opens Spotlight from the Home Screen and returns its search field.
    @MainActor private func openSpotlight() -> XCUIElement {
        XCUIDevice.shared.press(.home)
        let pill = springboard.otherElements["spotlight-pill"]
        if pill.waitForExistence(timeout: 5) && pill.isHittable { pill.tap() } else { springboard.swipeDown() }
        return spotlight.textFields["SpotlightSearchField"]
    }
    /// Clears the field with its own button (Spotlight completes inline, so deleting characters is unreliable) and types.
    @MainActor private func replaceSearch(_ field: XCUIElement, with text: String) {
        let clear = field.buttons["Clear text"]
        if clear.exists && clear.isHittable { clear.tap() }
        field.typeText(text)
    }
    @MainActor func testSpotlightOpensASession() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
        let session = try await setUpServer("-spotlight")
        // Settings → Widgets and Shortcuts: Spotlight indexing is on by default.
        app.buttons["openSettings"].tap()
        let toggle = app.switches["spotlightToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "The Spotlight switch")
        for _ in 0..<10 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1", "Spotlight indexing is on by default")
        screenshot("system-settings")
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["closeSettings"].waitForNonExistence(timeout: 10))
        // Indexing waits two seconds after the last change.
        try await Task.sleep(for: .seconds(5))
        let field = openSpotlight()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Spotlight's search field")
        // Whether iOS lists the app's App Shortcuts when its name is searched.
        replaceSearch(field, with: "Opencode")
        try await Task.sleep(for: .seconds(3))
        let titles = ["Send a prompt", "Session status", "Open session", "Review approval", "New prompt"]
        let listed = titles.filter { spotlight.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch.exists }
        screenshot("system-spotlight-shortcuts")
        finding("spotlight-app-shortcuts", listed.isEmpty ? "Searching the app's name lists none of its App Shortcuts." : "Searching the app's name lists: " + listed.joined(separator: ", "))
        // Running one from Spotlight: what the system does with it for this build.
        let shortcut = spotlight.cells.matching(NSPredicate(format: "label == %@", "Session status")).firstMatch
        if shortcut.exists && shortcut.isHittable {
            shortcut.tap()
            try await Task.sleep(for: .seconds(3))
            screenshot("system-spotlight-run")
            let alert = [spotlight, springboard, shortcuts].map { $0.alerts.firstMatch }.first { $0.exists }
            // Shortcuts may answer with a notification banner instead of an alert.
            let banner = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "couldn", "unable")).firstMatch
            finding("spotlight-run", alert.map { "Session status from Spotlight: the system showed the alert \"\($0.label)\"." }
                ?? (banner.exists ? "Session status from Spotlight: the system showed \"\(banner.label)\"."
                    : "Session status from Spotlight: no alert or banner; the screen after three seconds is system-spotlight-run."))
            alert?.buttons.firstMatch.tap()
        } else {
            finding("spotlight-run", "Session status was not listed, so it was not run.")
        }
        // A session by its title, among the results: never a web suggestion, which would open Safari, and never Session
        // status for it, which runs instead of opening. iOS 27 can list that App Shortcut first, its gauge symbol leading
        // the label, after the Shortcuts test has run it; Open session's leads with "Comment Left".
        let search = openSpotlight()
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Spotlight's search field")
        let result = spotlight.cells.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH %@) AND (identifier BEGINSWITH %@ OR identifier BEGINSWITH %@)",
                                                          session.title, "Gauge", "Identifier:ResultCell", "Identifier:AppViewResultCell")).firstMatch
        replaceSearch(search, with: session.title)
        var found = result.waitForExistence(timeout: 15)
        if !found { replaceSearch(search, with: session.title); found = result.waitForExistence(timeout: 15) }
        screenshot("system-spotlight")
        finding("spotlight", "query: \(search.value as? String ?? ""); result: \(found ? result.label + " (" + result.identifier + ")" : "none")")
        XCTAssertTrue(found, "Spotlight lists the session by its title")
        result.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The app comes forward")
        XCTAssertTrue(app.navigationBars[session.title].waitForExistence(timeout: 10), "Opened on the session")
    }

    @MainActor func testWidgetOnTheHomeScreen() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 400
        _ = try await setUpServer("-widget")
        // A session waiting for approval, so Needs you has a row.
        _ = try await api("/admin/scenario", method: "POST", body: ["name": "widget-approval", "script": ["calls": [
            ["tools": [["name": "shell", "arguments": ["command": "printf 'widget-approval\\n'"]]]], ["deltas": [["text": "Approval done."]]]]]], mock: true)
        let title = "Widget approval " + String(UUID().uuidString.prefix(6))
        let created = try await api("/api/session", method: "POST", body: ["title": title, "location": ["directory": try XCTUnwrap(env["OPENCODE_UI_DIRECTORY"])],
            "model": ["providerID": "mock", "id": "mock-1"], "permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
        let pending = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        _ = try await api("/api/session/\(pending)/prompt", method: "POST", body: ["text": "Ask for approval."])
        var waiting = 0
        for _ in 0..<100 where waiting == 0 {
            let permissions = try await api("/api/session/\(pending)/permission")
            waiting = (permissions["data"] as? [Any])?.count ?? 0
            if waiting == 0 { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertEqual(waiting, 1, "The session waits for approval")
        XCTAssertTrue(homeSessionRow(pending).waitForExistence(timeout: 10), "The waiting session reached Home")
        try await Task.sleep(for: .seconds(2))
        addTeardownBlock { @MainActor [self] in removeWidgets() }
        // Home Screen editing, then the widget gallery, searched for the app.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(1))
        editHomeScreen()
        XCTAssertTrue(tapLabel("Edit", in: [springboard]), "Home Screen editing")
        XCTAssertTrue(tapLabel("Add Widget", in: [springboard]), "The widget gallery")
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The gallery's search field")
        search.tap(); search.typeText("Opencode")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(tapLabel("Opencode", in: [springboard]), "The app in the gallery")
        try await Task.sleep(for: .seconds(2))
        // The gallery's first page is Needs you, small; its button reads "Add Widget" after a symbol.
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "The gallery adds Needs you")
        add.tap()
        try await Task.sleep(for: .seconds(2))
        tapLabel("Done", in: [springboard], timeout: 5)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(appWidget.waitForExistence(timeout: 10), "Needs you is on the Home Screen")
        let row = appWidget.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Needs you shows the waiting session")
        screenshot("system-widget")
        finding("widget", "widget: " + appWidget.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        // A small widget opens its top row: the newest waiting request, this session's permission.
        appWidget.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The widget opens the app")
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "Opened on the waiting session")
        // The link can open the session before the paused store resumes; once it has, the composer has loaded.
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(app.staticTexts["Could not load your saved draft."].exists, "The composer loaded")
        let requests = try await api("/api/session/\(pending)/permission")["data"] as? [[String: Any]] ?? []
        if let request = requests.first?["id"] as? String {
            _ = try await api("/api/session/\(pending)/permission/\(request)/reply", method: "POST", body: ["decision": "reject"])
        }
    }
    /// The app's widget on the Home Screen; the app's icon has the same identifier.
    @MainActor private var appWidget: XCUIElement {
        springboard.icons.matching(NSPredicate(format: "identifier == %@ AND value == %@", "Opencode", "Widget")).firstMatch
    }
    /// A long press on the Home Screen's empty lower half starts editing.
    @MainActor private func editHomeScreen() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 2)
    }
    /// Removes the app's widgets with their delete buttons while editing the Home Screen. (A long press on a widget
    /// opens a menu after which SpringBoard never reports idle, which costs XCUITest a minute per step.)
    @MainActor private func removeWidgets() {
        XCUIDevice.shared.press(.home)
        for _ in 1...3 {
            guard appWidget.waitForExistence(timeout: 3) else { break }
            if !appWidget.buttons["DeleteButton"].exists { editHomeScreen() }
            let delete = appWidget.buttons["DeleteButton"]
            guard delete.waitForExistence(timeout: 5) else { break }
            delete.tap()
            tapLabel("Remove", in: [springboard], timeout: 5)
        }
        XCUIDevice.shared.press(.home)
    }
}
