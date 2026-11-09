import Cocoa

struct TabData: Identifiable, Equatable {
    let id: UUID
    var name: String
    var content: String
    var language: String
    var fileURL: URL?
    var bookmark: Data?
    var languageLocked: Bool
    var isDirty: Bool
    var isPinned: Bool
    var cursorPosition: Int
    var lastModified: Date
    var headVersionID: String?
    var deletedAt: Date?
    var deletedOn: String?
    /// Local only: set when a sync conflict kept this device's text and
    /// parked the other side's in history. Cleared by Resolve or a restore.
    var hasConflict: Bool

    init(
        id: UUID = UUID(),
        name: String = String(localized: "tab.untitled", defaultValue: "Untitled"),
        content: String = "",
        language: String = "plain",
        fileURL: URL? = nil,
        bookmark: Data? = nil,
        languageLocked: Bool = false,
        isDirty: Bool = false,
        isPinned: Bool = false,
        cursorPosition: Int = 0,
        lastModified: Date = Date(),
        headVersionID: String? = nil,
        deletedAt: Date? = nil,
        deletedOn: String? = nil,
        hasConflict: Bool = false
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.language = language
        self.fileURL = fileURL
        self.bookmark = bookmark
        self.languageLocked = languageLocked
        self.isDirty = isDirty
        self.isPinned = isPinned
        self.cursorPosition = cursorPosition
        self.lastModified = lastModified
        self.headVersionID = headVersionID
        self.deletedAt = deletedAt
        self.deletedOn = deletedOn
        self.hasConflict = hasConflict
    }
}

extension TabData: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        content = try c.decode(String.self, forKey: .content)
        language = try c.decode(String.self, forKey: .language)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        languageLocked = try c.decode(Bool.self, forKey: .languageLocked)
        isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        cursorPosition = try c.decode(Int.self, forKey: .cursorPosition)
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? .distantPast
        headVersionID = try c.decodeIfPresent(String.self, forKey: .headVersionID)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        deletedOn = try c.decodeIfPresent(String.self, forKey: .deletedOn)
        hasConflict = try c.decodeIfPresent(Bool.self, forKey: .hasConflict) ?? false
    }
}

class TabStore: ObservableObject {
    static let shared = TabStore(launchBehavior: SettingsStore.shared.launchBehavior)

    @Published var tabs: [TabData] = []
    /// Soft-deleted scratch tabs; their versions stay until a hard delete.
    @Published var trashedTabs: [TabData] = []
    @Published var selectedTabID: UUID? {
        didSet {
            if let previous = oldValue, previous != selectedTabID {
                commitPendingSnapshot(id: previous)
            }
        }
    }
    @Published var lastICloudSync: Date?
    private(set) var savedLayout: LayoutNode?
    var currentLayout: LayoutNode?

    private var saveDebounceWork: DispatchWorkItem?
    private var languageDetectWork: DispatchWorkItem?
    private let sessionURL: URL
    private var kvsMigration: KVSMigration?

    let versionStore: VersionStore
    var now: () -> Date = Date.init
    var idleSnapshotInterval: TimeInterval = 3
    var heldSnapshotInterval: TimeInterval = 10
    var scheduleSnapshot: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var deviceName: String = Host.current().localizedName ?? "Mac"
    var historyEnabled: () -> Bool = { SettingsStore.shared.versionHistoryEnabled }
    var historyKeepCount: () -> Int = { SettingsStore.shared.versionKeepCount }
    var historyKeepDays: () -> Int = { SettingsStore.shared.versionKeepDays }
    var trashAutoEmptyDays: () -> Int = { SettingsStore.shared.trashAutoEmptyDays }
    var cloudRecordChanged: (UUID) -> Void = { CloudSyncEngine.shared.recordChanged($0) }
    var cloudRecordDeleted: (UUID) -> Void = { CloudSyncEngine.shared.recordDeleted($0) }

    var selectedTab: TabData? {
        tabs.first { $0.id == selectedTabID }
    }

