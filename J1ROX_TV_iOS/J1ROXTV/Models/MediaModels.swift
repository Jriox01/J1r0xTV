import Foundation

struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let mediaType: String
    let title: String
    let originalTitle: String
    let overview: String
    let posterURL: String
    let backdropURL: String
    let year: String
    let rating: String
    let genres: [String]
    let duration: String
    let raw: [String: JSONValue]

    static func parse(_ raw: [String: JSONValue], fallbackType: String = "movie") -> Self {
        let supplied = raw.text("media_type", "type_movie")
        let type = ["movie", "tv"].contains(supplied) ? supplied : fallbackType
        let date = raw.text("release_date", "first_air_date", "year", "premiere")
        let genres = raw["genres"]?.array?.compactMap { value -> String? in
            if !value.text.isEmpty { return value.text }
            return value.object?.text("name", "title")
        } ?? []
        return .init(
            id: raw.text("id", "movie_id", "tmdb_id", "kinopoisk_id", "kp_id"), mediaType: type,
            title: raw.text("title", "name", "title_ru", "name_ru", "localized_name", "label").nilIfEmpty ?? "Без названия",
            originalTitle: raw.text("original_title", "original_name", "title_en", "name_en"),
            overview: raw.text("overview", "description", "plot", "about", "text"),
            posterURL: imageURL(raw.text("poster_path", "poster", "poster_url", "image", "cover")),
            backdropURL: imageURL(raw.text("backdrop_path", "backdrop", "backdrop_url", "background")),
            year: String(date.prefix(4)), rating: String(raw.text("vote_average", "rating", "kinopoisk_rating", "imdb_rating").prefix(4)),
            genres: genres, duration: raw.text("runtime", "duration"), raw: raw)
    }
}

struct SourceOption: Identifiable, Hashable, Sendable { let id: String; let name: String }
struct TranslationOption: Identifiable, Hashable, Sendable { let id: String; let name: String; let payload: [String: JSONValue] }
struct SeasonOption: Identifiable, Hashable, Sendable { let id: String; let number: String; let name: String; let payload: [String: JSONValue] }
struct EpisodeOption: Identifiable, Hashable, Sendable { let id: String; let number: String; let name: String; let imageURL: String; let payload: [String: JSONValue] }
struct PlaybackRequest: Sendable { let media: MediaItem; var sourceID: String?; var translationID: String?; var season: String?; var episode: String?; var resumeAt: Double = 0; var translationName: String? = nil; var providerID: String = "atodo" }
struct PlaybackSelection: Identifiable, Sendable {
    let id = UUID()
    let source: PlaybackSource
    var switched = false
    var request: PlaybackRequest { source.request }
}

private func imageURL(_ value: String) -> String {
    if value.hasPrefix("//") { return "https:" + value }
    if value.hasPrefix("/") { return "https://image.tmdb.org/t/p/w780" + value }
    return value
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
