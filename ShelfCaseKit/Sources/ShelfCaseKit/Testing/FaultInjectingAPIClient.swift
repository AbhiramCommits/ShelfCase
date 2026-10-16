import Foundation

/// Deterministic, seeded fault-injection configuration.
///
/// This models what actually goes wrong on a phone in a lift, on a train, or in
/// a basement card shop — not a clean `500`:
///
///  * `timeoutRate`      — the request never left the device (server untouched).
///  * `dropResponseRate` — **the server committed the write and the reply never
///                         arrived.** This is the dangerous one: the client's
///                         view and the server's view disagree until something
///                         reconciles them.
///  * `serverErrorRate`  — a clean `500` that is retryable with no side effect.
///  * `latencyRange`     — added latency on every attempt.
public struct FaultProfile: Sendable, Equatable {
    public var seed: UInt64
    public var latencyRange: ClosedRange<Double>
    public var timeoutRate: Double
    public var dropResponseRate: Double
    public var serverErrorRate: Double

    public init(
        seed: UInt64 = 0x5eed,
        latencyRange: ClosedRange<Double> = 0...0,
        timeoutRate: Double = 0,
        dropResponseRate: Double = 0,
        serverErrorRate: Double = 0
    ) {
        self.seed = seed
        self.latencyRange = latencyRange
        self.timeoutRate = min(max(timeoutRate, 0), 1)
        self.dropResponseRate = min(max(dropResponseRate, 0), 1)
        self.serverErrorRate = min(max(serverErrorRate, 0), 1)
    }

    /// A clean link. Used to establish the baseline divergence.
    public static let reliable = FaultProfile(seed: 1)

    /// Typical "one bar of signal, walking around a convention hall".
    public static let flakyConventionHall = FaultProfile(
        seed: 0x5eed_1234,
        latencyRange: 0...0.25,
        timeoutRate: 0.10,
        dropResponseRate: 0.12,
        serverErrorRate: 0.05
    )

    /// Effectively offline: most attempts die on the way out.
    public static let basement = FaultProfile(
        seed: 0x5eed_9999,
        latencyRange: 0...0.4,
        timeoutRate: 0.55,
        dropResponseRate: 0.20,
        serverErrorRate: 0.10
    )
}

/// Counters for the instrumented trace.
public struct FaultMetrics: Sendable, Equatable {
    public var attempts = 0
    public var timeoutsInjected = 0
    public var droppedResponsesInjected = 0
    public var serverErrorsInjected = 0
    public var requestsPassedThrough = 0
    public var injectedLatencySeconds: Double = 0

    public init() {}
}

/// A seeded, deterministic wrapper around any `HTTPPerforming`.
///
/// Placed **below** the API client's retry loop, so retries, backoff and
/// idempotency-key reuse are all exercised by the real production code path.
public actor FaultInjectingAPIClient: HTTPPerforming {
    private let inner: HTTPPerforming
    private var profile: FaultProfile
    private var state: UInt64
    private var currentMetrics = FaultMetrics()

    public init(wrapping inner: HTTPPerforming, profile: FaultProfile) {
        self.inner = inner
        self.profile = profile
        self.state = profile.seed == 0 ? 0x9e37_79b9_7f4a_7c15 : profile.seed
    }

    public var metrics: FaultMetrics { currentMetrics }

    /// Swap the link quality mid-run (the soak harness flips between a reliable
    /// and a flaky link every cycle).
    public func configure(_ profile: FaultProfile) {
        self.profile = profile
        self.state = profile.seed == 0 ? 0x9e37_79b9_7f4a_7c15 : profile.seed
    }

    public func reset() {
        currentMetrics = FaultMetrics()
        state = profile.seed == 0 ? 0x9e37_79b9_7f4a_7c15 : profile.seed
    }

    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        currentMetrics.attempts += 1

        // 1. Latency.
        let latency = nextUnit() * (profile.latencyRange.upperBound - profile.latencyRange.lowerBound)
            + profile.latencyRange.lowerBound
        if latency > 0 {
            currentMetrics.injectedLatencySeconds += latency
            try? await Task.sleep(for: .seconds(latency))
        }

        // 2. Clean, side-effect-free failures.
        if nextUnit() < profile.serverErrorRate {
            currentMetrics.serverErrorsInjected += 1
            throw APIClientError.http(status: 503, body: "{\"error\":{\"code\":\"INJECTED\"}}")
        }
        if nextUnit() < profile.timeoutRate {
            currentMetrics.timeoutsInjected += 1
            throw APIClientError.timeout
        }

        // 3. The real thing.
        let response = try await inner.perform(request)

        // 4. The reply is lost on the way back — the server has already applied
        //    the write.
        if nextUnit() < profile.dropResponseRate {
            currentMetrics.droppedResponsesInjected += 1
            throw APIClientError.transport("response lost after the server committed")
        }

        currentMetrics.requestsPassedThrough += 1
        return response
    }

    /// splitmix64 — small, fast, and stable across platforms and Swift releases.
    private func nextUnit() -> Double {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
