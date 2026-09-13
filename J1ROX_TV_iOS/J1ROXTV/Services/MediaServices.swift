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
    func catalog(type: String, page: Int = 1) async throws -> [MediaItem] {
        let payload = try await APIClient.shared.get(path: "api/list", query: ["type_movie": type, "page": String(page)])
        return unwrapItems(payload).map { MediaItem.parse($0, fallbackType: type) }
    }
}
struct SearchService {
    func search(_ query: String, page: Int = 1) async throws -> [MediaItem] {
        let payload = try await APIClient.shared.get(path: "api/search", query: ["query": query, "page": String(page)])
        return unwrapItems(payload).map { MediaItem.parse($0) }
    }
}
struct DetailsService {
    func details(type: String, id: String) async throws -> MediaItem {
        var root = try await APIClient.shared.get(path: "api/details/\(type)/\(id)")
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

final class StreamingService: @unchecked Sendable {
    private let details = DetailsService()

    func sources(for input: MediaItem) async throws -> (MediaItem, [SourceOption]) {
        let item = input.mediaType == "tv" ? try await details.details(type: "tv", id: input.id) : input
        let payload = try await APIClient.shared.get(path: "api/source/list", query: canonical(item))
        let balancers = unwrapObject(payload)["balancers"]?.array ?? []
        return (item, balancers.compactMap { value in
            guard let object = value.object else { return nil }
            let id = object.text("id", "source_id", "key")
            return id.isEmpty ? nil : SourceOption(id: id, name: object.text("name", "title", "label").nilIfEmpty ?? id)
        })
    }

    func content(for item: MediaItem, sourceID: String) async throws -> [String: JSONValue] {
        unwrapObject(try await APIClient.shared.get(path: "api/source/\(sourceID)", query: canonical(item)))
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

    func resolve(_ request: PlaybackRequest, container: [String: JSONValue]) async throws -> PlaybackSelection {
        var urls = streamURLs(in: .object(container))
        if urls.isEmpty, let data = container["data"]?.object {
            let bytes = try JSONSerialization.data(withJSONObject: data.mapValues(\.jsonObject))
            let encoded = bytes.base64EncodedString()
            let resolved = try await APIClient.shared.get(path: "api/source/\(request.sourceID ?? "")", query: ["data": encoded])
            urls = streamURLs(in: resolved)
        }
        guard let url = urls.first(where: { $0.absoluteString.lowercased().contains(".m3u8") }) ?? urls.first(where: { $0.absoluteString.lowercased().contains(".mp4") }) else { throw StreamingError.noCompatibleSource }
        return PlaybackSelection(request: request, url: url, headers: ["Referer": APIConfig.headers["Referer"]!, "Origin": APIConfig.headers["Origin"]!, "User-Agent": APIConfig.headers["User-Agent"]!])
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
