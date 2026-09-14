#if DEBUG
import Foundation

/// Explicit user input only. Never discovers content or joins the production provider list.
struct TestHLSProvider: VideoProvider {
    let id = "debug-hls"
    let name = "Debug HLS"
    let availability = ProviderAvailability.available
    let url: URL
    let headers: [String: String]
    let expiresAt: Date?

    init(url: String, headers: [String: String] = [:], expiresAt: Date? = nil) throws {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host, !host.isEmpty, parsed.user == nil, parsed.password == nil else {
            throw PlaybackError.invalidURL
        }
        guard headers.allSatisfy({ !$0.key.contains(where: { $0.isNewline }) && !$0.value.contains(where: { $0.isNewline }) }) else {
            throw ProviderError.invalidResponse
        }
        self.url = parsed; self.headers = headers; self.expiresAt = expiresAt
    }
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for item: MediaItem) async throws -> (MediaItem, [SourceOption]) { (item, [.init(id: id, name: name)]) }
    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] { [:] }
    func translations(in content: [String: JSONValue]) -> [TranslationOption] { [] }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { [] }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { [] }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        var request = request; request.providerID = id; request.sourceID = id
        return [request]
    }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        PlaybackSource(request: request, url: url, providerID: id, providerName: name,
                       headers: headers, expiresAt: expiresAt)
    }
    // A manually supplied URL has no refresh endpoint. Default: refreshUnsupported.
}
/// Captures the resolver's real preflight result without making a second request.
actor PlaybackInspectionRecorder: PlaybackSourceChecking {
    private(set) var validation: PlaybackValidation?
    private(set) var failure: String?
    func validate(_ source: PlaybackSource) async throws {
        do {
            validation = try await PlaybackSourceValidator().inspect(source)
            failure = nil
        } catch {
            failure = PlaybackDiagnostics.error(error)
            throw error
        }
    }
}
#endif
