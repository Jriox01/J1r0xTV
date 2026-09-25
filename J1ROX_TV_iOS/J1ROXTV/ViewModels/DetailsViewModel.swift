import Foundation
import Combine

@MainActor final class DetailsViewModel: ObservableObject {
    @Published var item:MediaItem; @Published var sources:[SourceOption]=[]; @Published var translations:[TranslationOption]=[]
    @Published var selectedTranslation:TranslationOption?; @Published var seasons:[SeasonOption]=[]; @Published var selectedSeason:SeasonOption?; @Published var episodes:[EpisodeOption]=[]
    @Published private(set) var providerName = "Atodo"
    @Published var loading=false; @Published var error:String?
    @Published var selectedEpisode: String?
    private var generation = UUID()
    private var restoredRequest: PlaybackRequest?
    private var preferenceKey: String { "voice.\(item.mediaType).\(item.id)" }
    func restore(_ request: PlaybackRequest) { restoredRequest = request; selectedEpisode = request.episode }
    func cancel() { generation = UUID() }
    private let details=DetailsService(); private let streaming:StreamingService
    init(item:MediaItem,streaming:StreamingService){self.item=item;self.streaming=streaming}
    func load() async { loading=true;error=nil;do{item=try await details.details(type:item.mediaType,id:item.id)}catch{self.error="Не удалось получить данные фильма"};loading=false }
    func prepare() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let (full, values) = try await streaming.sources(for: item)
            try Task.checkCancellation()
            item = full; sources = values; providerName = streaming.providerName
            let ordered = values.filter { $0.id == restoredRequest?.sourceID } + values.filter { $0.id != restoredRequest?.sourceID }
            guard !ordered.isEmpty else { throw StreamingError.noCompatibleSource }
            var failure: Error?
            for source in ordered {
                do { try await select(source: source); return }
                catch { try Task.checkCancellation(); failure = error }
            }
            if let failure { throw failure }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func select(source: SourceOption) async throws {
        let token = UUID(); generation = token
        let content = try await streaming.content(for: item, sourceID: source.id)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let values = streaming.translations(in: content)
        guard let first = values.first else { throw StreamingError.noCompatibleSource }
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        let chosen = values.first { $0.name == saved } ?? (saved == nil ? values.first { $0.id == restoredRequest?.translationID } : nil) ?? first
        translations = values; activeSource = source.id
        select(translation: chosen, remember: false)
    }
    @Published private(set) var activeSource: String = ""
    func downloadRequest(episode: EpisodeOption? = nil) -> PlaybackRequest {
        .init(media: item, sourceID: activeSource, translationID: selectedTranslation?.id,
              season: episode == nil ? nil : selectedSeason?.number, episode: episode?.number,
              translationName: selectedTranslation?.name, providerID: streaming.providerID)
    }
    func downloadVariants(for request: PlaybackRequest) async throws -> (PlaybackRequest, [DownloadVariant]) {
        try await streaming.downloads(request)
    }
    func select(translation: TranslationOption, remember: Bool = true) {
        cancel()
        let number = selectedSeason?.number ?? restoredRequest?.season
        selectedTranslation = translation
        if remember { UserDefaults.standard.set(translation.name, forKey: preferenceKey) }
        seasons = streaming.seasons(in: translation).sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
        selectedSeason = seasons.first { $0.number == number } ?? seasons.first
        episodes = selectedSeason.map { streaming.episodes(in: $0).sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending } } ?? []
        selectedEpisode = episodes.first { $0.number == selectedEpisode }?.number ?? episodes.first?.number
    }
    func select(season: SeasonOption) {
        cancel()
        selectedSeason = season
        episodes = streaming.episodes(in: season).sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
        selectedEpisode = episodes.first?.number
    }
    func next(after request: PlaybackRequest) -> (SeasonOption, EpisodeOption)? {
        guard let index = seasons.firstIndex(where: { $0.number == request.season }) else { return nil }
        for season in seasons[index...] {
            let values = streaming.episodes(in: season).sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
            if season.number == request.season {
                guard let current = values.firstIndex(where: { $0.number == request.episode }) else { return nil }
                if current + 1 < values.count { return (season, values[current + 1]) }
            } else if let first = values.first { return (season, first) }
        }
        return nil
    }
    func play(episode: EpisodeOption? = nil, resume: Double = 0) async throws -> PlaybackSelection {
        guard let translation = selectedTranslation else { throw StreamingError.noCompatibleSource }
        let token = UUID(); generation = token
        selectedEpisode = episode?.number
        let selection = try await streaming.resolveSelected(.init(media: item, sourceID: activeSource,
            translationID: translation.id, season: selectedSeason?.number, episode: episode?.number,
            resumeAt: resume, translationName: translation.name, providerID: streaming.providerID))
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        return selection
    }

    func synchronize(_ request: PlaybackRequest) async {
        if item.id != request.media.id || item.mediaType != request.media.mediaType {
            cancel()
            item = request.media
            sources = []; translations = []; seasons = []; episodes = []
            selectedTranslation = nil; selectedSeason = nil; selectedEpisode = nil; activeSource = ""
        }
        restore(request)
        if sources.isEmpty { await prepare() }
        do {
            if let source = sources.first(where: { $0.id == request.sourceID }), activeSource != source.id {
                try await select(source: source)
            }
            try Task.checkCancellation()
            if let translation = translations.first(where: { $0.id == request.translationID && (request.translationName == nil || $0.name == request.translationName) })
                ?? translations.first(where: { request.translationName != nil && $0.name == request.translationName }) {
                select(translation: translation, remember: false)
            }
            if let season = seasons.first(where: { $0.number == request.season }) { select(season: season) }
            selectedEpisode = request.episode
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
