import XCTest
@testable import ItsypadCore

final class TabStoreTests: XCTestCase {
    private var store: TabStore!
    private var tempURL: URL!
    private var versionsURL: URL!
    private var versionStore: VersionStore!
    private var scheduled: [DispatchWorkItem] = []
    private var changedIDs: [UUID] = []
    private var deletedIDs: [UUID] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        versionsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-\(UUID().uuidString)")
        versionStore = VersionStore(baseURL: versionsURL)
        store = makeStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: versionsURL)
        store = nil
        super.tearDown()
    }

    private func makeStore() -> TabStore {
        let store = TabStore(sessionURL: tempURL, versionStore: versionStore)
        store.now = { [unowned self] in clock }
        store.deviceName = "Test Mac"
        store.scheduleSnapshot = { [unowned self] _, work in scheduled.append(work) }
        store.cloudRecordChanged = { [unowned self] in changedIDs.append($0) }
        store.cloudRecordDeleted = { [unowned self] in deletedIDs.append($0) }
        return store
    }

    /// Runs the most recently scheduled snapshot timer, as the idle delay would.
    private func fireScheduledSnapshot() {
        scheduled.last?.perform()
    }

    // MARK: - Init

    func testFirstLaunchCreatesWelcomeTab() {
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.name, "Welcome to Itsypad")
        XCTAssertEqual(store.tabs.first?.language, "markdown")
        XCTAssertTrue(store.tabs.first?.content.contains("# Welcome to Itsypad") == true)
        XCTAssertNotNil(store.selectedTabID)
    }

    func testExistingEmptySessionCreatesUntitledTab() {
        // Simulate an existing session with no tabs (user closed all tabs previously)
        let emptySession = SessionData(tabs: [], selectedTabID: nil)
        let data = try! JSONEncoder().encode(emptySession)
        try! data.write(to: tempURL)

        let restored = makeStore()
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.name, "Untitled")
        XCTAssertEqual(restored.tabs.first?.language, "plain")
    }

    // MARK: - addNewTab

    func testAddNewTab() {
        let initialCount = store.tabs.count
        store.addNewTab()
        XCTAssertEqual(store.tabs.count, initialCount + 1)
        XCTAssertEqual(store.selectedTabID, store.tabs.last?.id)
    }

    func testAddNewTabSelectsIt() {
        store.addNewTab()
        let newTab = store.tabs.last!
        XCTAssertEqual(store.selectedTabID, newTab.id)
    }

    // MARK: - closeTab

    func testCloseTabRemovesIt() {
        store.addNewTab()
        let tabToClose = store.tabs.first!
        store.closeTab(id: tabToClose.id)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == tabToClose.id }))
    }

    func testCloseLastTabCreatesNew() {
        let onlyTab = store.tabs.first!
        store.closeTab(id: onlyTab.id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.tabs.first?.id, onlyTab.id)
    }

    func testCloseSelectedTabSelectsNeighbor() {
        store.addNewTab()
        store.addNewTab()
        let middleTab = store.tabs[1]
        store.selectedTabID = middleTab.id
        store.closeTab(id: middleTab.id)
        XCTAssertNotNil(store.selectedTabID)
        XCTAssertNotEqual(store.selectedTabID, middleTab.id)
    }

    func testCloseNonSelectedTabKeepsSelection() {
        store.addNewTab()
        let firstTab = store.tabs[0]
        let secondTab = store.tabs[1]
        store.selectedTabID = secondTab.id
        store.closeTab(id: firstTab.id)
        XCTAssertEqual(store.selectedTabID, secondTab.id)
    }

    // MARK: - updateContent

    func testUpdateContentAutoNames() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "hello world")
        XCTAssertEqual(store.tabs.first?.name, "hello world")
    }

    func testUpdateContentTruncatesLongName() {
        let tabID = store.tabs.first!.id
        let longLine = String(repeating: "a", count: 50)
        store.updateContent(id: tabID, content: longLine)
        XCTAssertEqual(store.tabs.first?.name.count, 30)
    }

    func testUpdateContentSetsDirty() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "changed")
        XCTAssertTrue(store.tabs.first!.isDirty)
    }

    func testEmptyingScratchTabClearsDirty() {
        let tabID = store.tabs.first!.id
        XCTAssertNil(store.tabs.first?.fileURL)
        store.updateContent(id: tabID, content: "typed")
        XCTAssertTrue(store.tabs.first!.isDirty)
        store.updateContent(id: tabID, content: "")
        XCTAssertFalse(store.tabs.first!.isDirty)
    }

    func testUpdateContentEmptyLineUsesUntitled() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "   \nsomething")
        XCTAssertEqual(store.tabs.first?.name, "Untitled")
    }

    func testUpdateContentWithLockedLanguageDoesNotChangeLanguage() {
        let tabID = store.tabs.first!.id
        store.updateLanguage(id: tabID, language: "python")
        XCTAssertTrue(store.tabs.first!.languageLocked)
        store.updateContent(id: tabID, content: "import SwiftUI\nstruct Foo: View {}")
        XCTAssertEqual(store.tabs.first?.language, "python")
    }

    func testUpdateContentWithFileURLDoesNotAutoName() {
        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/test.swift")
        store.tabs[0].name = "test.swift"
        store.updateContent(id: tabID, content: "new content")
        XCTAssertEqual(store.tabs.first?.name, "test.swift")
    }

    func testUpdateContentSameContentNoOp() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "hello")
        store.tabs[0].isDirty = false
        store.updateContent(id: tabID, content: "hello")
        XCTAssertFalse(store.tabs.first!.isDirty)
    }

    // MARK: - updateLanguage

    func testUpdateLanguageLocksLanguage() {
        let tabID = store.tabs.first!.id
        store.updateLanguage(id: tabID, language: "rust")
        XCTAssertEqual(store.tabs.first?.language, "rust")
        XCTAssertTrue(store.tabs.first!.languageLocked)
    }

    // MARK: - unlockLanguage

    func testUnlockLanguageResetsLock() {
        let tabID = store.tabs.first!.id
        store.updateLanguage(id: tabID, language: "plain")
        XCTAssertTrue(store.tabs.first!.languageLocked)
        store.unlockLanguage(id: tabID)
        XCTAssertFalse(store.tabs.first!.languageLocked)
    }

    // MARK: - moveTab

    func testMoveTabForward() {
        store.addNewTab()
        store.addNewTab()
        let first = store.tabs[0]
        store.moveTab(from: 0, to: 2)
        XCTAssertEqual(store.tabs[1].id, first.id)
    }

    func testMoveTabBackward() {
        store.addNewTab()
        store.addNewTab()
        let last = store.tabs[2]
        store.moveTab(from: 2, to: 0)
        XCTAssertEqual(store.tabs[0].id, last.id)
    }

    func testMoveTabSameIndexNoOp() {
        store.addNewTab()
        let tabs = store.tabs
        store.moveTab(from: 0, to: 0)
        XCTAssertEqual(store.tabs.map(\.id), tabs.map(\.id))
    }

    func testMoveTabOutOfBoundsNoOp() {
        let tabs = store.tabs
        store.moveTab(from: 5, to: 0)
        XCTAssertEqual(store.tabs.map(\.id), tabs.map(\.id))
    }

    // MARK: - Session persistence

    func testSessionPersistenceRoundtrip() {
        let tabID = store.tabs.first!.id
        store.updateContent(id: tabID, content: "persisted content")
        store.saveSession()

        let restored = makeStore()
        XCTAssertEqual(restored.tabs.first?.content, "persisted content")
        XCTAssertEqual(restored.selectedTabID, tabID)
    }

    // MARK: - TabData Codable

    func testTabDataCodableRoundtrip() throws {
        let tab = TabData(
            name: "Test",
            content: "hello",
            language: "swift",
            fileURL: URL(fileURLWithPath: "/tmp/test.swift"),
            languageLocked: true,
            isDirty: true,
            cursorPosition: 42
        )
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabData.self, from: data)
        XCTAssertEqual(tab, decoded)
    }

    func testTabDataDefaultValues() {
        let tab = TabData()
        XCTAssertEqual(tab.name, "Untitled")
        XCTAssertEqual(tab.content, "")
        XCTAssertEqual(tab.language, "plain")
        XCTAssertNil(tab.fileURL)
        XCTAssertFalse(tab.languageLocked)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.cursorPosition, 0)
    }

    // MARK: - reloadFromDisk

    func testReloadFromDiskUpdatesContent() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = fileURL
        store.tabs[0].content = "original"
        store.tabs[0].isDirty = true

        try "updated from disk".write(to: fileURL, atomically: true, encoding: .utf8)
        let result = store.reloadFromDisk(id: tabID)

        XCTAssertTrue(result)
        XCTAssertEqual(store.tabs.first?.content, "updated from disk")
        XCTAssertFalse(store.tabs.first!.isDirty)
    }

    func testReloadFromDiskReturnsFalseWithoutFileURL() {
        let tabID = store.tabs.first!.id
        XCTAssertNil(store.tabs.first?.fileURL)
        let result = store.reloadFromDisk(id: tabID)
        XCTAssertFalse(result)
    }

    func testReloadFromDiskReturnsFalseForMissingFile() {
        let tabID = store.tabs.first!.id
        store.tabs[0].fileURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-nonexistent.txt")
        let result = store.reloadFromDisk(id: tabID)
        XCTAssertFalse(result)
    }

    func testReloadFromDiskReturnsFalseForInvalidID() {
        let result = store.reloadFromDisk(id: UUID())
        XCTAssertFalse(result)
    }

    // MARK: - Cloud sync (applyCloudTab / removeCloudTab)

    func testApplyCloudTabInsertsNewTab() {
        let initialCount = store.tabs.count
        let record = CloudTabRecord(
            id: UUID(),
            name: "Cloud note",
            content: "from cloud",
            language: "plain",
            languageLocked: false,
            lastModified: Date()
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.count, initialCount + 1)
        XCTAssertTrue(store.tabs.contains(where: { $0.id == record.id }))
        XCTAssertEqual(store.tabs.last?.content, "from cloud")
    }

    func testApplyCloudTabUpdatesExistingTab() {
        let existingID = newScratchTab()
        let record = CloudTabRecord(
            id: existingID,
            name: "Updated",
            content: "updated content",
            language: "swift",
            languageLocked: true,
            lastModified: Date()
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.last?.content, "updated content")
        XCTAssertEqual(store.tabs.last?.name, "Updated")
        XCTAssertEqual(store.tabs.last?.language, "swift")
        XCTAssertTrue(store.tabs.last!.languageLocked)
    }

    func testApplyCloudTabSkipsOlderVersion() {
        let existingID = store.tabs.first!.id
        store.updateContent(id: existingID, content: "local content")

        let record = CloudTabRecord(
            id: existingID,
            name: "Old cloud",
            content: "old content",
            language: "plain",
            languageLocked: false,
            lastModified: Date.distantPast
        )
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.first?.content, "local content")
    }

    func testRemoveCloudTabRemovesTab() {
        store.addNewTab()
        let tabToRemove = store.tabs.first!.id
        store.removeCloudTab(id: tabToRemove)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == tabToRemove }))
    }

    func testRemoveCloudTabEnsuresAtLeastOneTab() {
        let onlyTab = store.tabs.first!.id
        store.removeCloudTab(id: onlyTab)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotEqual(store.tabs.first?.id, onlyTab)
    }

    func testRemoveCloudTabIgnoresUnknownID() {
        let initialCount = store.tabs.count
        store.removeCloudTab(id: UUID())
        XCTAssertEqual(store.tabs.count, initialCount)
    }

    // MARK: - Version history

    private func newScratchTab() -> UUID {
        store.addNewTab()
        scheduled.removeAll()
        return store.tabs.last!.id
    }

    func testRapidEditsProduceOneVersionAfterIdle() {
        let tabID = newScratchTab()
        for text in ["h", "he", "hel", "hell", "hello"] {
            store.updateContent(id: tabID, content: text)
        }
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        XCTAssertEqual(scheduled.count, 5)
        fireScheduledSnapshot()
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.text, "hello")
        XCTAssertEqual(versions.first?.source, .edit)
        XCTAssertEqual(versions.first?.device, "Test Mac")
        XCTAssertEqual(versions.first?.createdAt, clock)
        XCTAssertNil(versions.first?.parentID)
    }

    func testRecordEditIsNoOpWhenHistoryDisabled() {
        let tabID = newScratchTab()
        store.historyEnabled = { false }
        store.updateContent(id: tabID, content: "hello")
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        store.recordEdit(id: tabID, content: String(repeating: "x", count: 500))
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
    }

    func testAppendedVersionsUseInjectedKeepCount() {
        let tabID = newScratchTab()
        store.historyKeepCount = { 2 }
        for index in 1...4 {
            clock.addTimeInterval(30)
            store.updateContent(id: tabID, content: "text \(index)")
            fireScheduledSnapshot()
        }
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["text 4", "text 1"])
    }

    func testIdleSnapshotsChainParents() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "first")
        fireScheduledSnapshot()
        clock.addTimeInterval(30)
        store.updateContent(id: tabID, content: "first second")
        fireScheduledSnapshot()
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["first second", "first"])
        XCTAssertEqual(versions[0].parentID, versions[1].id)
    }

    func testLargeDeltaSnapshotsImmediately() {
        let tabID = newScratchTab()
        let base = String(repeating: "x", count: 1000)
        store.updateContent(id: tabID, content: base)
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).count, 1)

        let count = scheduled.count
        store.updateContent(id: tabID, content: base + String(repeating: "y", count: 150))
        XCTAssertEqual(versionStore.versions(for: tabID).count, 2)
        XCTAssertEqual(scheduled.count, count)
        XCTAssertEqual(versionStore.latest(for: tabID)?.text.utf16.count, 1150)
    }

    func testSmallDeltaWaitsForIdle() {
        let tabID = newScratchTab()
        let base = String(repeating: "x", count: 1000)
        store.updateContent(id: tabID, content: base)
        fireScheduledSnapshot()
        store.updateContent(id: tabID, content: base + "abc")
        XCTAssertEqual(versionStore.versions(for: tabID).count, 1)
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).count, 2)
    }

    func testFirstEditOfExistingTextKeepsBaseline() {
        let tabID = store.tabs.first!.id
        let welcome = store.tabs.first!.content
        store.updateContent(id: tabID, content: "replaced")
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["replaced", welcome])
        XCTAssertEqual(versions[0].parentID, versions[1].id)
    }

    func testTabSwitchCommitsPendingSnapshot() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "typed before switching")
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        store.addNewTab()
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["typed before switching"])
        store.selectedTabID = tabID
        XCTAssertEqual(versionStore.versions(for: tabID).count, 1)
    }

    func testFlushPendingVersionsCommitsEverything() {
        let first = newScratchTab()
        store.updateContent(id: first, content: "one")
        let second = newScratchTab()
        store.updateContent(id: second, content: "two")
        store.recordEdit(id: second, content: "two held", hold: true)
        store.flushPendingVersions()
        XCTAssertEqual(versionStore.versions(for: first).map(\.text), ["one"])
        XCTAssertEqual(versionStore.versions(for: second).map(\.text), ["two held"])
        XCTAssertFalse(scheduled.isEmpty)
    }

    func testHeldSnapshotDiscard() {
        let tabID = newScratchTab()
        store.recordEdit(id: tabID, content: "pasted", hold: true)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        store.discardHeldSnapshot(id: tabID)
        fireScheduledSnapshot()
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
    }

    func testHeldSnapshotCommit() {
        let tabID = newScratchTab()
        store.recordEdit(id: tabID, content: "pasted", source: .paste, hold: true)
        store.commitHeldSnapshot(id: tabID)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["pasted"])
        XCTAssertEqual(versions.first?.source, .paste)
        store.commitHeldSnapshot(id: tabID)
        XCTAssertEqual(versionStore.versions(for: tabID).count, 1)
    }

    func testHeldSnapshotAutoCommitsOnTimerAndOnNextEdit() {
        let tabID = newScratchTab()
        store.recordEdit(id: tabID, content: "pasted", source: .paste, hold: true)
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["pasted"])

        store.recordEdit(id: tabID, content: "pasted again", source: .paste, hold: true)
        store.updateContent(id: tabID, content: "pasted again!")
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["pasted again", "pasted"])
    }

    private func cloudRecord(
        id: UUID,
        content: String,
        head: String? = nil,
        name: String = "Remote",
        deletedAt: Date? = nil,
        deletedOn: String? = nil
    ) -> CloudTabRecord {
        CloudTabRecord(
            id: id,
            name: name,
            content: content,
            language: "plain",
            languageLocked: false,
            lastModified: Date().addingTimeInterval(60),
            headVersionID: head,
            deletedAt: deletedAt,
            deletedOn: deletedOn
        )
    }

    func testCloudConflictKeepsLocalTextAndParksRemoteInHistory() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "local draft")
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote text"))

        XCTAssertEqual(store.tabs.last?.content, "local draft")
        XCTAssertEqual(store.tabs.last?.name, "local draft")
        XCTAssertTrue(store.tabs.last!.hasConflict)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["remote text", "local draft"])
        XCTAssertEqual(versions.map(\.source), [.conflict, .conflict])
        XCTAssertEqual(versions[0].device, "iCloud")
        XCTAssertEqual(versions[0].label, "Conflict – another device \(clock.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(versions[0].parentID, versions[1].id)
        XCTAssertNil(versions[1].label)
        XCTAssertEqual(store.tabs.last?.headVersionID, versions[0].id)
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).count, 2)
    }

    func testCloudConflictOnOverlappingEditsNamesTheRemoteDevice() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "one\ntwo\nthree")
        fireScheduledSnapshot()
        let baseID = versionStore.latest(for: tabID)!.id
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "one\nTWO\nthree")
        clock.addTimeInterval(60)
        store.applyCloudTab(cloudRecord(id: tabID, content: "one\n2\nthree", head: baseID))

        XCTAssertEqual(store.tabs.last?.content, "one\nTWO\nthree")
        XCTAssertTrue(store.tabs.last!.hasConflict)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["one\n2\nthree", "one\nTWO\nthree", "one\ntwo\nthree"])
        XCTAssertEqual(versions[0].source, .conflict)
        XCTAssertEqual(versions[0].device, "Test Mac")
        XCTAssertTrue(versions[0].label?.hasPrefix("Conflict – Test Mac ") == true)
        XCTAssertEqual(versions[0].parentID, baseID)
        XCTAssertEqual(versions[1].source, .conflict)
        XCTAssertEqual(versions[1].parentID, baseID)
    }

    func testCloudFastForwardAppliesRemoteText() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "shared text")
        fireScheduledSnapshot()
        let localID = versionStore.latest(for: tabID)!.id
        XCTAssertEqual(store.tabs.last?.headVersionID, localID)
        clock.addTimeInterval(60)
        store.applyCloudTab(cloudRecord(id: tabID, content: "shared text plus more", head: localID, name: "Shared"))

        XCTAssertEqual(store.tabs.last?.content, "shared text plus more")
        XCTAssertEqual(store.tabs.last?.name, "Shared")
        XCTAssertFalse(store.tabs.last!.hasConflict)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["shared text plus more", "shared text"])
        XCTAssertEqual(versions[0].source, .edit)
        XCTAssertEqual(versions[0].device, "Test Mac")
        XCTAssertEqual(versions[0].parentID, localID)
        XCTAssertEqual(store.tabs.last?.headVersionID, versions[0].id)
    }

    func testCloudFastForwardSnapshotsPendingLocalTextFirst() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "first")
        fireScheduledSnapshot()
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "first, then typed")
        let pendingID = TabVersion.makeID(tabID: tabID, text: "first, then typed")
        store.applyCloudTab(cloudRecord(id: tabID, content: "first, then typed, then remote", head: pendingID))

        XCTAssertEqual(store.tabs.last?.content, "first, then typed, then remote")
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["first, then typed, then remote", "first, then typed", "first"])
    }

    func testCloudMergeCombinesNonOverlappingEdits() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "one\ntwo\nthree")
        fireScheduledSnapshot()
        let baseID = versionStore.latest(for: tabID)!.id
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "ONE\ntwo\nthree")
        clock.addTimeInterval(60)
        store.applyCloudTab(cloudRecord(id: tabID, content: "one\ntwo\nTHREE", head: baseID))

        XCTAssertEqual(store.tabs.last?.content, "ONE\ntwo\nTHREE")
        XCTAssertEqual(store.tabs.last?.name, "ONE")
        XCTAssertFalse(store.tabs.last!.hasConflict)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["ONE\ntwo\nTHREE", "ONE\ntwo\nthree", "one\ntwo\nthree"])
        XCTAssertEqual(versions[0].source, .edit)
        XCTAssertEqual(versions[0].device, "Test Mac")
        XCTAssertEqual(versions[1].source, .conflict)
        XCTAssertEqual(store.tabs.last?.headVersionID, versions[0].id)
    }

    func testCloudMergeUsesCommonAncestorWhenRemoteHeadIsSyncedDown() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "one\ntwo\nthree")
        fireScheduledSnapshot()
        let baseID = versionStore.latest(for: tabID)!.id
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "ONE\ntwo\nthree")
        // The other device's own version arrives before its tab record.
        let remoteHead = TabVersion(
            tabID: tabID,
            parentID: baseID,
            createdAt: clock.addingTimeInterval(30),
            device: "iPhone",
            text: "one\ntwo\nTHREE",
            source: .edit
        )
        versionStore.applyCloud(remoteHead)
        clock.addTimeInterval(60)
        store.applyCloudTab(cloudRecord(id: tabID, content: "one\ntwo\nTHREE", head: remoteHead.id))

        XCTAssertEqual(store.tabs.last?.content, "ONE\ntwo\nTHREE")
        XCTAssertFalse(store.tabs.last!.hasConflict)
    }

    func testCloudMergeNeverDropsUnsnapshottedLocalText() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "typed but not yet saved")
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote text"))

        XCTAssertTrue(versionStore.versions(for: tabID).map(\.text).contains("typed but not yet saved"))
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).count, 2)
    }

    func testCloudEmptyFreshTabAdoptsRemoteText() {
        let tabID = newScratchTab()
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote text", name: "Remote"))

        XCTAssertEqual(store.tabs.last?.content, "remote text")
        XCTAssertEqual(store.tabs.last?.name, "Remote")
        XCTAssertFalse(store.tabs.last!.hasConflict)
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["remote text"])
        XCTAssertEqual(versions[0].source, .edit)
        XCTAssertNil(versions[0].parentID)
    }

    func testCloudMetadataOnlyUpdateAppliesWithoutTouchingHistory() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "same text")
        fireScheduledSnapshot()
        var record = cloudRecord(id: tabID, content: "same text", name: "Renamed")
        record.language = "swift"
        record.languageLocked = true
        store.applyCloudTab(record)

        XCTAssertEqual(store.tabs.last?.name, "Renamed")
        XCTAssertEqual(store.tabs.last?.language, "swift")
        XCTAssertTrue(store.tabs.last!.languageLocked)
        XCTAssertEqual(versionStore.versions(for: tabID).count, 1)
    }

    func testResolveConflictClearsFlagAndNotifies() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "local")
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote"))
        XCTAssertTrue(store.tabs.last!.hasConflict)

        let expectation = expectation(forNotification: TabStore.cloudTabsMerged, object: store) { notification in
            let result = notification.userInfo?["result"] as? TabStore.CloudMergeResult
            return result?.flaggedTabIDs == [tabID] && result?.updatedTabIDs.isEmpty == true
        }
        store.resolveConflict(id: tabID)
        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(store.tabs.last!.hasConflict)
    }

    func testRestoreClearsConflict() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "local")
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote"))
        let remoteVersion = versionStore.versions(for: tabID).first { $0.text == "remote" }!
        store.restoreVersion(id: tabID, version: remoteVersion)

        XCTAssertEqual(store.tabs.last?.content, "remote")
        XCTAssertFalse(store.tabs.last!.hasConflict)
    }

    func testTabDataDecodesSessionsWithoutConflictFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","content":"text","language":"plain","languageLocked":false,"cursorPosition":0}
        """
        let tab = try JSONDecoder().decode(TabData.self, from: Data(json.utf8))
        XCTAssertNil(tab.headVersionID)
        XCTAssertNil(tab.deletedAt)
        XCTAssertNil(tab.deletedOn)
        XCTAssertFalse(tab.hasConflict)
    }

    func testTabDataRoundTripsConflictFields() throws {
        var tab = TabData(name: "T", content: "c")
        tab.headVersionID = "head"
        tab.hasConflict = true
        let decoded = try JSONDecoder().decode(TabData.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(decoded.headVersionID, "head")
        XCTAssertTrue(decoded.hasConflict)
    }

    func testSessionPersistsHeadVersionIDAndConflict() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "local")
        fireScheduledSnapshot()
        store.applyCloudTab(cloudRecord(id: tabID, content: "remote"))
        store.saveSession()

        let restored = makeStore()
        let tab = restored.tabs.first { $0.id == tabID }
        XCTAssertEqual(tab?.headVersionID, store.tabs.last?.headVersionID)
        XCTAssertEqual(tab?.hasConflict, true)
    }

    func testRestoreAppendsRestoreVersionAndSetsContent() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "version one")
        fireScheduledSnapshot()
        let target = versionStore.latest(for: tabID)!
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "version two")
        fireScheduledSnapshot()
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "live text")

        let expectation = expectation(forNotification: TabStore.cloudTabsMerged, object: store) { notification in
            let result = notification.userInfo?["result"] as? TabStore.CloudMergeResult
            return result?.updatedTabIDs == [tabID]
        }
        store.restoreVersion(id: tabID, version: target)
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(store.tabs.last?.content, "version one")
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["live text", "version two", "version one"])
        XCTAssertEqual(versions.first?.source, .restore)
        XCTAssertEqual(store.cursorPosition(for: tabID), 0)
        fireScheduledSnapshot()
        XCTAssertEqual(versionStore.versions(for: tabID).count, 3)
    }

    func testSetContentExternallyDoesNotSnapshot() {
        let tabID = newScratchTab()
        store.setContentExternally(id: tabID, content: "programmatic")
        fireScheduledSnapshot()
        XCTAssertEqual(store.tabs.last?.content, "programmatic")
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
    }

    // MARK: - Trash

    private func mergeExpectation(_ check: @escaping (TabStore.CloudMergeResult) -> Bool) -> XCTestExpectation {
        expectation(forNotification: TabStore.cloudTabsMerged, object: store) { notification in
            guard let result = notification.userInfo?["result"] as? TabStore.CloudMergeResult else { return false }
            return check(result)
        }
    }

    func testCloseTabTrashesScratchTabAndKeepsVersions() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "will be trashed")
        fireScheduledSnapshot()
        store.updateContent(id: tabID, content: "will be trashed, edited")
        changedIDs.removeAll()

        store.closeTab(id: tabID)

        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        let trashed = store.trashedTabs.first { $0.id == tabID }
        XCTAssertEqual(trashed?.content, "will be trashed, edited")
        XCTAssertEqual(trashed?.deletedAt, clock)
        XCTAssertEqual(trashed?.deletedOn, "Test Mac")
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["will be trashed, edited", "will be trashed"])
        XCTAssertEqual(VersionStore(baseURL: versionsURL).versions(for: tabID).count, 2)
        XCTAssertTrue(changedIDs.contains(tabID))
        XCTAssertTrue(deletedIDs.isEmpty)
        XCTAssertTrue(store.isScratchTab(tabID))
    }

    func testCloseFileBackedTabDoesNotTrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "file text".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        store.openFile(url: url)
        let tabID = store.tabs.last!.id
        store.updateContent(id: tabID, content: "file text edited")
        fireScheduledSnapshot()
        changedIDs.removeAll()

        store.closeTab(id: tabID)

        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        XCTAssertFalse(changedIDs.contains(tabID))
    }

    func testCloseSelectedTabFromTrashKeepsNeighbourSelection() {
        let first = newScratchTab()
        let second = newScratchTab()
        store.selectedTabID = first
        store.closeTab(id: first)
        XCTAssertEqual(store.selectedTabID, second)
        XCTAssertEqual(store.trashedTabs.map(\.id), [first])
    }

    func testRestoreFromTrashBringsTabBack() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "trashed note")
        store.closeTab(id: tabID)
        changedIDs.removeAll()

        let expectation = mergeExpectation { $0.newTabIDs == [tabID] }
        store.restoreFromTrash(id: tabID)
        wait(for: [expectation], timeout: 1)

        let tab = store.tabs.first { $0.id == tabID }
        XCTAssertEqual(tab?.content, "trashed note")
        XCTAssertNil(tab?.deletedAt)
        XCTAssertNil(tab?.deletedOn)
        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertEqual(store.selectedTabID, tabID)
        XCTAssertEqual(changedIDs, [tabID])
    }

    func testDeletePermanentlyRemovesVersionsAndQueuesDelete() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "gone for good")
        fireScheduledSnapshot()
        store.closeTab(id: tabID)

        store.deletePermanently(id: tabID)

        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
        XCTAssertTrue(VersionStore(baseURL: versionsURL).versions(for: tabID).isEmpty)
        XCTAssertEqual(deletedIDs, [tabID])
        XCTAssertFalse(store.isScratchTab(tabID))
    }

    func testDeletePermanentlyOnLiveTabRemovesItAndNotifies() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "live")

        let expectation = mergeExpectation { $0.removedTabIDs == [tabID] }
        store.deletePermanently(id: tabID)
        wait(for: [expectation], timeout: 1)

        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertFalse(store.tabs.isEmpty)
        XCTAssertEqual(deletedIDs, [tabID])
    }

    func testEmptyTrashDeletesEverything() {
        let a = newScratchTab()
        store.updateContent(id: a, content: "a")
        fireScheduledSnapshot()
        let b = newScratchTab()
        store.updateContent(id: b, content: "b")
        fireScheduledSnapshot()
        store.closeTab(id: a)
        store.closeTab(id: b)
        XCTAssertEqual(store.trashedTabs.count, 2)

        store.emptyTrash()

        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(versionStore.versions(for: a).isEmpty)
        XCTAssertTrue(versionStore.versions(for: b).isEmpty)
        XCTAssertEqual(Set(deletedIDs), [a, b])
    }

    func testAutoEmptyTrashRespectsDaysAndNever() {
        let old = newScratchTab()
        store.updateContent(id: old, content: "old")
        store.closeTab(id: old)
        clock.addTimeInterval(31 * 86_400)
        let recent = newScratchTab()
        store.updateContent(id: recent, content: "recent")
        store.closeTab(id: recent)
        clock.addTimeInterval(2 * 86_400)

        store.trashAutoEmptyDays = { 0 }
        store.autoEmptyTrash()
        XCTAssertEqual(store.trashedTabs.count, 2)

        store.trashAutoEmptyDays = { 30 }
        store.autoEmptyTrash()
        XCTAssertEqual(store.trashedTabs.map(\.id), [recent])
        XCTAssertEqual(deletedIDs, [old])
    }

    func testCloudTombstoneTrashesLiveTabAndKeepsEdits() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "shared text")
        fireScheduledSnapshot()
        store.updateContent(id: tabID, content: "shared text plus local edit")
        let deletedAt = clock.addingTimeInterval(-5)

        let expectation = mergeExpectation { $0.removedTabIDs == [tabID] }
        store.applyCloudTab(cloudRecord(id: tabID, content: "shared text", deletedAt: deletedAt, deletedOn: "iPhone"))
        wait(for: [expectation], timeout: 1)

        XCTAssertFalse(store.tabs.contains { $0.id == tabID })
        XCTAssertFalse(store.tabs.isEmpty)
        let trashed = store.trashedTabs.first { $0.id == tabID }
        XCTAssertEqual(trashed?.content, "shared text plus local edit")
        XCTAssertEqual(trashed?.deletedAt, deletedAt)
        XCTAssertEqual(trashed?.deletedOn, "iPhone")
        XCTAssertEqual(versionStore.versions(for: tabID).map(\.text), ["shared text plus local edit", "shared text"])
    }

    func testCloudTombstoneForUnknownTabLandsInTrash() {
        let id = UUID()
        store.applyCloudTab(cloudRecord(id: id, content: "from the other device", deletedAt: clock, deletedOn: "iPhone"))
        XCTAssertFalse(store.tabs.contains { $0.id == id })
        let trashed = store.trashedTabs.first { $0.id == id }
        XCTAssertEqual(trashed?.content, "from the other device")
        XCTAssertEqual(trashed?.deletedAt, clock)
        XCTAssertEqual(trashed?.deletedOn, "iPhone")
    }

    func testCloudLiveRecordRestoresTrashedTab() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "note")
        store.closeTab(id: tabID)

        let expectation = mergeExpectation { $0.newTabIDs == [tabID] }
        store.applyCloudTab(cloudRecord(id: tabID, content: "note"))
        wait(for: [expectation], timeout: 1)

        XCTAssertTrue(store.trashedTabs.isEmpty)
        let tab = store.tabs.first { $0.id == tabID }
        XCTAssertEqual(tab?.content, "note")
        XCTAssertNil(tab?.deletedAt)
        XCTAssertNil(tab?.deletedOn)
    }

    func testRemoveCloudTabHardDeletesTrashedTab() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "note")
        fireScheduledSnapshot()
        store.closeTab(id: tabID)

        store.removeCloudTab(id: tabID)

        XCTAssertTrue(store.trashedTabs.isEmpty)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
    }

    func testSessionRoundTripsTrashedTabs() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "trashed")
        store.closeTab(id: tabID)
        store.saveSession()

        let restored = makeStore()
        XCTAssertEqual(restored.trashedTabs.map(\.id), [tabID])
        XCTAssertEqual(restored.trashedTabs.first?.deletedAt, clock)
        XCTAssertEqual(restored.trashedTabs.first?.deletedOn, "Test Mac")
        XCTAssertFalse(restored.tabs.contains { $0.id == tabID })
    }

    func testOldSessionWithoutTrashDecodes() throws {
        let json = """
        {"tabs":[{"id":"\(UUID().uuidString)","name":"Old","content":"text","language":"plain","languageLocked":false,"cursorPosition":0}],"selectedTabID":null}
        """
        try Data(json.utf8).write(to: tempURL)
        let restored = makeStore()
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertTrue(restored.trashedTabs.isEmpty)
    }

    func testDeleteVersionRepointsChildAndHead() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "one")
        fireScheduledSnapshot()
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "two")
        fireScheduledSnapshot()
        clock.addTimeInterval(60)
        store.updateContent(id: tabID, content: "three")
        fireScheduledSnapshot()
        let versions = versionStore.versions(for: tabID)
        XCTAssertEqual(versions.map(\.text), ["three", "two", "one"])
        let (three, two, one) = (versions[0], versions[1], versions[2])
        changedIDs.removeAll()

        store.deleteVersion(id: two.id, tabID: tabID)
        let remaining = versionStore.versions(for: tabID)
        XCTAssertEqual(remaining.map(\.text), ["three", "one"])
        XCTAssertEqual(remaining[0].parentID, one.id)
        XCTAssertEqual(store.tabs.last?.headVersionID, three.id)
        XCTAssertTrue(changedIDs.isEmpty)

        store.deleteVersion(id: three.id, tabID: tabID)
        XCTAssertEqual(store.tabs.last?.headVersionID, one.id)
        XCTAssertEqual(changedIDs, [tabID])
    }

    func testRemoveCloudTabDeletesVersions() {
        let tabID = newScratchTab()
        store.updateContent(id: tabID, content: "remote delete")
        fireScheduledSnapshot()
        store.removeCloudTab(id: tabID)
        XCTAssertTrue(versionStore.versions(for: tabID).isEmpty)
    }

    func testIsSignificantChange() {
        XCTAssertTrue(TabStore.isSignificantChange(from: "", to: String(repeating: "a", count: 200)))
        XCTAssertFalse(TabStore.isSignificantChange(from: "", to: "a"))
        XCTAssertFalse(TabStore.isSignificantChange(from: "short", to: "short!"))
        XCTAssertTrue(TabStore.isSignificantChange(from: String(repeating: "a", count: 100), to: String(repeating: "a", count: 125)))
        XCTAssertFalse(TabStore.isSignificantChange(from: String(repeating: "a", count: 1000), to: String(repeating: "a", count: 1050)))
        XCTAssertTrue(TabStore.isSignificantChange(from: String(repeating: "a", count: 1000), to: String(repeating: "a", count: 850)))
    }

    // MARK: - LayoutNode Codable

    func testLayoutNodePaneCodableRoundtrip() throws {
        let node = LayoutNode.pane(PaneNodeData(
            tabIDs: [UUID(), UUID()],
            selectedTabID: UUID()
        ))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        XCTAssertEqual(node, decoded)
    }

    func testLayoutNodeSplitCodableRoundtrip() throws {
        let node = LayoutNode.split(SplitNodeData(
            orientation: "horizontal",
            dividerPosition: 0.4,
            first: .pane(PaneNodeData(tabIDs: [UUID()], selectedTabID: nil)),
            second: .pane(PaneNodeData(tabIDs: [UUID()], selectedTabID: nil))
        ))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        XCTAssertEqual(node, decoded)
    }

    func testLayoutNodeNestedSplitCodableRoundtrip() throws {
        let inner = LayoutNode.split(SplitNodeData(
            orientation: "vertical",
            dividerPosition: 0.3,
            first: .pane(PaneNodeData(tabIDs: [UUID()], selectedTabID: nil)),
            second: .pane(PaneNodeData(tabIDs: [UUID()], selectedTabID: nil))
        ))
        let node = LayoutNode.split(SplitNodeData(
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: inner,
            second: .pane(PaneNodeData(tabIDs: [UUID(), UUID()], selectedTabID: UUID()))
        ))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        XCTAssertEqual(node, decoded)
    }

    // MARK: - Session persistence with layout

    func testSessionPersistenceWithLayout() {
        let tabID = store.tabs.first!.id
        store.currentLayout = .pane(PaneNodeData(tabIDs: [tabID], selectedTabID: tabID))
        store.saveSession()

        let restored = makeStore()
        XCTAssertNotNil(restored.savedLayout)
        if case .pane(let data) = restored.savedLayout {
            XCTAssertEqual(data.tabIDs, [tabID])
            XCTAssertEqual(data.selectedTabID, tabID)
        } else {
            XCTFail("Expected pane layout")
        }
    }

    func testSessionPersistenceWithSplitLayout() {
        let tabID = store.tabs.first!.id
        store.addNewTab()
        let secondTabID = store.tabs.last!.id

        store.currentLayout = .split(SplitNodeData(
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: .pane(PaneNodeData(tabIDs: [tabID], selectedTabID: tabID)),
            second: .pane(PaneNodeData(tabIDs: [secondTabID], selectedTabID: secondTabID))
        ))
        store.saveSession()

        let restored = makeStore()
        XCTAssertNotNil(restored.savedLayout)
        if case .split(let data) = restored.savedLayout {
            XCTAssertEqual(data.orientation, "horizontal")
            XCTAssertEqual(data.dividerPosition, 0.5)
        } else {
            XCTFail("Expected split layout")
        }
    }

    func testSessionPersistenceWithoutLayoutBackwardCompatible() {
        store.saveSession()

        let restored = makeStore()
        XCTAssertNil(restored.savedLayout)
    }

    func testSessionPersistenceLayoutNilByDefault() {
        XCTAssertNil(store.currentLayout)
    }

    // MARK: - Launch behaviour

    private func writeSession(_ tabs: [TabData], selected: UUID?) {
        let data = try! JSONEncoder().encode(SessionData(tabs: tabs, selectedTabID: selected))
        try! data.write(to: tempURL)
    }

    func testNewNoteLaunchAddsTabWhenSelectedTabHasContent() {
        let existing = TabData(name: "Notes", content: "some text")
        writeSession([existing], selected: existing.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs.first?.id, existing.id)
        XCTAssertNotEqual(restored.selectedTabID, existing.id)
        XCTAssertEqual(restored.selectedTab?.content, "")
    }

    func testNewNoteLaunchReusesBlankSelectedTab() {
        let blank = TabData(content: "  \n ")
        writeSession([blank], selected: blank.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedTabID, blank.id)
    }

    func testNewNoteLaunchAddsTabWhenSelectedBlankTabHasFile() {
        let file = TabData(name: "a.txt", content: "", fileURL: URL(fileURLWithPath: "/tmp/a.txt"))
        writeSession([file], selected: file.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertNotEqual(restored.selectedTabID, file.id)
    }

    func testNewNoteLaunchWithEmptySessionAddsSingleTab() {
        writeSession([], selected: nil)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .newNote)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedTab?.content, "")
    }

    func testNewNoteLaunchDoesNothingOnFirstLaunch() {
        let fresh = TabStore(
            sessionURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json"),
            launchBehavior: .newNote
        )
        XCTAssertEqual(fresh.tabs.count, 1)
        XCTAssertEqual(fresh.tabs.first?.name, "Welcome to Itsypad")
    }

    func testReopenLastLaunchKeepsRestoredSelection() {
        let existing = TabData(name: "Notes", content: "some text")
        writeSession([existing], selected: existing.id)

        let restored = TabStore(sessionURL: tempURL, launchBehavior: .reopenLast)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedTabID, existing.id)
    }
}
