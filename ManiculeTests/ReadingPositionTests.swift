import XCTest
@testable import Manicule

@MainActor
final class ReadingPositionTests: XCTestCase {

    // MARK: - Display Strings

    func testPDFPageDisplayString() {
        XCTAssertEqual(ReadingPosition.pdfPage(0).displayString, "Page 1")
        XCTAssertEqual(ReadingPosition.pdfPage(99).displayString, "Page 100")
    }

    func testEPubSpineDisplayString() {
        XCTAssertEqual(ReadingPosition.epubSpine(index: 2, scrollFraction: 0.5).displayString, "Chapter 3")
    }

    func testEPubCFIDisplayString() {
        let pos = ReadingPosition.epubCFI("/6/4[chap01]!/4/2/1:0", fraction: 0.42)
        XCTAssertEqual(pos.displayString, "42%")
    }

    func testTextOffsetDisplayString() {
        XCTAssertEqual(ReadingPosition.textOffset(1234).displayString, "Position 1234")
    }

    func testComicPageDisplayString() {
        XCTAssertEqual(ReadingPosition.comicPage(4).displayString, "Page 5")
    }

    // MARK: - Codable Roundtrip

    func testPDFPageCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.pdfPage(42))
    }

    func testEPubSpineCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.epubSpine(index: 3, scrollFraction: 0.75))
    }

    func testEPubCFICodable() throws {
        try assertCodableRoundtrip(ReadingPosition.epubCFI("/6/4!/4/2:100", fraction: 0.5))
    }

    func testTextOffsetCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.textOffset(9999))
    }

    func testComicPageCodable() throws {
        try assertCodableRoundtrip(ReadingPosition.comicPage(7))
    }

    // MARK: - ePub Fraction

    func testEPubFractionFromCFI() {
        let pos = ReadingPosition.epubCFI("cfi", fraction: 0.33)
        XCTAssertEqual(pos.epubFraction, 0.33)
    }

    func testEPubFractionFromSpine() {
        let pos = ReadingPosition.epubSpine(index: 0, scrollFraction: 0.8)
        XCTAssertEqual(pos.epubFraction, 0.8)
    }

    func testEPubFractionNilForPDF() {
        XCTAssertNil(ReadingPosition.pdfPage(0).epubFraction)
    }

    func testEPubFractionNilForText() {
        XCTAssertNil(ReadingPosition.textOffset(0).epubFraction)
    }

    func testEPubFractionNilForComic() {
        XCTAssertNil(ReadingPosition.comicPage(0).epubFraction)
    }

    // MARK: - AutoSavedPosition Codable

    func testAutoSavedPositionRoundtrip() throws {
        let pos = AutoSavedPosition(
            id: "abc123",
            fileName: "Test Book.epub",
            position: .epubCFI("/6/4", fraction: 0.5),
            lastOpened: Date(timeIntervalSinceReferenceDate: 700000000),
            tocLabel: "Chapter 3",
            pinned: true
        )
        let data = try JSONEncoder().encode(pos)
        let decoded = try JSONDecoder().decode(AutoSavedPosition.self, from: data)
        XCTAssertEqual(decoded.id, pos.id)
        XCTAssertEqual(decoded.fileName, pos.fileName)
        XCTAssertEqual(decoded.position, pos.position)
        XCTAssertEqual(decoded.tocLabel, pos.tocLabel)
        XCTAssertEqual(decoded.pinned, true)
    }

    // MARK: - BookmarkEntry Codable

    func testBookmarkEntryRoundtrip() throws {
        let entry = BookmarkEntry(
            fileHash: "hash123",
            fileName: "Test.pdf",
            position: .pdfPage(5),
            lastOpened: Date(timeIntervalSinceReferenceDate: 700000000),
            tocLabel: nil
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BookmarkEntry.self, from: data)
        XCTAssertEqual(decoded.fileHash, "hash123")
        XCTAssertEqual(decoded.fileName, "Test.pdf")
        XCTAssertEqual(decoded.position, .pdfPage(5))
    }

    func testBookmarkEntryLegacyMigration() throws {
        // Legacy entries had id = fileHash and no separate fileHash field
        let legacyJSON = """
        {
            "id": "oldhash",
            "fileName": "Old Book.pdf",
            "position": {"pdfPage": {"_0": 10}},
            "lastOpened": 700000000
        }
        """
        let decoder = JSONDecoder()
        let entry = try decoder.decode(BookmarkEntry.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertEqual(entry.fileHash, "oldhash")
        // id should be migrated to a UUID
        XCTAssertNotEqual(entry.id, "oldhash")
        XCTAssertFalse(entry.id.isEmpty)
    }

    // MARK: - Helpers

    private func assertCodableRoundtrip(_ position: ReadingPosition, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(position)
        let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)
        XCTAssertEqual(decoded, position, file: file, line: line)
    }
}

