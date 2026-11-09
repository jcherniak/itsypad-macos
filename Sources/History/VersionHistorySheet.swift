import Cocoa
import SwiftUI

/// Presents the version history of one tab as a sheet on the editor window.
@MainActor
enum VersionHistorySheet {
    private static let defaultSize = NSSize(width: 860, height: 560)

    static func present(tabID: UUID, over parent: NSWindow) {
        guard parent.attachedSheet == nil else { return }

        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.title = String(localized: "history.title", defaultValue: "Version history")
        sheet.isReleasedWhenClosed = false

        let view = VersionHistoryView(tabID: tabID) { [weak parent, weak sheet] in
            guard let sheet else { return }
            parent?.endSheet(sheet)
        }
        let hostingController = NSHostingController(rootView: view)
        hostingController.sizingOptions = [.minSize]
        sheet.contentViewController = hostingController
        sheet.setContentSize(defaultSize)

        parent.beginSheet(sheet)
    }
}
