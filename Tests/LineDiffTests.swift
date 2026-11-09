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

    // MARK: - merge3

    func testMerge3AppliesEditsInDifferentRegions() {
        let base = "one\ntwo\nthree\nfour\nfive"
        let ours = "ONE\ntwo\nthree\nfour\nfive"
        let theirs = "one\ntwo\nthree\nfour\nFIVE"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .clean("ONE\ntwo\nthree\nfour\nFIVE"))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: theirs, theirs: ours), .clean("ONE\ntwo\nthree\nfour\nFIVE"))
    }

    func testMerge3InsertionAndDeletionInDifferentRegions() {
        let base = "a\nb\nc\nd\ne"
        let ours = "a\nb\nc\nd\ne\nf"
        let theirs = "b\nc\nd\ne"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: ours, theirs: theirs), .clean("b\nc\nd\ne\nf"))
    }

    func testMerge3ConflictsOnSameLines() {
        let base = "a\nb\nc"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "a\nB\nc", theirs: "a\nX\nc"), .conflicted)
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "a\nc", theirs: "a\nX\nc"), .conflicted)
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "a\nb\nnew\nc", theirs: "a\nb\nother\nc"), .conflicted)
    }

    func testMerge3IdenticalSidesAreClean() {
        let base = "a\nb\nc"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "x\ny", theirs: "x\ny"), .clean("x\ny"))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: base, theirs: base), .clean(base))
    }

    func testMerge3OneSideUnchangedTakesTheOther() {
        let base = "a\nb\nc"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: base, theirs: "a\nB\nc"), .clean("a\nB\nc"))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "a\nB\nc", theirs: base), .clean("a\nB\nc"))
        XCTAssertEqual(LineDiff.merge3(base: base, ours: base, theirs: ""), .clean(""))
    }

    func testMerge3SameChangeOnBothSidesAppliesOnce() {
        let base = "a\nb\nc\nd"
        XCTAssertEqual(LineDiff.merge3(base: base, ours: "a\nB\nc\nd", theirs: "a\nB\nc\nD"), .clean("a\nB\nc\nD"))
    }

    func testMerge3KeepsTrailingNewline() {
        XCTAssertEqual(LineDiff.merge3(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n"), .clean("A\nb\nC\n"))
        XCTAssertEqual(LineDiff.merge3(base: "a\nb\nc", ours: "A\nb\nc", theirs: "a\nb\nC"), .clean("A\nb\nC"))
    }

    func testMerge3AdjacentEditsConflict() {
        XCTAssertEqual(LineDiff.merge3(base: "a\nb\n", ours: "A\nb\n", theirs: "a\nB\n"), .conflicted)
    }
}
