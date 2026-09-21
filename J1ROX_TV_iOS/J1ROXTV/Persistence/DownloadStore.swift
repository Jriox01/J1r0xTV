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
        let context = container.viewContext
        let entries = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadEntry"))
        var recovered: [UUID: DownloadRecord] = [:]
        for entry in entries {
            guard let id = entry.value(forKey: "id") as? UUID,
                  let data = entry.value(forKey: "payload") as? Data,
                  var record = Self.decode(data, id: id), record.id == id else {
                context.delete(entry) // Delete only the unreadable row, never downloaded files.
                continue
            }
            record.recoverPersistedState()
            if let previous = recovered[id], previous.state == .completed { continue }
            recovered[id] = record
        }
        if context.hasChanges { try context.save() }
        let records = recovered.values.sorted { $0.createdAt < $1.createdAt }
        try save(records) // Persist recovery before any background session is reattached.
        return records
    }
    private static func decode(_ data: Data, id: UUID) -> DownloadRecord? {
        if let record = try? JSONDecoder().decode(DownloadRecord.self, from: data) { return record }
        // Salvage old/completed records with damaged optional blobs instead of losing the library.
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["resumeData", "posterData", "hlsProgress", "localPackageBookmark"] { json.removeValue(forKey: key) }
        if json["id"] == nil { json["id"] = id.uuidString }
        if json["generation"] == nil { json["generation"] = UUID().uuidString }
        if json["createdAt"] == nil { json["createdAt"] = Date().timeIntervalSinceReferenceDate }
        if json["received"] == nil { json["received"] = 0 }
        if json["total"] == nil { json["total"] = 0 }
        if json["state"] as? String != DownloadState.completed.rawValue { json["state"] = DownloadState.failed.rawValue }
        guard let repaired = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(DownloadRecord.self, from: repaired)
    }
    func save(_ records: [DownloadRecord]) throws {
        let context = container.viewContext
        do {
            guard Set(records.map(\.id)).count == records.count else { throw DownloadError.invalidFile }
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
            saved = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch { context.rollback(); throw error }
    }
}

enum DownloadFiles {
    static func isSafeFilename(_ filename: String) -> Bool {
        filename == (filename as NSString).lastPathComponent && !filename.isEmpty &&
        filename != "." && filename != ".." && !filename.contains("\\") && !filename.contains("\0")
    }
    static func isSafePackagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0") else { return false }
        if path.hasPrefix("file:") { return URL(string: path)?.isFileURL == true }
        return !path.contains("://") && !path.split(separator: "/").contains("..") && path != "."
    }
    // Persist the exact URL supplied by AVFoundation, including locations outside
    // the app's home directory. No extension, bundle-layout or directory assumptions.
    static func packagePath(for location: URL) throws -> String {
        guard location.isFileURL else { throw DownloadError.invalidLocation }
        return location.absoluteURL.absoluteString
    }
    static func packageURL(_ path: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()), bookmark: Data? = nil) throws -> URL {
        guard isSafePackagePath(path) else { throw DownloadError.invalidLocation }
        let url: URL
        if path.hasPrefix("file:"), let saved = URL(string: path) { url = saved }
        else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else { url = home.appendingPathComponent(path) } // Legacy sandbox-relative records only.
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                       relativeTo: nil, bookmarkDataIsStale: &stale), resolved.isFileURL,
               FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        }
        return url
    }
    static func existingPackageURL(_ path: String, bookmark: Data? = nil) throws -> URL {
        let url = try packageURL(path, bookmark: bookmark)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DownloadError.missingFile }
        return url
    }
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
        guard isSafeFilename(filename) else { throw DownloadError.missingFile }
        let directory = try root().resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == directory.path else { throw DownloadError.missingFile }
        return url
    }
    static func checkSpace(required: Int64) throws {
        let values = try root().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
              available > max(0, required), available - max(0, required) > 64 * 1024 * 1024 else { throw DownloadError.noSpace }
    }
}
