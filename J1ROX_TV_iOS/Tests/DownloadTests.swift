import Foundation
import CoreData

@MainActor func runDownloadTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "DownloadTests: " + message, code: 1) }
    }
    let row: JSONValue = .object(["url": .string("https://fixture.invalid/movie.mp4"),
                                  "quality": .string("720p"), "size_bytes": .number(1234)])
    let allowed: [String: JSONValue] = ["download_allowed": .bool(true), "drm": .bool(false), "downloads": .array([row])]
    let variants = DownloadVariant.parse(allowed)
    try check(variants.count == 1 && variants[0].expectedBytes == 1234, "permitted direct file")
    var duplicate = allowed; duplicate["downloads"] = .array([row, row])
    try check(DownloadVariant.parse(duplicate).count == 1, "duplicate variants")
    for size in [Double(Int64.max), -1, Double.greatestFiniteMagnitude] {
        var nested = row.object!; nested["size_bytes"] = .number(size)
        var payload = allowed; payload["downloads"] = .array([.object(nested)])
        try check(DownloadVariant.parse(payload).first?.expectedBytes == nil, "invalid size cannot overflow")
    }
    for key in ["drm", "download_allowed"] {
        var value = allowed; value[key] = nil
        try check(DownloadVariant.parse(value).isEmpty, "missing permission/DRM declaration")
    }
    var denied = allowed; denied["drm"] = .bool(true)
    try check(DownloadVariant.parse(denied).isEmpty, "DRM refused")
    denied = allowed; denied["download_allowed"] = .bool(false)
    try check(DownloadVariant.parse(denied).isEmpty, "permission refused")
    denied = allowed; denied["download_allowed"] = .string("true")
    try check(DownloadVariant.parse(denied).isEmpty, "permission must be boolean")
    for text in ["file:///tmp/movie.mp4", "https://fixture.invalid/movie.m3u8", "https://fixture.invalid/page?movie=.mp4",
                 "https://fixture.invalid/movie.mpd", "https://user:pass@fixture.invalid/movie.mp4"] {
        try check(!DownloadVariant.isDirectFile(URL(string: text)!), "unsupported URL " + text)
    }
    for flag in ["drm", "download_allowed"] {
        var nested = row.object!; nested[flag] = .bool(flag == "drm")
        var payload = allowed; payload["downloads"] = .array([.object(nested)])
        try check(DownloadVariant.parse(payload).isEmpty, "per-file denial")
    }
    let media = MediaItem.parse(["id": .string("42"), "title": .string("Offline title"), "overview": .string("Offline description")])
    var record = DownloadRecord(media: media, sourceID: "source", providerID: "provider", translationID: "voice",
        translationName: "Voice", season: "2", episode: "3", episodeID: "episode-id", variant: variants[0])
    record.state = .paused; record.received = 400; record.total = 1234; record.resumeData = Data([1, 2, 3])
    record.posterData = Data([4, 5]); record.localFilename = "saved.mp4"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("downloads.sqlite")
    let first = try DownloadStore(storeURL: url)
    try first.save([record])
    let second = try DownloadStore(storeURL: url)
    let loaded = try second.load()
    record.resumeData = nil
    try check(loaded == [record], "durable Core Data round-trip; opaque resume data discarded")
    try second.save([])
    try check(try second.load().isEmpty, "deletion persists")
    for name in ["../escape.mp4", ".", "..", "/absolute.mp4", "..\\escape.mp4"] {
        do { _ = try DownloadFiles.file(name); throw NSError(domain: "Path traversal accepted", code: 1) }
        catch DownloadError.missingFile { }
    }
    do { try DownloadFiles.checkSpace(required: Int64.max); throw NSError(domain: "Disk overflow accepted", code: 1) }
    catch DownloadError.noSpace { }
    let hls = DownloadVariant(url: URL(string: "https://fixture.invalid/master.m3u8")!, quality: "Original",
                              expectedBytes: nil, headers: [:], expiresAt: nil)
    let qualities = hls.hlsVariants(manifest: """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="audio"
    low.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,AUDIO="audio"
    high.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=nan,RESOLUTION=1280x720
    invalid.m3u8
    """)
    try check(qualities.map(\.quality) == ["360p", "720p"] && qualities.allSatisfy { $0.url == hls.url },
              "quality choices preserve master and external audio")
    try check(qualities.last?.minimumBitrate == 2400000, "selected HLS bitrate")
    var interrupted = record
    interrupted.id = UUID(); interrupted.variant = hls; interrupted.state = .downloading
    interrupted.recoveryVersion = nil; interrupted.resumeData = Data([0, 1, 2])
    interrupted.received = Int64.min; interrupted.total = Int64.min; interrupted.hlsProgress = 100000
    let oldKey = interrupted.taskKey
    var finished = record
    finished.id = UUID(); finished.state = .completed; finished.recoveryVersion = nil
    finished.localFilename = "completed.mp4"
    var invalid = record
    invalid.id = UUID(); invalid.state = .queued
    invalid.variant = DownloadVariant(url: URL(string: "file:///tmp/broken.m3u8")!, quality: "bad",
                                      expectedBytes: nil, headers: [:], expiresAt: nil)
    invalid.localPackagePath = "../outside.movpkg"
    try second.save([interrupted, finished, invalid])

    // Inject a broken row and a completed record with malformed optional data into
    // the actual SQLite store, as left by an older installation.
    let model = NSManagedObjectModel()
    let entity = NSEntityDescription(); entity.name = "DownloadEntry"; entity.managedObjectClassName = "NSManagedObject"
    let idAttribute = NSAttributeDescription(); idAttribute.name = "id"; idAttribute.attributeType = .UUIDAttributeType
    let payloadAttribute = NSAttributeDescription(); payloadAttribute.name = "payload"; payloadAttribute.attributeType = .binaryDataAttributeType
    payloadAttribute.allowsExternalBinaryDataStorage = true
    entity.properties = [idAttribute, payloadAttribute]; entity.uniquenessConstraints = [["id"]]; model.entities = [entity]
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
    let broken = NSEntityDescription.insertNewObject(forEntityName: "DownloadEntry", into: context)
    broken.setValue(UUID(), forKey: "id"); broken.setValue(Data("{broken".utf8), forKey: "payload")
    let entries = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DownloadEntry"))
    guard let completedEntry = entries.first(where: { $0.value(forKey: "id") as? UUID == finished.id }),
          var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(finished)) as? [String: Any]
    else { throw NSError(domain: "Missing completed fixture", code: 1) }
    json["resumeData"] = "not valid base64!"
    completedEntry.setValue(try JSONSerialization.data(withJSONObject: json), forKey: "payload")
    try context.save()

    let recoveredStore = try DownloadStore(storeURL: url)
    let recovered = try recoveredStore.load()
    try check(recovered.count == 3, "one corrupt row cannot hide healthy downloads")
    let failedHLS = recovered.first { $0.id == interrupted.id }
    try check(failedHLS?.state == .failed && failedHLS?.taskKey != oldKey && failedHLS?.resumeData == nil,
              "legacy HLS quarantined; old background task cannot reattach")
    try check(failedHLS?.received == 0 && failedHLS?.total == 0 && failedHLS?.progress == 1, "unsafe numeric state clamped")
    try check(recovered.first { $0.id == finished.id }?.state == .completed, "completed record salvaged, not deleted")
    try check(recovered.first { $0.id == invalid.id }?.state == .failed, "invalid URL and path quarantined")
    try check(try recoveredStore.load().count == 3, "recovery persists across launches")
    do { try recoveredStore.save([record, record]); throw NSError(domain: "Duplicate IDs accepted", code: 1) }
    catch DownloadError.invalidFile { }
    try check(!DownloadFiles.isSafePackagePath("../a.movpkg") && !DownloadFiles.isSafePackagePath("https://fixture.invalid/a.movpkg"), "package traversal")
    var nonFinite = record; nonFinite.hlsProgress = .infinity
    try check(nonFinite.progress == record.progress, "non-finite progress never reaches integer conversion")
    // The system location is opaque: outside-home and unusual names are valid.
    let oldHome = directory.appendingPathComponent("old-sandbox", isDirectory: true)
    let newHome = directory.appendingPathComponent("new-sandbox", isDirectory: true)
    let package = directory.appendingPathComponent("system HLS % asset", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let savedLocation = try DownloadFiles.packagePath(for: package)
    try check(savedLocation == package.absoluteURL.absoluteString, "exact system URL preserved")
    let resolved = try DownloadFiles.packageURL(savedLocation, home: oldHome)
    try check(resolved == package, "system asset outside home is not rewritten")
    let legacy = "Library/Caches/HLS movie.asset"
    let relocated = try DownloadFiles.packageURL(legacy, home: newHome)
    try check(relocated.path == newHome.appendingPathComponent(legacy).path, "legacy relative path remains readable")
    for path in ["../escape.movpkg", ".", "Library/../escape"] {
        try check(!DownloadFiles.isSafePackagePath(path), "unsafe legacy HLS path " + path)
    }
    try check(DownloadFiles.isSafePackagePath("tmp/temporary") && DownloadFiles.isSafePackagePath("unusual-name"),
              "no directory or extension requirements for HLS")
    var missingHLS = finished
    missingHLS.id = UUID(); missingHLS.variant = hls
    missingHLS.localPackagePath = "Library/" + UUID().uuidString + ".movpkg"
    missingHLS.hlsProgress = 1; missingHLS.completedAt = Date()
    try recoveredStore.save([finished, missingHLS])
    let repaired = try recoveredStore.load()
    let missing = repaired.first { $0.id == missingHLS.id }
    try check(missing?.state == .failed && missing?.completedAt == nil && missing?.hlsProgress == nil,
              "old completed HLS without local asset is failed before display")
    try check(repaired.first { $0.id == finished.id }?.state == .completed, "unrelated completed MP4 retained")
    var existingHLS = finished
    existingHLS.id = UUID(); existingHLS.variant = hls
    existingHLS.localPackagePath = savedLocation
    existingHLS.localPackageBookmark = try package.bookmarkData(options: .minimalBookmark,
        includingResourceValuesForKeys: nil, relativeTo: nil)
    try recoveredStore.save([existingHLS])
    let retained = try recoveredStore.load()
    try check(retained.first?.state == .completed, "existing system asset is not missing based on bundle structure")
    try check(retained.first?.localPackagePath == savedLocation && retained.first?.localPackageBookmark != nil,
              "system location and bookmark persist in Core Data")
    let restoredURL = try DownloadFiles.existingPackageURL(savedLocation, bookmark: retained.first?.localPackageBookmark)
    try check(restoredURL == package, "offline playback receives original system URL")
    var fabricated = existingHLS
    fabricated.localPackagePath = "Library/Application Support/Downloads/fabricated.movpkg"
    fabricated.recoverPersistedState()
    try check(fabricated.state == .failed && fabricated.localPackagePath == nil && fabricated.failure != nil,
              "fabricated legacy MP4-directory HLS record requires download again")
    fabricated = existingHLS
    fabricated.localPackagePath = "file:///old/Library/Application%20Support/Downloads/fabricated.movpkg"
    fabricated.recoverPersistedState()
    try check(fabricated.state == .failed && fabricated.localPackagePath == nil, "legacy fabricated file URL also migrates")
    try FileManager.default.removeItem(at: package)
    existingHLS.recoverPersistedState()
    try check(existingHLS.state == .failed && existingHLS.failure == DownloadError.missingFile.localizedDescription,
              "missing error only when saved system asset is actually gone")
    print("PASS download permissions, DRM, direct-file formats, Core Data restoration/deletion, sandbox, disk capacity")
}
