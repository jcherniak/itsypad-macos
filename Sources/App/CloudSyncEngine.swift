import CloudKit
import Foundation
import os.log

struct CloudTabRecord {
    let id: UUID
    var name: String
    var content: String
    var language: String
    var languageLocked: Bool
    var lastModified: Date
    var headVersionID: String? = nil
    var deletedAt: Date? = nil
    var deletedOn: String? = nil
}

struct CloudClipboardRecord {
    let id: UUID
    var text: String
    var timestamp: Date
}

/// All mutable state (recordMetadata, syncEngine, container) is
/// confined to the main thread: the public API asserts main, and CKSyncEngine
/// delegate callbacks hop to the main actor before touching anything. That
/// confinement is what justifies `@unchecked Sendable` (required by
/// CKSyncEngineDelegate).
final class CloudSyncEngine: @unchecked Sendable {
    static let shared = CloudSyncEngine()

    enum RecordType: String {
        case scratchTab = "ScratchTab"
        case clipboardEntry = "ClipboardEntry"
        case tabVersion = "TabVersion"
    }

    private static let containerID = "iCloud." + (Bundle.main.bundleIdentifier ?? "com.justinc.itsypad")
    private static let zoneName = "ItsypadData"

    /// Bump this to force a full re-sync (clears stale metadata and change tokens).
    private static let syncVersion = 2

    // Lazy CloudKit objects – only created when start() is called
    private var container: CKContainer?
    private var database: CKDatabase?
    private let zoneID = CKRecordZone.ID(zoneName: CloudSyncEngine.zoneName)

    private var syncEngine: CKSyncEngine?
    private let stateURL: URL
    private let metadataURL: URL

    // Cache of last-known server record data (system fields) per record ID, for conflict detection
    private var recordMetadata: [String: Data] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.justinc.itsypad", category: "CloudSync")

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let itsypadDir = appSupport.appendingPathComponent("Itsypad")
        try? FileManager.default.createDirectory(at: itsypadDir, withIntermediateDirectories: true)
        stateURL = itsypadDir.appendingPathComponent("cloud-sync-state.data")
        metadataURL = itsypadDir.appendingPathComponent("cloud-record-metadata.json")

