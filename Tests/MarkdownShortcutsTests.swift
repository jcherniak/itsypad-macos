import XCTest
@testable import ItsypadCore

final class MarkdownShortcutsTests: XCTestCase {
    private func apply(_ edit: MarkdownShortcuts.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: - Wrap

    func testWrapBoldAroundSelectionKeepsInnerSelected() {
        let text = "hello world"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 6, length: 5), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "hello **world**")
        XCTAssertEqual(edit.selection, NSRange(location: 8, length: 5))
    }

    func testUnwrapWhenSelectionIncludesMarkers() {
        let text = "hello **world**"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 6, length: 9), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "hello world")
        XCTAssertEqual(edit.selection, NSRange(location: 6, length: 5))
    }

    func testUnwrapWhenMarkersSitJustOutsideSelection() {
        let text = "hello **world**"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 8, length: 5), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "hello world")
        XCTAssertEqual(edit.selection, NSRange(location: 6, length: 5))
    }

    func testEmptySelectionInsertsPairAndPlacesCaretBetween() {
        let text = "hello "
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 6, length: 0), marker: "_")

        XCTAssertEqual(apply(edit, to: text), "hello __")
        XCTAssertEqual(edit.selection, NSRange(location: 7, length: 0))
    }

    func testEmptySelectionBetweenEmptyPairRemovesPair() {
        let text = "hello ****"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 8, length: 0), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "hello ")
        XCTAssertEqual(edit.selection, NSRange(location: 6, length: 0))
    }

    func testStrikethroughAndInlineCodeMarkers() {
        let text = "a b"
        let strike = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 2, length: 1), marker: "~~")
        XCTAssertEqual(apply(strike, to: text), "a ~~b~~")

        let code = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 0, length: 1), marker: "`")
        XCTAssertEqual(apply(code, to: text), "`a` b")
        XCTAssertEqual(code.selection, NSRange(location: 1, length: 1))
    }

    func testWrapWithEmojiUsesUTF16Offsets() {
        let text = "🥛 milk 🥛"              // 🥛 = 2 UTF-16 units; "milk" at 3..<7
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 3, length: 4), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "🥛 **milk** 🥛")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 4))
    }

    func testWrapSelectionContainingEmoji() {
        let text = "say 🥛 now"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 4, length: 2), marker: "_")

        XCTAssertEqual(apply(edit, to: text), "say _🥛_ now")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 2))
    }

    func testWrapClampsOutOfRangeSelection() {
        let text = "abc"
        let edit = MarkdownShortcuts.wrap(text: text, selection: NSRange(location: 10, length: 5), marker: "**")

        XCTAssertEqual(apply(edit, to: text), "abc****")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 0))
    }

    // MARK: - Heading

    func testHeadingCycle() {
        var text = "title"
        var selection = NSRange(location: 3, length: 0)

        var edit = MarkdownShortcuts.toggleHeading(text: text, selection: selection)
        text = apply(edit, to: text); selection = edit.selection
        XCTAssertEqual(text, "# title")
        XCTAssertEqual(selection, NSRange(location: 5, length: 0))

        edit = MarkdownShortcuts.toggleHeading(text: text, selection: selection)
        text = apply(edit, to: text); selection = edit.selection
        XCTAssertEqual(text, "## title")
        XCTAssertEqual(selection, NSRange(location: 6, length: 0))

        edit = MarkdownShortcuts.toggleHeading(text: text, selection: selection)
        text = apply(edit, to: text); selection = edit.selection
        XCTAssertEqual(text, "### title")
        XCTAssertEqual(selection, NSRange(location: 7, length: 0))

        edit = MarkdownShortcuts.toggleHeading(text: text, selection: selection)
        text = apply(edit, to: text); selection = edit.selection
        XCTAssertEqual(text, "title")
        XCTAssertEqual(selection, NSRange(location: 3, length: 0))
    }

    func testHeadingOnlyAffectsCaretLine() {
        let text = "first\nsecond\nthird"
        let edit = MarkdownShortcuts.toggleHeading(text: text, selection: NSRange(location: 8, length: 0))

        XCTAssertEqual(apply(edit, to: text), "first\n# second\nthird")
        XCTAssertEqual(edit.selection, NSRange(location: 10, length: 0))
    }

    func testHeadingRemovalClampsCaretInsidePrefix() {
        let text = "### title"
        let edit = MarkdownShortcuts.toggleHeading(text: text, selection: NSRange(location: 1, length: 0))

        XCTAssertEqual(apply(edit, to: text), "title")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 0))
    }

    func testHeadingOnEmptyText() {
        let edit = MarkdownShortcuts.toggleHeading(text: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(apply(edit, to: ""), "# ")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    func testHeadingWithEmojiLine() {
        let text = "🥛\n🥛 milk"
        let edit = MarkdownShortcuts.toggleHeading(text: text, selection: NSRange(location: 7, length: 0))

        XCTAssertEqual(apply(edit, to: text), "🥛\n# 🥛 milk")
        XCTAssertEqual(edit.selection, NSRange(location: 9, length: 0))
    }

    // MARK: - Link

    func testInsertLinkWrapsSelectionAndSelectsURL() {
        let text = "see docs here"
        let edit = MarkdownShortcuts.insertLink(text: text, selection: NSRange(location: 4, length: 4))

        let result = apply(edit, to: text)
        XCTAssertEqual(result, "see [docs](url) here")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "url")
    }

    func testInsertLinkEmptySelectionSelectsText() {
        let text = ""
        let edit = MarkdownShortcuts.insertLink(text: text, selection: NSRange(location: 0, length: 0))

        let result = apply(edit, to: text)
        XCTAssertEqual(result, "[text](url)")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "text")
    }

    func testInsertLinkWithEmojiSelection() {
        let text = "a 🥛 b"
        let edit = MarkdownShortcuts.insertLink(text: text, selection: NSRange(location: 2, length: 2))

        let result = apply(edit, to: text)
        XCTAssertEqual(result, "a [🥛](url) b")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "url")
    }
}
