import Foundation

/// Monitoring has only its own Bearer header. Never ask a chat gateway for access credentials.
final class MonitoringRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = MonitoringRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest, let from = original.url, let to = request.url,
              Self.sameOrigin(from, to), to.user == nil, to.password == nil else {
            completionHandler(nil)
            return
        }
        // Rebuild from monitor-owned headers, never headers copied onto a redirect by a proxy.
        var safe = URLRequest(url: to)
        safe.httpMethod = original.httpMethod
        safe.timeoutInterval = original.timeoutInterval
        safe.cachePolicy = original.cachePolicy
        for name in ["Accept", "Cache-Control", "Authorization"] {
            safe.setValue(original.value(forHTTPHeaderField: name), forHTTPHeaderField: name)
        }
        completionHandler(safe)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        answer(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        answer(challenge, completionHandler: completionHandler)
    }

    private func answer(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // System trust evaluation is allowed. Every credential challenge is refused explicitly,
        // including a proposed client identity, rather than consulting default credential stores.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    private static func sameOrigin(_ from: URL, _ to: URL) -> Bool {
        guard let scheme = from.scheme?.lowercased(), ["http", "https"].contains(scheme),
              to.scheme?.lowercased() == scheme,
              let host = from.host?.lowercased(), to.host?.lowercased() == host else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (from.port ?? defaultPort) == (to.port ?? defaultPort)
    }
}
