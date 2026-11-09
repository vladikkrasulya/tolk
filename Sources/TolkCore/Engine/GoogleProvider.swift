import Foundation

/// Fallback: the unofficial Google Translate endpoint used by browser extensions. One chunk.
public final class GoogleProvider: TranslationProvider, @unchecked Sendable {
    public let name = "Google"
    private let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
    }

    public func isAvailable() async -> Bool { true }

    public func translate(_ request: ResolvedRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.fetch(request)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetch(_ r: ResolvedRequest) async throws -> String {
        let params = [("client", "gtx"), ("sl", r.source.googleCode), ("tl", r.target.googleCode), ("dt", "t")]
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req: URLRequest
        let q = URLQueryItem(name: "q", value: r.text)
        var probe = comps; probe.queryItems!.append(q)
        if let url = probe.url, url.absoluteString.utf8.count < 1800 {
            req = URLRequest(url: url)
        } else {
            // Long text: put q into a form body.
            req = URLRequest(url: comps.url!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = ("q=" + Self.formEncode(r.text)).data(using: .utf8)
        }
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TolkError.http(provider: name, status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw TolkError.badResponse("Google: непонятный ответ")
        }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { throw TolkError.emptyTranslation(name) }
        return text
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
