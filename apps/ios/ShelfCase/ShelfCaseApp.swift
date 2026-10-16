import SwiftUI
import SwiftData
import ShelfCaseKit

@main
struct ShelfCaseApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .task { await environment.start() }
        }
        .modelContainer(environment.modelContainer)
    }
}

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            CollectionGridView()
                .tabItem { Label("Collection", systemImage: "square.grid.2x2") }

            PortfolioView()
                .tabItem { Label("Portfolio", systemImage: "chart.line.uptrend.xyaxis") }

            TradesView()
                .tabItem { Label("Trades", systemImage: "arrow.left.arrow.right") }

            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .overlay(alignment: .top) { OfflineBanner() }
    }
}

/// Thin banner driven by `NWPathMonitor` plus the engine's own view of things:
/// being "online" is not the same as having drained the outbox.
struct OfflineBanner: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        let monitor = environment.network
        if !monitor.isOnline || environment.pendingChangeCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: monitor.isOnline ? "arrow.triangle.2.circlepath" : "wifi.slash")
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.isOnline ? "Syncing" : "Offline")
                        .font(.caption.weight(.semibold))
                    if environment.pendingChangeCount > 0 {
                        Text("\(environment.pendingChangeCount) change(s) queued")
                            .font(.caption2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Local, on-device view of what the sync engine has been doing. This is the
/// screen you ask a tester to screenshot when they report a sync bug.
struct DiagnosticsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var events: [TelemetryEvent] = []
    @State private var conflicts: [ConflictRecord] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    LabeledContent("Last sync", value: environment.lastSyncAt.map(Self.formatter.string) ?? "never")
                    LabeledContent("Queued changes", value: "\(environment.pendingChangeCount)")
                    if let report = environment.lastReport {
                        LabeledContent("Pushed / pulled", value: "\(report.pushed) / \(report.pulled)")
                        LabeledContent("Retries", value: "\(report.retries)")
                        LabeledContent("Conflicts", value: "\(report.conflicts) resolved")
                        LabeledContent("Duration", value: "\(report.durationMs) ms")
                        LabeledContent("Cursor", value: report.cursor ?? "—")
                    }
                    if let error = environment.lastSyncError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section("Network") {
                    LabeledContent("Status", value: environment.network.isOnline ? "online" : "offline")
                    LabeledContent("Interface", value: environment.network.interface)
                    LabeledContent("Expensive", value: environment.network.isExpensive ? "yes" : "no")
                }

                Section("API") {
                    LabeledContent("Base URL", value: AppConfiguration.baseURL.absoluteString)
                    LabeledContent("User", value: AppConfiguration.bearerToken)
                }

                Section("Conflict archive (\(conflicts.count))") {
                    if conflicts.isEmpty {
                        Text("No conflicts recorded").foregroundStyle(.secondary)
                    }
                    ForEach(conflicts) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.local.title).font(.subheadline.weight(.semibold))
                            Text(record.policy).font(.caption).foregroundStyle(.secondary)
                            Text("kept: notes=“\(record.merged.notes)” value=\(record.merged.estimatedValueCents)¢")
                                .font(.caption2)
                            Text("discarded: notes=“\(record.local.notes)”")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Telemetry (\(events.count))") {
                    ForEach(Array(events.prefix(40).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.name).font(.caption.monospaced())
                            Text(Self.formatter.string(from: event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await environment.syncNow(); await reload()
                        }
                    } label: {
                        if environment.isSyncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        conflicts = (try? await environment.store.conflictArchive()) ?? []
        events = await Telemetry.shared.recentEvents(limit: 200)
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        return formatter
    }()
}
