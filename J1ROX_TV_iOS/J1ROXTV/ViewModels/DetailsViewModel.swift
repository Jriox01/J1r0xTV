import Foundation
import Combine

@MainActor final class DetailsViewModel: ObservableObject {
    @Published var item:MediaItem; @Published var sources:[SourceOption]=[]; @Published var translations:[TranslationOption]=[]
    @Published var selectedTranslation:TranslationOption?; @Published var seasons:[SeasonOption]=[]; @Published var selectedSeason:SeasonOption?; @Published var episodes:[EpisodeOption]=[]
    @Published private(set) var providerName = "Atodo"
    @Published var loading=false; @Published var error:String?
    private let details=DetailsService(); private let streaming:StreamingService
    init(item:MediaItem,streaming:StreamingService){self.item=item;self.streaming=streaming}
    func load() async { loading=true;error=nil;do{item=try await details.details(type:item.mediaType,id:item.id)}catch{self.error="Не удалось получить данные фильма"};loading=false }
    func prepare() async { loading=true;error=nil;do{let(full,values)=try await streaming.sources(for:item);item=full;sources=values;providerName=streaming.providerName;guard !values.isEmpty else{throw StreamingError.noCompatibleSource};var lastError:Error?;for source in values{do{try await select(source:source);lastError=nil;break}catch{lastError=error}};if let lastError{throw lastError}}catch{self.error=error.localizedDescription};loading=false }
    func select(source:SourceOption) async throws { let content=try await streaming.content(for:item,sourceID:source.id);translations=streaming.translations(in:content);guard let first=translations.first else{throw StreamingError.noCompatibleSource};select(translation:first);activeSource=source.id }
    private(set) var activeSource:String=""
    func downloadRequest(episode: EpisodeOption? = nil) -> PlaybackRequest {
        .init(media: item, sourceID: activeSource, translationID: selectedTranslation?.id,
              season: episode == nil ? nil : selectedSeason?.number, episode: episode?.number,
              translationName: selectedTranslation?.name, providerID: streaming.providerID)
    }
    func downloadVariants(for request: PlaybackRequest) async throws -> (PlaybackRequest, [DownloadVariant]) {
        try await streaming.downloads(request)
    }
    func select(translation:TranslationOption){selectedTranslation=translation;seasons=streaming.seasons(in:translation);selectedSeason=nil;episodes=[]}
    func select(season:SeasonOption){selectedSeason=season;episodes=streaming.episodes(in:season)}
    func play(episode: EpisodeOption? = nil, resume: Double = 0) async throws -> PlaybackSelection {
        guard let translation = selectedTranslation else { throw StreamingError.noCompatibleSource }
        return try await streaming.resolve(.init(media: item, sourceID: activeSource,
            translationID: translation.id, season: selectedSeason?.number, episode: episode?.number,
            resumeAt: resume, translationName: translation.name, providerID: streaming.providerID))
    }
}
