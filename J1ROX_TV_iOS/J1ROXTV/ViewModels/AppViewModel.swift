import Foundation
import Combine

@MainActor final class AppViewModel: ObservableObject {
    @Published var movies:[MediaItem]=[]; @Published var series:[MediaItem]=[]; @Published var searchResults:[MediaItem]=[]
    @Published var isLoading=false; @Published var errorMessage:String?; @Published var playback:PlaybackSelection?
    let catalog=CatalogService(), searchService=SearchService(), detailsService=DetailsService(), streaming=StreamingService(), library:LibraryStore
    private var searchTask:Task<Void,Never>?
    let watchTogether = WatchTogetherManager()
    init(library:LibraryStore){
        self.library=library
        watchTogether.onOpen = { [weak self] in self?.playback = $0 }
        watchTogether.startListening()
    }
    func loadHome() async { isLoading=true; errorMessage=nil; do { async let m=catalog.catalog(type:"movie"); async let s=catalog.catalog(type:"tv"); (movies,series)=try await(m,s) } catch { errorMessage="Не удалось загрузить каталог"; debugPrint(error) }; isLoading=false }
    func search(_ query:String){ searchTask?.cancel(); guard !query.trimmingCharacters(in:.whitespaces).isEmpty else {searchResults=[];return}; searchTask=Task { try? await Task.sleep(for:.milliseconds(450)); guard !Task.isCancelled else{return}; isLoading=true; do{searchResults=try await searchService.search(query)}catch is CancellationError{}catch{errorMessage="Не удалось выполнить поиск";debugPrint(error)};isLoading=false } }
    func continueWatching(_ entry: WatchProgressEntity) async {
        guard let media = library.media(from: entry.rawJSON) else { return }
        if let local = DownloadManager.shared.records.first(where: {
            $0.state == .completed && $0.media.id == media.id && $0.media.mediaType == media.mediaType &&
            ($0.season ?? "") == entry.season && ($0.episode ?? "") == entry.episode &&
            ($0.translationID ?? "") == entry.translationID && ($0.sourceID ?? "") == entry.sourceID
        }) {
            playback = DownloadManager.shared.playback(local.id, resumeAt: entry.position)
            return
        }
        do {
            playback = try await streaming.resolve(.init(media: media, sourceID: entry.sourceID,
                translationID: entry.translationID, season: entry.season.isEmpty ? nil : entry.season,
                episode: entry.episode.isEmpty ? nil : entry.episode, resumeAt: entry.position))
        } catch { errorMessage = error.localizedDescription }
    }
}
