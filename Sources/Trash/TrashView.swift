import SwiftUI

struct TrashView: View {
    @ObservedObject private var tabStore: TabStore
    @State private var pendingDelete: TabData?
    @State private var confirmingEmpty = false

    init(tabStore: TabStore = .shared) {
        _tabStore = ObservedObject(wrappedValue: tabStore)
    }

    private var trashed: [TabData] {
        tabStore.trashedTabs.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if trashed.isEmpty {
                ContentUnavailableView(
                    String(localized: "trash.empty_state", defaultValue: "Trash is empty"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(trashed) { tab in
                    TrashRow(
                        tab: tab,
                        onRestore: { tabStore.restoreFromTrash(id: tab.id) },
                        onDelete: { pendingDelete = tab }
                    )
                    .contextMenu {
                        Button(String(localized: "trash.restore", defaultValue: "Restore")) {
                            tabStore.restoreFromTrash(id: tab.id)
                        }
                        Button(String(localized: "trash.delete_now", defaultValue: "Delete now"), role: .destructive) {
                            pendingDelete = tab
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button(String(localized: "trash.empty", defaultValue: "Empty trash"), role: .destructive) {
                    confirmingEmpty = true
                }
                .disabled(trashed.isEmpty)
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 300)
        .alert(
            String(localized: "trash.confirm_delete.title", defaultValue: "Delete \"\(pendingDelete?.name ?? "")\" permanently?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button(String(localized: "trash.confirm_delete.delete", defaultValue: "Delete"), role: .destructive) {
                if let tab = pendingDelete {
                    tabStore.deletePermanently(id: tab.id)
                }
                pendingDelete = nil
            }
            Button(String(localized: "trash.confirm_delete.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(String(localized: "trash.confirm_delete.message", defaultValue: "Its version history will be deleted too. This cannot be undone."))
        }
        .alert(
            String(localized: "trash.confirm_empty.title", defaultValue: "Empty trash?"),
            isPresented: $confirmingEmpty
        ) {
            Button(String(localized: "trash.confirm_empty.empty", defaultValue: "Empty trash"), role: .destructive) {
                tabStore.emptyTrash()
            }
            Button(String(localized: "trash.confirm_empty.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "trash.confirm_empty.message", defaultValue: "All trashed notes and their version history will be deleted. This cannot be undone."))
        }
    }
}

private struct TrashRow: View {
    let tab: TabData
    let onRestore: () -> Void
    let onDelete: () -> Void

    private var preview: String {
        tab.content.components(separatedBy: .newlines)
            .dropFirst()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private var deletedText: String {
        let when = tab.deletedAt?.formatted(.relative(presentation: .named)) ?? ""
        let device = tab.deletedOn
            ?? String(localized: "history.conflict_device_unknown", defaultValue: "another device")
        return String(localized: "trash.deleted_on", defaultValue: "Deleted \(when) on \(device)")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(deletedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(0.75)
            Spacer(minLength: 8)
            Button(String(localized: "trash.restore", defaultValue: "Restore")) {
                onRestore()
            }
            Button(String(localized: "trash.delete_now", defaultValue: "Delete now"), role: .destructive) {
                onDelete()
            }
        }
        .padding(.vertical, 4)
    }
}
