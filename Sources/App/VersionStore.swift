import CryptoKit
import Foundation

struct TabVersion: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case edit, paste, conflict, manual, restore }

    let id: String
    let tabID: UUID
    let parentID: String?
    let createdAt: Date
    let device: String
    var label: String?
    let text: String
    let source: Source

    /// Content-addressed: the same text in the same tab always maps to the
    /// same id, which is what makes cross-device dedupe work without a
    /// central authority.
    static func makeID(tabID: UUID, text: String) -> String {
        let digest = SHA256.hash(data: Data((tabID.uuidString + "\n" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    init(tabID: UUID, parentID: String?, createdAt: Date, device: String, label: String? = nil, text: String, source: Source) {
        self.id = Self.makeID(tabID: tabID, text: text)
        self.tabID = tabID
        self.parentID = parentID
        self.createdAt = createdAt
        self.device = device
        self.label = label
        self.text = text
        self.source = source
    }

    init(id: String, tabID: UUID, parentID: String?, createdAt: Date, device: String, label: String?, text: String, source: Source) {
        self.id = id
        self.tabID = tabID
        self.parentID = parentID
        self.createdAt = createdAt
        self.device = device
        self.label = label
        self.text = text
        self.source = source
    }

    var hasLabel: Bool {
        !(label ?? "").isEmpty
    }
}

enum VersionPrunePolicy {
    static let maxCount = 200
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
    static let bucket: TimeInterval = 600

    /// Keeps everything from the last hour, one version per 10-minute bucket
    /// between one hour and one day, one per calendar day beyond that, and at
    /// most `keepCount` overall (0 = unlimited). Unprotected versions older
    /// than `keepDays` days are dropped (0 = unlimited). The first, the latest
    /// and labelled versions are never dropped.
    static func idsToDrop(
        versions: [TabVersion],
        now: Date,
        keepCount: Int = maxCount,
        keepDays: Int = 0,
        calendar: Calendar = .current
    ) -> Set<String> {
        guard versions.count > 1 else { return [] }
        let sorted = versions.sorted { $0.createdAt > $1.createdAt }
        var protected = Set<String>()
        protected.insert(sorted.first!.id)
        protected.insert(sorted.last!.id)
        for version in sorted where version.hasLabel {
            protected.insert(version.id)
        }

        func bucketKey(_ version: TabVersion) -> String? {
            let age = now.timeIntervalSince(version.createdAt)
            if age < hour { return nil }
            if age < day { return "b\(Int(age / bucket))" }
            return "d\(calendar.startOfDay(for: version.createdAt).timeIntervalSinceReferenceDate)"
        }

        var dropped = Set<String>()
        var seenBuckets = Set<String>()
        for version in sorted where protected.contains(version.id) {
            if let key = bucketKey(version) {
                seenBuckets.insert(key)
            }
        }
        for version in sorted where !protected.contains(version.id) {
            guard let key = bucketKey(version) else { continue }
            if seenBuckets.contains(key) {
                dropped.insert(version.id)
            } else {
                seenBuckets.insert(key)
            }
        }

        if keepDays > 0 {
            let cutoff = TimeInterval(keepDays) * day
            for version in sorted where !protected.contains(version.id) && now.timeIntervalSince(version.createdAt) > cutoff {
                dropped.insert(version.id)
            }
        }

        var remaining = sorted.count - dropped.count
        if keepCount > 0, remaining > keepCount {
            for version in sorted.reversed() where !protected.contains(version.id) && !dropped.contains(version.id) {
                dropped.insert(version.id)
                remaining -= 1
                if remaining <= keepCount { break }
            }
        }
        return dropped
    }
}

final class VersionStore: ObservableObject {
    static let shared: VersionStore = {
        let store = VersionStore()
        store.onVersionChanged = { version in
            guard TabStore.shared.isScratchTab(version.tabID) else { return }
            CloudSyncEngine.shared.versionChanged(version.id)
        }
        store.onVersionDeleted = { version in
            guard TabStore.shared.isScratchTab(version.tabID) else { return }
            CloudSyncEngine.shared.versionDeleted(version.id)
        }
        return store
    }()

    @Published private(set) var changeCounter = 0

    /// Fired after a local mutation so the cloud mirror can follow. Cloud-applied
    /// changes (`applyCloud`/`removeCloud`) never fire them.
    var onVersionChanged: ((TabVersion) -> Void)?
    var onVersionDeleted: ((TabVersion) -> Void)?

    private let baseURL: URL
    // Per tab, in insertion order; `versions(for:)` sorts newest first.
    private var cache: [UUID: [TabVersion]] = [:]
    private var loadedAll = false

    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = appSupport.appendingPathComponent("Itsypad").appendingPathComponent("versions")
        }
        try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    // MARK: - Reading

    func versions(for tabID: UUID) -> [TabVersion] {
        let stored = load(tabID)
        return stored.reversed().sorted { $0.createdAt > $1.createdAt }
    }

    func latest(for tabID: UUID) -> TabVersion? {
        versions(for: tabID).first
    }

    func version(withID id: String) -> TabVersion? {
        if let found = cache.values.lazy.compactMap({ $0.first { $0.id == id } }).first {
            return found
        }
        guard !loadedAll else { return nil }
        loadAll()
        return cache.values.lazy.compactMap({ $0.first { $0.id == id } }).first
    }

    // MARK: - Local mutations

    @discardableResult
    func append(_ version: TabVersion) -> Bool {
        var stored = load(version.tabID)
        guard !stored.contains(where: { $0.id == version.id }) else { return false }
        stored.append(version)
        store(stored, for: version.tabID)
        onVersionChanged?(version)
        return true
    }

    func setLabel(_ label: String?, versionID: String, tabID: UUID) {
        var stored = load(tabID)
        guard let index = stored.firstIndex(where: { $0.id == versionID }) else { return }
        let normalized = (label ?? "").isEmpty ? nil : label
        guard stored[index].label != normalized else { return }
        stored[index].label = normalized
        store(stored, for: tabID)
        onVersionChanged?(stored[index])
    }

    /// Children of the deleted version are repointed to its parent so the
    /// chain stays connected; they re-sync as changed records.
    func delete(versionID: String, tabID: UUID) {
        var stored = load(tabID)
        guard let index = stored.firstIndex(where: { $0.id == versionID }) else { return }
        let removed = stored.remove(at: index)
        var repointed: [TabVersion] = []
        for childIndex in stored.indices where stored[childIndex].parentID == versionID {
            let child = stored[childIndex]
            stored[childIndex] = TabVersion(
                id: child.id,
                tabID: child.tabID,
                parentID: removed.parentID,
                createdAt: child.createdAt,
                device: child.device,
                label: child.label,
                text: child.text,
                source: child.source
            )
            repointed.append(stored[childIndex])
        }
        store(stored, for: tabID)
        onVersionDeleted?(removed)
        for child in repointed {
            onVersionChanged?(child)
        }
    }

    func deleteAll(tabID: UUID) {
        let stored = load(tabID)
        cache[tabID] = []
        try? FileManager.default.removeItem(at: fileURL(for: tabID))
        if !stored.isEmpty {
            changeCounter += 1
        }
        for version in stored {
            onVersionDeleted?(version)
        }
    }

    @discardableResult
    func prune(tabID: UUID, now: Date = Date(), keepCount: Int = VersionPrunePolicy.maxCount, keepDays: Int = 0) -> [String] {
        let stored = load(tabID)
        let drop = VersionPrunePolicy.idsToDrop(versions: stored, now: now, keepCount: keepCount, keepDays: keepDays)
        guard !drop.isEmpty else { return [] }
        let kept = stored.filter { !drop.contains($0.id) }
        store(kept, for: tabID)
        for version in stored where drop.contains(version.id) {
            onVersionDeleted?(version)
        }
        return Array(drop)
    }

    // MARK: - Cloud mirror

    /// Dedupes by id; an existing version only takes the server's label.
    func applyCloud(_ version: TabVersion) {
        var stored = load(version.tabID)
        if let index = stored.firstIndex(where: { $0.id == version.id }) {
            guard stored[index].label != version.label else { return }
            stored[index].label = version.label
        } else {
            stored.append(version)
        }
        store(stored, for: version.tabID)
    }

    func removeCloud(versionID: String, tabID: UUID) {
        var stored = load(tabID)
        guard let index = stored.firstIndex(where: { $0.id == versionID }) else { return }
        stored.remove(at: index)
        store(stored, for: tabID)
    }

    // MARK: - Persistence

    private func fileURL(for tabID: UUID) -> URL {
        baseURL.appendingPathComponent(tabID.uuidString).appendingPathExtension("json")
    }

    private func load(_ tabID: UUID) -> [TabVersion] {
        if let cached = cache[tabID] { return cached }
        let url = fileURL(for: tabID)
        var versions: [TabVersion] = []
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([TabVersion].self, from: data) {
                versions = decoded
            } else {
                // Same policy as restoreSession: keep the unreadable file so one
                // bad read never silently destroys a tab's history.
                try? data.write(to: url.appendingPathExtension("bak"), options: .atomic)
                NSLog("[VersionStore] decode failed for %@, backed up", tabID.uuidString)
            }
        }
        cache[tabID] = versions
        return versions
    }

    private func loadAll() {
        loadedAll = true
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let tabID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            _ = load(tabID)
        }
    }

    private func store(_ versions: [TabVersion], for tabID: UUID) {
        cache[tabID] = versions
        let url = fileURL(for: tabID)
        if versions.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            do {
                let data = try JSONEncoder().encode(versions)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[VersionStore] Failed to save versions for %@: %@", tabID.uuidString, String(describing: error))
            }
        }
        changeCounter += 1
    }
}
