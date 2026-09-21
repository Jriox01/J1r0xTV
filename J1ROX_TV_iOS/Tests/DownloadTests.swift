import Foundation

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
    try check(loaded == [record], "durable Core Data round-trip including poster/resumeData/episode")
    try second.save([])
    try check(try second.load().isEmpty, "deletion persists")
    for name in ["../escape.mp4", ".", "..", "/absolute.mp4", "..\\escape.mp4"] {
        do { _ = try DownloadFiles.file(name); throw NSError(domain: "Path traversal accepted", code: 1) }
        catch DownloadError.missingFile { }
    }
    do { try DownloadFiles.checkSpace(required: Int64.max); throw NSError(domain: "Disk overflow accepted", code: 1) }
    catch DownloadError.noSpace { }
    print("PASS download permissions, DRM, direct-file formats, Core Data restoration/deletion, sandbox, disk capacity")
}
