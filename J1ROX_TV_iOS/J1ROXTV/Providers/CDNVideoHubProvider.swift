import Foundation

/// Anonymous metadata and fresh HLS resolution; no cached signed URLs or embedded player.
struct CDNVideoHubProvider: VideoProvider {
    let id = "cdnvideohub"
    let name = "CDN VideoHub"
    let availability = ProviderAvailability.available
    let resolutionTimeout: TimeInterval? = 45
    var identify: @Sendable (MediaItem) async throws -> String = { media in
        try await ZonaProvider().kinopoiskID(for: media)
    }
    var fetch: @Sendable (String, [String: String]) async throws -> JSONValue = { path, query in
        var components = URLComponents(string: "https://plapi.cdnvideohub.com/api/v1/player/sv/" + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw ProviderError.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private let parser = AtodoProvider()
    static func voice(_ row: [String: JSONValue]) -> String {
        let studio = row.text("voiceStudio")
        let type = row.text("voiceType")
        return studio.isEmpty ? (type.isEmpty ? "Оригинал" : type) : studio
    }
    static func voiceID(_ row: [String: JSONValue]) -> String { "cdnvideohub:" + Data(voice(row).utf8).base64EncodedString() }
    private func rows(for media: MediaItem) async throws -> [[String: JSONValue]] {
        let kp = try await identify(media)
        guard Int(kp) ?? 0 > 0 else { throw ProviderError.mediaNotFound }
        guard let root = try await fetch("playlist", ["pub": "12", "aggr": "kp", "id": kp]).object,
              root["isSerial"] == .bool(media.mediaType == "tv") else { throw ProviderError.mediaNotFound }
        let rows = root["items"]?.array?.compactMap(\.object).filter { Int($0.text("vkId")) ?? 0 > 0 } ?? []
        guard !rows.isEmpty else { throw ProviderError.mediaNotFound }
        return rows
    }
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for media: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        _ = try await rows(for: media)
        return (media, [.init(id: id, name: name)])
    }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        _ = try await rows(for: request.media)
        var copy = request; copy.providerID = id; copy.sourceID = id
        if request.providerID != id { copy.translationID = nil }
        return [copy]
    }
    func content(for media: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        guard sourceID == id else { throw ProviderError.selectionUnavailable }
        let rows = try await rows(for: media)
        var seen = Set<String>()
        let translations: [JSONValue] = rows.filter { seen.insert(Self.voiceID($0)).inserted }.map { row in
            let matching = rows.filter { Self.voiceID($0) == Self.voiceID(row) }
            let numbers = Set(matching.compactMap { Int($0.text("season")) }.filter { $0 > 0 }).sorted()
            let seasons: [JSONValue] = numbers.map { number in
                let episodes = Set(matching.filter { Int($0.text("season")) == number }
                    .compactMap { Int($0.text("episode")) }.filter { $0 > 0 }).sorted()
                return .object(["season_number": .string(String(number)), "episodes": .array(episodes.map {
                    .object(["episode_number": .string(String($0)), "name": .string("\($0) серия")])
                })])
            }
            return .object(["id": .string(Self.voiceID(row)), "name": .string(Self.voice(row)), "seasons": .array(seasons)])
        }
        return ["translations": .array(translations)]
    }
    func translations(in content: [String: JSONValue]) -> [TranslationOption] { parser.translations(in: content) }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { parser.seasons(in: translation) }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { parser.episodes(in: season) }
    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        guard request.sourceID == id else { throw ProviderError.selectionUnavailable }
        var candidates = try await rows(for: request.media)
        if request.media.mediaType == "tv" {
            guard let season = request.season.flatMap(Int.init), let episode = request.episode.flatMap(Int.init), season > 0, episode > 0 else { throw ProviderError.selectionUnavailable }
            candidates = candidates.filter { Int($0.text("season")) == season && Int($0.text("episode")) == episode }
        }
        let matches = candidates.filter {
            (request.translationID == nil || request.translationID == Self.voiceID($0)) &&
            (request.translationName == nil || request.translationName == Self.voice($0))
        }
        guard let selected = matches.first else { throw ProviderError.selectionUnavailable }
        let result = try await fetch("video/" + selected.text("vkId"), [:])
        guard let sources = result.object?["sources"]?.object,
              let url = URL(string: sources.text("hlsUrl")), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw ProviderError.invalidResponse }
        var copy = request; copy.providerID = id; copy.translationID = Self.voiceID(selected); copy.translationName = Self.voice(selected)
        return PlaybackSource(request: copy, url: url, providerID: id, providerName: name, quality: "HLS")
    }
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource { try await playback(for: request) }
}
