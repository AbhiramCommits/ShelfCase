import Foundation

// MARK: - Typed errors

/// Every failure the sync engine can observe, classified so the retry policy and
/// the conflict policy can each make a decision without inspecting strings.
public enum APIClientError: Error, Equatable, Sendable {
    /// Socket-level failure (connection reset, DNS, TLS…). Retryable.
    case transport(String)
    /// The request did not complete inside the timeout. Retryable, and
    /// *ambiguous*: the server may or may not have applied it.
    case timeout
    /// A non-2xx response that is not a version conflict.
    case http(status: Int, body: String?)
    /// The response did not match the expected shape.
    case decoding(String)
    /// `409` carrying the server's current copy of the row.
    case conflict(serverItem: CollectibleItem)
    case unauthorized
    /// The caller supplied a payload the client refuses to send.
    case invalidRequest(String)

    /// Whether the retry policy should try again.
    public var isRetryable: Bool {
        switch self {
        case .transport, .timeout:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || (500..<600).contains(status)
        case .decoding, .conflict, .unauthorized, .invalidRequest:
            return false
        }
    }

    public var describingForTelemetry: String {
        switch self {
        case .transport(let message): return "transport:\(message)"
        case .timeout: return "timeout"
        case .http(let status, _): return "http:\(status)"
        case .decoding(let message): return "decoding:\(message)"
        case .conflict: return "conflict"
        case .unauthorized: return "unauthorized"
        case .invalidRequest(let message): return "invalidRequest:\(message)"
        }
    }
}

// MARK: - Retry policy

public struct RetryPolicy: Equatable, Sendable {
    public var maxAttempts: Int
    /// Delay before the first retry; doubles every attempt.
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Fraction of the delay that is randomised, 0...1.
    public var jitterRatio: Double

    public init(
        maxAttempts: Int = 4,
        baseDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(8),
        jitterRatio: Double = 0.3
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterRatio = min(max(jitterRatio, 0), 1)
    }

    /// Fast policy for tests and the soak harness: same shape, tiny delays.
    public static let immediate = RetryPolicy(
        maxAttempts: 4,
        baseDelay: .milliseconds(1),
        maxDelay: .milliseconds(4),
        jitterRatio: 0.25
    )

    /// Exponential backoff with full-width jitter, capped at `maxDelay`.
    /// `attempt` is 1-based: attempt 1 is the first *retry*.
    public func delay(forAttempt attempt: Int, using generator: inout some RandomNumberGenerator) -> Duration {
        let exponent = max(0, attempt - 1)
        let raw = baseDelay * Int(1 << min(exponent, 20))
        let capped = min(raw, maxDelay)
        guard jitterRatio > 0 else { return capped }
        let milliseconds = Double(capped.components.seconds) * 1000
            + Double(capped.components.attoseconds) / 1e15
        let spread = milliseconds * jitterRatio
        let jittered = milliseconds - spread / 2 + Double.random(in: 0...spread, using: &generator)
        return .milliseconds(Int(max(0, jittered.rounded())))
    }
}

// MARK: - Transport

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Stable identity used by the fake transports to route requests.
    public var routeKey: String { "\(method) \(path)" }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
}

