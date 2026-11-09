import XCTest
import CloudKit
@testable import ItsypadCore

final class CloudSyncEngineTests: XCTestCase {

    // MARK: - CloudTabRecord

    func testCloudTabRecordHoldsAllFields() {
        let id = UUID()
        let now = Date()
        let record = CloudTabRecord(
            id: id,
            name: "Test",
            content: "hello",
            language: "swift",
            languageLocked: true,
            lastModified: now
        )
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.name, "Test")
        XCTAssertEqual(record.content, "hello")
        XCTAssertEqual(record.language, "swift")
        XCTAssertTrue(record.languageLocked)
        XCTAssertEqual(record.lastModified, now)
        XCTAssertNil(record.headVersionID)
    }

    // MARK: - ScratchTab record fields

    private func scratchTabRecord(id: UUID, content: String, headVersionID: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: "ScratchTab", recordID: CKRecord.ID(recordName: id.uuidString))
        record["name"] = "Remote" as CKRecordValue
        record["content"] = content as CKRecordValue
        record["language"] = "plain" as CKRecordValue
        record["languageLocked"] = 0 as CKRecordValue
        record["lastModified"] = Date() as CKRecordValue
        record["headVersionID"] = headVersionID.map { $0 as CKRecordValue }
        return record
    }

    func testScratchTabRecordRoundTripsHeadVersionID() {
        let tab = TabData(name: "Note", content: "hello", language: "swift", languageLocked: true, headVersionID: "abc123")
        let record = CKRecord(recordType: "ScratchTab", recordID: CKRecord.ID(recordName: tab.id.uuidString))
        CloudSyncEngine.fillScratchTabRecord(record, from: tab)
        XCTAssertEqual(record["headVersionID"] as? String, "abc123")

        let parsed = CloudSyncEngine.scratchTabRecord(from: record)
        XCTAssertEqual(parsed?.id, tab.id)
        XCTAssertEqual(parsed?.content, "hello")
        XCTAssertEqual(parsed?.language, "swift")
        XCTAssertEqual(parsed?.languageLocked, true)
        XCTAssertEqual(parsed?.headVersionID, "abc123")
    }

    func testScratchTabRecordWithoutHeadParsesAsNil() {
        let parsed = CloudSyncEngine.scratchTabRecord(from: scratchTabRecord(id: UUID(), content: "x"))
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.headVersionID)
        XCTAssertNil(CloudSyncEngine.scratchTabRecord(from: CKRecord(recordType: "ScratchTab")))
    }

    // MARK: - Conflict resolution

    private func makeTabStore() -> TabStore {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let versionsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sessionURL)
            try? FileManager.default.removeItem(at: versionsURL)
        }
        let store = TabStore(sessionURL: sessionURL, versionStore: VersionStore(baseURL: versionsURL))
        store.scheduleSnapshot = { _, _ in }
        return store
    }

    func testMergeServerTabRePushesKeptLocalTextOnly() {
        let store = makeTabStore()
        store.addNewTab()
        let id = store.tabs.last!.id
        store.updateContent(id: id, content: "local text")

        XCTAssertTrue(CloudSyncEngine.mergeServerTab(scratchTabRecord(id: id, content: "server text"), into: store))
        XCTAssertEqual(store.tabs.last?.content, "local text")
        XCTAssertTrue(store.tabs.last!.hasConflict)

        XCTAssertFalse(CloudSyncEngine.mergeServerTab(scratchTabRecord(id: id, content: "local text"), into: store))
    }

    func testMergeServerTabRePushesMergedText() {
        let store = makeTabStore()
        store.addNewTab()
        let id = store.tabs.last!.id
        store.updateContent(id: id, content: "one\ntwo\nthree")
        store.flushPendingVersions()
        let baseID = store.versionStore.latest(for: id)!.id
        store.updateContent(id: id, content: "ONE\ntwo\nthree")

        let server = scratchTabRecord(id: id, content: "one\ntwo\nTHREE", headVersionID: baseID)
        XCTAssertTrue(CloudSyncEngine.mergeServerTab(server, into: store))
        XCTAssertEqual(store.tabs.last?.content, "ONE\ntwo\nTHREE")
        XCTAssertFalse(store.tabs.last!.hasConflict)
    }

    func testMergeServerTabFastForwardDoesNotRePush() {
        let store = makeTabStore()
        store.addNewTab()
        let id = store.tabs.last!.id
        store.updateContent(id: id, content: "shared")
        store.flushPendingVersions()
        let headID = store.versionStore.latest(for: id)!.id

        let server = scratchTabRecord(id: id, content: "shared and more", headVersionID: headID)
        XCTAssertFalse(CloudSyncEngine.mergeServerTab(server, into: store))
        XCTAssertEqual(store.tabs.last?.content, "shared and more")
    }

    // MARK: - CloudClipboardRecord

    func testCloudClipboardRecordHoldsAllFields() {
        let id = UUID()
        let now = Date()
        let record = CloudClipboardRecord(id: id, text: "copied text", timestamp: now)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.text, "copied text")
        XCTAssertEqual(record.timestamp, now)
    }

    // MARK: - RecordType raw values

    func testRecordTypeRawValues() {
        XCTAssertEqual(CloudSyncEngine.RecordType.scratchTab.rawValue, "ScratchTab")
        XCTAssertEqual(CloudSyncEngine.RecordType.clipboardEntry.rawValue, "ClipboardEntry")
        XCTAssertEqual(CloudSyncEngine.RecordType.tabVersion.rawValue, "TabVersion")
    }
}
