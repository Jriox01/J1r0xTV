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
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "J1ROXTV", managedObjectModel: Self.model())
        if inMemory { container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null") }
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
    init(context: NSManagedObjectContext) { self.context = context; reload() }
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
        let request = NSFetchRequest<WatchProgressEntity>(entityName: "WatchProgressEntity")
        request.predicate = NSPredicate(format: "mediaID == %@ AND mediaType == %@ AND season == %@ AND episode == %@", selection.request.media.id, selection.request.media.mediaType, selection.request.season ?? "", selection.request.episode ?? "")
        let entity = (try? context.fetch(request).first) ?? WatchProgressEntity(context: context); let item=selection.request.media
        entity.mediaID=item.id; entity.mediaType=item.mediaType; entity.title=item.title; entity.posterURL=item.posterURL; entity.year=item.year; entity.rawJSON=(try? JSONEncoder().encode(item)) ?? Data(); entity.sourceID=selection.request.sourceID ?? ""; entity.translationID=selection.request.translationID ?? ""; entity.season=selection.request.season ?? ""; entity.episode=selection.request.episode ?? ""; entity.position=position; entity.duration=duration; entity.lastWatchedAt=Date(); save()
    }
    func media(from data: Data) -> MediaItem? { try? JSONDecoder().decode(MediaItem.self, from: data) }
    private func save() { do { try context.save(); reload() } catch { context.rollback() } }
}
