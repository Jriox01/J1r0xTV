import Foundation

struct ZonaProvider: VideoProvider {
    let id = "zona"
    let name = "Zona"
    let availability = ProviderAvailability.available
    let resolutionTimeout: TimeInterval? = 60
    var fetch: @Sendable (String, [String: String]) async throws -> JSONValue = ZonaProvider.get
    var streamLoader: @Sendable (String, String?) async throws -> [JSONValue] = { kp, episode in
        try await ZonaStreamBridge.streams(kpID: kp, episodeKey: episode)
    }
    private let parser = AtodoProvider()

    static func get(_ path: String, _ query: [String: String]) async throws -> JSONValue {
        var components = URLComponents(string: "https://msx.zona.ms/" + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw ProviderError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func matches(_ row: [String: JSONValue], media: MediaItem) -> Bool {
        let wantedType = media.mediaType == "tv" ? "series" : "movie"
        guard row.text("type") == wantedType || (media.mediaType == "tv" && row.text("type") == "tv") else { return false }
        guard media.year.isEmpty || row.text("year") == media.year else { return false }
        let names = [media.title, media.originalTitle].filter { !$0.isEmpty }.map(normalized)
        return [row.text("title"), row.text("title_original")].contains { !normalized($0).isEmpty && names.contains(normalized($0)) }
    }
    private func metadata(_ media: MediaItem) async throws -> [String: JSONValue] {
        // Keep TMDB IDs separate from Zona/Kinopoisk IDs; never choose the first fuzzy search hit.
        let rows = try await fetch("search", ["query": media.title]).object?["data"]?.array ?? []
        let matches = rows.compactMap(\.object).filter { Self.matches($0, media: media) }
        guard matches.count == 1, let match = matches.first, !match.text("slug").isEmpty else { throw ProviderError.mediaNotFound }
        let category = media.mediaType == "tv" ? "series" : "movies"
        let slug = match.text("slug").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        guard let detail = try await fetch("api/\(category)/\(slug)", [:]).object?["data"]?.object,
              Int(detail.text("kp_id")) ?? 0 > 0 else { throw ProviderError.mediaNotFound }
        return detail
    }
    func search(_ query: MediaQuery) async throws -> [MediaItem] { [] }
    func sources(for media: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        _ = try await metadata(media)
        return (media, [.init(id: id, name: name)])
    }
    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        _ = try await metadata(request.media)
        var copy = request; copy.providerID = id; copy.sourceID = id
        if request.providerID != id { copy.translationID = nil }
        return [copy]
    }

    static func episodeKey(season: String?, episode: String?) throws -> String? {
        if season == nil && episode == nil { return nil }
        guard let season, let episode, let s = Int(season), let e = Int(episode), s > 0, e > 0 else {
            throw ProviderError.selectionUnavailable
        }
        return String(format: "S%02dE%02d", s, e)
    }
    struct Stream: Sendable {
        let voiceID: String
        let voiceName: String
        let url: URL
        let headers: [String: String]
        let quality: String
    }
    static func streams(_ results: [JSONValue]) -> [Stream] {
        var streams: [Stream] = []
        for result in results {
            guard let object = result.object, let extractor = object["extractorType"]?.object else { continue }
            for node in object["videoStreams"]?.array ?? [] {
                guard let value = node.object, let source = value["source"]?.object,
                      value["isTrailer"] != .bool(true),
                      ["HLS", "mp4"].contains(value.text("resolution")),
                      (value["parameters"]?.object?.text("urlTransform") ?? "").isEmpty,
                      let url = URL(string: source.text("url")), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil else { continue }
                let translation = value.text("translation", "language")
                let label = translation.isEmpty ? extractor.text("name") : translation
                let voiceID = "zona:" + Data((extractor.text("id") + "|" + label).utf8).base64EncodedString()
                let headers = source["headers"]?.object?.compactMapValues { node -> String? in
                    guard case .string(let value) = node, !value.contains("\r"), !value.contains("\n") else { return nil }
                    return value
                }.filter { !$0.key.contains("\r") && !$0.key.contains("\n") } ?? [:]
                streams.append(.init(voiceID: voiceID, voiceName: label.isEmpty ? "Оригинал" : label,
                                     url: url, headers: headers, quality: value.text("quality", "resolution")))
            }
        }
        return streams
    }

    private func seasonPayloads(_ detail: [String: JSONValue]) async throws -> [[String: JSONValue]] {
        let seasonRows = detail["seasons"]?.array?.compactMap(\.object).filter { $0["is_banned"] != .bool(true) } ?? []
        guard !seasonRows.isEmpty else { throw ProviderError.selectionUnavailable }
        let slug = detail.text("slug").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        // Bound concurrent catalog requests, including long-running series.
        var payloads: [[String: JSONValue]] = []
        for start in stride(from: 0, to: seasonRows.count, by: 4) {
            let batch = Array(seasonRows[start..<min(start + 4, seasonRows.count)])
            let fetch = self.fetch
            let values = try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
                for row in batch {
                    group.addTask {
                        let number = row.text("part")
                        guard Int(number) ?? 0 > 0,
                              let seasonDetail = try await fetch("api/series/\(slug)", ["season": number]).object?["data"]?.object else {
                            throw ProviderError.invalidResponse
                        }
                        let episodes = seasonDetail["episodes"]?.array?.compactMap(\.object)
                            .filter { $0["is_banned"] != .bool(true) }.map { ep -> JSONValue in
                                .object(["episode_number": .string(ep.text("part")), "name": .string(ep.text("title")), "image": .string(ep.text("cover_url"))])
                            } ?? []
                        return ["season_number": .string(number), "episodes": .array(episodes)]
                    }
                }
                var result: [[String: JSONValue]] = []
                for try await value in group { result.append(value) }
                return result
            }
            payloads += values
        }
        return payloads.sorted { $0.text("season_number").localizedStandardCompare($1.text("season_number")) == .orderedAscending }
    }
    func content(for media: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        guard sourceID == id else { throw ProviderError.selectionUnavailable }
        let detail = try await metadata(media)
        let seasons = media.mediaType == "tv" ? try await seasonPayloads(detail) : []
        let firstSeason = seasons.first { !($0["episodes"]?.array ?? []).isEmpty }
        guard media.mediaType != "tv" || firstSeason != nil else { throw ProviderError.selectionUnavailable }
        let key = try Self.episodeKey(season: firstSeason?.text("season_number"),
                                      episode: firstSeason?["episodes"]?.array?.first?.object?.text("episode_number"))
        let values = Self.streams(try await streamLoader(detail.text("kp_id"), key))
        guard !values.isEmpty else { throw StreamingError.noCompatibleSource }
        var seen: Set<String> = []
        let translations: [JSONValue] = values.filter { seen.insert($0.voiceID).inserted }.map { stream in
            .object(["id": .string(stream.voiceID), "name": .string(stream.voiceName), "seasons": .array(seasons.map(JSONValue.object))])
        }
        return ["translations": .array(translations)]
    }
    func translations(in content: [String: JSONValue]) -> [TranslationOption] { parser.translations(in: content) }
    func seasons(in translation: TranslationOption) -> [SeasonOption] { parser.seasons(in: translation) }
    func episodes(in season: SeasonOption) -> [EpisodeOption] { parser.episodes(in: season) }

    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        guard request.sourceID == id else { throw ProviderError.selectionUnavailable }
        let detail = try await metadata(request.media)
        let key = try Self.episodeKey(season: request.season, episode: request.episode)
        guard request.media.mediaType != "tv" || key != nil else { throw ProviderError.selectionUnavailable }
        let values = Self.streams(try await streamLoader(detail.text("kp_id"), key))
        let selected = values.first { $0.voiceID == request.translationID && (request.translationName == nil || request.translationName == $0.voiceName) }
            ?? values.first { request.translationID == nil && (request.translationName == nil || request.translationName == $0.voiceName) }
        guard let selected else { throw ProviderError.selectionUnavailable }
        var copy = request; copy.providerID = id; copy.translationID = selected.voiceID; copy.translationName = selected.voiceName
        return PlaybackSource(request: copy, url: selected.url, providerID: id, providerName: name,
                              headers: selected.headers, quality: selected.quality)
    }
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource { try await playback(for: request) }
}
