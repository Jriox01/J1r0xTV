import Foundation
import Combine
import UIKit
import AVFoundation

@MainActor final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    static let sessionPrefix = "com.jirox.jiroxtv.downloads."
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var speeds: [UUID: Double] = [:]
    @Published private(set) var pausing: Set<UUID> = []
    @Published var message: String?
    @Published var settings: DownloadSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "downloadSettings.v2") }
            if settings.wifiOnly != oldValue.wifiOnly {
                // Session policy is immutable. Move active tasks to the appropriate session.
                for id in Array(tasks.keys) where record(id)?.state == .downloading {
                    discardResumeAfterPause.insert(id); restartAfterPause.insert(id); pause(id)
                }
            }
            if settings.simultaneous < oldValue.simultaneous {
                let running = records.filter { $0.state == .downloading && !pausing.contains($0.id) }
                for entry in running.dropFirst(max(1, settings.simultaneous)) {
                    restartAfterPause.insert(entry.id); pause(entry.id)
                }
            }
            pump()
        }
    }
    private var store: DownloadStore?
    private let delegate = DownloadSessionDelegate()
    private var sessions: [URLSession] = []
    // Some CDNs reject Apple's background downloader at task creation or on the
    // first redirect. Direct MP4s use this foreground-capable session instead;
    // HLS continues through AVAssetDownloadURLSession.
    private var directSession: URLSession!
    // Keep the initializer's static type: Foundation's background-session class
    // cluster cannot reliably be downcast from URLSession to AVAssetDownloadURLSession.
    private var assetSessions: [AVAssetDownloadURLSession] = []
    private var tasks: [UUID: URLSessionTask] = [:]
    @Published private var restored = false
    private var removingAll = false
    private var restartAfterPause: Set<UUID> = []
    private var discardResumeAfterPause: Set<UUID> = []
    private var samples: [UUID: (Date, Int64)] = [:]
    private var lastSave = Date.distantPast
    private var completions: [String: () -> Void] = [:]

    private init() {
        // v2 resets the old implicit Wi-Fi-only default. Users can still enable
        // the toggle explicitly in Downloads settings.
        settings = UserDefaults.standard.data(forKey: "downloadSettings.v2")
            .flatMap { try? JSONDecoder().decode(DownloadSettings.self, from: $0) } ?? DownloadSettings()
        do { let store = try DownloadStore(); records = try store.load(); self.store = store }
        catch { message = "Не удалось открыть хранилище загрузок: \(error.localizedDescription)"; return }
        delegate.owner = self
        sessions = [true, false].map { wifi in
            let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + (wifi ? "wifi" : "any"))
            config.sessionSendsLaunchEvents = true
            config.isDiscretionary = false
            config.waitsForConnectivity = true
            config.allowsCellularAccess = !wifi
            config.allowsExpensiveNetworkAccess = !wifi
            config.timeoutIntervalForResource = 7 * 24 * 3600
            return URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        }
        let directConfig = URLSessionConfiguration.default
        directConfig.waitsForConnectivity = false
        directConfig.allowsCellularAccess = true
        directConfig.allowsExpensiveNetworkAccess = true
        directConfig.timeoutIntervalForResource = 7 * 24 * 3600
        directSession = URLSession(configuration: directConfig, delegate: delegate, delegateQueue: .main)
        sessions.append(directSession)
        assetSessions = [true, false].map { wifi in
            let config = URLSessionConfiguration.background(withIdentifier: Self.sessionPrefix + (wifi ? "hls.wifi" : "hls.any"))
            config.sessionSendsLaunchEvents = true
            config.allowsCellularAccess = !wifi
            config.allowsExpensiveNetworkAccess = !wifi
            return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegate, delegateQueue: .main)
        }
        sessions += assetSessions
        Task { await restore() }
    }

    func record(_ id: UUID) -> DownloadRecord? { records.first { $0.id == id } }
    func existing(_ request: PlaybackRequest) -> DownloadRecord? {
        records.first { $0.media.id == request.media.id && $0.media.mediaType == request.media.mediaType &&
            $0.season == request.season && $0.episode == request.episode &&
            $0.translationID == request.translationID && $0.providerID == request.providerID && $0.sourceID == request.sourceID }
    }
    var usedBytes: Int64 { records.filter { $0.state == .completed }.reduce(0) { Self.addBytes($0, max(0, $1.received)) } }
    var ready: Bool { restored && store != nil }
    func speed(_ id: UUID, at date: Date) -> Double {
        guard let sample = samples[id], date.timeIntervalSince(sample.0) < 3 else { return 0 }
        return speeds[id] ?? 0
    }

    func enqueue(_ request: PlaybackRequest, variant: DownloadVariant, episodeID: String?) {
        guard ready, existing(request) == nil else { return }
        do {
            guard variant.isValid else { throw DownloadError.unavailable }
            guard variant.expiresAt.map({ $0 > Date() }) ?? true else { throw DownloadError.expired }
            try DownloadFiles.checkSpace(required: Self.addBytes(variant.expectedBytes ?? 0, reservedBytes()))
            var entry = DownloadRecord(media: request.media, sourceID: request.sourceID, providerID: request.providerID,
                translationID: request.translationID, translationName: request.translationName, season: request.season,
                episode: request.episode, episodeID: episodeID, variant: variant)
            entry.total = variant.expectedBytes ?? 0
            records.append(entry)
            guard persist() else { records.removeAll { $0.id == entry.id }; return }
            cachePoster(for: entry)
            pump()
        } catch { message = Self.describe(error) }
    }

    func pause(_ id: UUID) {
        guard let index = index(id), [.queued, .downloading].contains(records[index].state), !pausing.contains(id) else { return }
        records[index].state = .paused; speeds[id] = nil; samples[id] = nil
        _ = persist()
        guard let task = tasks[id] else { pump(); return }
        cancelForPause(id, task: task)
    }

    private func cancelForPause(_ id: UUID, task: URLSessionTask) {
        if task is AVAssetDownloadTask {
            if restartAfterPause.remove(id) != nil {
                discardResumeAfterPause.remove(id)
                task.cancel() // New network policy requires a new asset task.
                if let index = index(id) { records[index].state = .queued }
            } else { task.suspend() }
            _ = persist(); pump(); return
        }
        guard let task = task as? URLSessionDownloadTask else { return }
        pausing.insert(id)
        let key = task.taskDescription
        task.cancel { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let index = self.index(id), self.records[index].taskKey == key else {
                    self.pausing.remove(id); self.pump(); return
                }
                self.records[index].resumeData = nil
                if self.tasks[id] === task { self.tasks[id] = nil }
                self.pausing.remove(id)
                if self.restartAfterPause.remove(id) != nil {
                    // MP4 resumes from a fresh request; never replay an opaque saved archive.
                    if self.discardResumeAfterPause.remove(id) != nil { self.records[index].resumeData = nil }
                    self.records[index].state = .queued
                }
                _ = self.persist(); self.pump()
            }
        }
    }

    func resume(_ id: UUID) {
        guard ready, let index = index(id), [.paused, .failed].contains(records[index].state), !pausing.contains(id) else { return }
        records[index].state = .queued; records[index].failure = nil
        if persist() { pump() }
    }

    /// Cancel removes the queue entry, saved resume data and any finished file.
    func remove(_ id: UUID) {
        guard let entry = record(id) else { return }
        do {
            if entry.variant.isHLS ? entry.localPackagePath != nil : entry.localFilename != nil {
                let url = try localURL(entry)
                if FileManager.default.fileExists(atPath: url.path),
                   !entry.variant.isHLS || AVURLAsset(url: url).assetCache != nil {
                    try FileManager.default.removeItem(at: url)
                }
            }
            records.removeAll { $0.id == id }
            tasks[id]?.cancel() // Keep its slot until didComplete, avoiding transient overbooking.
            restartAfterPause.remove(id); discardResumeAfterPause.remove(id); speeds[id] = nil; samples[id] = nil
            _ = persist(); pump()
        } catch { message = "Не удалось удалить файл: \(error.localizedDescription)" }
    }
    func removeAll() {
        removingAll = true
        for id in records.map(\.id) { remove(id) }
        removingAll = false
        pump()
    }

    func playback(_ id: UUID, resumeAt: Double = 0) -> PlaybackSelection? {
        guard let entry = record(id), entry.state == .completed else { return nil }
        do {
            let url = try localURL(entry)
            guard FileManager.default.fileExists(atPath: url.path) else { throw DownloadError.missingFile }
            if entry.variant.isHLS {
                guard let path = entry.localPackagePath else { throw DownloadError.invalidLocation }
                _ = try DownloadFiles.existingPackageURL(path, bookmark: entry.localPackageBookmark)
            }
            var request = entry.request; request.resumeAt = resumeAt
            return PlaybackSelection(source: PlaybackSource(request: request, url: url,
                providerID: entry.providerID, providerName: "Скачанные", quality: entry.variant.quality))
        } catch {
            if let index = index(id) {
                records[index].state = .failed; records[index].failure = error.localizedDescription
                records[index].completedAt = nil; records[index].hlsProgress = nil
                _ = persist()
            }
            message = error.localizedDescription; return nil
        }
    }

    private func restore() async {
        for session in sessions {
            let all = await session.allTasks // Async getAllTasks, including AVAssetDownloadTask.
            for task in all where task is URLSessionDownloadTask || task is AVAssetDownloadTask {
                guard let index = records.firstIndex(where: { $0.taskKey == task.taskDescription }),
                      records[index].state != .completed, records[index].state != .failed,
                      records[index].variant.isValid,
                      records[index].variant.isHLS == (task is AVAssetDownloadTask),
                      task.state != .canceling, task.state != .completed else { task.cancel(); continue }
                let id = records[index].id
                guard tasks[id] == nil else { task.cancel(); continue }
                tasks[id] = task
                if records[index].state == .paused { cancelForPause(id, task: task) }
                else if session.configuration.identifier != nil &&
                        session.configuration.allowsCellularAccess == settings.wifiOnly {
                    records[index].state = .paused
                    restartAfterPause.insert(id); discardResumeAfterPause.insert(id)
                    cancelForPause(id, task: task)
                }
                else { records[index].state = .downloading; task.resume() }
            }
        }
        for index in records.indices {
            let entry = records[index]
            if entry.variant.isHLS {
                // Never infer HLS completion from a directory or progress alone.
                records[index].recoverPersistedState()
                if tasks[entry.id] == nil && [.downloading, .paused].contains(records[index].state) {
                    records[index].state = .failed
                    records[index].failure = "Загрузка прервана. Нажмите «Повторить», чтобы начать заново."
                }
                continue
            }
            if let url = try? localURL(entry), FileManager.default.fileExists(atPath: url.path) {
                // File is only installed after validation; recover a crash between move and metadata commit.
                records[index].state = .completed; records[index].resumeData = nil
                records[index].completedAt = entry.completedAt ?? Date()
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? entry.received
                records[index].received = size; records[index].total = size
            } else if entry.state == .completed {
                records[index].state = .failed; records[index].failure = DownloadError.missingFile.localizedDescription
            } else if tasks[entry.id] == nil && entry.state == .downloading {
                records[index].state = .failed
                records[index].resumeData = nil
                records[index].failure = "Загрузка прервана. Нажмите «Повторить», чтобы начать заново."
            }
        }
        restored = true
        let running = records.filter { $0.state == .downloading }
        for entry in running.dropFirst(max(1, settings.simultaneous)) {
            restartAfterPause.insert(entry.id); pause(entry.id)
        }
        if persist() { pump() }
    }

    private func reservedBytes(excluding id: UUID? = nil) -> Int64 {
        records.filter { $0.id != id && [.queued, .downloading].contains($0.state) }
            .reduce(0) { Self.addBytes($0, max(0, $1.total - $1.received)) }
    }
    private static func addBytes(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
    private func pump() {
        guard ready, !removingAll else { return }
        let limit = min(4, max(1, settings.simultaneous))
        for id in records.filter({ $0.state == .queued }).map(\.id) {
            let occupied = tasks.filter { _, task in
                !(task is AVAssetDownloadTask && task.state == .suspended)
            }.count
            if let task = tasks[id] as? AVAssetDownloadTask, task.state == .suspended, let index = index(id) {
                guard occupied < limit else { continue }
                records[index].state = .downloading
                if persist() { task.resume() }
                continue
            }
            guard occupied < limit else { return }
            guard tasks[id] == nil, !pausing.contains(id), let index = index(id) else { continue }
            do {
                let entry = records[index]
                guard entry.variant.isValid else { throw DownloadError.unavailable }
                guard entry.variant.expiresAt.map({ $0 > Date() }) ?? true else { throw DownloadError.expired }
                try DownloadFiles.checkSpace(required: Self.addBytes(max(0, entry.total - entry.received), reservedBytes(excluding: id)))
                // Commit the attempt first: a process interruption must not replay task creation at startup.
                records[index].generation = UUID()
                records[index].state = .downloading
                records[index].resumeData = nil
                guard persist() else { records[index].state = .failed; return }
                let task: URLSessionTask
                if entry.variant.isHLS {
                    if entry.localPackagePath != nil, let old = try? localURL(entry),
                       FileManager.default.fileExists(atPath: old.path), AVURLAsset(url: old).assetCache != nil {
                        try FileManager.default.removeItem(at: old)
                    }
                    records[index].localPackagePath = nil; records[index].localPackageBookmark = nil
                    records[index].hlsLocationIsSystemProvided = nil; records[index].hlsProgress = 0
                    var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": entry.variant.headers]
                    if let agent = entry.variant.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                        options[AVURLAssetHTTPUserAgentKey] = agent
                    }
                    let asset = AVURLAsset(url: entry.variant.url, options: options)
                    let identifier = Self.sessionPrefix + (settings.wifiOnly ? "hls.wifi" : "hls.any")
                    guard let hlsSession = assetSessions.first(where: { $0.configuration.identifier == identifier })
                    else { throw DownloadError.unavailable }
                    var downloadOptions: [String: Any] = [:]
                    if let bitrate = entry.variant.minimumBitrate {
                        downloadOptions[AVAssetDownloadTaskMinimumRequiredMediaBitrateKey] = NSNumber(value: bitrate)
                    }
                    let title = entry.media.title.isEmpty ? "Видео" : entry.media.title
                    guard let download = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: title,
                        assetArtworkData: nil, options: downloadOptions) else { throw DownloadError.unavailable }
                    task = download
                } else {
                    guard let session = directSession else { throw DownloadError.unavailable }
                    var request = URLRequest(url: entry.variant.url)
                    request.allHTTPHeaderFields = entry.variant.headers
                    // The session enforces policy, including tasks restored from resumeData.
                    request.allowsCellularAccess = true
                    task = session.downloadTask(with: request)
                    records[index].received = 0
                }
                records[index].localFilename = entry.variant.isHLS ? nil : id.uuidString + "-" + records[index].generation.uuidString + "." + entry.variant.url.pathExtension.lowercased()
                records[index].state = .downloading
                records[index].failure = nil
                // HLS resumes through its asset task; MP4 restarts without opaque resume data.
                records[index].resumeData = nil
                task.taskDescription = records[index].taskKey
                tasks[id] = task
                guard persist() else { tasks[id] = nil; task.cancel(); records[index].state = .paused; return }
                samples[id] = (Date(), records[index].received)
                task.resume()
            } catch {
                records[index].state = .failed; records[index].failure = Self.describe(error)
                message = Self.describe(error); _ = persist()
            }
        }
    }

    fileprivate func progress(_ task: URLSessionDownloadTask, received: Int64, total: Int64) {
        guard let index = taskIndex(task), records[index].state == .downloading else { return }
        let id = records[index].id
        records[index].received = received
        if total > 0 { records[index].total = total }
        let now = Date()
        if let sample = samples[id], now.timeIntervalSince(sample.0) >= 0.5 {
            speeds[id] = max(0, Double(received - sample.1) / now.timeIntervalSince(sample.0))
            samples[id] = (now, received)
        }
        if now.timeIntervalSince(lastSave) > 1 {
            do { try DownloadFiles.checkSpace(required: reservedBytes()) }
            catch {
                records[index].state = .failed; records[index].failure = Self.describe(error); task.cancel()
            }
            _ = persist(); lastSave = now
        }
    }

    fileprivate func downloaded(_ task: URLSessionDownloadTask, location: URL) {
        guard let index = taskIndex(task), records[index].state == .downloading,
              !records[index].variant.isHLS else { return }
        do {
            guard let response = task.response as? HTTPURLResponse else { throw DownloadError.invalidFile }
            guard [200, 206].contains(response.statusCode) else { throw ProviderError.http(response.statusCode) }
            let mime = response.mimeType?.lowercased() ?? ""
            guard ["video/mp4", "video/x-m4v", "video/quicktime", "application/octet-stream", ""].contains(mime) else { throw DownloadError.invalidFile }
            let handle = try FileHandle(forReadingFrom: location)
            let head = try handle.read(upToCount: 12) ?? Data(); try handle.close()
            let box = String(data: head.dropFirst(4).prefix(4), encoding: .ascii)
            guard ["ftyp", "moov", "mdat", "wide"].contains(box ?? "") else { throw DownloadError.invalidFile }
            let size = Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size > 12 else { throw DownloadError.invalidFile }
            if response.statusCode == 200, response.expectedContentLength > 0,
               size != response.expectedContentLength { throw DownloadError.invalidFile }
            if response.statusCode == 206 {
                guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                      let expected = range.split(separator: "/").last.flatMap({ Int64($0) }), expected == size else { throw DownloadError.invalidFile }
            }
            guard let name = records[index].localFilename else { throw DownloadError.invalidFile }
            let destination = try DownloadFiles.file(name)
            // Must finalize before returning from this delegate callback: URLSession deletes
            // its temporary location. A retry can leave the same destination behind, and
            // FileManager.moveItem then reports the unhelpful "Cannot create file" error.
            // Remove that stale target and fall back to copy for providers/filesystems where
            // the temporary URL cannot be moved directly.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: location.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                try FileManager.default.copyItem(at: location, to: destination)
                try? FileManager.default.removeItem(at: location)
            }
            records[index].received = size; records[index].total = size
            records[index].state = .completed; records[index].completedAt = Date(); records[index].resumeData = nil
            speeds[records[index].id] = nil
            _ = persist()
        } catch { records[index].state = .failed; records[index].failure = Self.describe(error); _ = persist() }
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        #if DEBUG
        if task is AVAssetDownloadTask { print("TASK ERROR: \(error?.localizedDescription ?? "none")") }
        #endif
        let ownedID = tasks.first { $0.value === task }?.key
        if let index = taskIndex(task) {
            if task is AVAssetDownloadTask, error == nil,
               records[index].state != .completed, records[index].state != .failed {
                do {
                    guard let path = records[index].localPackagePath else { throw DownloadError.invalidLocation }
                    _ = try DownloadFiles.existingPackageURL(path, bookmark: records[index].localPackageBookmark)
                    // didFinishDownloadingTo supplied the URL; didComplete succeeded.
                    // Do not inspect the bundle or invent a byte count for HLS.
                    records[index].received = 0; records[index].total = 0
                    records[index].state = .completed; records[index].completedAt = Date()
                    records[index].hlsProgress = 1; records[index].failure = nil
                } catch {
                    records[index].state = .failed; records[index].failure = error.localizedDescription
                    records[index].completedAt = nil; records[index].hlsProgress = nil
                    message = error.localizedDescription
                }
            }
            let id = records[index].id
            if let error, records[index].state != .completed {
                records[index].resumeData = nil
                if records[index].state == .downloading {
                    records[index].state = .failed; records[index].failure = Self.describe(error)
                    message = Self.describe(error)
                }
            }
            speeds[id] = nil; samples[id] = nil
            if !pausing.contains(id), let ownedID { tasks[ownedID] = nil }
            _ = persist()
        } else if let ownedID { tasks[ownedID] = nil }
        pump()
    }

    private func localURL(_ entry: DownloadRecord) throws -> URL {
        if entry.variant.isHLS {
            guard let path = entry.localPackagePath else { throw DownloadError.invalidLocation }
            return try DownloadFiles.packageURL(path, bookmark: entry.localPackageBookmark)
        }
        guard let name = entry.localFilename else { throw DownloadError.missingFile }
        return try DownloadFiles.file(name)
    }

    fileprivate func hlsLocation(_ task: AVAssetDownloadTask, location: URL) {
        #if DEBUG
        print("DOWNLOAD LOCATION: \(location.absoluteString)")
        print("LOCATION EXISTS: \(FileManager.default.fileExists(atPath: location.path))")
        #endif
        // Stale/cancelled callbacks must never replace or remove a completed package.
        guard let index = taskIndex(task), records[index].state != .completed,
              records[index].state != .failed else { return }
        do {
            let path = try DownloadFiles.packagePath(for: location)
            records[index].localPackagePath = path
            records[index].hlsLocationIsSystemProvided = true
            records[index].localPackageBookmark = try? location.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            #if DEBUG
            print("SAVED LOCAL URL: \(path)")
            #endif
            guard FileManager.default.fileExists(atPath: location.path) else { throw DownloadError.missingFile }
            records[index].localFilename = nil
        } catch {
            records[index].state = .failed; records[index].failure = error.localizedDescription
            records[index].completedAt = nil; records[index].hlsProgress = nil
            message = error.localizedDescription
            task.cancel()
        }
        _ = persist()
    }

    fileprivate func hlsProgress(_ task: AVAssetDownloadTask, ranges: [NSValue], expected: CMTimeRange) {
        guard let index = taskIndex(task), records[index].state == .downloading else { return }
        let duration = expected.duration.seconds
        let loaded = ranges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        if duration.isFinite, duration > 0, loaded.isFinite {
            records[index].hlsProgress = min(1, max(0, loaded / duration))
        }
        if Date().timeIntervalSince(lastSave) > 1 {
            do { try DownloadFiles.checkSpace(required: reservedBytes()) }
            catch { records[index].state = .failed; records[index].failure = Self.describe(error); task.cancel() }
            _ = persist(); lastSave = Date()
        }
    }

    func handleBackgroundEvents(_ identifier: String, completion: @escaping () -> Void) {
        guard identifier.hasPrefix(Self.sessionPrefix), store != nil else { completion(); return }
        completions[identifier] = completion
    }
    fileprivate func finishEvents(_ identifier: String) {
        _ = persist()
        if let completion = completions.removeValue(forKey: identifier) {
            DispatchQueue.main.async { completion() }
        }
    }
    private func index(_ id: UUID) -> Int? { records.firstIndex { $0.id == id } }
    private func taskIndex(_ task: URLSessionTask) -> Int? { records.firstIndex { $0.taskKey == task.taskDescription } }
    @discardableResult private func persist() -> Bool {
        do { guard let store else { return false }; try store.save(records); return true }
        catch { message = "Не удалось сохранить загрузки: \(error.localizedDescription)"; return false }
    }
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) ||
           (ns.domain == NSURLErrorDomain && ns.code == URLError.cannotWriteToFile.rawValue) { return DownloadError.noSpace.localizedDescription }
        return error.localizedDescription
    }
    private func cachePoster(for entry: DownloadRecord) {
        guard let url = URL(string: entry.media.posterURL), ["http", "https"].contains(url.scheme) else { return }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !settings.wifiOnly
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 5_000_000,
                      let index = index(entry.id) else { return }
                let data = try Data(contentsOf: temporary)
                guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return }
                let scale = min(1, 320 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                records[index].posterData = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }.jpegData(compressionQuality: 0.8)
                _ = persist()
            } catch { /* A missing poster must not prevent downloading the video. */ }
        }
    }
}

/// URLSession invokes these callbacks on OperationQueue.main. Synchronous forwarding
/// preserves event order and the temporary file lifetime; no detached Tasks capture UIKit/Core Data.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, @unchecked Sendable {
    @MainActor weak var owner: DownloadManager?
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { owner?.hlsLocation(assetDownloadTask, location: location) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        MainActor.assumeIsolated { owner?.hlsProgress(assetDownloadTask, ranges: loadedTimeRanges, expected: timeRangeExpectedToLoad) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { owner?.progress(downloadTask, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { owner?.downloaded(downloadTask, location: location) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { owner?.completed(task, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { if let id = session.configuration.identifier { owner?.finishEvents(id) } }
    }
}

@MainActor final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.handleBackgroundEvents(identifier, completion: completionHandler)
    }
}
