import SwiftUI
import SwiftData
import ShelfCaseKit

/// Incoming/outgoing trades with optimistic accept/decline that rolls back if
/// the server rejects the transition.
struct TradesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\TradeEntity.updatedAt, order: .reverse)])
    private var trades: [TradeEntity]

    @State private var role: Role = .incoming
    @State private var showingPropose = false
    @State private var rollbackMessage: String?

    private enum Role: String, CaseIterable {
        case incoming = "Incoming"
        case outgoing = "Outgoing"
    }

    private var currentUserId: UUID {
        UUID(uuidString: UserIdentity.currentUserId) ?? UUID()
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Direction", selection: $role) {
                    ForEach(Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if filtered.isEmpty {
                    ContentUnavailableView(
                        role == .incoming ? "No incoming offers" : "No outgoing offers",
                        systemImage: "arrow.left.arrow.right",
                        description: Text("Propose a swap from an item's detail screen.")
                    )
                }

                ForEach(filtered) { trade in
                    TradeRow(trade: trade, isIncoming: role == .incoming) { action in
                        Task { await perform(action, on: trade) }
                    }
                }
            }
            .navigationTitle("Trades")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingPropose = true
                    } label: {
                        Label("Propose", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingPropose) { ProposeTradeSheet() }
            .task { await refresh() }
            .refreshable { await refresh() }
            .alert("Server rejected the change", isPresented: .constant(rollbackMessage != nil)) {
                Button("OK") { rollbackMessage = nil }
            } message: {
                Text(rollbackMessage ?? "")
            }
        }
    }

    private var filtered: [TradeEntity] {
        trades.filter { trade in
            role == .incoming
                ? trade.receiverUserId == currentUserId
                : trade.proposerUserId == currentUserId
        }
    }

    private func refresh() async {
        for remoteRole in ["incoming", "outgoing"] {
            if let remote = try? await environment.trades.trades(role: remoteRole) {
                for trade in remote {
                    try? await environment.store.upsertTrade(trade)
                }
            }
        }
    }

    /// Optimistic update: flip the local row, call the server, and put it back
    /// exactly as it was if the server disagrees.
    private func perform(_ action: TradeAction, on trade: TradeEntity) async {
        let previousStatus = trade.status
        let previousVersion = trade.version

        trade.statusRaw = (action == .accept ? TradeStatus.accepted : .declined).rawValue
        trade.updatedAt = Date()
        try? modelContext.save()

        do {
            let updated =
                action == .accept
                ? try await environment.trades.accept(id: trade.id)
                : try await environment.trades.decline(id: trade.id)
            trade.statusRaw = updated.status.rawValue
            trade.version = updated.version
            trade.updatedAt = updated.updatedAt
            try? modelContext.save()
            await Telemetry.shared.record(
                TelemetryEvent(
                    name: "trade.\(action == .accept ? "accepted" : "declined")",
                    attributes: ["tradeId": trade.id.uuidString]
                ))
        } catch {
            trade.statusRaw = previousStatus.rawValue
            trade.version = previousVersion
            trade.updatedAt = Date()
            try? modelContext.save()
            rollbackMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await Telemetry.shared.record(
                TelemetryEvent(
                    name: "trade.rollback",
                    errorMessage: error.localizedDescription,
                    attributes: ["tradeId": trade.id.uuidString, "action": action.rawValue]
                ))
        }
    }
}

enum TradeAction: String {
    case accept
    case decline
}

struct TradeRow: View {
    let trade: TradeEntity
    let isIncoming: Bool
    let onAction: (TradeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusPill(status: trade.status)
                Spacer()
                Text(trade.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isIncoming ? "They offer" : "You offer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(trade.offeredItemIds.count) item(s)")
                        .font(.subheadline)
                }
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isIncoming ? "You give" : "You receive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(trade.requestedItemIds.count) item(s)")
                        .font(.subheadline)
                }
            }

            if trade.status == .proposed, isIncoming {
                HStack(spacing: 12) {
                    Button("Accept") { onAction(.accept) }
                        .buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { onAction(.decline) }
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusPill: View {
    let status: TradeStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .proposed: return .orange
        case .accepted: return .green
        case .declined: return .red
        case .cancelled: return .secondary
        }
    }
}
