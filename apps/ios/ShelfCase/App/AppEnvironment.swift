import Foundation
import Network
import SwiftUI
import SwiftData
import ShelfCaseKit

/// Drives the offline banner off `NWPathMonitor`.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var isExpensive = false
    @Published private(set) var interface: String = "unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.shelfcase.app.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let name: String
            if path.usesInterfaceType(.wifi) {
                name = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                name = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                name = "ethernet"
            } else {
                name = "other"
            }
            Task { @MainActor in
                self?.isOnline = online
                self?.isExpensive = expensive
                self?.interface = name
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// Root dependency container for the app. Holds the SwiftData stack, the API
/// client and the sync engine, and surfaces sync state to the views.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncAt: Date?
    @Published var syncErrorMessage: String?

    let container: ModelContainer
    let store: SwiftDataLocalStore
    let api: URLSessionAPIClient
    let engine: SyncEngine
    let trades: TradeService
    let network = NetworkMonitor()

    init(inMemory: Bool = false) {
        let container: ModelContainer
        do {
            container = try ShelfCaseSchema.makeContainer(inMemory: inMemory)
        } catch {
            // A corrupt store should not brick the app: fall back to memory and
            // record it, rather than crashing at launch.
            container = try! ShelfCaseSchema.makeContainer(inMemory: true)
            Task {
                await Telemetry.shared.record(
                    TelemetryEvent(
                        name: "store.open_failed",
                        errorMessage: error.localizedDescription
                    ))
            }
        }

        self.container = container
        self.store = SwiftDataLocalStore(container: container)
        self.api = APIClientFactory.makeRetryingClient()
        self.engine = SyncEngine(api: api, store: store)
        self.trades = TradeService()
    }

    var modelContainer: ModelContainer { container }

    /// Called once from the app's root `.task`.
    func start() async {
        await Telemetry.shared.configure(baseURL: AppConfiguration.baseURL)
        await refreshPendingCount()
        await syncNow()
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let interval = await Telemetry.shared.beginSync()
        let report = await engine.sync()
        lastReport = report
        lastSyncAt = Date()

        await Telemetry.shared.endSync(
            interval,
            durationMs: report.durationMs,
            retries: report.retries,
            conflicts: report.conflicts
        )
        await Telemetry.shared.record(
            TelemetryEvent(
                name: report.errors > 0 ? "sync.completed_with_errors" : "sync.completed",
                syncDurationMs: report.durationMs,
                retries: report.retries,
                conflicts: report.conflicts,
                pushed: report.pushed,
                pulled: report.pulled
            ))

        if report.errors > 0 {
            lastSyncError = "\(report.errors) change(s) could not be sent"
        } else {
            lastSyncError = nil
        }
        await refreshPendingCount()
    }

    func refreshPendingCount() async {
        let pending = (try? await store.fetchPending()) ?? []
        pendingChangeCount = pending.count
    }
}
