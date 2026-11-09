import SwiftUI

struct VersionHistoryView: View {
    let tabID: UUID
    let onClose: () -> Void
    @ObservedObject private var tabStore: TabStore
    @ObservedObject private var versionStore: VersionStore
    @ObservedObject private var settings: SettingsStore
    @State private var selectedID: String? = VersionHistoryView.currentRowID
    @State private var namingVersionID: String?
    @State private var nameDraft = ""

    /// Version ids are SHA-256 hex digests, so this tag can never collide.
    static let currentRowID = "current"

    init(
        tabID: UUID,
        tabStore: TabStore = .shared,
        versionStore: VersionStore = .shared,
        settings: SettingsStore = .shared,
        onClose: @escaping () -> Void
    ) {
        self.tabID = tabID
        self.onClose = onClose
        _tabStore = ObservedObject(wrappedValue: tabStore)
        _versionStore = ObservedObject(wrappedValue: versionStore)
        _settings = ObservedObject(wrappedValue: settings)
    }

    private var tab: TabData? {
        tabStore.tabs.first { $0.id == tabID }
    }

    private var currentText: String {
        tab?.content ?? ""
    }

    private var versions: [TabVersion] {
        versionStore.versions(for: tabID)
    }

    private var selectedVersion: TabVersion? {
        guard let selectedID, selectedID != Self.currentRowID else { return nil }
        return versions.first { $0.id == selectedID }
    }

    private struct Entry: Identifiable {
        let version: TabVersion
        let previous: TabVersion?
        var id: String { version.id }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [Entry]
        var id: Date { day }
    }

    private var days: [DayGroup] {
        let all = versions
        let entries = all.indices.map { i in
            Entry(version: all[i], previous: i + 1 < all.count ? all[i + 1] : nil)
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.version.createdAt) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, entries: grouped[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if versions.isEmpty {
                ContentUnavailableView(
                    String(localized: "history.empty", defaultValue: "No versions yet – versions are saved automatically while you type."),
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    versionList
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 380)
                    diffPane
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 400)
        .alert(
            String(localized: "history.name_version.title", defaultValue: "Name this version"),
            isPresented: Binding(
                get: { namingVersionID != nil },
                set: { if !$0 { namingVersionID = nil } }
            )
        ) {
            TextField(String(localized: "history.name_version.placeholder", defaultValue: "Name"), text: $nameDraft)
            Button(String(localized: "history.name_version.save", defaultValue: "Save")) {
                if let versionID = namingVersionID {
                    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    versionStore.setLabel(name, versionID: versionID, tabID: tabID)
                }
                namingVersionID = nil
            }
            Button(String(localized: "history.name_version.cancel", defaultValue: "Cancel"), role: .cancel) {
                namingVersionID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "history.title", defaultValue: "Version history"))
                .font(.headline)
            if let tab {
                Text(tab.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "history.name_version", defaultValue: "Name this version…")) {
                guard let version = selectedVersion else { return }
                nameDraft = version.label ?? ""
                namingVersionID = version.id
            }
            .disabled(selectedVersion == nil)
            Spacer()
            Button(String(localized: "history.close", defaultValue: "Close")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "history.restore", defaultValue: "Restore")) {
                guard let version = selectedVersion else { return }
                tabStore.restoreVersion(id: tabID, version: version)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedVersion == nil)
        }
        .padding(12)
    }

    private var versionList: some View {
        List(selection: $selectedID) {
            Section {
                CurrentRow(text: currentText)
                    .tag(Self.currentRowID)
            }
            ForEach(days) { group in
                Section(group.day.formatted(date: .long, time: .omitted)) {
                    ForEach(group.entries) { entry in
                        VersionRow(version: entry.version, previous: entry.previous)
                            .tag(entry.version.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var diffPane: some View {
        let lines: [LineDiff.Line]
        if let version = selectedVersion {
            lines = LineDiff.diff(old: currentText, new: version.text)
        } else {
            lines = LineDiff.lines(currentText).map { LineDiff.Line(kind: .same, text: $0) }
        }
        let font = Font(settings.editorFont as CTFont)
        return GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(font)
                            .strikethrough(line.kind == .removed)
                            .foregroundStyle(line.kind == .removed ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Self.background(for: line.kind))
                    }
                }
                .padding(.vertical, 8)
                .frame(minWidth: geometry.size.width, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private static func background(for kind: LineDiff.Line.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color.green.opacity(0.2)
        case .removed: return Color.red.opacity(0.18)
        }
    }
}

private func firstLinePreview(_ text: String) -> String {
    text.components(separatedBy: .newlines)
        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
}

private struct CurrentRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "history.current", defaultValue: "Current"))
                    .fontWeight(.semibold)
                let preview = firstLinePreview(text)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VersionRow: View {
    let version: TabVersion
    let previous: TabVersion?

    private var delta: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in LineDiff.diff(old: previous?.text ?? "", new: version.text) {
            switch line.kind {
            case .added: added += line.text.utf16.count
            case .removed: removed += line.text.utf16.count
            case .same: break
            }
        }
        return (added, removed)
    }

    var body: some View {
        let counts = delta
        let preview = firstLinePreview(version.text)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: version.source.symbolName)
                .foregroundStyle(version.source == .conflict ? Color.orange : Color.secondary)
                .frame(width: 16)
                .help(version.source.accessibilityLabel)
                .accessibilityLabel(version.source.accessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.createdAt.formatted(date: .omitted, time: .shortened))
                        .fontWeight(.medium)
                    Text(version.device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(localized: "history.row.delta", defaultValue: "+\(counts.added) −\(counts.removed)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let label = version.label, !label.isEmpty {
                    Text(label)
                        .fontWeight(.bold)
                        .lineLimit(1)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension TabVersion.Source {
    var symbolName: String {
        switch self {
        case .edit: return "pencil"
        case .paste: return "doc.on.clipboard"
        case .conflict: return "exclamationmark.triangle"
        case .restore: return "clock.arrow.circlepath"
        case .manual: return "bookmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .edit: return String(localized: "history.source.edit", defaultValue: "Edited")
        case .paste: return String(localized: "history.source.paste", defaultValue: "Pasted")
        case .conflict: return String(localized: "history.source.conflict", defaultValue: "Conflict copy")
        case .restore: return String(localized: "history.source.restore", defaultValue: "Restored")
        case .manual: return String(localized: "history.source.manual", defaultValue: "Named")
        }
    }
}
