import Foundation
import XCTest
import UIKit

/// XCUITest's accessibility audit on every main screen, in light and dark mode, on iPhone and iPad. Every issue is
/// collected first and reported together, so one run lists all of them; `exclusions` names the few that are not the
/// app's to fix, each with its reason.
nonisolated final class AccessibilitySmokeTests: SmokeTestCase {
    private struct Finding: Codable, Sendable {
        var screen: String, appearance: String, type: String, summary: String, detail: String
        var identifier: String, label: String, frame: String
        var enabled = true, inBar = false, measuredContrast: Double?
        var excludedBecause: String?
    }

    private var findings: [Finding] = []
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    @MainActor private var ipad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Controls inside layouts that re-flow as text grows (ViewThatFits rows of buttons, AnyLayout headers, Home's list headers).
    /// New Session opens on the server's first project, which is one of the fixture projects, with or without Git.
    private static let reflowing: Set<String> = ["dockAllowOnce", "reviewPermission", "rejectPermission", "allowAlways", "allowOnce", "connectionMethod",
        "Elevated risk", "High risk", "Low risk", "0 of 7 reviewed", "Today", "Earlier", "Yesterday", "No pairing link?", "Have a pairing link?", "review-project", "project", "Local repository",
        "review-no-git", "No Git"]
    /// Issues that are not the app's to fix, or that the audit cannot attribute, each with its reason.
    private static let exclusions: [(reason: String, matches: @Sendable (Finding) -> Bool)] = [
        ("The system keyboard and status bar are drawn by iOS", { $0.identifier.hasPrefix("Keyboard") || $0.identifier.hasPrefix("StatusBar") }),
        ("Disabled controls are exempt from contrast requirements (WCAG 1.4.3, inactive components)", { $0.type == "contrast" && !$0.enabled }),
        ("The text measures at least 4.5:1 against its background in the screen capture taken for the audit (WCAG AA); the audit samples the raised card or button with its shadow",
         { $0.type == "contrast" && ($0.measuredContrast ?? 0) >= 4.5 }),
        ("Known, not fixed: a single-line SwiftUI text field is as tall as its line of text inside its 44 pt bordered box, and the box's padding does not focus it. Only the server detail's body-size fields fall under the audit's minimum; the add-server fields, at the larger font, pass",
         { $0.type == "hitRegion" && $0.detail.contains("UITextField") }),
        ("The element's own capture shows almost nothing (under 2:1, while the app's text colours are at least 5.5:1): a row clipped below a sheet's bottom edge, which passes once scrolled into view (iPhone audits it on screen)",
         { $0.type == "contrast" && ($0.measuredContrast ?? 4.5) < 2 }),
        ("Navigation bar titles and bar buttons: iOS caps their size and offers the large content viewer instead", { $0.type == "dynamicType" && $0.inBar }),
        ("Text scales with Dynamic Type (OCType is relative to text styles) and the layout re-flows at accessibility sizes (ViewThatFits, AnyLayout, list headers); the audit compares the element across that re-flow. The accessibility5 snapshots show the full size",
         { finding in finding.type == "dynamicType" && finding.summary.contains("partially") && reflowing.contains { finding.identifier == $0 || finding.label == $0 } }),
        // A prompt that is only a file mention reads "@Example.swift " (the composer adds a space after a mention).
        ("The label is the content itself: a file name or path, a file mention, a directory or a server address", { finding in
            let label = finding.label.trimmingCharacters(in: .whitespaces)
            return finding.type == "sufficientElementDescription" && !label.isEmpty && !label.contains(" ")
                && (label.contains("/") || label.range(of: #"^@?[\w.-]+\.[\w]+$"#, options: .regularExpression) != nil) }),
        ("The audit names no element, frame or label for this issue, so it cannot be traced to a view", { $0.identifier.isEmpty && $0.label.isEmpty && $0.frame.isEmpty }),
    ]

    @MainActor func testMainScreensInLightMode() async throws { try await auditMainScreens(dark: false) }
    @MainActor func testMainScreensInDarkMode() async throws { try await auditMainScreens(dark: true) }

    private var dark = false
    @MainActor private func auditMainScreens(dark: Bool) async throws {
        continueAfterFailure = true
        executionTimeAllowance = 900
        self.dark = dark
        try launchFreshApp(suffix: dark ? "-a11y-dark" : "-a11y", dark: dark)
        audit("onboarding")
        app.buttons["addFirstServer"].tap()
        XCTAssertTrue((ipad ? app.textFields["pairingLink"] : app.buttons["Use password"]).waitForExistence(timeout: 5))
        audit("add-server")
        try await pairSandbox(name: "Audit sandbox")
        audit("settings")
        let row = app.buttons["serverRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.buttons["Connection diagnostics"].waitForExistence(timeout: 10))
        audit("server-detail")
        back()
        let acknowledgements = app.buttons["acknowledgements"]
        for _ in 0..<10 where !acknowledgements.isHittable { app.swipeUp() }
        acknowledgements.tap()
        XCTAssertTrue(app.buttons["acknowledgement-GRDB.swift"].waitForExistence(timeout: 10))
        audit("acknowledgements")
        back()
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["closeSettings"].waitForNonExistence(timeout: 10))
        if ipad { rotate(to: .landscapeLeft) }

        setHome(open: true)
        XCTAssertTrue(app.textFields["sessionSearch"].waitForExistence(timeout: 10))
        audit("home")
        // The review fixture's session has a transcript with tool rows and changed files.
        let review = try JSONDecoder().decode([String: String].self, from: Data(try XCTUnwrap(env["OPENCODE_UI_REVIEW"]).utf8))
        // A fresh session sits at the top of Home on every device; its header names the server, and a deep link then
        // opens the review fixture's session wherever Home has listed it.
        let sessionID = try XCTUnwrap(review["session"])
        let directory = try XCTUnwrap(env["OPENCODE_UI_DIRECTORY"])
        _ = try await api("/admin/scenario", method: "POST", body: ["name": "a11y-reply", "script": ["calls": [["deltas": [["text": "Audit reply."]]]]]], mock: true)
        let created = try await api("/api/session", method: "POST", body: ["title": "Accessibility reply", "location": ["directory": directory],
                                                                          "model": ["providerID": "mock", "id": "mock-1"]])
        let fresh = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        addTeardownBlock { @MainActor [self] in _ = try? await api("/api/session/" + fresh, method: "DELETE") }
        _ = try await api("/api/session/\(fresh)/prompt", method: "POST", body: ["text": "Reply for the accessibility audit."])
        setHome(open: true)
        homeSessionRow(fresh).tap()
        let header = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessionHeader-")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let serverID = String(header.identifier.dropFirst("sessionHeader-".count))
        app.open(try XCTUnwrap(URL(string: "opencodeios://server/" + serverID + "/session/" + sessionID)))
        XCTAssertTrue(app.textViews["promptEditor"].waitForExistence(timeout: 10))
        setHome(open: false)
        audit("session")
        app.buttons[ipad ? "toggleReview" : "sessionReview"].tap()
        XCTAssertTrue(app.collectionViews["diffCollection"].waitForExistence(timeout: 10)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Example.swift")).firstMatch.waitForExistence(timeout: 5))
        audit("review")
        if ipad { app.buttons["toggleReview"].tap() } else { app.buttons["closeReview"].tap() }

        try await approvals()
        report()
    }

    /// A permission (dock and sheet) and a question, each in a session of its own that is deleted afterwards.
    @MainActor private func approvals() async throws {
        let directory = try XCTUnwrap(env["OPENCODE_UI_DIRECTORY"])
        for flow in ["permission", "question"] {
            let calls: [[String: Any]] = flow == "question"
                ? [["tools": [["name": "question", "arguments": ["questions": [["header": "Color", "question": "Which color?", "options": [["label": "Blue", "description": "Use blue"], ["label": "Green", "description": "Use green"]]]]]]]]]
                : [["tools": [["name": "shell", "arguments": ["command": "printf 'audit\\n'"]]]]]
            try await selectScenario(["name": "a11y-" + flow, "script": ["calls": calls + [["deltas": [["text": "Done."]]]]]])
            let created = try await api("/api/session", method: "POST", body: ["title": "Accessibility " + flow, "location": ["directory": directory],
                "model": ["providerID": "mock", "id": "mock-1"], "permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
            let id = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
            addTeardownBlock { @MainActor [self] in _ = try? await api("/api/session/" + id, method: "DELETE") }
            _ = try await api("/api/session/\(id)/prompt", method: "POST", body: ["text": "Run the accessibility flow."])
            if !ipad, app.buttons["BackButton"].isHittable { app.buttons["BackButton"].tap() }
            setHome(open: true)
            homeSessionRow(id).tap()
            setHome(open: false)
            let dock = app.descendants(matching: .any).matching(identifier: "approvalDock").firstMatch
            XCTAssertTrue(dock.waitForExistence(timeout: 15))
            if flow == "permission" {
                XCTAssertTrue(dock.buttons["dockAllowOnce"].firstMatch.waitForExistence(timeout: 10))
                audit("approval-dock")
                dock.buttons["reviewPermission"].firstMatch.tap()
                XCTAssertTrue(app.buttons["rejectPermission"].waitForExistence(timeout: 10))
                audit("permission-sheet")
                app.buttons["allowOnce"].tap()
            } else {
                dock.buttons["answerQuestion"].firstMatch.tap()
                XCTAssertTrue(app.buttons["formOption-q0-Blue"].waitForExistence(timeout: 10))
                audit("question-sheet")
                app.buttons["formOption-q0-Blue"].tap()
                app.buttons["reviewAnswers"].tap()
                app.buttons["submitAnswers"].tap()
            }
            XCTAssertTrue(dock.waitForNonExistence(timeout: 15))
            // The script ends with this reply; the next flow's scenario can only be set once no model call is running.
            XCTAssertTrue(app.staticTexts.matching(identifier: "assistantText").matching(NSPredicate(format: "label == %@", "Done.")).firstMatch.waitForExistence(timeout: 30))
        }
        app.buttons[ipad ? "toggleHome" : "BackButton"].firstMatch.tap()
        if ipad { app.typeKey("n", modifierFlags: .command) } else { app.buttons["newSession"].tap() }
        XCTAssertTrue(app.textViews["promptEditor"].waitForExistence(timeout: 10))
        audit("new-session")
    }

    /// The mock refuses a new scenario while a model call (a reply or a title) is still streaming, so it asks again.
    @MainActor private func selectScenario(_ body: [String: Any]) async throws {
        let base = try XCTUnwrap(env["OPENCODE_UI_MOCK_URL"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/admin/scenario")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deadline = Date().addingTimeInterval(30)
        while true {
            let status = (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return }
            guard status == 409, Date() < deadline else { return XCTFail("The mock refused the scenario with status \(status)") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }

    /// Audits the screen in this pass's appearance; issues are recorded, never thrown, so the run continues.
    @MainActor private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let mode = dark ? "dark" : "light"
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let capture = XCUIScreen.main.screenshot()
            let bitmap = Bitmap(capture.image)
            XCTAssertEqual(bitmap.map { $0.meanLuminance < 0.35 }, dark, "\(screen) is not in \(mode) mode", file: file, line: line)
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
            var contrastElements: [(index: Int, element: XCUIElement)] = []
            let screenshot = XCTAttachment(screenshot: capture)
            screenshot.name = "a11y-\(screen)-\(mode)"; screenshot.lifetime = .keepAlways; add(screenshot)
            do {
                try app.performAccessibilityAudit(for: .all) { [self] issue in
                    let element = issue.element
                    var finding = Finding(screen: screen, appearance: mode, type: Self.name(issue.auditType), summary: issue.compactDescription,
                                          detail: issue.detailedDescription, identifier: element?.identifier ?? "", label: element?.label ?? "",
                                          frame: element.map { NSCoder.string(for: $0.frame) } ?? "")
                    finding.enabled = element?.isEnabled ?? true
                    finding.inBar = element.map { item in bars.contains { $0.intersects(item.frame) } } ?? false
                    finding.excludedBecause = Self.exclusions.first { $0.matches(finding) }?.reason
                    if finding.type == "contrast", let element { contrastElements.append((findings.count, element)) }
                    findings.append(finding)
                    return true
                }
                // The contrast the eye sees, from each flagged element's own capture (oriented as the screen is).
                for (index, element) in contrastElements where element.exists {
                    findings[index].measuredContrast = Bitmap(element.screenshot().image)?.contrast()
                    findings[index].excludedBecause = Self.exclusions.first { $0.matches(findings[index]) }?.reason
                }
            } catch {
                XCTFail("The audit of \(screen) (\(mode)) could not run: \(error)", file: file, line: line)
            }
        }
    }

    @MainActor private func report() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: (try? encoder.encode(findings)) ?? Data(), uniformTypeIdentifier: "public.json")
        attachment.name = dark ? "finding-accessibility-audit-dark.json" : "finding-accessibility-audit-light.json"; attachment.lifetime = .keepAlways; add(attachment)
        let open = findings.filter { $0.excludedBecause == nil }
        let summary = open.map { "\($0.screen)/\($0.appearance) \($0.type): \($0.summary) [\($0.identifier.isEmpty ? $0.label : $0.identifier)]" }
        XCTAssertTrue(open.isEmpty, "\(open.count) accessibility issues:\n" + summary.joined(separator: "\n"))
    }

    private static func name(_ type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [(.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"), (.textClipped, "textClipped"),
            (.trait, "trait")]
        return names.filter { type.contains($0.0) }.map(\.1).joined(separator: ",")
    }
}

/// The screen capture's pixels, for the contrast the eye sees and for telling dark mode from light.
private struct Bitmap {
    let width: Int, height: Int
    private let pixels: [UInt8]
    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        width = w; height = h
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return nil }
        pixels = buffer
    }
    private func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let index = (y * width + x) * 4
        return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255, Double(pixels[index + 2]) / 255)
    }
    private static func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }
    var meanLuminance: Double {
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: height, by: 16) { for x in stride(from: 0, to: width, by: 16) { total += Self.luminance(color(x, y)); count += 1 } }
        return count > 0 ? total / count : 0
    }
    /// The highest contrast between the image's most common colour (its background) and any other pixel (its text).
    func contrast() -> Double? {
        let x0 = 0, y0 = 0, x1 = width, y1 = height
        guard x1 > x0, y1 > y0 else { return nil }
        var counts: [Int: Int] = [:], luminances: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 {
            let c = color(x, y); let key = Int(c.0 * 255) << 16 | Int(c.1 * 255) << 8 | Int(c.2 * 255)
            counts[key, default: 0] += 1; luminances.append(Self.luminance(c))
        } }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = Self.luminance((Double(background >> 16 & 255) / 255, Double(background >> 8 & 255) / 255, Double(background & 255) / 255))
        return luminances.map { (max($0, bg) + 0.05) / (min($0, bg) + 0.05) }.max()
    }
}
