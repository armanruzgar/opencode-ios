#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import Testing
import SnapshotTesting
import OCFoundation
import OCModels
import OCNetworking
import OCDesign
import OCPersistence
import OCSecurity
@testable import OCSync
import FeatureTranscript

@MainActor @Suite(.serialized) struct SessionScreenSnapshots {
    @Test func sessionKeepsTranscriptVisibleAtLargeTextAndShortHeights() async throws {
        let server = ServerStore(record: .init(name: "Studio", endpoints: []),
            connection: ServerConnection(endpoints: [], credential: nil),
            credentials: CredentialStore(secrets: InMemorySecretStore()), cache: CacheStore(writer: try PersistenceWriter()))
        server.readPath.client = nil
        let info = SessionInfo(raw: .object(["id": .string("s"), "title": .string("Review the changes"),
            "agent": .string("build"), "model": .object(["id": .string("mock-1"), "providerID": .string("mock")]),
            "location": .object(["directory": .string("/workspace")])]))
        let messages: [SessionMessage] = (0..<20).map {
            .init(raw: .object(["id": .string("m\($0)"), "type": .string("user"), "text": .string("Review change \($0)")]))
        }
        server.readPath.seed(info: info, messages: messages)
        let composer = server.readPath.composer(sessionID: "s", directory: "/workspace"); await composer.load()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for accessibility in [false, true] { for height: CGFloat in [852, 500] {
            let content = NavigationStack { SessionScreen(server: server, sessionID: "s", openChild: { _ in }) }
                .environment(\.dynamicTypeSize, accessibility ? .accessibility5 : .large).environment(\.colorScheme, .light).ocTheme()
            let controller = UIHostingController(rootView: content)
            controller.overrideUserInterfaceStyle = .light
            controller.traitOverrides.horizontalSizeClass = .compact
            controller.traitOverrides.preferredContentSizeCategory = accessibility ? .accessibilityExtraExtraExtraLarge : .large
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: height)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            // Rows are built off the main actor; wait until the first render has them.
            var found: UIView?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutIfNeeded()
                found = find("transcriptScroll", in: controller.view)
                // Wait for the list to settle at the latest message, as a user would see it.
                if let list = found as? UICollectionView, list.visibleCells.count > 1,
                   abs(list.contentOffset.y - (list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)) < 1 { break }
            }
            try await Task.sleep(for: .milliseconds(200))
            let transcript = try #require(found)
            let editor = try #require(find("promptEditor", in: controller.view))
            #expect(transcript.bounds.height >= OCLayout.timelineMinimumHeight)
            #expect(editor.bounds.height >= OCComposerMetrics.editorMinimum)
            let label = "session-393-\(Int(height))-" + (accessibility ? "accessibility5" : "default")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            // Large text drawn over a scrolled transcript can come out one step in 255 different in about a hundred
            // pixels from run to run, which no one can see: the perceptual comparison lets that pass, while a moved
            // or changed row still fails.
            assertSnapshot(of: image, as: .image(perceptualPrecision: 0.98), named: label,
                           record: ProcessInfo.processInfo.environment["OC_RECORD_SNAPSHOTS"] == "1")
        } }
        await server.readPath.stop()
    }
    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
}
#endif
