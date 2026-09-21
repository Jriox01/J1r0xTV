import CoreData

/// A separate Core Data store keeps the existing favorites/history schema untouched.
/// The Codable payload retains the complete catalogue snapshot offline.
@MainActor final class DownloadStore {
    private let container: NSPersistentContainer
    private var saved: [UUID: DownloadRecord] = [:]
    init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "DownloadEntry"; entity.managedObjectClassName = "NSManagedObject"
        let id = NSAttributeDescription(); id.name = "id"; id.attributeType = .UUIDAttributeType
        let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType
        payload.allowsExternalBinaryDataStorage = true
        entity.properties = [id, payload]; entity.uniquenessConstraints = [["id"]]
        model.entities = [entity]
        container = NSPersistentContainer(name: "J1ROXDownloads", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        if inMemory { description.type = NSInMemoryStoreType }
        else { description.url = try storeURL ?? DownloadFiles.root().appendingPathComponent("metadata.sqlite") }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        try container.persistentStoreCoordinator.addPersistentStore(ofType: description.type,
            configurationName: nil, at: description.url,
            options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
    }
    func load() throws -> [DownloadRecord] {
        try container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadEntry")).map {
            guard let data = $0.value(forKey: "payload") as? Data else { throw DownloadError.invalidFile }
            return try JSONDecoder().decode(DownloadRecord.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    func save(_ records: [DownloadRecord]) throws {
        let context = container.viewContext
        do {
            let entries = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadEntry"))
            let ids = Set(records.map(\.id))
            for entry in entries where (entry.value(forKey: "id") as? UUID).map({ !ids.contains($0) }) ?? true { context.delete(entry) }
            for record in records {
                if saved[record.id] == record { continue }
                let entry = entries.first { $0.value(forKey: "id") as? UUID == record.id }
                    ?? NSEntityDescription.insertNewObject(forEntityName: "DownloadEntry", into: context)
                entry.setValue(record.id, forKey: "id")
                entry.setValue(try JSONEncoder().encode(record), forKey: "payload")
            }
            try context.save()
            saved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        } catch { context.rollback(); throw error }
    }
}

enum DownloadFiles {
    static func root() throws -> URL {
        var name = "Downloads"
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--download-smoke-test") { name = "DownloadsSmoke" }
        #endif
        var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
    static func file(_ filename: String) throws -> URL {
        guard filename == (filename as NSString).lastPathComponent, !filename.isEmpty,
              filename != ".", filename != "..", !filename.contains("\\") else { throw DownloadError.missingFile }
        return try root().appendingPathComponent(filename)
    }
    static func checkSpace(required: Int64) throws {
        let values = try root().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
              available > max(0, required), available - max(0, required) > 64 * 1024 * 1024 else { throw DownloadError.noSpace }
    }
}