        loadRecordMetadata()
    }

    /// Call after app launch to start sync if the user has it enabled.
    func startIfEnabled() {
        if SettingsStore.shared.icloudSync {
            start()
        }
    }

    // MARK: - Public API

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard syncEngine == nil else { return }

        // CKContainer traps if CloudKit entitlement is missing (e.g. in unit tests)
        guard Self.hasCloudKitEntitlement else { return }

        if container == nil {
            let ckContainer = CKContainer(identifier: Self.containerID)
            container = ckContainer
            database = ckContainer.privateCloudDatabase
        }

        guard let database else { return }

        // Detect first sync: either no metadata, or sync version bumped (e.g. dev→prod migration).
        let storedVersion = UserDefaults.standard.integer(forKey: "cloudSyncVersion")
        let versionMismatch = storedVersion < Self.syncVersion
        let isFirstSync = recordMetadata.isEmpty || versionMismatch
        if isFirstSync {
            if versionMismatch {
                logger.info("Sync version bumped (\(storedVersion) → \(Self.syncVersion)) – clearing state for full re-sync")
                recordMetadata.removeAll()
                saveRecordMetadata()
                UserDefaults.standard.set(Self.syncVersion, forKey: "cloudSyncVersion")
            }
            try? FileManager.default.removeItem(at: stateURL)
        }

        let stateSerialization = isFirstSync ? nil : loadStateSerialization()
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = true
        syncEngine = CKSyncEngine(configuration)

        if isFirstSync {
            syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            reuploadAllRecords()
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.fetchChanges()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        pollTimer?.invalidate()
        pollTimer = nil
        syncEngine = nil
        recordMetadata.removeAll()
        flushRecordMetadata()
        logger.info("CloudSyncEngine stopped")
    }

    func recordChanged(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let engine = syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    func fetchChanges() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let engine = syncEngine else {
            return
        }
        Task {
            do {
                try await engine.fetchChanges()
            } catch {
            }
        }
    }

    func recordDeleted(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let engine = syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    /// Version ids are SHA-256 hex, never UUIDs – that is how
    /// nextRecordZoneChangeBatch tells them apart from tab/clipboard records.
    func versionChanged(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let engine = syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    func versionDeleted(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let engine = syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    // MARK: - State persistence

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Failed to save sync state: \(error)")
        }
    }

    // MARK: - Record metadata cache

    private func loadRecordMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else { return }
        recordMetadata = decoded
    }

    /// Debounced: the metadata dictionary can hold thousands of entries and is
    /// touched once per record during a sync batch – encoding and writing the
    /// whole file per record would dominate sync time. A crash inside the
    /// debounce window only loses change tags, which the conflict handler
    /// recovers on the next save.
    private var metadataSaveWork: DispatchWorkItem?

    /// Poll fallback: development/Developer ID builds without a push-enabled
    /// provisioning profile never receive CloudKit silent pushes, so an idle
    /// foreground app would only sync on activation. Fetches are change-token
    /// based and cheap when nothing changed.
    /// ponytail: 20s poll – remove if APNs registration is confirmed working
    /// across all distribution channels.
    private var pollTimer: Timer?

    private func saveRecordMetadata() {
        metadataSaveWork?.cancel()
        let snapshot = recordMetadata
        let url = metadataURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        metadataSaveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write pending metadata immediately. The debounced save is lost if the
    /// process quits inside the window – a stale/empty metadata file makes the
    /// next launch look like a first sync and re-uploads everything.
    func flushRecordMetadata() {
        metadataSaveWork?.cancel()
        metadataSaveWork = nil
        guard let data = try? JSONEncoder().encode(recordMetadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func cacheRecordSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        recordMetadata[record.recordID.recordName] = coder.encodedData
        saveRecordMetadata()
    }

    private func cachedRecord(for recordID: CKRecord.ID, recordType: String) -> CKRecord {
        if let data = recordMetadata[recordID.recordName],
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            if let record = CKRecord(coder: coder) {
                return record
            }
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private func removeRecordMetadata(for recordID: CKRecord.ID) {
        recordMetadata.removeValue(forKey: recordID.recordName)
        saveRecordMetadata()
    }

    // MARK: - Record building

    private func buildScratchTabRecord(id: UUID, recordID: CKRecord.ID) -> CKRecord? {
        guard let tab = TabStore.shared.tab(withID: id), tab.fileURL == nil else { return nil }
        let record = cachedRecord(for: recordID, recordType: RecordType.scratchTab.rawValue)
        Self.fillScratchTabRecord(record, from: tab)
        return record
    }

    static func fillScratchTabRecord(_ record: CKRecord, from tab: TabData) {
        record["name"] = tab.name as CKRecordValue
        record["content"] = tab.content as CKRecordValue
        record["language"] = tab.language as CKRecordValue
        record["languageLocked"] = (tab.languageLocked ? 1 : 0) as CKRecordValue
        record["lastModified"] = tab.lastModified as CKRecordValue
        record["headVersionID"] = tab.headVersionID.map { $0 as CKRecordValue }
        record["deletedAt"] = tab.deletedAt.map { $0 as CKRecordValue }
        record["deletedOn"] = tab.deletedOn.map { $0 as CKRecordValue }
    }

    private func buildClipboardEntryRecord(id: UUID, recordID: CKRecord.ID) -> CKRecord? {
        guard let entry = ClipboardStore.shared.entries.first(where: { $0.id == id && $0.kind == .text }) else { return nil }
        guard let text = entry.text else { return nil }
        let record = cachedRecord(for: recordID, recordType: RecordType.clipboardEntry.rawValue)
        record["text"] = text as CKRecordValue
        record["timestamp"] = entry.timestamp as CKRecordValue
        return record
    }

    private func buildTabVersionRecord(id: String, recordID: CKRecord.ID) -> CKRecord? {
        guard let version = VersionStore.shared.version(withID: id),
              TabStore.shared.isScratchTab(version.tabID) else { return nil }
        let record = cachedRecord(for: recordID, recordType: RecordType.tabVersion.rawValue)
        record["tabID"] = version.tabID.uuidString as CKRecordValue
        record["parentID"] = version.parentID.map { $0 as CKRecordValue }
        record["createdAt"] = version.createdAt as CKRecordValue
        record["device"] = version.device as CKRecordValue
        record["label"] = version.label.map { $0 as CKRecordValue }
        record["text"] = version.text as CKRecordValue
        record["source"] = version.source.rawValue as CKRecordValue
        return record
    }

    // MARK: - Incoming changes

    private func applyFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        // Versions first: a tab merge needs the remote head version to find
        // its base, and both usually arrive in the same batch.
        let modifications = event.modifications.sorted { lhs, _ in
            lhs.record.recordType == RecordType.tabVersion.rawValue
        }
        for modification in modifications {
            let record = modification.record
            cacheRecordSystemFields(record)

            switch record.recordType {
            case RecordType.scratchTab.rawValue:
                applyScratchTabRecord(record)
            case RecordType.clipboardEntry.rawValue:
                applyClipboardEntryRecord(record)
            case RecordType.tabVersion.rawValue:
                applyTabVersionRecord(record)
            default:
                logger.warning("Unknown record type: \(record.recordType)")
            }
        }

        for deletion in event.deletions {
            let id = deletion.recordID.recordName
            removeRecordMetadata(for: deletion.recordID)

            if deletion.recordType == RecordType.tabVersion.rawValue {
                if let version = VersionStore.shared.version(withID: id) {
                    VersionStore.shared.removeCloud(versionID: id, tabID: version.tabID)
                }
                continue
            }

            guard let uuid = UUID(uuidString: id) else { continue }

            switch deletion.recordType {
            case RecordType.scratchTab.rawValue:
                TabStore.shared.removeCloudTab(id: uuid)
            case RecordType.clipboardEntry.rawValue:
                ClipboardStore.shared.removeCloudClipboardEntry(id: uuid)
            default:
                break
            }
        }
    }

    private func applyScratchTabRecord(_ record: CKRecord) {
        guard let tabRecord = Self.scratchTabRecord(from: record) else {
            logger.error("Malformed ScratchTab record: \(record.recordID)")
            return
        }
        TabStore.shared.applyCloudTab(tabRecord)
    }

    static func scratchTabRecord(from record: CKRecord) -> CloudTabRecord? {
        guard let name = record["name"] as? String,
              let content = record["content"] as? String,
              let language = record["language"] as? String,
              let lastModified = record["lastModified"] as? Date,
              let uuid = UUID(uuidString: record.recordID.recordName) else {
            return nil
        }
        let languageLocked = (record["languageLocked"] as? Int64 ?? 0) != 0
        return CloudTabRecord(
            id: uuid,
            name: name,
            content: content,
            language: language,
            languageLocked: languageLocked,
            lastModified: lastModified,
            headVersionID: record["headVersionID"] as? String,
            deletedAt: record["deletedAt"] as? Date,
            deletedOn: record["deletedOn"] as? String
        )
    }

    private func applyClipboardEntryRecord(_ record: CKRecord) {
        guard let text = record["text"] as? String,
              let timestamp = record["timestamp"] as? Date else {
            logger.error("Malformed ClipboardEntry record: \(record.recordID)")
            return
        }
        guard let uuid = UUID(uuidString: record.recordID.recordName) else { return }

        let clipboardRecord = CloudClipboardRecord(id: uuid, text: text, timestamp: timestamp)
        ClipboardStore.shared.applyCloudClipboardEntry(clipboardRecord)
    }

    private func applyTabVersionRecord(_ record: CKRecord) {
        guard let tabIDString = record["tabID"] as? String,
              let tabID = UUID(uuidString: tabIDString),
              let createdAt = record["createdAt"] as? Date,
              let device = record["device"] as? String,
              let text = record["text"] as? String,
              let sourceRaw = record["source"] as? String,
              let source = TabVersion.Source(rawValue: sourceRaw) else {
            logger.error("Malformed TabVersion record: \(record.recordID)")
            return
        }
        let version = TabVersion(
            id: record.recordID.recordName,
            tabID: tabID,
            parentID: record["parentID"] as? String,
            createdAt: createdAt,
            device: device,
            label: record["label"] as? String,
            text: text,
            source: source
        )
        VersionStore.shared.applyCloud(version)
    }

    // MARK: - Conflict resolution

    /// Adopts the server's change tag and merges the server content through
    /// the same snapshot/merge/keep-both logic as a fetched record. Returns
    /// true when the text we keep differs from the server's, so the merged or
    /// kept local text is re-uploaded; re-saving identical content would only
    /// churn the record.
    private func resolveTabConflict(server serverRecord: CKRecord) -> Bool {
        cacheRecordSystemFields(serverRecord)
        return Self.mergeServerTab(serverRecord, into: TabStore.shared)
    }

    static func mergeServerTab(_ serverRecord: CKRecord, into tabStore: TabStore) -> Bool {
        guard let data = scratchTabRecord(from: serverRecord) else { return false }
        tabStore.applyCloudTab(data)
        guard let tab = tabStore.tab(withID: data.id) else { return false }
        return tab.content != data.content || (tab.deletedAt == nil) != (data.deletedAt == nil)
    }

    private func resolveClipboardConflict(local record: CKRecord, server serverRecord: CKRecord) {
        // Clipboard entries are append-only; server wins
        cacheRecordSystemFields(serverRecord)
        applyClipboardEntryRecord(serverRecord)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run {
            processEvent(event, syncEngine: syncEngine)
        }
    }

    @MainActor
    private func processEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveStateSerialization(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            logger.info("Account change: \(String(describing: accountChange.changeType))")
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let event):
            handleFetchedDatabaseChanges(event)

        case .fetchedRecordZoneChanges(let event):
            logger.info("Fetched \(event.modifications.count) changes, \(event.deletions.count) deletions")
            applyFetchedChanges(event)

        case .sentRecordZoneChanges(let event):
            handleSentRecordZoneChanges(event)

        case .sentDatabaseChanges(let event):
            for failedZone in event.failedZoneSaves {
                logger.error("Failed zone save: code=\(failedZone.error.code.rawValue) \(failedZone.error.localizedDescription)")
            }

        case .didFetchChanges:
            TabStore.shared.lastICloudSync = Date()

        case .didSendChanges:
            TabStore.shared.lastICloudSync = Date()

        case .willFetchChanges, .willSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        // Snapshot record content on the main actor – TabStore/ClipboardStore
        // and recordMetadata are main-thread state
        let records: [CKRecord.ID: CKRecord] = await MainActor.run {
            var map = [CKRecord.ID: CKRecord]()
            for change in changes {
                guard case .saveRecord(let recordID) = change else { continue }
                let record: CKRecord?
                if let uuid = UUID(uuidString: recordID.recordName) {
                    record = buildScratchTabRecord(id: uuid, recordID: recordID)
                        ?? buildClipboardEntryRecord(id: uuid, recordID: recordID)
                } else {
                    record = buildTabVersionRecord(id: recordID.recordName, recordID: recordID)
                }
                if let record {
                    map[recordID] = record
                }
            }
            return map
        }

        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            if let record = records[recordID] {
                return record
            }
            // Record no longer exists locally; remove from pending
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return batch
    }

    // MARK: - Event handlers

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            reuploadAllRecords()

        case .switchAccounts:
            clearLocalCloudState()

        case .signOut:
            clearLocalCloudState()

        @unknown default:
            break
        }
    }

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in event.deletions {
            if deletion.zoneID == zoneID {
                clearLocalCloudState()
            }
        }
    }

    private func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        var newPendingRecordZoneChanges = [CKSyncEngine.PendingRecordZoneChange]()
        var newPendingDatabaseChanges = [CKSyncEngine.PendingDatabaseChange]()

        for savedRecord in event.savedRecords {
            cacheRecordSystemFields(savedRecord)
        }

        for failedSave in event.failedRecordSaves {
            let failedRecord = failedSave.record

            switch failedSave.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failedSave.error.serverRecord else { continue }

                switch failedRecord.recordType {
                case RecordType.scratchTab.rawValue:
                    if resolveTabConflict(server: serverRecord) {
                        newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
                    }
                case RecordType.clipboardEntry.rawValue:
                    // Server wins, entries are immutable – nothing to re-push
                    resolveClipboardConflict(local: failedRecord, server: serverRecord)
                case RecordType.tabVersion.rawValue:
                    // Versions are immutable too – server wins
                    cacheRecordSystemFields(serverRecord)
                    applyTabVersionRecord(serverRecord)
                default:
                    break
                }

            case .zoneNotFound:
                let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
                newPendingDatabaseChanges.append(.saveZone(zone))
                newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
                removeRecordMetadata(for: failedRecord.recordID)

            case .unknownItem:
                newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
                removeRecordMetadata(for: failedRecord.recordID)

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled:
                break

            default:
                logger.error("Unhandled save error: \(failedSave.error)")
            }
        }

        if !newPendingDatabaseChanges.isEmpty {
            syncEngine?.state.add(pendingDatabaseChanges: newPendingDatabaseChanges)
        }
        if !newPendingRecordZoneChanges.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: newPendingRecordZoneChanges)
        }
    }

    // MARK: - Helpers

    private func reuploadAllRecords() {
        let scratchTabs = TabStore.shared.tabs.filter { $0.fileURL == nil } + TabStore.shared.trashedTabs
        let tabChanges: [CKSyncEngine.PendingRecordZoneChange] = scratchTabs
            .map { .saveRecord(CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)) }

        let clipboardChanges: [CKSyncEngine.PendingRecordZoneChange] = ClipboardStore.shared.entries
            .filter { $0.kind == .text }
            .map { .saveRecord(CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)) }

        let versionChanges: [CKSyncEngine.PendingRecordZoneChange] = scratchTabs
            .flatMap { VersionStore.shared.versions(for: $0.id) }
            .map { .saveRecord(CKRecord.ID(recordName: $0.id, zoneID: zoneID)) }

        logger.info("Re-uploading \(tabChanges.count) tabs, \(clipboardChanges.count) clipboard entries, \(versionChanges.count) versions")
        syncEngine?.state.add(pendingRecordZoneChanges: tabChanges + clipboardChanges + versionChanges)
    }

    private func clearLocalCloudState() {
        recordMetadata.removeAll()
        saveRecordMetadata()
        try? FileManager.default.removeItem(at: stateURL)
    }

    private static let hasCloudKitEntitlement: Bool = {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }()
}
