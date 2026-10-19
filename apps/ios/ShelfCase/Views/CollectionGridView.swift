import SwiftUI
import SwiftData
import ShelfCaseKit

/// Browse the collection: lazy grid, search, category/grade filters,
/// pull-to-refresh that drives the sync engine.
struct CollectionGridView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<ItemEntity> { $0.isSoftDeleted == false },
        sort: [SortDescriptor(\ItemEntity.updatedAt, order: .reverse)]
    )
    private var items: [ItemEntity]

    @State private var searchText = ""
    @State private var categoryFilter: ItemCategory?
    @State private var gradeFilter: ConditionGrade?
    @State private var showingCapture = false
    @State private var selection: ItemEntity?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filtered) { item in
                        NavigationLink(value: item.persistentModelID) {
                            ItemCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Collection")
            .searchable(text: $searchText, prompt: "Title or set")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCapture = true
                    } label: {
                        Label("Add", systemImage: "camera.fill")
                    }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { identifier in
                if let item = modelContext.model(for: identifier) as? ItemEntity {
                    ItemDetailView(item: item)
                } else {
                    ContentUnavailableView("Item removed", systemImage: "questionmark.folder")
                }
            }
            .sheet(isPresented: $showingCapture) {
                CaptureView()
            }
            .refreshable { await environment.syncNow() }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No items yet" : "No matches",
                        systemImage: searchText.isEmpty ? "shippingbox" : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Tap the camera to catalogue your first collectible."
                                : "Try a different title, category or grade.")
                    )
                }
            }
        }
    }

    private var filtered: [ItemEntity] {
        items.filter { item in
            if let categoryFilter, item.category != categoryFilter { return false }
            if let gradeFilter, item.conditionGrade != gradeFilter { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return item.title.lowercased().contains(needle) || item.setName.lowercased().contains(needle)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Category", selection: $categoryFilter) {
                Text("All categories").tag(ItemCategory?.none)
                ForEach(ItemCategory.allCases, id: \.self) { category in
                    Text(category.rawValue.capitalized).tag(ItemCategory?.some(category))
                }
            }
            Picker("Grade", selection: $gradeFilter) {
                Text("All grades").tag(ConditionGrade?.none)
                ForEach(ConditionGrade.allCases.sorted { $0.rank > $1.rank }, id: \.self) { grade in
                    Text(grade.displayName).tag(ConditionGrade?.some(grade))
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var hasFilters: Bool { categoryFilter != nil || gradeFilter != nil }
}

struct ItemCard: View {
    let item: ItemEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                ThumbnailView(path: item.imageLocalPath)
            }
            .frame(height: 140)

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                GradeChip(grade: item.conditionGrade)
                Spacer()
                Text(CurrencyFormat.string(cents: item.estimatedValueCents))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }

            if item.syncState != .synced {
                SyncBadge(state: item.syncState)
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}

struct GradeChip: View {
    let grade: ConditionGrade

    var body: some View {
        Text(grade.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch grade {
        case .mint: return .green
        case .nearMint: return .teal
        case .excellent: return .blue
        case .good: return .orange
        case .poor: return .red
        }
    }
}

struct SyncBadge: View {
    let state: SyncState

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var text: String {
        switch state {
        case .pendingCreate: return "queued: new"
        case .pendingUpdate: return "queued: edit"
        case .pendingDelete: return "queued: delete"
        case .conflicted: return "conflict"
        case .synced: return "synced"
        }
    }

    private var symbol: String {
        switch state {
        case .pendingCreate, .pendingUpdate: return "arrow.up.circle"
        case .pendingDelete: return "trash.circle"
        case .conflicted: return "exclamationmark.triangle"
        case .synced: return "checkmark.circle"
        }
    }
}

/// Loads a locally-stored image by its container-relative path.
struct ThumbnailView: View {
    let path: String?

    var body: some View {
        if let path, let image = LocalImageStore.loadImage(relativePath: path) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
        }
    }
}

enum CurrencyFormat {
    static func string(cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "$\(Double(cents) / 100.0)"
    }
}
