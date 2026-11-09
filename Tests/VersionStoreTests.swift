import XCTest
@testable import ItsypadCore

final class VersionStoreTests: XCTestCase {
    private var baseURL: URL!
    private var store: VersionStore!
    private let tabID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-\(UUID().uuidString)")
        store = VersionStore(baseURL: baseURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseURL)
        store = nil
        super.tearDown()
    }

    private func make(_ text: String, tab: UUID? = nil, parent: String? = nil, at: Date? = nil,
                      label: String? = nil, source: TabVersion.Source = .edit) -> TabVersion {
        TabVersion(tabID: tab ?? tabID, parentID: parent, createdAt: at ?? now,
                   device: "Test Mac", label: label, text: text, source: source)
    }

    // MARK: - Identity

    func testIDIsStableForSameTabAndText() {
        XCTAssertEqual(TabVersion.makeID(tabID: tabID, text: "hello"), TabVersion.makeID(tabID: tabID, text: "hello"))
        XCTAssertEqual(TabVersion.makeID(tabID: tabID, text: "hello").count, 64)
        XCTAssertNil(UUID(uuidString: TabVersion.makeID(tabID: tabID, text: "hello")))
    }

    func testIDIsScopedPerTab() {
        XCTAssertNotEqual(TabVersion.makeID(tabID: tabID, text: "hello"), TabVersion.makeID(tabID: UUID(), text: "hello"))
        XCTAssertNotEqual(TabVersion.makeID(tabID: tabID, text: "hello"), TabVersion.makeID(tabID: tabID, text: "hello!"))
    }

    func testSourceRawValuesMatchSchema() {
        XCTAssertEqual(TabVersion.Source.edit.rawValue, "edit")
        XCTAssertEqual(TabVersion.Source.paste.rawValue, "paste")
        XCTAssertEqual(TabVersion.Source.conflict.rawValue, "conflict")
        XCTAssertEqual(TabVersion.Source.manual.rawValue, "manual")
        XCTAssertEqual(TabVersion.Source.restore.rawValue, "restore")
    }

    // MARK: - Append

    func testAppendDedupesByID() {
        XCTAssertTrue(store.append(make("a")))
        XCTAssertFalse(store.append(make("a", at: now.addingTimeInterval(60))))
        XCTAssertEqual(store.versions(for: tabID).count, 1)
    }

    func testVersionsAreNewestFirstAndLatestMatches() {
        store.append(make("one", at: now))
        store.append(make("two", at: now.addingTimeInterval(10)))
        store.append(make("three", at: now.addingTimeInterval(5)))
        XCTAssertEqual(store.versions(for: tabID).map(\.text), ["two", "three", "one"])
        XCTAssertEqual(store.latest(for: tabID)?.text, "two")
    }

    func testParentChainIsPreserved() {
        let first = make("one")
        store.append(first)
        let second = make("two", parent: first.id, at: now.addingTimeInterval(1))
        store.append(second)
        XCTAssertEqual(store.latest(for: tabID)?.parentID, first.id)
        XCTAssertNil(store.version(withID: first.id)?.parentID)
    }

    func testAppendFiresChangeHookAndCounter() {
        var changed: [String] = []
        store.onVersionChanged = { changed.append($0.id) }
        let version = make("a")
        store.append(version)
        store.append(version)
        XCTAssertEqual(changed, [version.id])
        XCTAssertEqual(store.changeCounter, 1)
    }

    func testVersionsAreScopedPerTab() {
        let other = UUID()
        store.append(make("a"))
        store.append(make("a", tab: other))
        XCTAssertEqual(store.versions(for: tabID).count, 1)
        XCTAssertEqual(store.versions(for: other).count, 1)
        XCTAssertNotEqual(store.versions(for: tabID).first?.id, store.versions(for: other).first?.id)
    }

    // MARK: - Persistence

    func testPersistsAcrossInstances() {
        store.append(make("persisted", label: "Draft"))
        let reloaded = VersionStore(baseURL: baseURL)
        let versions = reloaded.versions(for: tabID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.text, "persisted")
        XCTAssertEqual(versions.first?.label, "Draft")
        XCTAssertEqual(versions.first?.device, "Test Mac")
    }

    func testVersionWithIDSearchesAllTabsOnDisk() {
        let other = UUID()
        let version = make("elsewhere", tab: other)
        store.append(version)
        let reloaded = VersionStore(baseURL: baseURL)
        XCTAssertEqual(reloaded.version(withID: version.id)?.tabID, other)
        XCTAssertNil(reloaded.version(withID: "missing"))
    }

    func testCorruptFileIsBackedUpAndTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let file = baseURL.appendingPathComponent(tabID.uuidString).appendingPathExtension("json")
        try Data("not json".utf8).write(to: file)
        let reloaded = VersionStore(baseURL: baseURL)
        XCTAssertTrue(reloaded.versions(for: tabID).isEmpty)
        let backup = file.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "not json")
        reloaded.append(make("fresh"))
        XCTAssertEqual(VersionStore(baseURL: baseURL).versions(for: tabID).count, 1)
    }

    // MARK: - Label, delete

    func testSetLabelPersistsAndFiresHook() {
        let version = make("a")
        store.append(version)
        var changed: [String] = []
        store.onVersionChanged = { changed.append($0.label ?? "") }
        store.setLabel("Milestone", versionID: version.id, tabID: tabID)
        XCTAssertEqual(store.latest(for: tabID)?.label, "Milestone")
        XCTAssertEqual(VersionStore(baseURL: baseURL).latest(for: tabID)?.label, "Milestone")
        store.setLabel("", versionID: version.id, tabID: tabID)
        XCTAssertNil(store.latest(for: tabID)?.label)
        XCTAssertEqual(changed, ["Milestone", ""])
    }

    func testDeleteRemovesOneVersion() {
        let a = make("a")
        let b = make("b", at: now.addingTimeInterval(1))
        store.append(a)
        store.append(b)
        var deleted: [String] = []
        store.onVersionDeleted = { deleted.append($0.id) }
        store.delete(versionID: a.id, tabID: tabID)
        XCTAssertEqual(store.versions(for: tabID).map(\.id), [b.id])
        XCTAssertEqual(deleted, [a.id])
    }

    func testDeleteRepointsChildrenToParentAndFiresChanged() {
        let a = make("a")
        let b = make("b", parent: a.id, at: now.addingTimeInterval(1))
        let c = make("c", parent: b.id, at: now.addingTimeInterval(2))
        store.append(a)
        store.append(b)
        store.append(c)
        var changed: [String] = []
        store.onVersionChanged = { changed.append($0.id) }
        var deleted: [String] = []
        store.onVersionDeleted = { deleted.append($0.id) }

        store.delete(versionID: b.id, tabID: tabID)

        XCTAssertEqual(store.version(withID: c.id)?.parentID, a.id)
        XCTAssertEqual(changed, [c.id])
        XCTAssertEqual(deleted, [b.id])
        XCTAssertEqual(VersionStore(baseURL: baseURL).version(withID: c.id)?.parentID, a.id)
    }

    func testDeleteAllRemovesFileAndFiresPerVersion() {
        store.append(make("a"))
        store.append(make("b"))
        var deleted = 0
        store.onVersionDeleted = { _ in deleted += 1 }
        store.deleteAll(tabID: tabID)
        XCTAssertTrue(store.versions(for: tabID).isEmpty)
        XCTAssertEqual(deleted, 2)
        let file = baseURL.appendingPathComponent(tabID.uuidString).appendingPathExtension("json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(VersionStore(baseURL: baseURL).versions(for: tabID).isEmpty)
    }

    // MARK: - Cloud

    func testApplyCloudDedupesAndTakesServerLabel() {
        var changed = 0
        store.onVersionChanged = { _ in changed += 1 }
        let local = make("a")
        store.append(local)
        var remote = local
        remote.label = "From iPhone"
        store.applyCloud(remote)
        XCTAssertEqual(store.versions(for: tabID).count, 1)
        XCTAssertEqual(store.latest(for: tabID)?.label, "From iPhone")
        XCTAssertEqual(changed, 1)
    }

    func testApplyCloudInsertsUnknownVersionWithoutHook() {
        var changed = 0
        store.onVersionChanged = { _ in changed += 1 }
        store.applyCloud(make("remote"))
        XCTAssertEqual(store.versions(for: tabID).count, 1)
        XCTAssertEqual(changed, 0)
    }

    func testRemoveCloudDeletesWithoutHook() {
        let version = make("a")
        store.append(version)
        var deleted = 0
        store.onVersionDeleted = { _ in deleted += 1 }
        store.removeCloud(versionID: version.id, tabID: tabID)
        XCTAssertTrue(store.versions(for: tabID).isEmpty)
        XCTAssertEqual(deleted, 0)
    }

    // MARK: - Prune policy

    private func versions(ages: [TimeInterval], labelAt: Set<Int> = []) -> [TabVersion] {
        ages.enumerated().map { index, age in
            make("v\(index)", at: now.addingTimeInterval(-age), label: labelAt.contains(index) ? "Keep" : nil)
        }
    }

    func testPruneKeepsEverythingFromTheLastHour() {
        let list = versions(ages: [0, 10, 20, 30, 1_000, 3_000, 3_599])
        XCTAssertTrue(VersionPrunePolicy.idsToDrop(versions: list, now: now).isEmpty)
    }

    func testPruneKeepsOnePerTenMinuteBucketBetweenOneHourAndOneDay() {
        // Three versions in the 2h00–2h10 bucket, two in the 2h10–2h20 bucket
        let list = versions(ages: [0, 7_210, 7_400, 7_700, 7_900, 8_300, 100_000])
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now)
        XCTAssertEqual(drop, [list[2].id, list[3].id, list[5].id])
    }

    func testPruneKeepsOnePerCalendarDayBeyondOneDay() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-3 * 86_400))
        let sameDay = [dayStart.addingTimeInterval(3_600), dayStart.addingTimeInterval(7_200), dayStart.addingTimeInterval(10_800)]
        let otherDay = dayStart.addingTimeInterval(-86_400 + 3_600)
        let list = [make("latest", at: now)]
            + sameDay.enumerated().map { make("d\($0.offset)", at: $0.element) }
            + [make("other", at: otherDay)]
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now, calendar: calendar)
        XCTAssertEqual(drop, [list[1].id, list[2].id])
    }

    func testPruneNeverDropsFirstLatestOrLabelled() {
        let list = versions(ages: [0, 7_210, 7_400, 7_700, 200_000, 200_100, 200_200], labelAt: [3, 5])
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now)
        XCTAssertFalse(drop.contains(list[0].id))
        XCTAssertFalse(drop.contains(list[3].id))
        XCTAssertFalse(drop.contains(list[5].id))
        XCTAssertFalse(drop.contains(list[6].id))
        XCTAssertTrue(drop.contains(list[2].id))
        XCTAssertTrue(drop.contains(list[4].id))
    }

    func testPruneKeepCountLimitsAndZeroIsUnlimited() {
        let list = (0..<20).map { make("v\($0)", at: now.addingTimeInterval(-Double($0))) }
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now, keepCount: 10)
        XCTAssertEqual(drop.count, 10)
        XCTAssertFalse(drop.contains(list[0].id))
        XCTAssertFalse(drop.contains(list[19].id))
        let big = (0..<250).map { make("b\($0)", at: now.addingTimeInterval(-Double($0))) }
        XCTAssertTrue(VersionPrunePolicy.idsToDrop(versions: big, now: now, keepCount: 0).isEmpty)
    }

    func testPruneKeepDaysDropsOldButProtectsFirstLatestLabelled() {
        let day = 86_400.0
        let list = [
            make("latest", at: now),
            make("recent", at: now.addingTimeInterval(-3 * day)),
            make("old1", at: now.addingTimeInterval(-10 * day)),
            make("oldLabelled", at: now.addingTimeInterval(-11 * day), label: "Keep"),
            make("old2", at: now.addingTimeInterval(-12 * day)),
            make("first", at: now.addingTimeInterval(-20 * day))
        ]
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now, keepCount: 0, keepDays: 7)
        XCTAssertEqual(drop, [list[2].id, list[4].id])
    }

    func testPruneCapsAtTwoHundred() {
        let list = (0..<250).map { make("v\($0)", at: now.addingTimeInterval(-Double($0))) }
        let drop = VersionPrunePolicy.idsToDrop(versions: list, now: now)
        XCTAssertEqual(drop.count, 50)
        XCTAssertFalse(drop.contains(list[0].id))
        XCTAssertFalse(drop.contains(list[249].id))
        XCTAssertTrue(drop.contains(list[248].id))
        XCTAssertFalse(drop.contains(list[198].id))
    }

    func testPruneOnStoreRemovesAndFiresDeleteHook() {
        for version in versions(ages: [0, 7_210, 7_400, 100_000]) {
            store.append(version)
        }
        var deleted: [String] = []
        store.onVersionDeleted = { deleted.append($0.text) }
        let dropped = store.prune(tabID: tabID, now: now)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(deleted, ["v2"])
        XCTAssertEqual(store.versions(for: tabID).map(\.text), ["v0", "v1", "v3"])
    }
}