@MainActor
final class ReadingSyncTests: XCTestCase {
    private func bookmark(_ id: String) -> BookmarkEntry {
        BookmarkEntry(id: id, fileHash: "book", fileName: "Book.epub",
                      position: .epubCFI(id, fraction: 0.5), lastOpened: Date(timeIntervalSince1970: 100))
    }

    func testConcurrentAdditionsConvergeAndDeletionSurvivesOfflineMerge() throws {
        var first = SyncedCollection<BookmarkEntry>()
        var second = SyncedCollection<BookmarkEntry>()
        first.replace(with: [bookmark("a")])
        second.replace(with: [bookmark("b")])
        first.merge(second)
        second.merge(first)
        XCTAssertEqual(first.values, second.values)
        XCTAssertEqual(Set(first.values.map(\.id)), ["a", "b"])
        let offline = second
        first.replace(with: [bookmark("b")])
        first.merge(offline)
        second.merge(first)
        XCTAssertEqual(first.values.map(\.id), ["b"])
        XCTAssertEqual(second.values, first.values)
        let reloaded = try SyncedCollection<BookmarkEntry>.decode(JSONEncoder().encode(first), legacyDate: { $0.lastOpened })
        second.merge(reloaded)
        XCTAssertEqual(second.values.map(\.id), ["b"])
    }

    func testEqualClockConflictsHaveDeterministicWinner() {
        let now = Date(timeIntervalSince1970: 200)
        var first = SyncedCollection<BookmarkEntry>()
        var second = first
        first.replace(with: [bookmark("a")], now: now)
        var changed = bookmark("a")
        changed.position = .pdfPage(20)
        second.replace(with: [changed], now: now)
        let original = first
        first.merge(second)
        second.merge(original)
        XCTAssertEqual(first.values, second.values)
        first.replace(with: [], now: now.addingTimeInterval(-100))
        first.merge(second)
        XCTAssertTrue(first.values.isEmpty, "A clock rollback must not undo an observed deletion")
    }

    func testUnreadableCloudDoesNotEraseLocalEditsOrReplaceRemoteBytes() throws {
        let suite = "Manicule.SyncTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var remote: Data?
        let storage = SyncedCollectionStorage<BookmarkEntry>(key: "bookmarks", defaults: defaults,
            readCloud: { remote }, writeCloud: { remote = $0 }, legacyDate: { $0.lastOpened })
        storage.replace(with: [bookmark("a")])
        let corrupt = Data("not JSON".utf8)
        remote = corrupt
        storage.synchronize()
        XCTAssertEqual(storage.values.map(\.id), ["a"])
        storage.replace(with: [bookmark("a"), bookmark("b")])
        XCTAssertEqual(remote, corrupt)
        XCTAssertNotNil(storage.error)
        let reloaded = SyncedCollectionStorage<BookmarkEntry>(key: "bookmarks", defaults: defaults,
            readCloud: { remote }, writeCloud: { remote = $0 }, legacyDate: { $0.lastOpened })
        XCTAssertEqual(Set(reloaded.values.map(\.id)), ["a", "b"])
        remote = nil
        reloaded.synchronize()
        XCTAssertNotNil(remote)
    }

