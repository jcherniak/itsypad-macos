import AppKit
import XCTest
@testable import ItsypadCore

final class MenuBuilderTests: XCTestCase {
    private let target = NSObject()

    func testIndentationMenuItemsUseCommandBrackets() throws {
        let items = try XCTUnwrap(MenuBuilder(target: target).buildEditMenuItem().submenu?.items)
        let indentItem = try XCTUnwrap(items.first { $0.action == #selector(AppDelegate.indentAction) })
        let outdentItem = try XCTUnwrap(items.first { $0.action == #selector(AppDelegate.outdentAction) })

        XCTAssertEqual(indentItem.keyEquivalent, "]")
        XCTAssertEqual(indentItem.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(outdentItem.keyEquivalent, "[")
        XCTAssertEqual(outdentItem.keyEquivalentModifierMask, [.command])
    }

    func testVersionHistoryFollowsSaveAsWithoutShortcut() throws {
        let items = try XCTUnwrap(MenuBuilder(target: target).buildFileMenuItem(recentFilesMenu: NSMenu()).submenu?.items)
        let saveAsIndex = try XCTUnwrap(items.firstIndex { $0.action == #selector(AppDelegate.saveFileAsAction) })
        let historyItem = items[saveAsIndex + 1]

        XCTAssertEqual(historyItem.action, #selector(AppDelegate.showVersionHistoryAction))
        XCTAssertEqual(historyItem.keyEquivalent, "")
        XCTAssertTrue(historyItem.target === target)
    }

    func testTabNavigationKeepsCommandShiftBrackets() throws {
        let items = try XCTUnwrap(MenuBuilder(target: target).buildViewMenuItem().submenu?.items)
        let nextTabItem = try XCTUnwrap(items.first { $0.action == #selector(AppDelegate.nextTabAction) })
        let previousTabItem = try XCTUnwrap(items.first { $0.action == #selector(AppDelegate.previousTabAction) })

        XCTAssertEqual(nextTabItem.keyEquivalent, "]")
        XCTAssertEqual(nextTabItem.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(previousTabItem.keyEquivalent, "[")
        XCTAssertEqual(previousTabItem.keyEquivalentModifierMask, [.command, .shift])
    }
}
