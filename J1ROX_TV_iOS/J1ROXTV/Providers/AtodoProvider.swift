import Foundation

private func unwrapItems(_ value: JSONValue) -> [[String: JSONValue]] {
    if let array = value.array { return array.compactMap(\.object) }
    guard let object = value.object else { return [] }
    for key in ["results", "items", "data", "movies", "content", "list", "docs"] {
        if let child = object[key] { let result = unwrapItems(child); if !result.isEmpty { return result } }
    }
    return []
}
private func unwrapObject(_ value: JSONValue) -> [String: JSONValue] {
    guard let object = value.object else { return [:] }
    return object["data"]?.object ?? object
}

struct CatalogService {
    var client: any ProviderAPI = APIClient.shared
    func catalog(type: String, page: Int = 1) async throws -> [MediaItem] {
        let payload = try await client.get(path: "api/list", query: ["type_movie": type, "page": String(page)])
        return unwrapItems(payload).map { MediaItem.parse($0, fallbackType: type) }
    }
}
struct SearchService {
    var client: any ProviderAPI = APIClient.shared
    func search(_ query: String, page: Int = 1) async throws -> [MediaItem] {
        let payload = try await client.get(path: "api/search", query: ["query": query, "page": String(page)])
        return unwrapItems(payload).map { MediaItem.parse($0) }
    }
}
struct DetailsService {
    var client: any ProviderAPI = APIClient.shared
    func details(type: String, id: String) async throws -> MediaItem {
        var root = try await client.get(path: "api/details/\(type)/\(id)")
        if let object = root.object { for key in ["data", "result", "item", "movie"] { if let nested = object[key]?.object { root = .object(nested); break } } }
        guard let object = root.object else { throw APIError.invalidJSON }
        return MediaItem.parse(object, fallbackType: type)
    }
}

extension JSONValue {
    fileprivate var jsonObject: Any {
        switch self { case .string(let v): v; case .number(let v): v; case .bool(let v): v; case .object(let v): v.mapValues(\.jsonObject); case .array(let v): v.map(\.jsonObject); case .null: NSNull() }
    }
}

final class AtodoProvider: VideoProvider, @unchecked Sendable {
    let id = "atodo"
    let name = "Atodo"
    let availability = ProviderAvailability.available
    private let client: any ProviderAPI
    private let details: DetailsService
    init(client: any ProviderAPI = APIClient.shared) {
        self.client = client
        self.details = DetailsService(client: client)
    }

    func search(_ query: MediaQuery) async throws -> [MediaItem] {
        if let id = query.tmdbID, !id.isEmpty {
            return [try await details.details(type: query.mediaType, id: id)]
        }
        return try await SearchService(client: client).search(query.title).filter {
            (query.year == nil || query.year == $0.year) && $0.mediaType == query.mediaType
        }
    }

    func requests(for request: PlaybackRequest) async throws -> [PlaybackRequest] {
        let (_, options) = try await sources(for: request.media)
        let ordered = options.filter { $0.id == request.sourceID } + options.filter { $0.id != request.sourceID }
        return ordered.map { option in
            var next = request
            next.providerID = id
            next.sourceID = option.id
            if option.id != request.sourceID && request.translationName != nil { next.translationID = nil }
            return next
        }
    }

    func playback(for request: PlaybackRequest) async throws -> PlaybackSource {
        let (selected, container) = try await selectedContainer(for: request)
        return try await resolve(selected, container: container)
    }

    func downloads(for request: PlaybackRequest) async throws -> [DownloadVariant] {
        let (selected, container) = try await selectedContainer(for: request)
        guard selected.translationID == request.translationID else { throw ProviderError.selectionUnavailable }
        var metadata = container
        if metadata["downloads"] == nil, let data = container["data"]?.object {
            let bytes = try JSONSerialization.data(withJSONObject: data.mapValues(\.jsonObject))
            metadata = unwrapObject(try await client.get(path: "api/source/\(request.sourceID ?? "")",
                query: ["data": bytes.base64EncodedString()]))
        }
        return DownloadVariant.parse(metadata)
    }

    private func selectedContainer(for request: PlaybackRequest) async throws -> (PlaybackRequest, [String: JSONValue]) {
        guard let sourceID = request.sourceID else { throw ProviderError.selectionUnavailable }
        let full = try await details.details(type: request.media.mediaType, id: request.media.id)
        let content = try await content(for: full, sourceID: sourceID)
        let options = translations(in: content)
        let translation: TranslationOption?
        if let name = request.translationName {
            translation = options.first { $0.id == request.translationID && $0.name == name } ?? options.first { $0.name == name }
        } else {
            translation = options.first { $0.id == request.translationID } ?? options.first
        }
        guard let translation else { throw ProviderError.selectionUnavailable }
        var container = translation.payload
        if let seasonNumber = request.season, !seasonNumber.isEmpty {
            guard let season = seasons(in: translation).first(where: { $0.number == seasonNumber }) else {
                throw ProviderError.selectionUnavailable
            }
            container = season.payload
            if let episodeNumber = request.episode, !episodeNumber.isEmpty {
                guard let episode = episodes(in: season).first(where: { $0.number == episodeNumber }) else {
                    throw ProviderError.selectionUnavailable
                }
                container = episode.payload
            }
        } else if request.episode != nil { throw ProviderError.selectionUnavailable }
        var selected = request
        selected.translationID = translation.id
        selected.translationName = translation.name
        selected.providerID = id
        return (selected, container)
    }