    func testFailedCloudWriteRetainsRecoveryAndLegacyArraysMigrate() throws {
        let suite = "Manicule.SyncTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONEncoder().encode([bookmark("a")])
        let storage = SyncedCollectionStorage<BookmarkEntry>(key: "bookmarks", defaults: defaults,
            readCloud: { legacy }, writeCloud: { _ in throw CocoaError(.fileWriteOutOfSpace) }, legacyDate: { $0.lastOpened })
        storage.replace(with: [])
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertNotNil(storage.error)
        let reloaded = SyncedCollectionStorage<BookmarkEntry>(key: "bookmarks", defaults: defaults,
            readCloud: { legacy }, writeCloud: { _ in }, legacyDate: { $0.lastOpened })
        XCTAssertTrue(reloaded.values.isEmpty)
    }

    func testUnchangedSynchronizationDoesNotWriteAgain() throws {
        let suite = "Manicule.SyncTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var remote: Data?
        var writes = 0
        let storage = SyncedCollectionStorage<BookmarkEntry>(key: "bookmarks", defaults: defaults,
            readCloud: { remote }, writeCloud: { remote = $0; writes += 1 }, legacyDate: { $0.lastOpened })
        storage.replace(with: [bookmark("b"), bookmark("a")])
        let previous = writes
        storage.synchronize()
        storage.synchronize()
        XCTAssertEqual(writes, previous)
    }
}

@MainActor
final class PreferencePersistenceTests: XCTestCase {
    /// All persistence is isolated; these tests never use the user's KVS.
    private final class Cloud: NSUbiquitousKeyValueStore {
        var values: [String: Any] = [:]
        override func data(forKey key: String) -> Data? { values[key] as? Data }
        override func set(_ data: Data?, forKey key: String) { values[key] = data }
        override var dictionaryRepresentation: [String: Any] { values }
        override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        override func synchronize() -> Bool { true }
    }

    func testMalformedCloudDoesNotOverwriteLocalPreferencesOrRemoteBytes() throws {
        let suite = "Manicule.PreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "manicule.readingPrefs.overrides"
        let local = ["book": BookOverride(fontSize: 24)]
        defaults.set(try JSONEncoder().encode(local), forKey: key)
        let cloud = Cloud()
        let corrupt = Data("unreadable".utf8)
        cloud.values[key] = corrupt
        let preferences = ReadingPreferences(defaults: defaults, cloud: cloud, updatePinnedStatus: { _ in })
        XCTAssertEqual(preferences.effective(for: "book").fontSize, 24)
        XCTAssertNotNil(preferences.lastError)
        preferences.setOverride(for: "book", override: BookOverride(fontSize: 30))
        XCTAssertEqual(cloud.data(forKey: key), corrupt)
        let saved = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode([String: BookOverride].self, from: saved)["book"]?.fontSize, 30)
    }

    func testConcurrentPreferenceEditsMergeAndDeletionsDoNotResurrect() throws {
        let suite = "Manicule.PreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "manicule.readingPrefs.overrides"
        defaults.set(try JSONEncoder().encode(["local": BookOverride(fontSize: 24)]), forKey: key)
        let cloud = Cloud()
        cloud.values[key] = try JSONEncoder().encode(["remote": BookOverride(fontSize: 30)])
        let preferences = ReadingPreferences(defaults: defaults, cloud: cloud, updatePinnedStatus: { _ in })
        XCTAssertEqual(Set(preferences.perBookOverrides.keys), ["local", "remote"])
        preferences.removeOverride(for: "remote")
        // An old device publishes the pre-deletion dictionary.
        cloud.values[key] = try JSONEncoder().encode(["remote": BookOverride(fontSize: 30)])
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)
        XCTAssertNil(preferences.perBookOverrides["remote"])
        XCTAssertNotNil(preferences.perBookOverrides["local"])
    }

    func testQuotaNotificationReachesTheErrorSurface() throws {
        let suite = "Manicule.PreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = Cloud()
        let preferences = ReadingPreferences(defaults: defaults, cloud: cloud, updatePinnedStatus: { _ in })
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange])
        XCTAssertEqual(preferences.lastError, ReadingCloud.quotaMessage)
    }
}

