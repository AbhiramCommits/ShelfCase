import Foundation
import ShelfCaseKit

/// Where the app points for its API, and who it claims to be.
///
/// Precedence: `UserDefaults` (set from the in-app Settings screen) →
/// `Info.plist` → the local development default.
public enum AppConfiguration {
    public static let fallbackBaseURL = URL(string: "http://localhost:4000")!

    public static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: Keys.baseURL),
           let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ShelfCaseAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return fallbackBaseURL
    }

    public static var bearerToken: String {
        UserDefaults.standard.string(forKey: Keys.token) ?? "dev-alice"
    }

    public static func setBaseURL(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.absoluteString, forKey: Keys.baseURL)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.baseURL)
        }
    }

    public static func setBearerToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: Keys.token)
    }

    private enum Keys {
        static let baseURL = "shelfcase.apiBaseURL"
        static let token = "shelfcase.apiToken"
    }
}

/// Builds the production API client: real `URLSession` transport, bearer auth,
/// and the default retry policy.
public enum APIClientFactory {
    public static func makeRetryingClient(
        baseURL: URL = AppConfiguration.baseURL,
        token: String = AppConfiguration.bearerToken,
        session: URLSession? = nil
    ) -> URLSessionAPIClient {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        let resolvedSession = session ?? URLSession(configuration: configuration)

        return URLSessionAPIClient(
            transport: URLSessionTransport(baseURL: baseURL, session: resolvedSession),
            tokenProvider: { token },
            retryPolicy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: .milliseconds(300),
                maxDelay: .seconds(8),
                jitterRatio: 0.3
            )
        )
    }
}
