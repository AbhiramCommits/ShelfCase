import Foundation

/// A single structured log line emitted by the sync stack.
///
/// Deliberately tiny and dependency-free so the same events can back OSLog in
/// the app, NDJSON in `Telemetry`, and the `ShelfCaseSyncSoak` trace output used
/// for the investigations in `docs/DEBUGGING.md`.
public struct TraceEvent: Sendable, Equatable {
    public enum Level: String, Sendable {
        case debug, info, warn, error
    }

    public var timestamp: Date
    /// Correlates every line belonging to one logical operation — one pending
    /// change, one pull page — mirroring the server's `X-Request-Id`.
    public var requestId: String
    public var level: Level
    public var event: String
    public var fields: [String: String]

    public init(
        timestamp: Date = Date(),
        requestId: String,
        level: Level = .info,
        event: String,
        fields: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.requestId = requestId
        self.level = level
        self.event = event
        self.fields = fields
    }

    /// NDJSON, the same shape the server writes.
    public var jsonLine: String {
        var payload: [String: Any] = [
            "ts": ISO8601DateFormatter.shelfCaseWithFractional.string(from: timestamp),
            "level": level.rawValue,
            "requestId": requestId,
            "event": event,
        ]
        for (key, value) in fields { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"event\":\"\(event)\"}"
        }
        return text
    }

    /// Human-readable form used by the harness.
    public var consoleLine: String {
        let stamp = ISO8601DateFormatter.shelfCaseWithFractional.string(from: timestamp)
        let rendered = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        return "\(stamp) \(level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) [\(requestId)] \(event)\(rendered.isEmpty ? "" : " " + rendered)"
    }
}

/// A sink for `TraceEvent`s. A struct rather than a bare closure so call sites
/// can use `trace?.emit(...)` and so it composes cleanly with `Sendable`.
public struct TraceSink: Sendable {
    private let handler: @Sendable (TraceEvent) -> Void

    public init(_ handler: @escaping @Sendable (TraceEvent) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ event: TraceEvent) {
        handler(event)
    }

    public func emit(
        requestId: String,
        _ event: String,
        level: TraceEvent.Level = .info,
        _ fields: [String: String] = [:]
    ) {
        handler(TraceEvent(requestId: requestId, level: level, event: event, fields: fields))
    }
}

/// Mints short, human-greppable correlation ids.
public enum TraceIdentifiers {
    public static func next(prefix: String = "req") -> String {
        let alphabet = Array("0123456789abcdef")
        let suffix = String((0..<8).map { _ in alphabet.randomElement() ?? "0" })
        return "\(prefix)-\(suffix)"
    }
}
