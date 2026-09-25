import CoreData
import Foundation

private struct ContinueWatchingFailure: Error { let message: String }
private func expectHistory(_ value: Bool, _ message: String) throws {
    if !value { throw ContinueWatchingFailure(message: message) }
}

@MainActor func runContinueWatchingTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let persistence = PersistenceController(storeURL: url)
    let library = LibraryStore(context: persistence.container.viewContext)
    func selection(_ id: String, type: String = "movie", season: String? = nil, episode: String? = nil) -> PlaybackSelection {
        let media = MediaItem.parse(["id": .string(id), "media_type": .string(type), "title": .string("Test")])
        let request = PlaybackRequest(media: media, sourceID: "one", translationID: "First", season: season, episode: episode)
        return PlaybackSelection(source: PlaybackSource(request: request, url: URL(string: "https://test.invalid/video.m3u8")!,
                                                        providerID: "atodo", providerName: "Test"))
    }
    let movie = selection("movie")
    library.toggle(movie.request.media)
    library.beginPlayback(movie)
    library.save(movie, position: 40, duration: 100)
    try expectHistory(library.history.count == 1, "partial movie remains")
    // Closing uses the same save path, including near-end positions, without an end event.
    library.save(movie, position: 99.9, duration: 100)
    try expectHistory(library.history.first?.position == 99.9, "closing near end is not completion")
    library.playbackEnded(movie)
    try expectHistory(library.history.isEmpty && library.isFavorite(movie.request.media), "actual end removes movie, preserves favorite")
    library.save(movie, position: 100, duration: 100)
    try expectHistory(library.history.isEmpty, "late periodic/close save cannot resurrect movie")

    let first = selection("series", type: "tv", season: "1", episode: "1")
    library.toggle(first.request.media)
    library.beginPlayback(first)
    library.save(first, position: 100, duration: 100)
    library.playbackEnded(first, finalEpisode: false)
    try expectHistory(library.history.count == 1, "ordinary episode remains for next episode")
    let seasonEnd = selection("series", type: "tv", season: "1", episode: "2")
    library.continuePlayback(seasonEnd)
    library.save(seasonEnd, position: 100, duration: 100)
    library.playbackEnded(seasonEnd, finalEpisode: false)
    try expectHistory(library.history.count == 2, "next season exists: history retained")
    let final = selection("series", type: "tv", season: "2", episode: "1")
    library.continuePlayback(final)
    library.save(final, position: 99, duration: 100)
    try expectHistory(library.history.count == 3, "seeking near final end alone does not complete series")
    library.playbackEnded(final, finalEpisode: true)
    try expectHistory(library.history.isEmpty, "final episode removes all older episode rows too")
    try expectHistory(library.isFavorite(first.request.media), "series favorite survives")
    let duplicate = selection("series", type: "tv", season: "2", episode: "1")
    library.continuePlayback(duplicate)
    library.save(duplicate, position: 1, duration: 100)
    library.save(first, position: 100, duration: 100)
    library.playbackEnded(final, finalEpisode: true)
    try expectHistory(library.history.isEmpty, "SharePlay replacement, old progress and duplicate end do not resurrect completed series")

    // A fresh coordinator/context opens the actual SQLite store, not merely the published array.
    let reopened = PersistenceController(storeURL: url)
    let afterRestart = LibraryStore(context: reopened.container.viewContext)
    try expectHistory(afterRestart.history.isEmpty && afterRestart.favorites.count == 2,
                      "restart keeps completed movie/series absent and both favorites present")

    let replay = selection("movie")
    library.beginPlayback(replay)
    library.save(replay, position: 10, duration: 100)
    library.save(movie, position: 100, duration: 100)
    library.playbackEnded(movie)
    try expectHistory(library.history.first?.position == 10, "explicit replay saves anew; stale old run cannot overwrite or complete it")

    // Completion is local on each SharePlay device; owner election never gates this API.
    let peerPersistence = PersistenceController(inMemory: true)
    let peer = LibraryStore(context: peerPersistence.container.viewContext)
    peer.beginPlayback(final)
    peer.save(final, position: 100, duration: 100)
    peer.playbackEnded(final, finalEpisode: true)
    try expectHistory(peer.history.isEmpty, "non-owner participant records its own final end")
    print("PASS ContinueWatchingTests: partial/close/end, series succession/final, restart, favorites, stale SharePlay writes, explicit replay")
}
