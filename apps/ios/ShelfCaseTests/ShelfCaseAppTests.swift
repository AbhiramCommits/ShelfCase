import XCTest
import SwiftData
import ShelfCaseKit
@testable import ShelfCase

/// App-target tests. These exercise the SwiftData persistence layer that the
/// headless `ShelfCaseKit` suite deliberately does not cover.
///
/// They require full Xcode (the `SwiftDataMacros` plugin is not part of the
/// Command Line Tools toolchain), so they run in Xcode or on CI, not via
/// `swift test`. See docs/ENVIRONMENT.md.
final class SwiftDataLocalStoreTests: XCTestCase {

    private func makeStore() throws -> (SwiftDataLocalStore, ModelContainer) {
        let container = try ShelfCaseSchema.makeContainer(inMemory: true)
        return (SwiftDataLocalStore(container: container), container)
    }

    func testUpsertRoundTripsThroughSwiftData() async throws {
        let (store, _) = try makeStore()
        let item = CollectibleItem(
            title: "Glurak",
            setName: "Base Set",
            category: .card,
            conditionGrade: .excellent,
            purchasePriceCents: 12_345,
            estimatedValueCents: 45_678,
            notes: "sleeved",
            syncState: .pendingCreate
        )

        try await store.upsert(item)
        let loaded = try await store.item(id: item.id)

        XCTAssertEqual(loaded, item)
        let allItems = try await store.allItems()
        XCTAssertEqual(allItems.count, 1)
    }

    func testPendingItemsAreReturnedOldestFirst() async throws {
        let (store, _) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, offset) in [30.0, 10.0, 20.0].enumerated() {
            try await store.upsert(
                CollectibleItem(
                    title: "Item \(index)",
                    updatedAt: base.addingTimeInterval(offset),
                    syncState: .pendingCreate
                ))
        }

        let pending = try await store.fetchPending()
        XCTAssertEqual(pending.map(\.title), ["Item 1", "Item 2", "Item 0"])
    }

    func testMarkSyncedWithServerMintedIdReKeysTheRow() async throws {
        let (store, _) = try makeStore()
        let localId = UUID()
        let serverId = UUID()
        try await store.upsert(CollectibleItem(id: localId, title: "Re-keyed", syncState: .pendingCreate))

        try await store.markSynced(
            id: localId,
            serverId: serverId,
            serverVersion: 3,
            serverUpdatedAt: Date()
        )

        let original = try await store.item(id: localId)
        XCTAssertNil(original)
        let rekeyed = try await store.item(id: serverId)
        XCTAssertEqual(rekeyed?.version, 3)
        XCTAssertEqual(rekeyed?.syncState, .synced)
    }

    func testCursorIsPersistedInMetadata() async throws {
        let (store, _) = try makeStore()
        let initialCursor = try await store.cursor()
        XCTAssertNil(initialCursor)
        try await store.setCursor("2026-01-01T00:00:00.000Z|42")
        let storedCursor = try await store.cursor()
        XCTAssertEqual(storedCursor, "2026-01-01T00:00:00.000Z|42")
    }

    func testConflictArchivePreservesBothCopies() async throws {
        let (store, _) = try makeStore()
        let itemId = UUID()
        let local = CollectibleItem(id: itemId, title: "Card", notes: "mine", syncState: .pendingUpdate)
        let server = CollectibleItem(id: itemId, title: "Card", notes: "theirs", version: 2, syncState: .synced)
        var merged = server
        merged.notes = local.notes

        try await store.recordConflict(
            ConflictRecord(
                itemId: itemId,
                local: local,
                server: server,
                merged: merged,
                policy: "client-newer:user-authored-fields"
            ))

        let archive = try await store.conflictArchive()
        XCTAssertEqual(archive.count, 1)
        XCTAssertEqual(archive.first?.local.notes, "mine")
        XCTAssertEqual(archive.first?.server.notes, "theirs")
        XCTAssertEqual(archive.first?.policy, "client-newer:user-authored-fields")
    }

    func testObservationsSortNewestFirst() async throws {
        let (store, _) = try makeStore()
        let item = CollectibleItem(title: "Priced")
        try await store.upsert(item)

        for (label, offset) in [("eBay", 0.0), ("TCGPlayer", 3600.0)] {
            try await store.upsertObservation(
                PriceObservation(
                    itemId: item.id,
                    sourceLabel: label,
                    valueCents: 1_000,
                    observedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
                ))
        }

        let observations = try await store.observations(forItem: item.id)
        XCTAssertEqual(observations.map(\.sourceLabel), ["TCGPlayer", "eBay"])
    }

    func testSoftDeletedItemsAreHiddenByDefault() async throws {
        let (store, _) = try makeStore()
        var item = CollectibleItem(title: "Doomed")
        try await store.upsert(item)
        item.isDeleted = true
        item.syncState = .synced
        try await store.upsert(item)

        let visible = try await store.allItems()
        let everything = try await store.allItems(includeDeleted: true)
        XCTAssertEqual(visible.count, 0)
        XCTAssertEqual(everything.count, 1)
    }
}

final class LocalImageStoreTests: XCTestCase {

    func testSaveThenLoadReturnsAnImageAndAStableRelativePath() throws {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }

        let path = try LocalImageStore.save(image: image)
        XCTAssertFalse(path.hasPrefix("/"), "the stored path must be container-relative")
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalImageStore.absoluteURL(for: path).path))
        XCTAssertNotNil(LocalImageStore.loadImage(relativePath: path))

        LocalImageStore.delete(relativePath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalImageStore.absoluteURL(for: path).path))
    }
}

final class AppConfigurationTests: XCTestCase {

    func testBaseURLFallsBackToLocalhostAndHonoursUserDefaults() {
        AppConfiguration.setBaseURL(nil)
        XCTAssertEqual(AppConfiguration.baseURL, AppConfiguration.fallbackBaseURL)

        AppConfiguration.setBaseURL(URL(string: "https://api.shelfcase.test"))
        XCTAssertEqual(AppConfiguration.baseURL.absoluteString, "https://api.shelfcase.test")
        AppConfiguration.setBaseURL(nil)
    }

    func testRetryingClientUsesTheConfiguredToken() {
        let client = APIClientFactory.makeRetryingClient(
            baseURL: URL(string: "http://localhost:4000")!,
            token: "dev-bob"
        )
        XCTAssertEqual(client.metrics.requestsSent, 0)
    }
}