@MainActor
final class ReadingMembershipTests: XCTestCase {
    private func position(_ page: Int) -> AutoSavedPosition {
        AutoSavedPosition(id: "book", fileName: "Book.pdf", position: .pdfPage(page), lastOpened: Date())
    }

    func testOfflineAutosaveCannotUndoRemovalAndOldWindowCannotUndoReopening() throws {
        var first = SyncedCollection<AutoSavedPosition>()
        first.replace(with: [position(3)], now: Date(timeIntervalSince1970: 100))
        var offline = first
        let oldSession = try XCTUnwrap(first.membership(for: "book"))
        first.replace(with: [], now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(offline.update(position(8), membership: oldSession, now: Date(timeIntervalSince1970: 300)))
        first.merge(offline)
        offline.merge(first)
        XCTAssertTrue(first.values.isEmpty)
        XCTAssertTrue(offline.values.isEmpty)
        XCTAssertFalse(offline.update(position(9), membership: oldSession))

        // Explicit opening creates a new membership; the old window stays revoked.
        first.replace(with: [position(0)], now: Date(timeIntervalSince1970: 400))
        offline.merge(first)
        XCTAssertFalse(offline.update(position(10), membership: oldSession))
        let newSession = try XCTUnwrap(offline.membership(for: "book"))
        XCTAssertNotEqual(oldSession, newSession)
        XCTAssertTrue(offline.update(position(1), membership: newSession))
        XCTAssertEqual(offline.values.first?.position, .pdfPage(1))
    }

    func testRemovalReceivedDuringSaveWinsAndSurvivesRelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var remote: Data?
        let storage = SyncedCollectionStorage<AutoSavedPosition>(key: "reading", defaults: defaults,
            readCloud: { remote }, writeCloud: { remote = $0 }, legacyDate: { $0.lastOpened })
        storage.replace(with: [position(2)])
        let session = try XCTUnwrap(storage.membership(for: "book"))
        var other = try SyncedCollection<AutoSavedPosition>.decode(XCTUnwrap(remote), legacyDate: { $0.lastOpened })
        other.replace(with: [])
        remote = try JSONEncoder().encode(other)
        XCTAssertFalse(storage.update(position(7), membership: session))
        XCTAssertTrue(storage.values.isEmpty)
        let relaunched = SyncedCollectionStorage<AutoSavedPosition>(key: "reading", defaults: defaults,
            readCloud: { remote }, writeCloud: { remote = $0 }, legacyDate: { $0.lastOpened })
        XCTAssertTrue(relaunched.values.isEmpty)
    }

    func testExistingRecordEnvelopeWithoutMembershipStillMigrates() throws {
        var state = SyncedCollection<AutoSavedPosition>()
        state.replace(with: [position(2)])
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var records = try XCTUnwrap(envelope["records"] as? [String: [String: Any]])
        records["book"]?.removeValue(forKey: "membership")
        envelope["records"] = records
        var migrated = try SyncedCollection<AutoSavedPosition>.decode(
            JSONSerialization.data(withJSONObject: envelope), legacyDate: { $0.lastOpened })
        let session = try XCTUnwrap(migrated.membership(for: "book"))
        XCTAssertTrue(migrated.update(position(3), membership: session))
        XCTAssertEqual(migrated.membership(for: "book"), session)
    }
}
