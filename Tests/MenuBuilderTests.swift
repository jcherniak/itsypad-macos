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

    func testTrashFollowsVersionHistoryWithoutShortcut() throws {
        let items = try XCTUnwrap(MenuBuilder(target: target).buildFileMenuItem(recentFilesMenu: NSMenu()).submenu?.items)
        let historyIndex = try XCTUnwrap(items.firstIndex { $0.action == #selector(AppDelegate.showVersionHistoryAction) })
        let trashItem = items[historyIndex + 1]

        XCTAssertEqual(trashItem.action, #selector(AppDelegate.showTrashAction))
        XCTAssertEqual(trashItem.keyEquivalent, "")
        XCTAssertTrue(trashItem.target === target)
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

    func testFormatSubmenuShortcutsDoNotCollide() throws {
        let builder = MenuBuilder(target: target)
        let editItems = try XCTUnwrap(builder.buildEditMenuItem().submenu?.items)
        let formatItems = try XCTUnwrap(editItems.first { $0.submenu?.items.contains { $0.action == #selector(AppDelegate.formatBoldAction) } == true }?.submenu?.items)

        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(AppDelegate.formatBoldAction), "b", [.command, .shift]),
            (#selector(AppDelegate.formatItalicAction), "i", [.command]),
            (#selector(AppDelegate.formatStrikethroughAction), "x", [.command, .shift]),
            (#selector(AppDelegate.formatInlineCodeAction), "c", [.command, .shift]),
            (#selector(AppDelegate.formatHeadingAction), "h", [.command, .shift]),
            (#selector(AppDelegate.formatLinkAction), "k", [.command]),
        ]
        XCTAssertEqual(formatItems.count, expected.count)
        for (action, key, modifiers) in expected {
            let item = try XCTUnwrap(formatItems.first { $0.action == action })
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
        }

        func flatten(_ items: [NSMenuItem]) -> [NSMenuItem] {
            items.flatMap { [$0] + flatten($0.submenu?.items ?? []) }
        }
        func shortcut(_ item: NSMenuItem) -> String? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            var mods = item.keyEquivalentModifierMask
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) }
            return "\(mods.rawValue)-\(item.keyEquivalent.lowercased())"
        }
        let allItems = flatten([
            builder.buildAppMenuItem(),
            builder.buildFileMenuItem(recentFilesMenu: NSMenu()),
            builder.buildEditMenuItem(),
            builder.buildViewMenuItem(),
            builder.buildHelpMenuItem(),
        ])
        let formatActions = Set(expected.map(\.0))
        let otherShortcuts = Set(allItems.filter { $0.action.map { !formatActions.contains($0) } ?? true }.compactMap(shortcut))
        for item in formatItems {
            XCTAssertFalse(otherShortcuts.contains(try XCTUnwrap(shortcut(item))), "\(item.title) collides with another menu shortcut")
        }
    }
}
