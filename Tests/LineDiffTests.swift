import XCTest
@testable import ItsypadCore

final class LineDiffTests: XCTestCase {
    private func kinds(_ lines: [LineDiff.Line]) -> [LineDiff.Line.Kind] {
        lines.map(\.kind)
    }

    func testEmptyInputs() {
        XCTAssertEqual(LineDiff.diff(old: "", new: ""), [])
        XCTAssertEqual(LineDiff.diff(old: "", new: "a\nb"), [
            .init(kind: .added, text: "a"), .init(kind: .added, text: "b"),
        ])
        XCTAssertEqual(LineDiff.diff(old: "a\nb", new: ""), [
            .init(kind: .removed, text: "a"), .init(kind: .removed, text: "b"),
        ])
    }

    func testIdenticalTextIsAllSame() {
        let text = "one\ntwo\nthree"
        let result = LineDiff.diff(old: text, new: text)
        XCTAssertEqual(kinds(result), [.same, .same, .same])
        XCTAssertEqual(result.map(\.text), ["one", "two", "three"])
    }

    func testInsertion() {
        let result = LineDiff.diff(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .added, text: "b"),
            .init(kind: .same, text: "c"),
        ])
    }

    func testDeletion() {
        let result = LineDiff.diff(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .removed, text: "b"),
            .init(kind: .same, text: "c"),
        ])
    }

    func testReplacement() {
        let result = LineDiff.diff(old: "a\nb\nc", new: "a\nX\nc")
        XCTAssertEqual(kinds(result), [.same, .removed, .added, .same])
        XCTAssertEqual(result[1].text, "b")
        XCTAssertEqual(result[2].text, "X")
    }

    func testTrailingNewlineDoesNotCreateAnEmptyLine() {
        XCTAssertEqual(LineDiff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines("a\nb"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines("\n"), [""])
        XCTAssertEqual(LineDiff.lines(""), [])

        let result = LineDiff.diff(old: "a\nb\n", new: "a\nb\nc")
        XCTAssertEqual(result, [
            .init(kind: .same, text: "a"),
            .init(kind: .same, text: "b"),
            .init(kind: .added, text: "c"),
        ])
        XCTAssertEqual(kinds(LineDiff.diff(old: "a\nb", new: "a\nb\n")), [.same, .same])
    }

    func testBlankLinesInsideTextArePreserved() {
        let result = LineDiff.diff(old: "a\n\nb", new: "a\n\nb")
        XCTAssertEqual(result.map(\.text), ["a", "", "b"])
    }

    func testOversizedInputFallsBackToRemoveAllAddAll() {
        let big = (0...LineDiff.maxLines).map(String.init).joined(separator: "\n")
        let result = LineDiff.diff(old: big, new: "0\n1")
        XCTAssertEqual(result.filter { $0.kind == .removed }.count, LineDiff.maxLines + 1)
        XCTAssertEqual(result.filter { $0.kind == .added }.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.kind != .same })
    }
}
