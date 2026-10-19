import SwiftUI
import SwiftData
import ShelfCaseKit

/// Editable detail screen: photo, grade, notes, price history and the two
/// marketplace actions.
struct ItemDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var modelContext

    @Bindable var item: ItemEntity

    @State private var observations: [PriceObservation] = []
    @State private var wishlistSheet = false
    @State private var tradeSheet = false
    @State private var isDirty = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 220, height: 220)
                        ThumbnailView(path: item.imageLocalPath)
                            .frame(width: 220, height: 220)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Valuation") {
                LabeledContent("Estimated", value: CurrencyFormat.string(cents: item.estimatedValueCents))
                LabeledContent("Paid", value: CurrencyFormat.string(cents: item.purchasePriceCents))
                LabeledContent(
                    "Unrealised",
                    value: CurrencyFormat.string(cents: item.estimatedValueCents - item.purchasePriceCents)
                )
                .foregroundStyle(item.estimatedValueCents >= item.purchasePriceCents ? .green : .red)

                if observations.count >= 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Price history").font(.caption).foregroundStyle(.secondary)
                        Sparkline(values: observations.map(\.valueCents))
                            .frame(height: 56)
                    }
                } else {
                    Text("Not enough observations for a trend yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                TextField("Title", text: $item.title)
                TextField("Set", text: $item.setName)
                Picker("Category", selection: categoryBinding) {
                    ForEach(ItemCategory.allCases, id: \.self) { value in
                        Text(value.rawValue.capitalized).tag(value)
                    }
                }
                Picker("Grade", selection: gradeBinding) {
                    ForEach(ConditionGrade.allCases.sorted { $0.rank > $1.rank }, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                TextField("Notes", text: $item.notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section("Marketplace") {
                Button {
                    wishlistSheet = true
                } label: {
                    Label("Add to wishlist", systemImage: "star")
                }
                Button {
                    tradeSheet = true
                } label: {
                    Label("List for trade", systemImage: "arrow.left.arrow.right")
                }
            }

            Section("Sync") {
                LabeledContent("State", value: String(describing: item.syncState))
                LabeledContent("Version", value: "\(item.version)")
                LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: item.title) { _, _ in markDirty() }
        .onChange(of: item.notes) { _, _ in markDirty() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .disabled(!isDirty)
            }
        }
        .task { await loadObservations() }
        .sheet(isPresented: $wishlistSheet) {
            WishlistSheet(seedTitle: item.title)
        }
        .sheet(isPresented: $tradeSheet) {
            ProposeTradeSheet(preselectedOffered: item.id)
        }
    }

    // MARK: Bindings that mark the row dirty

    private var categoryBinding: Binding<ItemCategory> {
        Binding(
            get: { item.category },
            set: {
                item.categoryRaw = $0.rawValue; markDirty()
            }
        )
    }

    private var gradeBinding: Binding<ConditionGrade> {
        Binding(
            get: { item.conditionGrade },
            set: {
                item.conditionGradeRaw = $0.rawValue; markDirty()
            }
        )
    }

    private func markDirty() {
        isDirty = true
    }

    /// Save queues the edit for sync rather than writing straight through, which
    /// is what makes the screen work with no signal.
    private func save() {
        item.updatedAt = Date()
        item.syncStateRaw = SyncState.pendingUpdate.rawValue
        try? modelContext.save()
        isDirty = false

        Task {
            await environment.refreshPendingCount()
            await environment.syncNow()
        }
    }

    private func loadObservations() async {
        observations = (try? await environment.store.observations(forItem: item.id)) ?? []
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geometry in
            let points = normalised(in: geometry.size)
            ZStack {
                if points.count >= 2 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.15))
                }
            }
        }
        .accessibilityLabel("Price history, \(values.count) observations")
    }

    /// Newest-first input is reversed so the line reads left-to-right in time.
    private func normalised(in size: CGSize) -> [CGPoint] {
        let series = Array(values.reversed())
        guard series.count >= 2 else { return [] }
        let minimum = series.min() ?? 0
        let maximum = series.max() ?? 1
        let span = max(1, maximum - minimum)
        let step = size.width / CGFloat(series.count - 1)
        return series.enumerated().map { index, value in
            let ratio = CGFloat(value - minimum) / CGFloat(span)
            return CGPoint(x: CGFloat(index) * step, y: size.height - ratio * (size.height - 6) - 3)
        }
    }
}

