import Foundation

/// Pure markdown editing helpers. All offsets are UTF-16 (NSString/NSRange),
/// matching UITextView.selectedRange.
enum MarkdownShortcuts {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    static let boldMarker = "**"
    static let italicMarker = "_"
    static let strikethroughMarker = "~~"
    static let inlineCodeMarker = "`"

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6}) ", options: [])

    // MARK: - Inline wrap/unwrap

    static func wrap(text: String, selection: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)
        let m = marker.utf16.count

        if sel.length == 0 {
            // Caret between an empty pair → remove the pair
            let pairRange = NSRange(location: sel.location - m, length: 2 * m)
            if sel.location >= m, sel.location + m <= ns.length,
               ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
               ns.substring(with: NSRange(location: sel.location, length: m)) == marker {
                return Edit(range: pairRange, replacement: "", selection: NSRange(location: pairRange.location, length: 0))
            }
            return Edit(range: sel, replacement: marker + marker, selection: NSRange(location: sel.location + m, length: 0))
        }

        let selected = ns.substring(with: sel)

        // Selection includes the markers → unwrap
        if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return Edit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: inner.utf16.count))
        }

        // Markers sit just outside the selection → unwrap
        if sel.location >= m, sel.location + sel.length + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: sel.location + sel.length, length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return Edit(range: outer, replacement: selected, selection: NSRange(location: outer.location, length: sel.length))
        }

        return Edit(
            range: sel,
            replacement: marker + selected + marker,
            selection: NSRange(location: sel.location + m, length: sel.length)
        )
    }

    // MARK: - Heading cycle

    /// none → `# ` → `## ` → `### ` → none. The caret keeps its offset within
    /// the line's content.
    static func toggleHeading(text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)

        var oldPrefixLength = 0
        var level = 0
        if let match = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            oldPrefixLength = match.range.length
            level = match.range(at: 1).length
        }

        let newPrefix: String
        switch level {
        case 0: newPrefix = "# "
        case 1: newPrefix = "## "
        case 2: newPrefix = "### "
        default: newPrefix = ""
        }
        let newPrefixLength = newPrefix.utf16.count

        let contentLength = lineEndWithoutNewline(lineRange, in: ns) - lineRange.location - oldPrefixLength
        let contentOffset = max(0, sel.location - lineRange.location - oldPrefixLength)
        let location = lineRange.location + newPrefixLength + min(contentOffset, contentLength)
        let newLength = ns.length - oldPrefixLength + newPrefixLength
        let length = min(sel.length, newLength - location)

        return Edit(
            range: NSRange(location: lineRange.location, length: oldPrefixLength),
            replacement: newPrefix,
            selection: NSRange(location: location, length: max(0, length))
        )
    }

    // MARK: - Link

    /// Non-empty selection → `[selection](url)` with `url` selected; empty →
    /// `[text](url)` with `text` selected.
    static func insertLink(text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)

        if sel.length == 0 {
            return Edit(
                range: sel,
                replacement: "[text](url)",
                selection: NSRange(location: sel.location + 1, length: 4)
            )
        }

        let selected = ns.substring(with: sel)
        return Edit(
            range: sel,
            replacement: "[\(selected)](url)",
            selection: NSRange(location: sel.location + 1 + sel.length + 2, length: 3)
        )
    }

    // MARK: - Helpers

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    private static func lineEndWithoutNewline(_ lineRange: NSRange, in ns: NSString) -> Int {
        var end = lineRange.location + lineRange.length
        if end > lineRange.location, ns.character(at: end - 1) == 0x0A {
            end -= 1
            if end > lineRange.location, ns.character(at: end - 1) == 0x0D {
                end -= 1
            }
        } else if end > lineRange.location, ns.character(at: end - 1) == 0x0D {
            end -= 1
        }
        return end
    }
}
