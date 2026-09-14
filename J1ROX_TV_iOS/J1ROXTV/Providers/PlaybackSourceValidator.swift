import Foundation

struct PlaybackProbe: Sendable {
    let status: Int
    let mimeType: String
    let prefix: Data
}

protocol PlaybackProbing: Sendable {
    func probe(_ request: URLRequest, maxBytes: Int) async throws -> PlaybackProbe
}

struct PlaybackSourceValidator: PlaybackSourceChecking {
    var transport: any PlaybackProbing = URLSessionPlaybackProbe()

    func validate(_ source: PlaybackSource) async throws {
        guard ["https", "http"].contains(source.url.scheme?.lowercased() ?? "") else {
            throw ProviderError.invalidResponse
        }
        guard source.expiresAt.map({ $0 > Date() }) ?? true else { throw ProviderError.expired }
        var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        source.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpMethod = "HEAD"
        let head = try await transport.probe(request, maxBytes: 0)
        let headUnsupported = head.status == 405 || head.status == 501
        if !headUnsupported { try Self.checkStatus(head.status) }
        let isHLS = source.url.pathExtension.lowercased() == "m3u8" || Self.hlsTypes.contains(head.mimeType)
        if !headUnsupported && head.mimeType == "video/mp4" && !isHLS { return }
        if !headUnsupported && !head.mimeType.isEmpty &&
            !Self.hlsTypes.contains(head.mimeType) && head.mimeType != "application/octet-stream" && !(isHLS && head.mimeType == "text/plain") {
            throw ProviderError.invalidContentType
        }
        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        // If Range is ignored, the transport still stops reading after 1024 bytes.
        let get = try await transport.probe(request, maxBytes: 1024)
        try Self.checkStatus(get.status)
        if get.mimeType == "video/mp4" && !isHLS { return }
        guard Self.hlsTypes.contains(get.mimeType) ||
              (["application/octet-stream", "text/plain"].contains(get.mimeType) && isHLS) else {
            throw ProviderError.invalidContentType
        }
        let prefix = String(decoding: get.prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard prefix.hasPrefix("#EXTM3U") else { throw ProviderError.invalidPlaylist }
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
        let (bytes, response) = try await session.bytes(for: request, delegate: ProbeRedirectDelegate())
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
                             mimeType: response.mimeType?.lowercased() ?? "", prefix: prefix)
    }
}

private final class ProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
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
