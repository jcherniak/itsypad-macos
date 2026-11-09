import Foundation

enum LineDiff {
    struct Line: Equatable {
        enum Kind { case same, added, removed }
        let kind: Kind
        let text: String
    }

    enum Merge3Result: Equatable {
        case clean(String)
        case conflicted
    }

    /// Beyond this many lines on either side the quadratic LCS is skipped and
    /// the result degrades to "everything removed, everything added".
    static let maxLines = 5000

    static func diff(old: String, new: String) -> [Line] {
        let a = lines(old)
        let b = lines(new)

        if a.count > maxLines || b.count > maxLines {
            return a.map { Line(kind: .removed, text: $0) } + b.map { Line(kind: .added, text: $0) }
        }

        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix
            && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var result: [Line] = a[..<prefix].map { Line(kind: .same, text: $0) }
        result += lcsDiff(midA, midB)
        result += a[(a.count - suffix)...].map { Line(kind: .same, text: $0) }
        return result
    }

    /// Line-level three-way merge. Each side's hunks against `base` are
    /// applied when they touch different base lines. Hunks that overlap or
    /// abut are taken once when both sides made the same change and make
    /// the whole merge `.conflicted` otherwise.
    static func merge3(base: String, ours: String, theirs: String) -> Merge3Result {
        if ours == theirs { return .clean(ours) }
        if ours == base { return .clean(theirs) }
        if theirs == base { return .clean(ours) }

        let baseLines = lines(base)
        if baseLines.count > maxLines || lines(ours).count > maxLines || lines(theirs).count > maxLines {
            return .conflicted
        }

        let oursHunks = hunks(base: base, side: ours)
        let theirsHunks = hunks(base: base, side: theirs)

        var merged: [Hunk] = []
        var i = 0
        var j = 0
        while i < oursHunks.count && j < theirsHunks.count {
            let a = oursHunks[i]
            let b = theirsHunks[j]
            if a.touches(b) {
                guard a == b else { return .conflicted }
                merged.append(a)
                i += 1
                j += 1
            } else if a.range.lowerBound < b.range.lowerBound {
                merged.append(a)
                i += 1
            } else {
                merged.append(b)
                j += 1
            }
        }
        merged += oursHunks[i...]
        merged += theirsHunks[j...]

        var out: [String] = []
        var cursor = 0
        for hunk in merged {
            out += baseLines[cursor..<hunk.range.lowerBound]
            out += hunk.replacement
            cursor = hunk.range.upperBound
        }
        out += baseLines[cursor...]

        var text = out.joined(separator: "\n")
        let oursChangedTrailing = ours.hasSuffix("\n") != base.hasSuffix("\n")
        let trailing = oursChangedTrailing ? ours.hasSuffix("\n") : theirs.hasSuffix("\n")
        if trailing && !out.isEmpty {
            text += "\n"
        }
        return .clean(text)
    }

    /// A trailing newline terminates the last line rather than starting an
    /// empty one, so "a\n" and "a" both yield ["a"].
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    /// A run of changed lines: `range` is the replaced span of base lines
    /// (empty for a pure insertion) and `replacement` what the side has there.
    private struct Hunk: Equatable {
        var range: Range<Int>
        var replacement: [String]

        func touches(_ other: Hunk) -> Bool {
            range.lowerBound <= other.range.upperBound && other.range.lowerBound <= range.upperBound
        }
    }

    private static func hunks(base: String, side: String) -> [Hunk] {
        var result: [Hunk] = []
        var open: Hunk?
        var index = 0
        for line in diff(old: base, new: side) {
            switch line.kind {
            case .same:
                if let hunk = open {
                    result.append(hunk)
                    open = nil
                }
                index += 1
            case .removed:
                var hunk = open ?? Hunk(range: index..<index, replacement: [])
                hunk.range = hunk.range.lowerBound..<(index + 1)
                open = hunk
                index += 1
            case .added:
                var hunk = open ?? Hunk(range: index..<index, replacement: [])
                hunk.replacement.append(line.text)
                open = hunk
            }
        }
        if let hunk = open {
            result.append(hunk)
        }
        return result
    }

    private static func lcsDiff(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { Line(kind: .added, text: $0) } }
        if m == 0 { return a.map { Line(kind: .removed, text: $0) } }

        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                } else {
                    table[i * width + j] = max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }

        var result: [Line] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(Line(kind: .same, text: a[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                result.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: b[j]))
                j += 1
            }
        }
        while i < n {
            result.append(Line(kind: .removed, text: a[i]))
            i += 1
        }
        while j < m {
            result.append(Line(kind: .added, text: b[j]))
            j += 1
        }
        return result
    }
}
