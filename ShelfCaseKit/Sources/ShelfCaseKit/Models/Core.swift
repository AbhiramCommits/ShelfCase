import Foundation

// MARK: - Shared JSON coding

/// Shared ISO8601 date coding strategy used across every domain model so that
/// the Swift client and the TypeScript API agree on the wire format.
public enum ShelfCaseCoding {
    /// Encode with fractional seconds. Plain `[.withInternetDateTime]` truncates
    /// to whole seconds, which breaks `Equatable` round-trips (and, worse, makes
    /// last-writer-wins conflict resolution tie on distinct timestamps).
    public static let iso8601: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(ISO8601DateFormatter.shelfCaseWithFractional.string(from: date))
    }

    public static let iso8601Decoding: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard
            let date = ISO8601DateFormatter.shelfCaseWithFractional.date(from: raw)
                ?? ISO8601DateFormatter.shelfCase.date(from: raw)
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date, got \(raw)"
            )
        }
        return date
    }

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = iso8601Decoding
        return decoder
    }
}

extension ISO8601DateFormatter {
    public static let shelfCase: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static let shelfCaseWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Enums

public enum ItemCategory: String, Codable, Equatable, CaseIterable, Sendable {
    case card
    case figure
    case vinyl
    case other
}

/// Grade multiplier table applied to the raw median market observation to
/// produce a grade-adjusted estimate.
public enum ConditionGrade: String, Codable, Equatable, CaseIterable, Sendable {
    case mint
    case nearMint
    case excellent
    case good
    case poor

    public var multiplier: Double {
        switch self {
        case .mint: return 1.25
        case .nearMint: return 1.00
        case .excellent: return 0.85
        case .good: return 0.65
        case .poor: return 0.40
        }
    }

    public var rank: Int {
        switch self {
        case .mint: return 5
        case .nearMint: return 4
        case .excellent: return 3
        case .good: return 2
        case .poor: return 1
        }
    }

    public var displayName: String {
        switch self {
        case .mint: return "Mint"
        case .nearMint: return "Near Mint"
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .poor: return "Poor"
        }
    }
}

public enum SyncState: String, Codable, Equatable, CaseIterable, Sendable {
    case synced
    case pendingCreate
    case pendingUpdate
    case pendingDelete
    case conflicted

    public var isPending: Bool {
        switch self {
        case .pendingCreate, .pendingUpdate, .pendingDelete: return true
        case .synced, .conflicted: return false
        }
    }
}

public enum TradeStatus: String, Codable, Equatable, CaseIterable, Sendable {
    case proposed
    case accepted
    case declined
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .accepted, .declined, .cancelled: return true
        case .proposed: return false
        }
    }
}
