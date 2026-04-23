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
    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareExtensionRootView(
            onSend: { [weak self] pending in
                self?.handleSend(pending)
            },
            onCancel: { [weak self] in
                self?.complete(cancelled: true)
            },
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
    /// URL. Updates `pending` on the root view via a notification
    /// so SwiftUI can re-render with the captured payload.
    private func extractInputs() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else { return }

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

        let pending = PendingImport(
            url: foundURL,
            text: foundText,
            capturedAt: .now,
        )
        NotificationCenter.default.post(
            name: .stirShareExtensionDidExtract,
            object: pending,
        )
    }

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

extension Notification.Name {
    static let stirShareExtensionDidExtract = Notification.Name(
        "stir.shareExtension.didExtract",
    )
}
