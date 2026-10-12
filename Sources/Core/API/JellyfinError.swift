import Foundation

enum JellyfinError: LocalizedError {
    case badURL
    case notAuthenticated
    case http(status: Int, body: String)
    case notJellyfin
    case quickConnectDisabled
    case quickConnectExpired
    case decoding(String)
    case noMediaSource
    case liveStreamUnavailable

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That doesn't look like a valid server address."
        case .notAuthenticated:
            return "Not signed in to the server."
        case .http(let status, let body):
            return "Server error (\(status))\(body.isEmpty ? "" : ": \(body)")"
        case .notJellyfin:
            return "That address responded, but it doesn't look like a Jellyfin server."
        case .quickConnectDisabled:
            return "Quick Connect is disabled on this server. Enable it in the Jellyfin dashboard, or sign in with a password."
        case .quickConnectExpired:
            return "The Quick Connect code expired."
        case .decoding(let detail):
            return "Unexpected server response (\(detail))."
        case .noMediaSource:
            return "The server did not return a playable stream."
        case .liveStreamUnavailable:
            return "The server did not return an HLS stream for this channel."
        }
    }
}

extension Error {
    /// True when this error is a cancelled task or a cancelled URL request.
    var isCancellation: Bool {
        self is CancellationError
            || (self as? URLError)?.code == .cancelled
            || (self as NSError).code == NSURLErrorCancelled
                && (self as NSError).domain == NSURLErrorDomain
    }
}
