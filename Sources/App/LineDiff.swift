import Foundation

enum LineDiff {
    struct Line: Equatable {
        enum Kind { case same, added, removed }
        let kind: Kind
        let text: String
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
