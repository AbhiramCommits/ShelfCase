import Foundation
import ShelfCaseKit

/// Thin client for the marketplace endpoints (`/trades`, `/wishlist`).
///
/// These are request/response, user-initiated actions rather than queued offline
/// work, so they do not go through the sync engine's outbox. They reuse the
/// Kit's `HTTPPerforming` transport and ISO8601 coding so errors, dates and the
/// bearer token behave identically to the sync path.
public struct TradeService: Sendable {
    private let transport: HTTPPerforming
    private let token: String
    private let retryPolicy: RetryPolicy

    public init(
        transport: HTTPPerforming = URLSessionTransport(baseURL: AppConfiguration.baseURL),
        token: String = AppConfiguration.bearerToken,
        retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(250), jitterRatio: 0.3)
    ) {
        self.transport = transport
        self.token = token
        self.retryPolicy = retryPolicy
    }

    // MARK: Trades

    public func propose(_ trade: Trade) async throws -> Trade {
        struct Body: Encodable {
            let id: UUID
            let receiverUserId: UUID
            let offeredItemIds: [UUID]
            let requestedItemIds: [UUID]
        }
        let envelope: TradeEnvelope = try await send(
            method: "POST",
            path: "/trades",
            query: [:],
            body: Body(
                id: trade.id,
                receiverUserId: trade.receiverUserId,
                offeredItemIds: trade.offeredItemIds,
                requestedItemIds: trade.requestedItemIds
            )
        )
        return envelope.trade
    }

    public func trades(role: String) async throws -> [Trade] {
        let envelope: TradeListEnvelope = try await send(
            method: "GET",
            path: "/trades",
            query: ["role": role],
            body: Optional<EmptyBody>.none
        )
        return envelope.trades
    }

    public func accept(id: UUID) async throws -> Trade {
        let envelope: TradeEnvelope = try await send(
            method: "POST",
            path: "/trades/\(id.uuidString.lowercased())/accept",
            query: [:],
            body: Optional<EmptyBody>.none
        )
        return envelope.trade
    }

    public func decline(id: UUID) async throws -> Trade {
        let envelope: TradeEnvelope = try await send(
            method: "POST",
            path: "/trades/\(id.uuidString.lowercased())/decline",
            query: [:],
            body: Optional<EmptyBody>.none
        )
        return envelope.trade
    }

    // MARK: Wishlist

    public func wishlist() async throws -> [WishlistEntry] {
        let envelope: WishlistListEnvelope = try await send(
            method: "GET",
            path: "/wishlist",
            query: [:],
            body: Optional<EmptyBody>.none
        )
        return envelope.wishlistEntries
    }

    @discardableResult
    public func addWishlist(_ entry: WishlistEntry) async throws -> WishlistEntry {
        struct Body: Encodable {
            let id: UUID
            let titleQuery: String
            let maxPriceCents: Int
        }
        let envelope: WishlistEnvelope = try await send(
            method: "POST",
            path: "/wishlist",
            query: [:],
            body: Body(id: entry.id, titleQuery: entry.titleQuery, maxPriceCents: entry.maxPriceCents)
        )
        return envelope.wishlistEntry
    }

    public func deleteWishlist(id: UUID) async throws {
        _ = try await sendRaw(
            method: "DELETE",
            path: "/wishlist/\(id.uuidString.lowercased())",
            query: [:],
            body: Optional<EmptyBody>.none
        )
    }

    // MARK: Plumbing

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> Response {
        let response = try await sendRaw(method: method, path: path, query: query, body: body)
        do {
            return try ShelfCaseCoding.makeDecoder().decode(Response.self, from: response.body)
        } catch {
            throw APIClientError.decoding("\(error)")
        }
    }

    private func sendRaw<Body: Encodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(token)"]
        var encoded: Data?
        if let body {
            encoded = try ShelfCaseCoding.makeEncoder().encode(body)
            headers["Content-Type"] = "application/json"
        }
        // Every marketplace POST is safe to retry thanks to the server's
        // Idempotency-Key middleware.
        if method == "POST" {
            headers["Idempotency-Key"] = UUID().uuidString.lowercased()
        }

        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: encoded)

        var attempt = 0
        var generator = SystemRandomNumberGenerator()
        var lastError: APIClientError = .transport("no attempt made")

        while attempt < retryPolicy.maxAttempts {
            attempt += 1
            do {
                let response = try await transport.perform(request)
                switch response.statusCode {
                case 200..<300:
                    return response
                case 401, 403:
                    throw APIClientError.unauthorized
                case 409:
                    throw APIClientError.http(status: 409, body: response.bodyString)
                default:
                    throw APIClientError.http(status: response.statusCode, body: response.bodyString)
                }
            } catch let error as APIClientError {
                lastError = error
                guard error.isRetryable, attempt < retryPolicy.maxAttempts else { throw error }
                try await Task.sleep(for: retryPolicy.delay(forAttempt: attempt, using: &generator))
            }
        }
        throw lastError
    }
}

private struct EmptyBody: Encodable {}
private struct TradeEnvelope: Decodable { let trade: Trade }
private struct TradeListEnvelope: Decodable { let trades: [Trade] }
private struct WishlistEnvelope: Decodable { let wishlistEntry: WishlistEntry }
private struct WishlistListEnvelope: Decodable { let wishlistEntries: [WishlistEntry] }