    init(sessionURL: URL? = nil, versionStore: VersionStore = .shared, launchBehavior: LaunchBehavior = .reopenLast) {
        self.versionStore = versionStore
        if let sessionURL {
            self.sessionURL = sessionURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let itsypadDir = appSupport.appendingPathComponent("Itsypad")
            try? FileManager.default.createDirectory(at: itsypadDir, withIntermediateDirectories: true)
            self.sessionURL = itsypadDir.appendingPathComponent("session.json")
        }

        let isFirstLaunch = !FileManager.default.fileExists(atPath: self.sessionURL.path)

        TabStore.migrateLegacyData(to: sessionURL ?? self.sessionURL)
        restoreSession()
        kvsMigration = KVSMigration(flagKey: "kvsTabsMigrated") { [weak self] kvs in
            self?.importKVSTabs(from: kvs) ?? false
        }

        if tabs.isEmpty {
            if isFirstLaunch {
                addWelcomeTab()
            } else {
                addNewTab()
            }
        } else if launchBehavior == .newNote, !isFirstLaunch {
            let isBlankScratch = selectedTab.map {
                $0.fileURL == nil && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            if !isBlankScratch {
                addNewTab()
            }
        }
    }

    // MARK: - Tab operations

    func addNewTab() {
        let tab = TabData()
        tabs.append(tab)
        selectedTabID = tab.id
        cloudRecordChanged(tab.id)
        scheduleSave()
    }

    static var welcomeContent: String {
        String(localized: "welcome.content", defaultValue: """
        # Welcome to Itsypad

        A tiny, fast scratchpad that lives in your menu bar.

        Here's what you can do:

        - [x] Download Itsypad
        - [ ] Write notes, ideas, code snippets
        - [ ] Use automatic checklists, bullet and numbered lists
        - [ ] Split the editor into multiple panes
        - [ ] Browse clipboard history
        - [ ] Try Itsypad for iOS
        - [ ] Sync tabs across devices with iCloud
        - [ ] Switch between themes in settings

        Happy writing! Close this tab whenever you're ready to start.
        """)
    }

    func addWelcomeTab() {
        let tab = TabData(
            name: String(localized: "welcome.tab_name", defaultValue: "Welcome to Itsypad"),
            content: Self.welcomeContent,
            language: "markdown"
        )
        tabs.append(tab)
        selectedTabID = tab.id
        scheduleSave()
    }

    /// Tabs whose fileURL this process called startAccessingSecurityScopedResource
    /// on. Stopping a scope that was never started is a documented programmer
    /// error and can prematurely release access shared with another tab.
    private var scopedAccessTabIDs: Set<UUID> = []

    func adoptScopedAccess(id: UUID) {
        scopedAccessTabIDs.insert(id)
    }

    /// Closing a scratch tab moves it to the trash with a tombstone that syncs;
    /// its text and versions stay until it is deleted permanently. File-backed
    /// tabs are not Itsypad-owned data and simply close.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if scopedAccessTabIDs.remove(id) != nil, let url = tabs[index].fileURL {
            url.stopAccessingSecurityScopedResource()
        }
        if tabs[index].fileURL == nil {
            commitPendingSnapshot(id: id)
            commitHeldSnapshot(id: id)
            var tab = tabs.remove(at: index)
            tab.deletedAt = now()
            tab.deletedOn = deviceName
            trashedTabs.append(tab)
            cloudRecordChanged(id)
        } else {
            dropSnapshotState(id: id)
            versionStore.deleteAll(tabID: id)
            tabs.remove(at: index)
        }