/// One HTTP round trip. Implemented by `URLSessionTransport` in the app and by
/// the in-process transports in tests and the soak harness.
public protocol HTTPPerforming: Sendable {
    func perform(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - URLSession transport

/// Real network transport.
public struct URLSessionTransport: HTTPPerforming {
    public let baseURL: URL
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        )
        if !request.query.isEmpty {
            components?.queryItems = request.query
                .map { URLQueryItem(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
        guard let url = components?.url else {
            throw APIClientError.invalidRequest("Could not build URL for \(request.path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIClientError.transport("Non-HTTP response for \(request.routeKey)")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers["\(key)".lowercased()] = "\(value)"
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as APIClientError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw APIClientError.timeout
            default:
                throw APIClientError.transport("\(error.code.rawValue): \(error.localizedDescription)")
            }
        } catch {
            throw APIClientError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Wire types

public struct WishlistMatch: Codable, Equatable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let titleQuery: String
    public let maxPriceCents: Int
    public let createdAt: Date
}

public struct ItemWriteResponse: Codable, Equatable, Sendable {
    public let item: CollectibleItem
    public let wishlistMatches: [WishlistMatch]?
}

public struct SyncPullPage: Codable, Equatable, Sendable {
    public var items: [CollectibleItem]
    public var observations: [PriceObservation]
    public var trades: [Trade]
    public var wishlistEntries: [WishlistEntry]
    public var nextCursor: String
    public var hasMore: Bool

    public init(
        items: [CollectibleItem] = [],
        observations: [PriceObservation] = [],
        trades: [Trade] = [],
        wishlistEntries: [WishlistEntry] = [],
        nextCursor: String = "1970-01-01T00:00:00.000Z|0",
        hasMore: Bool = false
    ) {
        self.items = items
        self.observations = observations
        self.trades = trades
        self.wishlistEntries = wishlistEntries
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

// MARK: - API surface

/// The operations the sync engine needs. Deliberately small: everything the app
/// does that is not a sync (trades, wishlist browsing) can be layered on top.
public protocol ShelfCaseAPI: Sendable {
    func createItem(_ item: CollectibleItem, idempotencyKey: String) async throws -> ItemWriteResponse
    func updateItem(_ item: CollectibleItem, idempotencyKey: String) async throws -> ItemWriteResponse
    func deleteItem(id: UUID, version: Int, idempotencyKey: String) async throws -> ItemWriteResponse
    func pull(since: String?) async throws -> SyncPullPage
}

// MARK: - Metrics

public struct APIClientMetrics: Equatable, Sendable {
    public var requestsSent: Int = 0
    public var retries: Int = 0
    public var conflicts: Int = 0
    public var decodeFailures: Int = 0

    public init() {}
}

/// Lets the sync engine attribute retry counts to a pass without knowing which
/// concrete API client it was handed.
public protocol APIClientMetricsReporting: Sendable {
    var metrics: APIClientMetrics { get }
}

// MARK: - URLSession API client

/// `ShelfCaseAPI` over an injectable `HTTPPerforming`, with bearer auth,
/// per-operation `Idempotency-Key`s, typed errors, and capped exponential
/// backoff with jitter.
public final class URLSessionAPIClient: ShelfCaseAPI, APIClientMetricsReporting, @unchecked Sendable {
    public typealias KeyGenerator = @Sendable () -> String

    private let transport: HTTPPerforming
    private let tokenProvider: @Sendable () -> String?
    private let retryPolicy: RetryPolicy
    private let keyGenerator: KeyGenerator
    private let lock = NSLock()
    private var mutableMetrics = APIClientMetrics()

    public init(
        transport: HTTPPerforming,
        tokenProvider: @escaping @Sendable () -> String?,
        retryPolicy: RetryPolicy = RetryPolicy(),
        keyGenerator: @escaping KeyGenerator = { UUID().uuidString.lowercased() }
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.retryPolicy = retryPolicy
        self.keyGenerator = keyGenerator
    }

    public var metrics: APIClientMetrics {
        lock.lock()
        defer { lock.unlock() }
        return mutableMetrics
    }

    // MARK: Item writes

    public func createItem(_ item: CollectibleItem, idempotencyKey: String) async throws -> ItemWriteResponse {
        // NOTE: the create payload intentionally omits the client-generated id —
        // the server is treated as the authority for row identity.
        let payload = CreateItemPayload(item: item)
        return try await send(
            method: "POST",
            path: "/items",
            body: payload,
            idempotencyKey: idempotencyKey
        )
    }

    public func updateItem(_ item: CollectibleItem, idempotencyKey: String) async throws -> ItemWriteResponse {
        let payload = UpdateItemPayload(item: item)
        return try await send(
            method: "PATCH",
            path: "/items/\(item.id.uuidString.lowercased())",
            body: payload,
            idempotencyKey: idempotencyKey
        )
    }

    public func deleteItem(id: UUID, version: Int, idempotencyKey: String) async throws -> ItemWriteResponse {
        try await send(
            method: "DELETE",
            path: "/items/\(id.uuidString.lowercased())",
            query: ["version": String(version)],
            body: Optional<EmptyBody>.none,
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: Pull

    public func pull(since: String?) async throws -> SyncPullPage {
        var query: [String: String] = [:]
        if let since { query["since"] = since }
        return try await send(
            method: "GET",
            path: "/sync/pull",
            query: query,
            body: Optional<EmptyBody>.none,
            idempotencyKey: nil
        )
    }

    // MARK: Core

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Body?,
        idempotencyKey: String?
    ) async throws -> Response {
        var headers: [String: String] = ["Accept": "application/json"]
        if let token = tokenProvider() {
            headers["Authorization"] = "Bearer \(token)"
        }
        // A GET must never carry an idempotency key: the server's middleware is
        // deliberately POST-only and the header would be meaningless.
        if let idempotencyKey, method != "GET" {
            headers["Idempotency-Key"] = idempotencyKey
        }

        var encoded: Data?
        if let body {
            encoded = try ShelfCaseCoding.makeEncoder().encode(body)
            headers["Content-Type"] = "application/json"
        }

        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: encoded)

        var attempt = 0
        var lastError: APIClientError = .transport("no attempt made")
        var generator = SystemRandomNumberGenerator()

        while attempt < retryPolicy.maxAttempts {
            attempt += 1
            noteRequest()
            do {
                let response = try await transport.perform(request)
                return try interpret(response)
            } catch let error as APIClientError {
                lastError = error
                guard error.isRetryable, attempt < retryPolicy.maxAttempts else { throw error }
                noteRetry()
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt, using: &generator))
            }
        }
        throw lastError
    }

    private func interpret<Response: Decodable>(_ response: HTTPResponse) throws -> Response {
        let decoder = ShelfCaseCoding.makeDecoder()

        switch response.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(Response.self, from: response.body)
            } catch {
                noteDecodeFailure()
                throw APIClientError.decoding("\(error)")
            }
        case 401, 403:
            throw APIClientError.unauthorized
        case 409:
            noteConflict()
            if let envelope = try? decoder.decode(ConflictEnvelope.self, from: response.body) {
                throw APIClientError.conflict(serverItem: envelope.error.details.serverItem)
            }
            throw APIClientError.http(status: 409, body: response.bodyString)
        default:
            throw APIClientError.http(status: response.statusCode, body: response.bodyString)
        }
    }

    // MARK: Metrics

    private func noteRequest() {
        lock.lock(); mutableMetrics.requestsSent += 1; lock.unlock()
    }

    private func noteRetry() {
        lock.lock(); mutableMetrics.retries += 1; lock.unlock()
    }

    private func noteConflict() {
        lock.lock(); mutableMetrics.conflicts += 1; lock.unlock()
    }

    private func noteDecodeFailure() {
        lock.lock(); mutableMetrics.decodeFailures += 1; lock.unlock()
    }
}

// MARK: - Request bodies

private struct EmptyBody: Encodable {}

/// Body for `POST /items`.
///
/// The client deliberately does **not** send `id`: row identity is treated as
/// server-owned, and the local item is re-keyed from the response.
struct CreateItemPayload: Encodable {
    let title: String
    let setName: String
    let category: ItemCategory
    let conditionGrade: ConditionGrade
    let purchasePriceCents: Int
    let estimatedValueCents: Int
    let acquiredAt: Date
    let notes: String
    let imageLocalPath: String?

    init(item: CollectibleItem) {
        self.title = item.title
        self.setName = item.setName
        self.category = item.category
        self.conditionGrade = item.conditionGrade
        self.purchasePriceCents = item.purchasePriceCents
        self.estimatedValueCents = item.estimatedValueCents
        self.acquiredAt = item.acquiredAt
        self.notes = item.notes
        self.imageLocalPath = item.imageLocalPath
    }
}

/// Body for `PATCH /items/:id`. Carries `version` so the server can reject a
/// stale write with `409`.
struct UpdateItemPayload: Encodable {
    let title: String
    let setName: String
    let category: ItemCategory
    let conditionGrade: ConditionGrade
    let purchasePriceCents: Int
    let estimatedValueCents: Int
    let notes: String
    let imageLocalPath: String?
    let version: Int

    init(item: CollectibleItem) {
        self.title = item.title
        self.setName = item.setName
        self.category = item.category
        self.conditionGrade = item.conditionGrade
        self.purchasePriceCents = item.purchasePriceCents
        self.estimatedValueCents = item.estimatedValueCents
        self.notes = item.notes
        self.imageLocalPath = item.imageLocalPath
        self.version = item.version
    }
}

// MARK: - Error envelope

struct ConflictEnvelope: Decodable {
    struct Payload: Decodable {
        struct Details: Decodable {
            let serverItem: CollectibleItem
        }
        let code: String
        let message: String
        let details: Details
    }
    let error: Payload
}
