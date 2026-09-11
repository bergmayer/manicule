import Foundation

/// A last-writer-wins record set. Missing keys are not deletions: a dated nil
/// value is retained so an offline device cannot resurrect a removed bookmark.
/// The revision breaks equal-clock ties consistently on every device.
struct SyncedCollection<Value: Codable & Equatable & Identifiable>: Codable where Value.ID == String {
    struct Membership: Codable, Equatable, Comparable, Sendable {
        let modified: Date
        let revision: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.modified, lhs.revision) < (rhs.modified, rhs.revision)
        }
    }

    struct Record: Codable, Equatable {
        var value: Value?
        var modified: Date
        var revision: String
        var membership: Membership?
        var membershipVersion: Membership {
            membership ?? Membership(modified: modified, revision: revision)
        }
    }

    private(set) var records: [String: Record] = [:]
    var values: [Value] { records.keys.sorted().compactMap { records[$0]?.value } }

    func membership(for id: String) -> Membership? {
        guard let record = records[id], record.value != nil else { return nil }
        return record.membershipVersion
    }

    mutating func replace(with values: [Value], now: Date = Date()) {
        let desired = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in Set(records.keys).union(desired.keys) where records[id]?.value != desired[id] {
            // A user action must supersede the version this device has observed,
            // even if the wall clock moved backwards since that version arrived.
            let modified = max(now, (records[id]?.modified ?? .distantPast).addingTimeInterval(0.001))
            let revision = UUID().uuidString
            let membership = records[id]?.value == nil || desired[id] == nil
                ? Membership(modified: modified, revision: revision)
                : records[id]?.membershipVersion
            records[id] = Record(value: desired[id], modified: modified, revision: revision, membership: membership)
        }
    }

    @discardableResult
    mutating func update(_ value: Value, membership: Membership, now: Date = Date()) -> Bool {
        guard self.membership(for: value.id) == membership else { return false }
        replace(with: values.map { $0.id == value.id ? value : $0 }, now: now)
        return true
    }

    mutating func merge(_ other: Self) {
        for (id, remote) in other.records {
            if let local = records[id] {
                if local.membershipVersion > remote.membershipVersion { continue }
                if local.membershipVersion == remote.membershipVersion,
                   (local.modified, local.revision) >= (remote.modified, remote.revision) { continue }
            }
            records[id] = remote
        }
    }

    static func decode(_ data: Data, legacyDate: (Value) -> Date) throws -> Self {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Self.self, from: data) {
            guard envelope.records.allSatisfy({ id, record in
                (record.value == nil || record.value?.id == id) && record.modified.timeIntervalSince1970.isFinite
                    && record.membershipVersion.modified.timeIntervalSince1970.isFinite
            }) else { throw CocoaError(.coderReadCorrupt) }
            return envelope
        }
        let legacy = try decoder.decode([Value].self, from: data)
        var result = Self()
        for value in legacy {
            result.records[value.id] = Record(value: value, modified: legacyDate(value), revision: "legacy", membership: nil)
        }
        return result
    }
}

/// Device-local recovery and cloud merging share the same serialized records.
/// Invalid remote bytes are left untouched; local changes remain recoverable.
@MainActor
final class SyncedCollectionStorage<Value: Codable & Equatable & Identifiable> where Value.ID == String {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private var collection = SyncedCollection<Value>()
    private let defaults: UserDefaults
    private let key: String
    private let readCloud: () -> Data?
    private let writeCloud: (Data) throws -> Void
    private let legacyDate: (Value) -> Date
    private(set) var error: String?
    var values: [Value] { collection.values }

    init(key: String, defaults: UserDefaults = .standard,
         readCloud: @escaping () -> Data?, writeCloud: @escaping (Data) throws -> Void,
         legacyDate: @escaping (Value) -> Date) {
        self.key = key + ".recovery"
        self.defaults = defaults
        self.readCloud = readCloud
        self.writeCloud = writeCloud
        self.legacyDate = legacyDate
        if let data = defaults.data(forKey: self.key) {
            do { collection = try SyncedCollection.decode(data, legacyDate: legacyDate) }
            catch {
                // Preserve the exact bytes before any subsequent save.
                defaults.set(data, forKey: self.key + ".unreadable")
                self.error = "Saved reading data could not be decoded. Its recovery copy has been preserved. \(error.localizedDescription)"
            }
        }
        let recoveryError = error
        synchronize()
        if error == nil { error = recoveryError }
    }

    func membership(for id: String) -> SyncedCollection<Value>.Membership? {
        collection.membership(for: id)
    }

    func replace(with values: [Value]) {
        collection.replace(with: values)
        synchronize()
    }

    @discardableResult
    func update(_ value: Value, membership: SyncedCollection<Value>.Membership) -> Bool {
        guard collection.update(value, membership: membership) else { return false }
        synchronize()
        return collection.membership(for: value.id) == membership
    }

    func synchronize() {
        error = nil
        do {
            if let data = readCloud() {
                collection.merge(try SyncedCollection.decode(data, legacyDate: legacyDate))
            }
            let data = try Self.encoder.encode(collection)
            defaults.set(data, forKey: key)
            if data != readCloud() { try writeCloud(data) }
        } catch {
            // Never replace an unreadable server value with an empty library.
            // Still save local edits, including deletion records, for recovery.
            if let local = try? Self.encoder.encode(collection) { defaults.set(local, forKey: key) }
            self.error = "Reading data is saved on this device, but iCloud sync failed. \(error.localizedDescription)"
        }
    }
}

@MainActor
enum ReadingCloud {
    static let quotaMessage = "iCloud reading-data storage is full. Your changes remain on this device."

    static func write(_ data: Data, key: String, store: NSUbiquitousKeyValueStore = .default) throws {
        // Covers are reproducible; positions are not. Reclaim covers before
        // rejecting a reading-state update. The system notification remains
        // authoritative for server-side quota/account failures.
        var values = store.dictionaryRepresentation
        values[key] = data
        if try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).count > 950_000 {
            for coverKey in values.keys where coverKey.hasPrefix("manicule.cover.") {
                store.removeObject(forKey: coverKey)
                values.removeValue(forKey: coverKey)
            }
        }
        guard values.count <= 1024,
              try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).count < 1_000_000 else {
            throw NSError(domain: "Manicule.ReadingCloud", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: quotaMessage])
        }
        store.set(data, forKey: key)
        store.synchronize()
    }
}
