import CoreData
import Combine

@objc(FavoriteEntity) final class FavoriteEntity: NSManagedObject {
    @NSManaged var mediaID: String; @NSManaged var mediaType: String; @NSManaged var title: String
    @NSManaged var posterURL: String; @NSManaged var year: String; @NSManaged var rawJSON: Data; @NSManaged var createdAt: Date
}
@objc(WatchProgressEntity) final class WatchProgressEntity: NSManagedObject {
    @NSManaged var mediaID: String; @NSManaged var mediaType: String; @NSManaged var title: String; @NSManaged var posterURL: String
    @NSManaged var year: String; @NSManaged var rawJSON: Data; @NSManaged var sourceID: String; @NSManaged var translationID: String
    @NSManaged var season: String; @NSManaged var episode: String; @NSManaged var position: Double; @NSManaged var duration: Double; @NSManaged var lastWatchedAt: Date
}

final class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        container = NSPersistentContainer(name: "J1ROXTV", managedObjectModel: Self.model())
        if inMemory { container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null") }
        else if let storeURL { container.persistentStoreDescriptions.first?.url = storeURL }
        container.loadPersistentStores { _, error in if let error { assertionFailure("Core Data: \(error)") } }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
        let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = optional; value.defaultValue = defaultValue; return value
    }
    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let favorite = NSEntityDescription(); favorite.name = "FavoriteEntity"; favorite.managedObjectClassName = NSStringFromClass(FavoriteEntity.self)
        favorite.properties = [attribute("mediaID", .stringAttributeType), attribute("mediaType", .stringAttributeType), attribute("title", .stringAttributeType), attribute("posterURL", .stringAttributeType), attribute("year", .stringAttributeType), attribute("rawJSON", .binaryDataAttributeType), attribute("createdAt", .dateAttributeType)]
        favorite.uniquenessConstraints = [["mediaID", "mediaType"]]
        let progress = NSEntityDescription(); progress.name = "WatchProgressEntity"; progress.managedObjectClassName = NSStringFromClass(WatchProgressEntity.self)
        progress.properties = [attribute("mediaID", .stringAttributeType), attribute("mediaType", .stringAttributeType), attribute("title", .stringAttributeType), attribute("posterURL", .stringAttributeType), attribute("year", .stringAttributeType), attribute("rawJSON", .binaryDataAttributeType), attribute("sourceID", .stringAttributeType), attribute("translationID", .stringAttributeType), attribute("season", .stringAttributeType), attribute("episode", .stringAttributeType), attribute("position", .doubleAttributeType, defaultValue: 0), attribute("duration", .doubleAttributeType, defaultValue: 0), attribute("lastWatchedAt", .dateAttributeType)]
        progress.uniquenessConstraints = [["mediaID", "mediaType", "season", "episode"]]
        model.entities = [favorite, progress]; return model
    }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteEntity] = []
    @Published private(set) var history: [WatchProgressEntity] = []
    private let context: NSManagedObjectContext
    private var activeSources: [String: UUID] = [:]
    private var completed = Set<String>()
    private var completionTasks: [String: Task<Void, Never>] = [:]
    private func key(_ selection: PlaybackSelection) -> String {
        selection.request.media.mediaType + ":" + selection.request.media.id
    }
    init(context: NSManagedObjectContext) { self.context = context; reload() }
    deinit { for task in completionTasks.values { task.cancel() } }

    /// Only an explicit new PlayerScreen may start watching a completed title again.
    func beginPlayback(_ selection: PlaybackSelection) {
        let id = key(selection)
        completionTasks[id]?.cancel(); completionTasks[id] = nil
        completed.remove(id)
        activeSources[id] = selection.source.id
    }

    /// Item replacement / SharePlay state is not an explicit request to replay a completed title.
    func continuePlayback(_ selection: PlaybackSelection) {
        let id = key(selection)
        guard !completed.contains(id) else { return }
        completionTasks[id]?.cancel(); completionTasks[id] = nil
        activeSources[id] = selection.source.id
    }

    /// Called only from AVPlayerItemDidPlayToEndTime, never inferred from position or closing.
    func playbackEnded(_ selection: PlaybackSelection, finalEpisode: Bool? = nil) {
        let id = key(selection)
        guard !completed.contains(id), activeSources[id] == selection.source.id else { return }
        if selection.request.media.mediaType == "movie" || finalEpisode == true {
            complete(selection); return
        }
        guard selection.request.media.mediaType == "tv", finalEpisode == nil,
              completionTasks[id] == nil else { return }
        // Library ownership allows confirmation after the screen closes following a genuine end.
        // A separate model never mutates the player's selectors or countdown.
        completionTasks[id] = Task { [weak self] in
            let model = DetailsViewModel(item: selection.request.media, streaming: StreamingService())
            await model.synchronize(selection.request)
            guard !Task.isCancelled, let self, self.activeSources[id] == selection.source.id else { return }
            self.completionTasks[id] = nil
            if model.isFinalAvailableEpisode(selection.request) == true { self.complete(selection) }
        }
    }

    private func complete(_ selection: PlaybackSelection) {
        let id = key(selection)
        guard activeSources[id] == selection.source.id else { return }
        let request = NSFetchRequest<WatchProgressEntity>(entityName: "WatchProgressEntity")
        request.predicate = NSPredicate(format: "mediaID == %@ AND mediaType == %@", selection.request.media.id, selection.request.media.mediaType)
        do {
            // Remove all episodes so an older row cannot resurface after restart.
            for entity in try context.fetch(request) { context.delete(entity) }
            try context.save()
            completed.insert(id)
            completionTasks[id]?.cancel(); completionTasks[id] = nil
            reload()
        } catch { context.rollback() }
    }
    func reload() {
        let favoritesRequest = NSFetchRequest<FavoriteEntity>(entityName: "FavoriteEntity"); favoritesRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        let historyRequest = NSFetchRequest<WatchProgressEntity>(entityName: "WatchProgressEntity"); historyRequest.sortDescriptors = [NSSortDescriptor(key: "lastWatchedAt", ascending: false)]
        favorites = (try? context.fetch(favoritesRequest)) ?? []; history = (try? context.fetch(historyRequest)) ?? []
    }
    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains { $0.mediaID == item.id && $0.mediaType == item.mediaType } }
    func toggle(_ item: MediaItem) {
        if let entity = favorites.first(where: { $0.mediaID == item.id && $0.mediaType == item.mediaType }) { context.delete(entity) }
        else { let entity = FavoriteEntity(context: context); entity.mediaID=item.id; entity.mediaType=item.mediaType; entity.title=item.title; entity.posterURL=item.posterURL; entity.year=item.year; entity.rawJSON=(try? JSONEncoder().encode(item)) ?? Data(); entity.createdAt=Date() }
        save()
    }
    func save(_ selection: PlaybackSelection, position: Double, duration: Double) {
        let id = key(selection)
        guard position.isFinite, position >= 0, !completed.contains(id),
              activeSources[id] == nil || activeSources[id] == selection.source.id else { return }
        let request = NSFetchRequest<WatchProgressEntity>(entityName: "WatchProgressEntity")
        request.predicate = NSPredicate(format: "mediaID == %@ AND mediaType == %@ AND season == %@ AND episode == %@", selection.request.media.id, selection.request.media.mediaType, selection.request.season ?? "", selection.request.episode ?? "")
        let entity = (try? context.fetch(request).first) ?? WatchProgressEntity(context: context); let item=selection.request.media
        entity.mediaID=item.id; entity.mediaType=item.mediaType; entity.title=item.title; entity.posterURL=item.posterURL; entity.year=item.year; entity.rawJSON=(try? JSONEncoder().encode(item)) ?? Data(); entity.sourceID=selection.request.sourceID ?? ""; entity.translationID=selection.request.translationID ?? ""; entity.season=selection.request.season ?? ""; entity.episode=selection.request.episode ?? ""; entity.position=position; entity.duration=duration; entity.lastWatchedAt=Date(); save()
    }
    func media(from data: Data) -> MediaItem? { try? JSONDecoder().decode(MediaItem.self, from: data) }
    private func save() { do { try context.save(); reload() } catch { context.rollback() } }
}