    func sources(for input: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        let item = input.mediaType == "tv" ? try await details.details(type: "tv", id: input.id) : input
        let payload = try await client.get(path: "api/source/list", query: canonical(item))
        let balancers = unwrapObject(payload)["balancers"]?.array ?? []
        return (item, balancers.compactMap { value in
            guard let object = value.object else { return nil }
            let id = object.text("id", "source_id", "key")
            return id.isEmpty ? nil : SourceOption(id: id, name: object.text("name", "title", "label").nilIfEmpty ?? id)
        })
    }

    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        unwrapObject(try await client.get(path: "api/source/\(sourceID)", query: canonical(item)))
    }

    func translations(in object: [String: JSONValue]) -> [TranslationOption] {
        collection(object["translations"], keys: ["translation_id", "id"]).enumerated().map { index, entry in
            let explicit = entry.value.text("translation_name", "name", "title", "label", "voice", "studio")
            return TranslationOption(id: entry.value.text("translation_id", "id").nilIfEmpty ?? entry.key, name: explicit.nilIfEmpty ?? "Озвучка №\(index + 1)", payload: entry.value)
        }
    }
    func seasons(in translation: TranslationOption) -> [SeasonOption] {
        collection(translation.payload["seasons"], keys: ["season_number", "season", "number", "id"]).map {
            let number = $0.value.text("season_number", "season", "number").nilIfEmpty ?? $0.key
            return SeasonOption(id: $0.value.text("id", "season_id").nilIfEmpty ?? number, number: number, name: $0.value.text("name", "title", "label").nilIfEmpty ?? "Сезон \(number)", payload: $0.value)
        }
    }
    func episodes(in season: SeasonOption) -> [EpisodeOption] {
        collection(season.payload["episodes"], keys: ["episode_number", "episode", "number", "id"]).map {
            let number = $0.value.text("episode_number", "episode", "number").nilIfEmpty ?? $0.key
            return EpisodeOption(id: $0.value.text("id", "episode_id").nilIfEmpty ?? number, number: number, name: $0.value.text("name", "title", "label").nilIfEmpty ?? "Серия \(number)", imageURL: $0.value.text("image", "still", "poster"), payload: $0.value)
        }
    }

    func resolve(_ request: PlaybackRequest, container: [String: JSONValue]) async throws -> PlaybackSource {
        var metadata = container
        var urls = streamURLs(in: .object(container))
        if urls.isEmpty, let data = container["data"]?.object {
            let bytes = try JSONSerialization.data(withJSONObject: data.mapValues(\.jsonObject))
            let encoded = bytes.base64EncodedString()
            let resolved = try await client.get(path: "api/source/\(request.sourceID ?? "")", query: ["data": encoded])
            urls = streamURLs(in: resolved)
            metadata = resolved.object ?? container
        }
        guard let url = urls.first(where: { $0.absoluteString.lowercased().contains(".m3u8") }) ?? urls.first(where: { $0.absoluteString.lowercased().contains(".mp4") }) else { throw StreamingError.noCompatibleSource }
        return PlaybackSource(request: request, url: url, providerID: id, providerName: name, headers: ["Referer": APIConfig.headers["Referer"]!, "Origin": APIConfig.headers["Origin"]!, "User-Agent": APIConfig.headers["User-Agent"]!],
            expiresAt: Self.expiration(metadata["expires_at"]), quality: metadata.text("quality").nilIfEmpty)
    }

    private static func expiration(_ value: JSONValue?) -> Date? {
        guard let text = value?.text, !text.isEmpty else { return nil }
        if let timestamp = Double(text), timestamp.isFinite {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private func canonical(_ item: MediaItem) -> [String: String] {
        let external = item.raw["external_ids"]?.object
        let date = item.raw.text("first_air_date", "release_date", "year").nilIfEmpty ?? item.year
        return ["id": item.id, "title": item.raw.text("title", "name").nilIfEmpty ?? item.title,
                "original_title": item.raw.text("original_title", "original_name").nilIfEmpty ?? item.originalTitle,
                "original_language": item.raw.text("original_language"),
                "imdb_id": item.raw.text("imdb_id").nilIfEmpty ?? external?.text("imdb_id") ?? "",
                "year": String(date.prefix(4)), "type": item.mediaType].filter { !$0.value.isEmpty }
    }
    private func collection(_ value: JSONValue?, keys: [String]) -> [(key: String, value: [String: JSONValue])] {
        if let object = value?.object { return object.compactMap { key, node in node.object.map { (key, $0) } } }
        return value?.array?.enumerated().compactMap { index, value in value.object.map { object in (keys.lazy.map { object[$0]?.text ?? "" }.first { !$0.isEmpty } ?? String(index + 1), object) } } ?? []
    }
    private func streamURLs(in value: JSONValue) -> [URL] {
        var result: [URL] = []
        func walk(_ node: JSONValue, key: String = "") {
            if let object = node.object { object.forEach { walk($0.value, key: $0.key.lowercased()) } }
            else if let array = node.array { array.forEach { walk($0, key: key) } }
            else { let text = node.text.replacingOccurrences(of: "\\/", with: "/").components(separatedBy: "|")[0].trimmingCharacters(in: .whitespaces); let allowed = ["url", "src", "file", "stream", "hls", "master"].contains(key) || text.lowercased().contains(".m3u8") || text.lowercased().contains(".mp4"); if allowed, let url = URL(string: text), ["http", "https"].contains(url.scheme) { result.append(url) } }
        }
        walk(value); return Array(NSOrderedSet(array: result)) as? [URL] ?? result
    }
}

enum StreamingError: LocalizedError { case noCompatibleSource; var errorDescription: String? { "Нет совместимого видеоисточника" } }
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

extension AtodoProvider {
    func refresh(source: PlaybackSource, request: PlaybackRequest) async throws -> PlaybackSource {
        try await playback(for: request)
    }
}
