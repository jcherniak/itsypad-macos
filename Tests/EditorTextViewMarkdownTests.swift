import AppKit
import XCTest
@testable import ItsypadCore

final class EditorTextViewMarkdownTests: XCTestCase {
    func testToggleBoldWrapsSelection() {
        let textView = makeTextView(text: "hello world", selection: NSRange(location: 6, length: 5))

        textView.toggleBold()

        XCTAssertEqual(textView.string, "hello **world**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 5))
    }

    func testToggleItalicTwiceRestoresText() {
        let textView = makeTextView(text: "hello world", selection: NSRange(location: 6, length: 5))

        textView.toggleItalic()
        textView.toggleItalic()

        XCTAssertEqual(textView.string, "hello world")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 5))
    }

    func testToggleHeadingAndInsertLink() {
        let textView = makeTextView(text: "title", selection: NSRange(location: 0, length: 0))

        textView.toggleHeading()
        XCTAssertEqual(textView.string, "# title")

        textView.setSelectedRange(NSRange(location: 2, length: 5))
        textView.insertLink()
        XCTAssertEqual(textView.string, "# [title](url)")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 3))
    }

    func testStrikethroughAndInlineCode() {
        let textView = makeTextView(text: "a b", selection: NSRange(location: 0, length: 1))

        textView.toggleStrikethrough()
        XCTAssertEqual(textView.string, "~~a~~ b")

        textView.setSelectedRange(NSRange(location: 6, length: 1))
        textView.toggleInlineCode()
        XCTAssertEqual(textView.string, "~~a~~ `b`")
    }

    func testFormattingIsDisabledForCodeLanguages() {
        let textView = makeTextView(text: "let x = 1", selection: NSRange(location: 4, length: 1))
        let coordinator = SyntaxHighlightCoordinator()
        coordinator.language = "swift"
        textView.delegate = coordinator

        XCTAssertFalse(textView.markdownFormattingAllowed)
        textView.toggleBold()
        XCTAssertEqual(textView.string, "let x = 1")

        coordinator.language = "markdown"
        XCTAssertTrue(textView.markdownFormattingAllowed)
    }

    private func makeTextView(text: String, selection: NSRange) -> EditorTextView {
        let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = text
        textView.setSelectedRange(selection)
        return textView
    }
}
