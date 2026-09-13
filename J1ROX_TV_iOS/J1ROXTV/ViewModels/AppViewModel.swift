import Foundation
import Combine

@MainActor final class AppViewModel: ObservableObject {
    @Published var movies:[MediaItem]=[]; @Published var series:[MediaItem]=[]; @Published var searchResults:[MediaItem]=[]
    @Published var isLoading=false; @Published var errorMessage:String?; @Published var playback:PlaybackSelection?
    let catalog=CatalogService(), searchService=SearchService(), detailsService=DetailsService(), streaming=StreamingService(), library:LibraryStore
    private var searchTask:Task<Void,Never>?
    init(library:LibraryStore){self.library=library}
    func loadHome() async { isLoading=true; errorMessage=nil; do { async let m=catalog.catalog(type:"movie"); async let s=catalog.catalog(type:"tv"); (movies,series)=try await(m,s) } catch { errorMessage="Не удалось загрузить каталог"; debugPrint(error) }; isLoading=false }
    func search(_ query:String){ searchTask?.cancel(); guard !query.trimmingCharacters(in:.whitespaces).isEmpty else {searchResults=[];return}; searchTask=Task { try? await Task.sleep(for:.milliseconds(450)); guard !Task.isCancelled else{return}; isLoading=true; do{searchResults=try await searchService.search(query)}catch is CancellationError{}catch{errorMessage="Не удалось выполнить поиск";debugPrint(error)};isLoading=false } }
    func continueWatching(_ entry:WatchProgressEntity) async { guard let media=library.media(from:entry.rawJSON) else{return}; do { let (_,sources)=try await streaming.sources(for:media); guard let source=sources.first(where:{$0.id==entry.sourceID}) ?? sources.first else{throw StreamingError.noCompatibleSource}; let full=try await detailsService.details(type:media.mediaType,id:media.id); let content=try await streaming.content(for:full,sourceID:source.id); let translations=streaming.translations(in:content); guard let translation=translations.first(where:{$0.id==entry.translationID}) ?? translations.first else{throw StreamingError.noCompatibleSource}; var container=translation.payload; if !entry.season.isEmpty, let season=streaming.seasons(in:translation).first(where:{$0.number==entry.season}) { container=season.payload; if !entry.episode.isEmpty, let episode=streaming.episodes(in:season).first(where:{$0.number==entry.episode}) {container=episode.payload} }; playback=try await streaming.resolve(.init(media:full,sourceID:source.id,translationID:translation.id,season:entry.season,episode:entry.episode,resumeAt:entry.position),container:container) } catch {errorMessage=error.localizedDescription} }
}
