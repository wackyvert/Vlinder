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
        }
    }
}
