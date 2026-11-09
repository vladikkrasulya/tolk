import Foundation

public enum TolkError: LocalizedError, Sendable {
    case unavailable(String)
    case http(provider: String, status: Int, message: String)
    case badResponse(String)
    case emptyTranslation(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(m): m
        case let .http(p, s, m): "\(p): HTTP \(s)\(m.isEmpty ? "" : " — \(m)")"
        case let .badResponse(m): m
        case let .emptyTranslation(p): "\(p): пустой ответ"
        }
    }
}

func expandPath(_ path: String) -> String { (path as NSString).expandingTildeInPath }
