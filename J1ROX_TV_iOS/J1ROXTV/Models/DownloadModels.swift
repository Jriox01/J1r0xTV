import Foundation

enum DownloadState: String, Codable, Sendable {
    case queued, downloading, paused, completed, failed
    var title: String {
        switch self {
        case .queued: return "Ожидает"
        case .downloading: return "Скачивается"
        case .paused: return "Пауза"
        case .completed: return "Завершено"
        case .failed: return "Ошибка"
        }
    }
}

/// Only populated from an explicit, permission-bearing provider download contract.
struct DownloadVariant: Codable, Hashable, Identifiable, Sendable {
    let url: URL
    let quality: String
    let expectedBytes: Int64?
    let headers: [String: String]
    let expiresAt: Date?
    var minimumBitrate: Double? = nil
    var id: String { quality + "|" + url.absoluteString }
    var isHLS: Bool { url.pathExtension.lowercased() == "m3u8" }
    var isValid: Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") &&
        url.host?.isEmpty == false && url.user == nil && url.password == nil &&
        (isHLS || Self.isDirectFile(url)) &&
        (minimumBitrate.map { $0.isFinite && $0 > 0 } ?? true) &&
        (expectedBytes.map { $0 >= 0 } ?? true) &&
        headers.allSatisfy { !$0.key.isEmpty && !$0.key.contains(where: { $0.isNewline }) && !$0.value.contains(where: { $0.isNewline }) }
    }

    // Keep the master URL: downloading a child playlist can lose external audio.
    func hlsVariants(manifest: String) -> [Self] {
        guard isHLS, manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return [self] }
        var choices: [Self] = []
        var seen: Set<String> = []
        for line in manifest.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let fields = line.dropFirst("#EXT-X-STREAM-INF:".count).split(separator: ",")
            func field(_ name: String) -> String? {
                fields.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
            }
            guard let size = field("RESOLUTION")?.split(separator: "x"), size.count == 2,
                  let height = Int(size[1]), height > 0, height <= 16384,
                  let bitrate = field("BANDWIDTH").flatMap(Double.init), bitrate.isFinite, bitrate > 0 else { continue }
            let quality = "\(height)p"
            guard seen.insert(quality).inserted else { continue }
            choices.append(Self(url: url, quality: quality, expectedBytes: nil, headers: headers,
                                expiresAt: expiresAt, minimumBitrate: bitrate))
        }
        return choices.isEmpty ? [self] : choices.sorted { ($0.minimumBitrate ?? 0) < ($1.minimumBitrate ?? 0) }
    }

    static func parse(_ metadata: [String: JSONValue]) -> [Self] {
        guard metadata["download_allowed"] == .bool(true), metadata["drm"] == .bool(false) else { return [] }
        let variants: [Self] = (metadata["downloads"]?.array ?? []).compactMap { node in
            guard let row = node.object,
                  row["download_allowed"] != .bool(false),
                  row["drm"] == nil || row["drm"] == .bool(false),
                  let url = URL(string: row.text("url")), isDirectFile(url) else { return nil }
            let size = Self.byteCount(row["size_bytes"])
            let expiration = Self.number(row["expires_at"]).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            let headers = row["headers"]?.object?.compactMapValues { value -> String? in
                if case .string(let text) = value { return text }; return nil
            } ?? [:]
            return Self(url: url, quality: row.text("quality").isEmpty ? "Оригинал" : row.text("quality"),
                        expectedBytes: size.flatMap { $0 > 0 ? $0 : nil }, headers: headers, expiresAt: expiration)
        }
        var seen: Set<String> = []
        return variants.filter { seen.insert($0.id).inserted }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let number): return number
        case .string(let text): return Double(text)
        default: return nil
        }
    }
    private static func byteCount(_ value: JSONValue?) -> Int64? {
        if let value, case .string(let text) = value { return Int64(text) }
        guard let number = Self.number(value), number.isFinite, number > 0, number < Double(Int64.max) else { return nil }
        return Int64(number)
    }

    static func isDirectFile(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil &&
        url.user == nil && url.password == nil && ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// HEAD is optional: servers without HEAD support may still download with an unknown size.
    func inspectingSize() async throws -> Self {
        if expectedBytes != nil { return self }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.allHTTPHeaderFields = headers
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return self }
            if [401, 403, 410].contains(http.statusCode) { throw DownloadError.expired }
            guard http.statusCode == 200, response.expectedContentLength > 0 else { return self }
            return Self(url: url, quality: quality, expectedBytes: response.expectedContentLength,
                        headers: headers, expiresAt: expiresAt)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DownloadError { throw error }
        catch { try Task.checkCancellation(); return self }
    }
}

struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let media: MediaItem
    let sourceID: String?
    let providerID: String
    let translationID: String?
    let translationName: String?
    let season: String?
    let episode: String?
    let episodeID: String?
    var variant: DownloadVariant
    var createdAt = Date()
    var completedAt: Date?
    var state = DownloadState.queued
    var received: Int64 = 0
    var total: Int64 = 0
    var localFilename: String?
    var localPackagePath: String?
    var localPackageBookmark: Data?
    var hlsLocationIsSystemProvided: Bool?
    var hlsProgress: Double?
    var posterData: Data?
    var resumeData: Data?
    var generation = UUID()
    var failure: String?
    // Missing in older payloads. Quarantine their unfinished HLS work on upgrade.
    var recoveryVersion: Int? = 2

    mutating func recoverPersistedState() {
        resumeData = nil // Opaque data may be corrupt or reference a previous sandbox; restart MP4 safely.
        received = max(0, received); total = max(0, total)
        if let value = hlsProgress { hlsProgress = value.isFinite ? min(1, max(0, value)) : nil }
        let invalidLocal = localFilename.map { !DownloadFiles.isSafeFilename($0) } == true ||
            localPackagePath.map { !DownloadFiles.isSafePackagePath($0) } == true
        if invalidLocal { localFilename = nil; localPackagePath = nil }
        if state != .completed && (!variant.isValid || invalidLocal || (variant.isHLS && recoveryVersion != 2)) {
            state = .failed
            failure = "Незавершённая или повреждённая загрузка сброшена. Повторите загрузку."
            generation = UUID()
        }
        recoveryVersion = 2
        // Old versions invented a package path in the MP4 directory. Do not
        // search for files there or treat that fabricated path as an HLS asset.
        if variant.isHLS, hlsLocationIsSystemProvided != true,
           (localPackagePath.map {
                let path = (try? DownloadFiles.packageURL($0).path) ?? $0
                return path.contains("Application Support/Downloads/") && path.hasSuffix(".movpkg")
            } == true ||
            (localPackagePath == nil && localFilename?.hasSuffix(".movpkg") == true)) {
            state = .failed; completedAt = nil; hlsProgress = nil
            localPackagePath = nil; localPackageBookmark = nil; localFilename = nil
            failure = DownloadError.invalidLocation.localizedDescription
            generation = UUID()
        }
        if variant.isHLS && state == .completed {
            do {
                guard let path = localPackagePath else { throw DownloadError.invalidLocation }
                let url = try DownloadFiles.existingPackageURL(path, bookmark: localPackageBookmark)
                localPackagePath = try DownloadFiles.packagePath(for: url)
            } catch {
                state = .failed; completedAt = nil; hlsProgress = nil
                failure = error.localizedDescription
            }
        }
    }

    var request: PlaybackRequest {
        .init(media: media, sourceID: sourceID, translationID: translationID, season: season,
              episode: episode, translationName: translationName, providerID: providerID)
    }
    var taskKey: String { id.uuidString + ":" + generation.uuidString }
    var progress: Double? {
        if let hlsProgress, hlsProgress.isFinite { return min(1, max(0, hlsProgress)) }
        return total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil
    }
    var episodeLabel: String { episode.map { "Сезон \(season ?? "—") · Серия \($0)" } ?? "Фильм" }
}

struct DownloadSettings: Codable, Equatable, Sendable {
    var quality = "720p"
    var askQuality = true
    var wifiOnly = true
    var simultaneous = 2
}

enum DownloadError: LocalizedError {
    case unavailable, noSpace, missingFile, invalidFile, expired, invalidLocation
    var errorDescription: String? {
        switch self {
        case .invalidLocation: return "Системное расположение HLS-загрузки не сохранено. Удалите запись и скачайте видео заново."
        case .unavailable: return "Источник не поддерживает скачивание этого видео. Защищённое видео не поддерживается."
        case .noSpace: return "Недостаточно свободного места. Удалите ненужные загрузки и повторите попытку."
        case .missingFile: return "Скачанный файл отсутствует. Удалите запись и скачайте видео заново."
        case .invalidFile: return "Сервер вернул неподдерживаемый или неполный видеофайл."
        case .expired: return "Ссылка истекла. Удалите загрузку и снова выберите «Скачать» на странице фильма или серии."
        }
    }
}
