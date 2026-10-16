import Foundation
import OSLog
import os

#if canImport(UIKit)
import UIKit
#endif

/// Lightweight event + error logger.
///
/// Three sinks, in order of durability:
///  1. **OSLog signposts** — sync intervals and retry counts, visible in
///     Instruments and in `Console.app` against the `com.shelfcase.app` subsystem.
///  2. **A rotating JSONL file** in Application Support — survives app kills and
///     is what you attach to a bug report.
///  3. **An optional `POST /telemetry`** batch, when a base URL is configured.
public struct TelemetryEvent: Codable, Sendable, Equatable {
    public var name: String
    public var timestamp: Date
    public var syncDurationMs: Int?
    public var retries: Int?
    public var conflicts: Int?
    public var pushed: Int?
    public var pulled: Int?
    public var errorMessage: String?
    public var sessionId: String?
    public var deviceModel: String?
    public var osVersion: String?
    public var appVersion: String?
    public var attributes: [String: String]?

    public init(
        name: String,
        timestamp: Date = Date(),
        syncDurationMs: Int? = nil,
        retries: Int? = nil,
        conflicts: Int? = nil,
        pushed: Int? = nil,
        pulled: Int? = nil,
        errorMessage: String? = nil,
        sessionId: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.name = name
        self.timestamp = timestamp
        self.syncDurationMs = syncDurationMs
        self.retries = retries
        self.conflicts = conflicts
        self.pushed = pushed
        self.pulled = pulled
        self.errorMessage = errorMessage
        self.sessionId = sessionId
        self.attributes = attributes
    }
}

public actor Telemetry {
    public static let shared = Telemetry()

    private let logger = Logger(subsystem: Self.subsystem, category: "telemetry")
    private let syncSignposter = OSSignposter(subsystem: Self.subsystem, category: "sync")

    private static let subsystem = "com.shelfcase.app"
    private static let maxFileBytes = 1_024 * 1_024

    private let sessionId = UUID().uuidString.lowercased()
    private var queue: [TelemetryEvent] = []
    private var baseURL: URL?
    private var uploadTask: Task<Void, Never>?

    public init() {}

    // MARK: Configuration

    public func configure(baseURL: URL?) {
        self.baseURL = baseURL
    }

    // MARK: Signposts

    public func beginSync() -> OSSignpostIntervalState {
        syncSignposter.beginInterval("sync", id: syncSignposter.makeSignpostID())
    }

    public func endSync(
        _ state: OSSignpostIntervalState,
        durationMs: Int,
        retries: Int,
        conflicts: Int
    ) {
        syncSignposter.endInterval(
            "sync",
            state,
            "durationMs=\(durationMs) retries=\(retries) conflicts=\(conflicts)"
        )
    }

    public func signpost(_ name: StaticString, _ message: String) {
        syncSignposter.emitEvent(name, "\(message, privacy: .public)")
    }

    // MARK: Recording

    public func record(_ event: TelemetryEvent) {
        var enriched = event
        enriched.sessionId = event.sessionId ?? sessionId
        enriched.deviceModel = event.deviceModel ?? Self.deviceModel
        enriched.osVersion = event.osVersion ?? Self.osVersion
        enriched.appVersion = event.appVersion ?? Self.appVersion

        if let errorMessage = event.errorMessage {
            logger.error("\(event.name, privacy: .public) error=\(errorMessage, privacy: .public)")
        } else {
            logger.info(
                "\(event.name, privacy: .public) durationMs=\(event.syncDurationMs ?? -1) retries=\(event.retries ?? 0) conflicts=\(event.conflicts ?? 0)"
            )
        }

        append(enriched)
        queue.append(enriched)
        if queue.count >= 20 {
            flush()
        }
    }

    /// Call on a crash-adjacent error path, or on `applicationWillTerminate`.
    public func flush() {
        guard !queue.isEmpty else { return }
        let batch = queue
        queue.removeAll(keepingCapacity: true)

        guard let baseURL else { return }
        uploadTask?.cancel()
        uploadTask = Task { [batch] in
            await Self.upload(batch, to: baseURL, logger: logger)
        }
    }

    /// Most recent events, newest first — used by the in-app diagnostics screen.
    public func recentEvents(limit: Int = 200) -> [TelemetryEvent] {
        guard let data = try? Data(contentsOf: Self.logFileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = ShelfCaseTelemetryCoding.decoder
        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(TelemetryEvent.self, from: lineData)
            }
            .reversed()
    }

    // MARK: File sink

    private func append(_ event: TelemetryEvent) {
        do {
            let url = Self.logFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded()

            let data = try ShelfCaseTelemetryCoding.encoder.encode(event)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(data)
                handle.write(Data("\n".utf8))
            } else {
                try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            }
        } catch {
            logger.error("telemetry.append_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateIfNeeded() {
        let url = Self.logFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > Self.maxFileBytes else { return }
        let rotated = url.deletingLastPathComponent().appendingPathComponent("telemetry.1.jsonl")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    static var logFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ShelfCase/telemetry.jsonl")
    }

    // MARK: Upload

    private static func upload(_ events: [TelemetryEvent], to baseURL: URL, logger: Logger) async {
        struct Payload: Encodable { let events: [TelemetryEvent] }
        struct Ack: Decodable { let accepted: Int }

        var request = URLRequest(url: baseURL.appendingPathComponent("telemetry"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? ShelfCaseTelemetryCoding.encoder.encode(Payload(events: events))
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let ack = try? JSONDecoder().decode(Ack.self, from: data)
            logger.debug("telemetry.uploaded status=\(status) accepted=\(ack?.accepted ?? -1)")
        } catch {
            logger.error("telemetry.upload_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Environment

    static var deviceModel: String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

enum ShelfCaseTelemetryCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
