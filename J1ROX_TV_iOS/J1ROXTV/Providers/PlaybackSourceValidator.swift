import Foundation

struct PlaybackProbe: Sendable {
    let status: Int
    let mimeType: String
    let prefix: Data
    var finalURL: URL? = nil
    var redirects: [String] = []
}

protocol PlaybackProbing: Sendable {
    func probe(_ request: URLRequest, maxBytes: Int) async throws -> PlaybackProbe
}

struct PlaybackSourceValidator: PlaybackSourceChecking {
    var transport: any PlaybackProbing = URLSessionPlaybackProbe()

    func validate(_ source: PlaybackSource) async throws { _ = try await inspect(source) }

    func inspect(_ source: PlaybackSource) async throws -> PlaybackValidation {

        guard ["https", "http"].contains(source.url.scheme?.lowercased() ?? ""),
              source.url.host?.isEmpty == false, source.url.user == nil, source.url.password == nil else {
            throw PlaybackError.invalidURL
        }
        guard source.expiresAt.map({ $0 > Date() }) ?? true else { throw ProviderError.expired }
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        source.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpMethod = "HEAD"
        let head = try await transport.probe(request, maxBytes: 0)
        let headUnsupported = head.status == 405 || head.status == 501
        if !headUnsupported { try Self.checkStatus(head.status) }
        let isHLS = source.url.pathExtension.lowercased() == "m3u8" || Self.hlsTypes.contains(head.mimeType)
        if !headUnsupported && head.mimeType == "video/mp4" && !isHLS { return .init(kind: .mp4, probe: head) }
        if !isHLS && !headUnsupported && !head.mimeType.isEmpty &&
            !Self.hlsTypes.contains(head.mimeType) && head.mimeType != "application/octet-stream" && !(isHLS && head.mimeType == "text/plain") {
            throw ProviderError.invalidContentType
        }
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        // If Range is ignored, the transport still stops reading after 1024 bytes.
        let get = try await transport.probe(request, maxBytes: 1024)
        try Self.checkStatus(get.status)
        if get.mimeType == "video/mp4" && !isHLS { return .init(kind: .mp4, probe: get) }
        // ATODO's CDN serves valid .m3u8 manifests as text/html. Trust the
        // manifest signature, not a mislabeled MIME; actual HTML/JSON still fails.
        if isHLS {
            let firstLine = String(decoding: get.prefix, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
                .components(separatedBy: .newlines).first
            if firstLine == "#EXTM3U" {
                let text = String(decoding: get.prefix, as: UTF8.self)
                return .init(kind: text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-I-FRAME-STREAM-INF:") ? .master :
                    (text.contains("#EXTINF:") || text.contains("#EXT-X-TARGETDURATION:") ? .media : .undetermined), probe: get)
            }
        }
        guard Self.hlsTypes.contains(get.mimeType) ||
              (["application/octet-stream", "text/plain"].contains(get.mimeType) && isHLS) else {
            throw ProviderError.invalidContentType
        }
        let prefix = String(decoding: get.prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard prefix.components(separatedBy: .newlines).first == "#EXTM3U" else { throw ProviderError.invalidPlaylist }
        let kind: PlaylistKind = prefix.contains("#EXT-X-STREAM-INF:") || prefix.contains("#EXT-X-I-FRAME-STREAM-INF:") ? .master :
            (prefix.contains("#EXTINF:") || prefix.contains("#EXT-X-TARGETDURATION:") ? .media : .undetermined)
        return .init(kind: kind, probe: get)

    }

    private static let hlsTypes: Set<String> = [
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"
    ]
    private static func checkStatus(_ status: Int) throws {
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
    }
}

struct URLSessionPlaybackProbe: PlaybackProbing {
    func probe(_ request: URLRequest, maxBytes: Int) async throws -> PlaybackProbe {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = ProbeRedirectDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        var prefix = Data()
        if maxBytes > 0 && (200..<300).contains(response.statusCode) {
            for try await byte in bytes {
                try Task.checkCancellation()
                prefix.append(byte)
                if prefix.count >= maxBytes { break }
            }
        }
        return PlaybackProbe(status: response.statusCode,
                             mimeType: response.mimeType?.lowercased() ?? "", prefix: prefix,
                             finalURL: response.url, redirects: delegate.snapshot())
    }
}

private final class ProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var chain: [String] = []
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return chain }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        chain.append("HTTP \(response.statusCode) \(PlaybackDiagnostics.url(response.url)) ? \(PlaybackDiagnostics.url(request.url))")
        lock.unlock()
        var redirected = request
        if response.url?.host != request.url?.host || response.url?.scheme != request.url?.scheme ||
            response.url?.port != request.url?.port {
            // Never forward provider credentials to a different origin.
            redirected.allHTTPHeaderFields = [:]
        }
        if response.url?.scheme == "https" && request.url?.scheme != "https" {
            completionHandler(nil)
        } else { completionHandler(redirected) }
    }
}

enum PlaylistKind: String, Sendable { case master, media, mp4, undetermined }
struct PlaybackValidation: Sendable {
    let kind: PlaylistKind
    let probe: PlaybackProbe
}
