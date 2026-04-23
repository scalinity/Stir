// ShareViewController
//
// StirShareExtension's principal class. Accepts URL / text shares
// from Safari / Notes / any app that publishes a share sheet,
// captures the payload into App Group SharedStorage, and returns
// control to the host app.
//
// Architectural choice: the extension does NOT call /v1/ai/recipe-import
// directly. Reasons:
//   1. Keeps the extension bundle tiny (~300 lines) — no Supabase
//      client, no auth plumbing, no URLSession ceremony. Matters
//      because Apple's extension memory budget is strict.
//   2. The main Stir app already has a warm AIDispatch + auth state.
//      Forwarding via SharedStorage.writePendingImport lets the main
//      app process with its existing session JWT, existing retry
//      policy, existing audit-row persistence.
//   3. Failure UX is cleaner: the user returns to Stir and sees the
//      import progress inline in ImportRoot. A mid-extension network
//      failure here would leave the user staring at a spinner in a
//      cramped share sheet.
//
// Hand-off:
//   ShareVC captures url/text → SharedStorage.writePendingImport(...)
//   → extensionContext.completeRequest(returningItems: nil)
//   → iOS returns user to the host app
//   → next time user opens Stir → RootView.onChange(.active) polls
//     SharedStorage.consumePendingImport() → presents ImportRoot
//     prefilled with the payload.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    /// Shared state owned by the VC, observed by ShareExtensionRootView
    /// via @Bindable. Replaces the NotificationCenter-based
    /// extraction→UI handoff whose subscription timing raced with the
    /// extraction post (CR1-22/DB1-22).
    private let extractionState = ShareExtractionState()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareExtensionRootView(
            onSend: { [weak self] pending in
                self?.handleSend(pending)
            },
            onCancel: { [weak self] in
                self?.complete(cancelled: true)
            },
            state: extractionState,
        ))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { [weak self] in
            await self?.extractInputs()
        }
    }

    // MARK: - Input extraction

    /// Parse NSExtensionItem attachments looking for a URL or plain
    /// text. iOS delivers both in the Safari share case — we prefer
    /// URL. Updates the shared `extractionState` on the main actor so
    /// SwiftUI re-renders with the captured payload — no publisher
    /// timing dance required.
    @MainActor
    private func extractInputs() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            extractionState.isWaitingForExtraction = false
            return
        }

        var foundURL: String?
        var foundText: String?

        for provider in providers {
            if foundURL == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.url.identifier,
                    options: nil,
                ) as? URL {
                    foundURL = url.absoluteString
                }
            }
            if foundText == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(
                    forTypeIdentifier: UTType.plainText.identifier,
                    options: nil,
                ) as? String {
                    foundText = text
                }
            }
        }

        // Length caps — defense against a malicious host app handing us
        // a 50MB payload (CWE-770). Extension memory budget is ~120MB
        // so even one multi-MB String can OOM us. 2KB is generous for a
        // URL (Safari's hard cap is ~80KB); 200KB is generous for a
        // pasted recipe (99th-percentile recipe text is <40KB).
        if let u = foundURL, u.count > Self.maxURLChars {
            foundURL = String(u.prefix(Self.maxURLChars))
        }
        if let t = foundText, t.count > Self.maxTextChars {
            foundText = String(t.prefix(Self.maxTextChars))
        }

        // Bind the payload to the current user so the main app's
        // consume path can drop cross-user-bleed cases (CWE-345). The
        // extension reads SharedStorage — no Supabase access needed —
        // which is populated by the main app at bootstrap + webhook
        // refresh. Nil when no identity has ever been cached (fresh
        // install pre-first-bootstrap); main app treats nil as "same
        // user" to stay back-compat.
        let userKey = SharedStorage().readCanonicalUserKey()

        let pending = PendingImport(
            url: foundURL,
            text: foundText,
            capturedAt: .now,
            consumingUserKey: userKey,
        )
        extractionState.pending = pending
        extractionState.isWaitingForExtraction = false
    }

    /// Upper bounds for share-sheet payload size (SA1-7).
    private static let maxURLChars = 2048
    private static let maxTextChars = 200_000

    // MARK: - Send / cancel

    private func handleSend(_ pending: PendingImport) {
        SharedStorage().writePendingImport(pending)
        complete(cancelled: false)
    }

    private func complete(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(
                withError: NSError(domain: "com.scalinity.stir.share", code: -1),
            )
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