        selectAfterRemoval(of: id, at: index)
        scheduleSave()
    }

    private func selectAfterRemoval(of id: UUID, at index: Int) {
        if tabs.isEmpty {
            addNewTab()
        } else if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Live or trashed – the cloud mirror serves both.
    func tab(withID id: UUID) -> TabData? {
        tabs.first { $0.id == id } ?? trashedTabs.first { $0.id == id }
    }

    // MARK: - Trash

    func restoreFromTrash(id: UUID) {
        guard let index = trashedTabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = trashedTabs.remove(at: index)
        tab.deletedAt = nil
        tab.deletedOn = nil
        tabs.append(tab)
        selectedTabID = id
        cloudRecordChanged(id)
        var result = CloudMergeResult()
        result.newTabIDs.append(id)
        NotificationCenter.default.post(
            name: Self.cloudTabsMerged,
            object: self,
            userInfo: ["result": result]
        )
        scheduleSave()
    }

    /// Removes the tab and its whole history here and on the server. The
    /// versions go first: their delete hooks only fire while the tab is still
    /// known as a scratch tab.
    func deletePermanently(id: UUID) {
        let liveIndex = tabs.firstIndex { $0.id == id }
        guard liveIndex != nil || trashedTabs.contains(where: { $0.id == id }) else { return }
        let isScratch = isScratchTab(id)
        dropSnapshotState(id: id)
        versionStore.deleteAll(tabID: id)
        trashedTabs.removeAll { $0.id == id }
        if let liveIndex {
            tabs.remove(at: liveIndex)
            var result = CloudMergeResult()
            result.removedTabIDs.append(id)
            NotificationCenter.default.post(
                name: Self.cloudTabsMerged,
                object: self,
                userInfo: ["result": result]
            )
            selectAfterRemoval(of: id, at: liveIndex)
        }
        if isScratch {
            cloudRecordDeleted(id)
        }
        scheduleSave()
    }

    func emptyTrash() {
        for id in trashedTabs.map(\.id) {
            deletePermanently(id: id)
        }
    }

    /// Hard-deletes trashed tabs older than the auto-empty setting (0 = never).
    func autoEmptyTrash() {
        let days = trashAutoEmptyDays()
        guard days > 0 else { return }
        let cutoff = now().addingTimeInterval(-TimeInterval(days) * VersionPrunePolicy.day)
        for tab in trashedTabs where (tab.deletedAt ?? .distantFuture) < cutoff {
            deletePermanently(id: tab.id)
        }
    }

    /// Hard-deletes one version; the store repoints its children to its parent.
    /// A deleted head moves back to that parent as well.
    func deleteVersion(id versionID: String, tabID: UUID) {
        guard let version = versionStore.version(withID: versionID), version.tabID == tabID else { return }
        versionStore.delete(versionID: versionID, tabID: tabID)
        if let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].headVersionID == versionID {
            tabs[index].headVersionID = version.parentID
            if tabs[index].fileURL == nil {
                cloudRecordChanged(tabID)
            }
            scheduleSave()
        } else if let index = trashedTabs.firstIndex(where: { $0.id == tabID }), trashedTabs[index].headVersionID == versionID {
            trashedTabs[index].headVersionID = version.parentID
            cloudRecordChanged(tabID)
            scheduleSave()
        }
    }

    func updateContent(id: UUID, content: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].content != content else { return }
        let previous = tabs[index].content
        applyContent(id: id, content: content)
        if !previous.isEmpty && versionStore.latest(for: id) == nil
            && pendingSnapshots[id] == nil && heldSnapshots[id] == nil {
            // First edit of a tab without history: keep the pre-edit text so
            // the state before version tracking began is restorable too.
            appendVersion(id: id, text: previous, source: .edit)
        }
        recordEdit(id: id, content: content, source: .edit)
    }

    /// Replaces a tab's text without recording a version – restore and other
    /// programmatic rewrites go through here. The editor refreshes its text
    /// view via `cloudTabsMerged`, the same path cloud updates use.
    func setContentExternally(id: UUID, content: String, cursor: Int? = nil) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        dropSnapshotState(id: id)
        applyContent(id: id, content: content)
        if let cursor {
            cursorPositions[id] = cursor
        }
        var result = CloudMergeResult()
        result.updatedTabIDs.append(id)
        NotificationCenter.default.post(
            name: Self.cloudTabsMerged,
            object: self,
            userInfo: ["result": result]
        )
    }

    private func applyContent(id: UUID, content: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].content != content else { return }

        // Batch mutations into a single array setter to fire @Published once
        var tab = tabs[index]
        tab.content = content
        // Scratch tab emptied back to its initial state has no real changes to preserve.
        tab.isDirty = !(tab.fileURL == nil && content.isEmpty)
        tab.lastModified = Date()

        // Auto-name from first line when no file
        if tab.fileURL == nil {
            let firstLine = content.prefix(while: { $0 != "\n" && $0 != "\r" })
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty ? String(localized: "tab.untitled", defaultValue: "Untitled") : String(trimmed.prefix(30))
            tab.name = newName
        }

        tabs[index] = tab

        // Auto-detect language if not locked (debounced to avoid per-keystroke cost)
        if !tab.languageLocked {
            scheduleLanguageDetection(id: tab.id, content: content, name: tab.name, fileURL: tab.fileURL)
        }

        if tab.fileURL == nil {
            cloudRecordChanged(id)
        }

        scheduleSave()
    }

    /// Fires when auto-detection changes a tab's language: (tabID, newLanguage).
    var onLanguageDetected: ((UUID, String) -> Void)?

    private func scheduleLanguageDetection(id: UUID, content: String, name: String?, fileURL: URL?) {
        languageDetectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }),
                  !self.tabs[index].languageLocked else { return }
            let result = LanguageDetector.shared.detect(text: content, name: name, fileURL: fileURL)
            let oldLang = self.tabs[index].language
            if result.confidence > 0 {
                self.tabs[index].language = result.lang
            } else if oldLang != "plain" && result.lang == "plain" {
                self.tabs[index].language = "plain"
            }
            let newLang = self.tabs[index].language
            NSLog("[AutoDetect] RESULT: '%@' -> '%@' (confidence=%d, name=%@)",
                  oldLang, newLang, result.confidence, name ?? "(untitled)")
            if newLang != oldLang {
                self.onLanguageDetected?(id, newLang)
            }
        }
        languageDetectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func updateLanguage(id: UUID, language: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].language = language
        tabs[index].languageLocked = true
        tabs[index].lastModified = Date()
        if tabs[index].fileURL == nil {
            cloudRecordChanged(id)
        }
        scheduleSave()
    }

    func unlockLanguage(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].languageLocked = false
        tabs[index].lastModified = Date()
        let tab = tabs[index]
        scheduleLanguageDetection(id: id, content: tab.content, name: tab.name, fileURL: tab.fileURL)
        scheduleSave()
    }

    /// Kept outside the @Published tabs array – the caret moves on every
    /// keystroke and mutating tabs would notify every TabStore observer each
    /// time. Merged into the persisted session by saveSession.
    private var cursorPositions: [UUID: Int] = [:]

    func updateCursorPosition(id: UUID, position: Int) {
        cursorPositions[id] = position
    }

    func cursorPosition(for id: UUID) -> Int {
        cursorPositions[id] ?? tabs.first { $0.id == id }?.cursorPosition ?? 0
    }

    // MARK: - File operations

    /// Returns true only when the content actually reached disk – callers
    /// (e.g. the close-confirmation flow) must not destroy the tab otherwise.
    @discardableResult
    func saveFile(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

        if let fileURL = tabs[index].fileURL {
            do {
                try tabs[index].content.write(to: fileURL, atomically: true, encoding: .utf8)
                tabs[index].isDirty = false
                scheduleSave()
                return true
            } catch {
                NSLog("Failed to save file: \(error)")
                presentSaveError(error, name: tabs[index].name)
                return false
            }
        } else {
            return saveFileAs(id: id)
        }
    }

    /// Returns true only on a completed save; false on cancel or write failure.
    @discardableResult
    func saveFileAs(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = tabs[index].name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try tabs[index].content.write(to: url, atomically: true, encoding: .utf8)
            tabs[index].fileURL = url
            tabs[index].name = url.lastPathComponent
            tabs[index].isDirty = false
            tabs[index].bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            if let lang = LanguageDetector.shared.detectFromExtension(name: url.lastPathComponent) {
                tabs[index].language = lang
                tabs[index].languageLocked = true
            }

            scheduleSave()
            return true
        } catch {
            NSLog("Failed to save file: \(error)")
            presentSaveError(error, name: tabs[index].name)
            return false
        }
    }

    private func presentSaveError(_ error: Error, name: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.file_save.title", defaultValue: "Can't save \"\(name)\"")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            openFile(url: url)
        }
    }

    func openFile(url: URL) {
        // Check if already open
        if let existing = tabs.firstIndex(where: { $0.fileURL == url }) {
            selectedTabID = tabs[existing].id
            return
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            let lang = LanguageDetector.shared.detectFromExtension(name: name)
                ?? LanguageDetector.shared.detect(text: content, name: name, fileURL: url).lang
            let bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let tab = TabData(
                name: name,
                content: content,
                language: lang,
                fileURL: url,
                bookmark: bookmarkData,
                languageLocked: true
            )
            tabs.append(tab)
            selectedTabID = tab.id
            scheduleSave()
        } catch {
            NSLog("Failed to open file: \(error)")
        }
    }

    func reloadFromDisk(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let fileURL = tabs[index].fileURL else { return false }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            tabs[index].content = content
            tabs[index].isDirty = false
            scheduleSave()
            return true
        } catch {
            NSLog("Failed to reload file from disk: \(error)")
            return false
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              tabs.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= tabs.count else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertAt = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(tab, at: insertAt)
        scheduleSave()
    }

    // MARK: - Cloud sync

    struct CloudMergeResult {
        var newTabIDs: [UUID] = []
        var updatedTabIDs: [UUID] = []
        var removedTabIDs: [UUID] = []
        /// Tabs whose text is unchanged but whose conflict badge changed.
        var flaggedTabIDs: [UUID] = []
    }

    static let cloudTabsMerged = Notification.Name("cloudTabsMerged")

    func applyCloudTab(_ data: CloudTabRecord) {
        var result = CloudMergeResult()
        var touched = false

        if let deletedAt = data.deletedAt {
            touched = applyCloudTombstone(data, deletedAt: deletedAt, result: &result)
        } else if let trashedIndex = trashedTabs.firstIndex(where: { $0.id == data.id }) {
            // Restored on the other device: it comes back here, then its
            // content merges like any live tab's.
            var tab = trashedTabs.remove(at: trashedIndex)
            tab.deletedAt = nil
            tab.deletedOn = nil
            tabs.append(tab)
            result.newTabIDs.append(data.id)
            touched = mergeCloudTab(at: tabs.count - 1, data: data, result: &result)
        } else if let localIndex = tabs.firstIndex(where: { $0.id == data.id }) {
            touched = mergeCloudTab(at: localIndex, data: data, result: &result)
        } else {
            let tab = TabData(
                id: data.id,
                name: data.name,
                content: data.content,
                language: data.language,
                languageLocked: data.languageLocked,
                isDirty: !data.content.isEmpty,
                lastModified: data.lastModified,
                headVersionID: data.headVersionID
            )
            tabs.append(tab)
            result.newTabIDs.append(data.id)
        }

        let changed = !result.newTabIDs.isEmpty || !result.updatedTabIDs.isEmpty
            || !result.flaggedTabIDs.isEmpty || !result.removedTabIDs.isEmpty
        lastICloudSync = Date()

        if changed {
            NotificationCenter.default.post(
                name: Self.cloudTabsMerged,
                object: self,
                userInfo: ["result": result]
            )
        }
        if changed || touched {
            scheduleSave()
        }
    }

    /// Returns true when only `lastModified` moved (nothing to notify, still save).
    private func mergeCloudTab(at localIndex: Int, data: CloudTabRecord, result: inout CloudMergeResult) -> Bool {
        if tabs[localIndex].content != data.content {
            mergeCloudContent(at: localIndex, data: data, result: &result)
        } else if data.lastModified >= tabs[localIndex].lastModified,
                  tabs[localIndex].name != data.name
                    || tabs[localIndex].language != data.language
                    || tabs[localIndex].languageLocked != data.languageLocked {
            // Content-equal records only carry metadata; last write wins there.
            tabs[localIndex].name = data.name
            tabs[localIndex].language = data.language
            tabs[localIndex].languageLocked = data.languageLocked
            result.updatedTabIDs.append(data.id)
        }
        if let index = tabs.firstIndex(where: { $0.id == data.id }), tabs[index].lastModified < data.lastModified {
            tabs[index].lastModified = data.lastModified
            return true
        }
        return false
    }

    /// A remote tombstone trashes the tab here as well, even over newer local
    /// edits – those are snapshotted first, so the trashed tab keeps them.
    private func applyCloudTombstone(_ data: CloudTabRecord, deletedAt: Date, result: inout CloudMergeResult) -> Bool {
        let id = data.id
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            commitPendingSnapshot(id: id)
            commitHeldSnapshot(id: id)
            if tabs[index].content != data.content {
                appendVersion(id: id, text: tabs[index].content, source: .conflict)
            }
            var tab = tabs.remove(at: index)
            tab.deletedAt = deletedAt
            tab.deletedOn = data.deletedOn
            tab.lastModified = max(tab.lastModified, data.lastModified)
            trashedTabs.append(tab)
            result.removedTabIDs.append(id)
            selectAfterRemoval(of: id, at: index)
            return true
        }
        if let index = trashedTabs.firstIndex(where: { $0.id == id }) {
            guard trashedTabs[index].deletedAt != deletedAt || trashedTabs[index].deletedOn != data.deletedOn else { return false }
            trashedTabs[index].deletedAt = deletedAt
            trashedTabs[index].deletedOn = data.deletedOn
            return true
        }
        trashedTabs.append(TabData(
            id: id,
            name: data.name,
            content: data.content,
            language: data.language,
            languageLocked: data.languageLocked,
            isDirty: !data.content.isEmpty,
            lastModified: data.lastModified,
            headVersionID: data.headVersionID,
            deletedAt: deletedAt,
            deletedOn: data.deletedOn
        ))
        return true
    }

    /// Remote text differs from the live text. The live text is always
    /// snapshotted first, so nothing below can lose it. Then, in order:
    /// fast-forward when the remote descends from our text, three-way merge
    /// against the common ancestor when one is known, otherwise keep ours and
    /// park the remote text in history as a labelled conflict version. The
    /// remote device is only known through its head version, which syncs as a
    /// TabVersion record.
    private func mergeCloudContent(at index: Int, data: CloudTabRecord, result: inout CloudMergeResult) {
        let id = data.id
        let localText = tabs[index].content
        let remoteHead = data.headVersionID.flatMap { versionStore.version(withID: $0) }
        let remoteDevice = remoteHead?.device

        dropSnapshotState(id: id)
        let hadHistory = versionStore.latest(for: id) != nil
        appendVersion(id: id, text: localText, source: .conflict)

        let localID = TabVersion.makeID(tabID: id, text: localText)
        let remoteID = TabVersion.makeID(tabID: id, text: data.content)
        // The remote text descends from the remote head, not from our snapshot.
        let remoteParent = data.headVersionID == remoteID ? nil : data.headVersionID
        if (!hadHistory && localText.isEmpty) || data.headVersionID == localID {
            tabs[index].content = data.content
            tabs[index].name = data.name
            tabs[index].language = data.language
            tabs[index].languageLocked = data.languageLocked
            appendVersion(id: id, text: data.content, source: .edit, device: remoteDevice ?? "iCloud", parentID: remoteParent)
            result.updatedTabIDs.append(id)
            return
        }

        if let base = mergeBase(tabID: id, localID: localID, remoteHeadID: data.headVersionID),
           case .clean(let merged) = LineDiff.merge3(base: base.text, ours: localText, theirs: data.content) {
            applyContent(id: id, content: merged)
            tabs[index].language = data.language
            tabs[index].languageLocked = data.languageLocked
            appendVersion(id: id, text: merged, source: .edit)
            if merged == data.content {
                tabs[index].name = data.name
            }
            result.updatedTabIDs.append(id)
            return
        }

        let device = remoteDevice
            ?? String(localized: "history.conflict_device_unknown", defaultValue: "another device")
        let time = now().formatted(date: .omitted, time: .shortened)
        let label = String(localized: "history.conflict_label", defaultValue: "Conflict – \(device) \(time)")
        appendVersion(
            id: id,
            text: data.content,
            source: .conflict,
            device: remoteDevice ?? "iCloud",
            label: label,
            parentID: remoteParent
        )
        tabs[index].hasConflict = true
        result.flaggedTabIDs.append(id)
        cloudRecordChanged(id)
    }

    /// Common ancestor of our text and the remote head: the first version on
    /// the remote head's parent chain that also lies on our own chain. The
    /// head itself qualifies only when it is in our lineage – a head that was
    /// merely synced down would make the remote edits look like ours.
    private func mergeBase(tabID: UUID, localID: String, remoteHeadID: String?) -> TabVersion? {
        var ours = Set<String>()
        var cursor = versionStore.version(withID: localID) ?? versionStore.latest(for: tabID)
        while let version = cursor, !ours.contains(version.id) {
            ours.insert(version.id)
            cursor = version.parentID.flatMap { versionStore.version(withID: $0) }
        }

        var seen = Set<String>()
        var candidate = remoteHeadID.flatMap { versionStore.version(withID: $0) }
        while let version = candidate, !seen.contains(version.id) {
            if ours.contains(version.id) { return version }
            seen.insert(version.id)
            candidate = version.parentID.flatMap { versionStore.version(withID: $0) }
        }
        return nil
    }

    /// Clears the conflict badge once the user has looked at both texts.
    func resolveConflict(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].hasConflict else { return }
        tabs[index].hasConflict = false
        var result = CloudMergeResult()
        result.flaggedTabIDs.append(id)
        NotificationCenter.default.post(
            name: Self.cloudTabsMerged,
            object: self,
            userInfo: ["result": result]
        )
        scheduleSave()
    }

    /// A deleted ScratchTab record is a hard delete: the tab leaves the live
    /// list or the trash and its history goes with it.
    func removeCloudTab(id: UUID) {
        let liveIndex = tabs.firstIndex { $0.id == id }
        guard liveIndex != nil || trashedTabs.contains(where: { $0.id == id }) else { return }

        var result = CloudMergeResult()
        dropSnapshotState(id: id)
        versionStore.deleteAll(tabID: id)
        trashedTabs.removeAll { $0.id == id }
        if let liveIndex {
            result.removedTabIDs.append(id)
            tabs.remove(at: liveIndex)
            selectAfterRemoval(of: id, at: liveIndex)
        }

        lastICloudSync = Date()
        if !result.removedTabIDs.isEmpty {
            NotificationCenter.default.post(
                name: Self.cloudTabsMerged,
                object: self,
                userInfo: ["result": result]
            )
        }
        scheduleSave()
    }

    // MARK: - Version history

    private struct PendingSnapshot {
        var content: String
        var source: TabVersion.Source
        var work: DispatchWorkItem?
    }

    private var pendingSnapshots: [UUID: PendingSnapshot] = [:]
    private var heldSnapshots: [UUID: PendingSnapshot] = [:]

    func isScratchTab(_ id: UUID) -> Bool {
        tabs.contains { $0.id == id && $0.fileURL == nil } || trashedTabs.contains { $0.id == id }
    }

    /// Snapshot scheduling for one edit: immediate when the text changed by
    /// ≥ 10 % (at least 20 chars) or ≥ 200 chars against the latest version,
    /// otherwise after `idleSnapshotInterval` of no further edits. `hold`
    /// parks the snapshot in memory instead (see commit/discardHeldSnapshot);
    /// it auto-commits after `heldSnapshotInterval` or on the next real edit.
    func recordEdit(id: UUID, content: String, source: TabVersion.Source = .edit, hold: Bool = false) {
        guard historyEnabled(), tabs.contains(where: { $0.id == id }) else { return }
        if hold {
            cancelPendingSnapshot(id: id)
            heldSnapshots[id]?.work?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.commitHeldSnapshot(id: id)
            }
            heldSnapshots[id] = PendingSnapshot(content: content, source: source, work: work)
            scheduleSnapshot(heldSnapshotInterval, work)
            return
        }
        if heldSnapshots[id] != nil {
            commitHeldSnapshot(id: id)
        }

        cancelPendingSnapshot(id: id)
        if let latest = versionStore.latest(for: id), Self.isSignificantChange(from: latest.text, to: content) {
            appendVersion(id: id, text: content, source: source)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.commitPendingSnapshot(id: id)
        }
        pendingSnapshots[id] = PendingSnapshot(content: content, source: source, work: work)
        scheduleSnapshot(idleSnapshotInterval, work)
    }

    static func isSignificantChange(from old: String, to new: String) -> Bool {
        let oldLength = old.utf16.count
        let delta = abs(new.utf16.count - oldLength)
        if delta >= 200 { return true }
        return delta >= 20 && delta * 10 >= oldLength
    }

    func commitPendingSnapshot(id: UUID) {
        guard let pending = pendingSnapshots.removeValue(forKey: id) else { return }
        pending.work?.cancel()
        appendVersion(id: id, text: pending.content, source: pending.source)
    }

    func commitHeldSnapshot(id: UUID) {
        guard let held = heldSnapshots.removeValue(forKey: id) else { return }
        held.work?.cancel()
        appendVersion(id: id, text: held.content, source: held.source)
    }

    func discardHeldSnapshot(id: UUID) {
        heldSnapshots.removeValue(forKey: id)?.work?.cancel()
    }

    /// Commits every pending and held snapshot – call before the app goes to
    /// the background or quits.
    func flushPendingVersions() {
        for id in Array(pendingSnapshots.keys) {
            commitPendingSnapshot(id: id)
        }
        for id in Array(heldSnapshots.keys) {
            commitHeldSnapshot(id: id)
        }
    }

    /// History is never rewritten: the live text is saved as a `.restore`
    /// version first, then the chosen version becomes the live text.
    func restoreVersion(id: UUID, version: TabVersion) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), version.tabID == id else { return }
        // The pending snapshot holds the live text, which is about to be saved
        // as the restore point anyway; a held one may differ, so commit it.
        cancelPendingSnapshot(id: id)
        commitHeldSnapshot(id: id)
        appendVersion(id: id, text: tabs[index].content, source: .restore)
        tabs[index].hasConflict = false
        setContentExternally(id: id, content: version.text, cursor: 0)
    }

    private func cancelPendingSnapshot(id: UUID) {
        pendingSnapshots.removeValue(forKey: id)?.work?.cancel()
    }

    private func dropSnapshotState(id: UUID) {
        cancelPendingSnapshot(id: id)
        discardHeldSnapshot(id: id)
    }

    /// Appends `text` as a version and records it as the tab's head – also
    /// when the same text is already in history, since the head names the
    /// text this device last recorded, which the other device fast-forwards to.
    /// The parent is that head, not the newest version by date: versions
    /// synced down from another device must not enter this device's lineage.
    @discardableResult
    private func appendVersion(
        id: UUID,
        text: String,
        source: TabVersion.Source,
        device: String? = nil,
        label: String? = nil,
        parentID: String? = nil
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let latest = versionStore.latest(for: id)
        if latest == nil && text.isEmpty { return false }
        let version = TabVersion(
            tabID: id,
            parentID: parentID ?? tabs[index].headVersionID ?? latest?.id,
            createdAt: now(),
            device: device ?? deviceName,
            label: label,
            text: text,
            source: source
        )
        let appended = versionStore.append(version)
        if appended {
            versionStore.prune(tabID: id, now: now(), keepCount: historyKeepCount(), keepDays: historyKeepDays())
        } else if let label, versionStore.version(withID: version.id)?.hasLabel == false {
            versionStore.setLabel(label, versionID: version.id, tabID: id)
        }
        if tabs[index].headVersionID != version.id {
            tabs[index].headVersionID = version.id
            if tabs[index].fileURL == nil {
                cloudRecordChanged(id)
            }
            scheduleSave()
        }
        return appended
    }

    // MARK: - KVS migration (v1.6.0 iCloud sync → App Store)

    @discardableResult
    private func importKVSTabs(from kvs: NSUbiquitousKeyValueStore) -> Bool {
        // The old KVS sync stored tabs under the "tabs" key as JSON-encoded [TabData].
        // TabData's Codable init handles missing optional fields (isPinned, bookmark, etc.)
        // via defaults, so decoding old payloads works without a legacy struct.
        guard let data = kvs.data(forKey: "tabs"),
              let kvsTabs = try? JSONDecoder().decode([TabData].self, from: data),
              !kvsTabs.isEmpty else { return false }

        let existingIDs = Set(tabs.map { $0.id })
        let newTabs = kvsTabs.filter { !existingIDs.contains($0.id) }

        if !newTabs.isEmpty {
            // If the only local tab is the empty default "Untitled" tab created on
            // first launch, replace it entirely with the KVS tabs.
            let isDefaultOnly = tabs.count == 1 && tabs[0].content.isEmpty
            if isDefaultOnly {
                tabs = kvsTabs
                selectedTabID = kvsTabs.first?.id
            } else {
                tabs.append(contentsOf: newTabs)
            }
            scheduleSave()
        }

        // Remove KVS keys so the old data isn't re-imported if this code runs again
        // (belt-and-suspenders alongside the UserDefaults flag).
        kvs.removeObject(forKey: "tabs")
        kvs.removeObject(forKey: "deletedTabIDs")
        kvs.synchronize()
        UserDefaults.standard.set(true, forKey: "kvsTabsMigrated")
        NSLog("[KVS Migration] Imported %d tabs from iCloud KVS", newTabs.count)
        return true
    }

    // MARK: - Legacy data migration (non-sandboxed → sandboxed path)
    //
    // Background: versions up to 1.6.0 ran without App Sandbox, so session.json
    // lived at ~/Library/Application Support/Itsypad/session.json. Starting with
    // 1.8.0 we enabled App Sandbox for App Store distribution, which moves the
    // data directory into ~/Library/Containers/com.justinc.itsypad/Data/
    // Library/Application Support/Itsypad/session.json.
    //
    // Problem: users upgrading from ≤1.6.0 to 1.8.x lost all their tabs because
    // the sandboxed app couldn't see the old session.json at the non-sandboxed path.
    //
    // Solution: the direct-download build (itsypad-direct.entitlements) has a
    // temporary-exception entitlement granting read-write access to the old path
    // (com.apple.security.temporary-exception.files.home-relative-path.read-write).
    // On first launch, this method reads the old session.json, merges its tabs
    // into the new sandboxed session, and deletes the old file.
    //
    // Note: the App Store build does NOT have this entitlement (Apple would reject
    // it), so this migration only works for users upgrading the direct-download
    // version. App Store users coming from ≤1.6.0 are covered by the KVS migration
    // above (if they had iCloud sync enabled) or are out of luck (no local file
    // access from sandbox).
    //
    // Uses getpwuid() to find the real home directory because NSHomeDirectory()
    // returns the sandbox container path when sandboxed.

    private static func migrateLegacyData(to sandboxedURL: URL) {
        let fm = FileManager.default

        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return }
        let realHome = String(cString: home)
        let oldDir = "\(realHome)/Library/Application Support/Itsypad"
        let oldFile = "\(oldDir)/session.json"

        NSLog("[Migration] session: oldFile=%@ sandboxed=%@ exists=%d",
              oldFile, sandboxedURL.path, fm.fileExists(atPath: oldFile))

        // Same path means we're running non-sandboxed – nothing to migrate
        guard oldFile != sandboxedURL.path else { return }

        guard fm.fileExists(atPath: oldFile) else { return }

        guard let oldData = try? Data(contentsOf: URL(fileURLWithPath: oldFile)),
              let oldSession = try? JSONDecoder().decode(SessionData.self, from: oldData),
              !oldSession.tabs.isEmpty else {
            try? fm.removeItem(atPath: oldFile)
            return
        }

        let existingSession: SessionData?
        if let data = try? Data(contentsOf: sandboxedURL) {
            existingSession = try? JSONDecoder().decode(SessionData.self, from: data)
        } else {
            existingSession = nil
        }

        var mergedTabs: [TabData]
        if let existing = existingSession {
            let existingIDs = Set(existing.tabs.map { $0.id })
            let newTabs = oldSession.tabs.filter { !existingIDs.contains($0.id) }
            let isDefaultOnly = existing.tabs.count == 1 && existing.tabs[0].content.isEmpty
            mergedTabs = isDefaultOnly ? oldSession.tabs : existing.tabs + newTabs
        } else {
            mergedTabs = oldSession.tabs
        }

        let selectedID = existingSession?.selectedTabID ?? oldSession.selectedTabID
        let layout = existingSession?.layout ?? oldSession.layout
        let merged = SessionData(tabs: mergedTabs, selectedTabID: selectedID, layout: layout, trashedTabs: existingSession?.trashedTabs)

        do {
            let encoded = try JSONEncoder().encode(merged)
            try encoded.write(to: sandboxedURL, options: .atomic)
            try? fm.removeItem(atPath: oldFile)
            NSLog("[Migration] Merged %d legacy tabs into session", oldSession.tabs.count)
        } catch {
            NSLog("[Migration] Failed to migrate session.json: \(error)")
        }
    }

    // MARK: - Session persistence

    func scheduleSave() {
        saveDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        saveDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveSession() {
        do {
            var snapshot = tabs
            for index in snapshot.indices {
                if let position = cursorPositions[snapshot[index].id] {
                    snapshot[index].cursorPosition = position
                }
            }
            let session = SessionData(tabs: snapshot, selectedTabID: selectedTabID, layout: currentLayout, trashedTabs: trashedTabs)
            let data = try JSONEncoder().encode(session)
            try data.write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("Failed to save session: \(error)")
        }
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL) else { return }

        guard let session = try? JSONDecoder().decode(SessionData.self, from: data) else {
            // The file exists but can't be decoded. Keep a copy before the
            // next debounced save overwrites it with an empty session –
            // without this, one bad read permanently destroys every tab.
            try? data.write(to: sessionURL.appendingPathExtension("bak"), options: .atomic)
            NSLog("[TabStore] restoreSession: decode failed, backed up session.json")
            return
        }

        tabs = session.tabs
        trashedTabs = session.trashedTabs ?? []
        selectedTabID = session.selectedTabID ?? tabs.first?.id
        savedLayout = session.layout

        // Resolve security-scoped bookmarks for file-backed tabs
        for index in tabs.indices {
            guard let bookmarkData = tabs[index].bookmark else { continue }
            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if resolvedURL.startAccessingSecurityScopedResource() {
                scopedAccessTabIDs.insert(tabs[index].id)
            }
            tabs[index].fileURL = resolvedURL
            if isStale {
                tabs[index].bookmark = try? resolvedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        }

        // Re-detect language for unlocked tabs to fix stale detection
        for index in tabs.indices where !tabs[index].languageLocked {
            let tab = tabs[index]
            let result = LanguageDetector.shared.detect(
                text: tab.content,
                name: tab.name,
                fileURL: tab.fileURL
            )
            if result.confidence > 0 {
                tabs[index].language = result.lang
            } else if result.lang == "plain" && tab.language != "plain" {
                tabs[index].language = "plain"
            }
        }
    }
}

struct SessionData: Codable {
    let tabs: [TabData]
    let selectedTabID: UUID?
    var layout: LayoutNode?
    var trashedTabs: [TabData]?
}

indirect enum LayoutNode: Codable, Equatable {
    case pane(PaneNodeData)
    case split(SplitNodeData)
}

struct PaneNodeData: Codable, Equatable {
    let tabIDs: [UUID]
    let selectedTabID: UUID?
    var hasClipboard: Bool

    init(tabIDs: [UUID], selectedTabID: UUID?, hasClipboard: Bool = false) {
        self.tabIDs = tabIDs
        self.selectedTabID = selectedTabID
        self.hasClipboard = hasClipboard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabIDs = try container.decode([UUID].self, forKey: .tabIDs)
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        hasClipboard = try container.decodeIfPresent(Bool.self, forKey: .hasClipboard) ?? false
    }
}

struct SplitNodeData: Codable, Equatable {
    let orientation: String
    let dividerPosition: Double
    let first: LayoutNode
    let second: LayoutNode
}
