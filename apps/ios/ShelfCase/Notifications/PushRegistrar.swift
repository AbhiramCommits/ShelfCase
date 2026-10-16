import Foundation
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

/// Push registration plus the local notifications that stand in for push while
/// the app is in the foreground.
///
/// Local notifications are raised for the two events the server tells us about
/// inline: a wishlist match on `POST /items` (`wishlistMatches`) and a newly
/// proposed trade. The APNs payload shape the backend is expected to send is
/// documented in `docs/APNS.md`.
public final class PushRegistrar: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = PushRegistrar()

    public enum PushError: LocalizedError {
        case denied
        case registrationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .denied: return "Notifications are turned off for ShelfCase."
            case .registrationFailed(let reason): return "Push registration failed: \(reason)"
            }
        }
    }

    private var deviceToken: String?

    public override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Permission

    @discardableResult
    public func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else { throw PushError.denied }
        await registerForRemoteNotifications()
        return granted
    }

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Remote registration

    @MainActor
    private func registerForRemoteNotifications() async {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Called from `UIApplicationDelegate` once APNs hands back a token.
    public func store(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task {
            await Telemetry.shared.record(TelemetryEvent(
                name: "push.registered",
                attributes: ["tokenPrefix": String(hex.prefix(8))]
            ))
        }
    }

    public var registeredDeviceToken: String? { deviceToken }

    // MARK: Local notifications

    /// Raised when `POST /items` reports a wishlist match for someone else's
    /// standing query.
    public func notifyWishlistMatch(title: String, matchedQuery: String, valueCents: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Wishlist match"
        content.body = "“\(title)” matches your “\(matchedQuery)” search at \(format(cents: valueCents))."
        content.sound = .default
        content.userInfo = ["kind": "wishlistMatch", "title": title, "query": matchedQuery]
        await deliver(content, identifier: "wishlist-\(title)-\(matchedQuery)")
    }

    public func notifyTradeProposal(from displayName: String, itemCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "New trade proposal"
        content.body = "\(displayName) wants to swap \(itemCount) item(s) with you."
        content.sound = .default
        content.userInfo = ["kind": "tradeProposal"]
        await deliver(content, identifier: "trade-\(UUID().uuidString)")
    }

    /// Raised when a sync run resolved a conflict, so the user knows a field was
    /// changed out from under them.
    public func notifyConflictResolved(itemTitle: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Edit reconciled"
        content.body = "“\(itemTitle)” was changed on another device. ShelfCase kept the newest edit."
        content.userInfo = ["kind": "conflictResolved"]
        await deliver(content, identifier: "conflict-\(itemTitle)-\(UUID().uuidString)")
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            await Telemetry.shared.record(TelemetryEvent(
                name: "push.deliver_failed",
                errorMessage: error.localizedDescription
            ))
        }
    }

    private func format(cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents)¢"
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while the app is in the foreground — a wishlist match
    /// matters most when the user is actively browsing.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await Telemetry.shared.record(TelemetryEvent(
            name: "push.opened",
            attributes: ["kind": (response.notification.request.content.userInfo["kind"] as? String) ?? "unknown"]
        ))
    }
}