// MARK: - Wishlist sheet

struct WishlistSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State var seedTitle: String = ""
    @State private var maxPrice = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Notify me when an item matches") {
                    TextField("Title contains", text: $seedTitle)
                    TextField("At or below (cents)", text: $maxPrice)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Wishlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(seedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let entry = WishlistEntry(
            userId: UUID(uuidString: UserIdentity.currentUserId) ?? UUID(),
            titleQuery: seedTitle.trimmingCharacters(in: .whitespaces),
            maxPriceCents: Int(maxPrice) ?? 0
        )
        modelContext.insert(WishlistEntity(domain: entry))
        try? modelContext.save()
        dismiss()
    }
}

enum UserIdentity {
    /// Must match the id the server's dev bearer token resolves to, otherwise
    /// wishlist matching is scoped to the wrong user.
    static let currentUserId = "11111111-1111-4111-8111-111111111111"
}

// MARK: - Propose trade sheet

struct ProposeTradeSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<ItemEntity> { $0.isSoftDeleted == false },
        sort: [SortDescriptor(\ItemEntity.title)])
    private var items: [ItemEntity]

    @State var preselectedOffered: UUID?
    @State private var offered: Set<UUID> = []
    @State private var requested: Set<UUID> = []
    @State private var receiverId = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You offer") {
                    selectionList(selection: $offered)
                }
                Section("You want") {
                    selectionList(selection: $requested)
                }
                Section("Other collector") {
                    TextField("Receiver user id", text: $receiverId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use dev-bob") {
                        receiverId = "22222222-2222-4222-8222-222222222222"
                    }
                    .font(.footnote)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Propose a swap")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Propose") { Task { await propose() } }
                        .disabled(!canPropose || isSubmitting)
                }
            }
            .onAppear {
                if let preselectedOffered { offered.insert(preselectedOffered) }
            }
        }
    }

    private var canPropose: Bool {
        !offered.isEmpty && !requested.isEmpty && UUID(uuidString: receiverId) != nil
    }

    @ViewBuilder
    private func selectionList(selection: Binding<Set<UUID>>) -> some View {
        ForEach(items) { item in
            Button {
                if selection.wrappedValue.contains(item.id) {
                    selection.wrappedValue.remove(item.id)
                } else {
                    selection.wrappedValue.insert(item.id)
                }
            } label: {
                HStack {
                    Image(systemName: selection.wrappedValue.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.wrappedValue.contains(item.id) ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(item.title).font(.subheadline)
                        Text(CurrencyFormat.string(cents: item.estimatedValueCents))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func propose() async {
        isSubmitting = true
        defer { isSubmitting = false }

        guard let receiver = UUID(uuidString: receiverId) else { return }
        let trade = Trade(
            proposerUserId: UUID(uuidString: UserIdentity.currentUserId) ?? UUID(),
            receiverUserId: receiver,
            offeredItemIds: Array(offered),
            requestedItemIds: Array(requested)
        )

        // Optimistic: show it immediately, roll back if the server rejects.
        let entity = TradeEntity(domain: trade)
        modelContext.insert(entity)
        try? modelContext.save()

        do {
            try await environment.trades.propose(trade)
            dismiss()
        } catch {
            modelContext.delete(entity)
            try? modelContext.save()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await Telemetry.shared.record(
                TelemetryEvent(
                    name: "trade.propose_failed",
                    errorMessage: error.localizedDescription
                ))
        }
    }
}
