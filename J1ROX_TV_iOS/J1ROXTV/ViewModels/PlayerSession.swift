import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// AVFoundation only. No provider discovery, network resolution or fallback decisions.
@MainActor final class PlayerSession: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "idle"
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffer = "unknown"
    @Published private(set) var loadedTimeRanges = "[]"
    @Published private(set) var bitrate: Double = 0
    @Published private(set) var resolution = "unknown"
    @Published private(set) var cdnHost = "unknown"
    @Published private(set) var lastError: String?
    @Published private(set) var events: [String] = []
    var onEnded: (() -> Void)?
    // Optional integration hooks; ordinary playback and standalone tests need no SharePlay dependency.
    var onWillChangeItem: (() -> Void)?
    var onItemCreated: ((AVPlayerItem, PlaybackRequest) -> Void)?
    var onReady: (() -> Void)?
    var isReadyForCoordination: Bool { active && !restoring && !failed && status == "readyToPlay" }
    var hasEnded: Bool { ended }
    private var ended = false
    var onProgress: ((Double, Double) -> Void)?
    var onFailure: ((PlaybackSnapshot, PlaybackError) -> Void)?
    private(set) var source: PlaybackSource
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timer: Any?
    private var failed = false
    private var active = false
    private var restoring = false
    private var groups: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
    private var lastSavedAt = Date.distantPast
    private var wantsPlayback = true
    private var restoreTask: Task<Void, Never>?

    init(source: PlaybackSource) { self.source = source }

    func start() {
        guard !active else { return }
        active = true
        failed = false
        ended = false
        lastError = nil
        wantsPlayback = source.resumeState?.isPlaying ?? true
        cdnHost = source.url.host ?? "unknown"
        guard source.expiresAt.map({ $0 > Date() }) ?? true else {
            fail(PlaybackError.refreshFailed(ProviderError.expired)); return
        }
        #if canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { log("audioSession " + PlaybackDiagnostics.error(error)) }
        #endif
        // Compatibility path already used by the app. Arbitrary headers are not a
        // documented AVFoundation contract; propagation to child requests isn't guaranteed.
        var options: [String: Any] = [:]
        if !source.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers }
        if let agent = source.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        // Offline assets use the system local URL, without network headers/resolution.
        let asset = source.url.isFileURL ? AVURLAsset(url: source.url) : AVURLAsset(url: source.url, options: options)
        #if DEBUG
        if source.url.isFileURL { print("PLAYBACK LOCAL URL: \(source.url.absoluteString)") }
        #endif
        let item = AVPlayerItem(asset: asset)
        onItemCreated?(item, source.request)
        status = "loading"
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.active, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay: self.ready(item)
                case .failed: self.fail(.avFoundation(item.error ?? NSError(domain: "AVPlayerItem", code: -1)))
                default: self.status = "loading"
                }
            }
        })
        for key in [\AVPlayerItem.isPlaybackLikelyToKeepUp, \.isPlaybackBufferEmpty, \.isPlaybackBufferFull] {
            observations.append(item.observe(key, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.player.currentItem === item else { return }
                    self.buffer = "likely=\(item.isPlaybackLikelyToKeepUp) empty=\(item.isPlaybackBufferEmpty) full=\(item.isPlaybackBufferFull)"
                    self.log(self.buffer)
                }
            })
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.log("timeControlStatus=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                guard !self.failed, !self.restoring, player.currentItem?.status == .readyToPlay else { return }
                self.wantsPlayback = player.timeControlStatus != .paused
            }
        })
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemNewErrorLogEntry,
                     .AVPlayerItemNewAccessLogEntry, .AVPlayerItemPlaybackStalled] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.player.currentItem === item else { return }
                    if name == .AVPlayerItemDidPlayToEndTime {
                        guard !self.ended else { return }
                        self.ended = true
                        self.sample()
                        self.onProgress?(self.currentTime, self.duration)
                        self.onEnded?()
                    } else if name == .AVPlayerItemFailedToPlayToEndTime {
                        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                        self.fail(.avFoundation(error ?? item.error ?? NSError(domain: "AVPlayerItem", code: -2)))
                    } else if name == .AVPlayerItemNewErrorLogEntry { self.readErrorLog(item) }
                    else if name == .AVPlayerItemNewAccessLogEntry { self.readAccessLog(item) }
                    else { self.log("playbackStalled") }
                }
            })
        }
        // Install item observers before association starts asynchronous media loading.
        player.replaceCurrentItem(with: item)
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        log("asset=" + PlaybackDiagnostics.url(source.url))
        // Kick off AVPlayer's media loading. Waiting for readyToPlay before ever
        // requesting playback can leave a fresh HLS item indefinitely unknown.
        player.play()
    }

    private func ready(_ item: AVPlayerItem) {
        guard !restoring, status != "readyToPlay" else { return }
        status = "readyToPlay"
        log("readyToPlay")
        restoring = true
        player.pause()
        let state = source.resumeState ?? PlaybackSnapshot(position: source.request.resumeAt)
        restoreTask = Task { [weak self] in
            guard let self else { return }
            if let playable = try? await item.asset.load(.isPlayable) {
                self.log("asset isPlayable=\(playable)")
            }
            await self.restoreTracks(item, state: state)
            guard !Task.isCancelled, self.active, self.player.currentItem === item else { return }
            if state.position.isFinite && state.position > 0 {
                let length = item.duration.seconds
                let position = length.isFinite && length > 0 ? min(state.position, max(0, length - 1)) : state.position
                _ = await self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard !Task.isCancelled, self.active, self.player.currentItem === item else { return }
            self.restoring = false
            self.wantsPlayback = state.isPlaying
            if state.isPlaying { self.player.play() }
            self.sample()
            self.onReady?()
        }
    }

    private func restoreTracks(_ item: AVPlayerItem, state: PlaybackSnapshot) async {
        for characteristic in [AVMediaCharacteristic.audible, .legible] {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic), !Task.isCancelled, player.currentItem === item else { continue }
            groups[characteristic] = group
            if characteristic == .legible && state.subtitlesOff { item.select(nil, in: group); continue }
            let name = characteristic == .audible ? state.audioName : state.subtitleName
            let language = characteristic == .audible ? state.audioLanguage : state.subtitleLanguage
            guard name != nil || language != nil else { continue }
            let option = group.options.first { $0.displayName == name && (language == nil || $0.extendedLanguageTag == language) }
                ?? group.options.first { language != nil && $0.extendedLanguageTag == language }
            if let option { item.select(option, in: group) }
        }
    }

    func snapshot() -> PlaybackSnapshot {
        let time = player.currentTime().seconds
        var result = source.resumeState ?? PlaybackSnapshot(position: source.request.resumeAt)
        result.isPlaying = wantsPlayback
        if status == "readyToPlay", !restoring, time.isFinite { result.position = max(0, time) }
        if let item = player.currentItem {
            for characteristic in [AVMediaCharacteristic.audible, .legible] {
                // Cached groups are populated during readyToPlay restoration.
                guard let group = groups[characteristic] else { continue }
                let option = item.currentMediaSelection.selectedMediaOption(in: group)
                if characteristic == .audible { result.audioName = option?.displayName; result.audioLanguage = option?.extendedLanguageTag }
                else { result.subtitleName = option?.displayName; result.subtitleLanguage = option?.extendedLanguageTag; result.subtitlesOff = option == nil }
            }
        }
        return result
    }

    private func sample() {
        guard active else { return }
        let time = player.currentTime().seconds
        if time.isFinite { currentTime = max(0, time) }
        let length = player.currentItem?.duration.seconds ?? source.duration ?? 0
        duration = length.isFinite ? length : 0
        let ranges = player.currentItem?.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return "\(range.start.seconds)..\(CMTimeRangeGetEnd(range).seconds)"
        }.joined(separator: ", ") ?? ""
        if ranges != loadedTimeRanges {
            loadedTimeRanges = ranges
            log("loadedTimeRanges=[\(ranges)] duration=\(duration)")
        }
        if let size = player.currentItem?.presentationSize, size.width.isFinite, size.height.isFinite {
            resolution = "\(Int(size.width))×\(Int(size.height))"
        }
        if !restoring, status == "readyToPlay", Date().timeIntervalSince(lastSavedAt) >= 10 {
            onProgress?(currentTime, duration)
            lastSavedAt = Date()
        }
        if source.expiresAt.map({ $0 <= Date() }) ?? false, !failed { fail(.refreshFailed(ProviderError.expired)) }
    }

    private func readErrorLog(_ item: AVPlayerItem) {
        guard let event = item.errorLog()?.events.last else { return }
        let detail = "errorLog domain=\(event.errorDomain) code=\(event.errorStatusCode) failedURL=\(PlaybackDiagnostics.url(event.uri.flatMap(URL.init(string:))))"
        lastError = detail
        log(detail)
    }
    private func readAccessLog(_ item: AVPlayerItem) {
        guard let event = item.accessLog()?.events.last else { return }
        bitrate = event.observedBitrate
        if let uri = event.uri, let host = URL(string: uri)?.host { cdnHost = host }
        log("accessLog bitrate=\(event.observedBitrate) indicated=\(event.indicatedBitrate) stalls=\(event.numberOfStalls) host=\(cdnHost)")
    }
    private func fail(_ error: PlaybackError) {
        guard active, !failed else { return }
        let saved = snapshot()
        failed = true
        status = "failed"
        let detail = PlaybackDiagnostics.error(error)
        lastError = [lastError, detail].compactMap { $0 }.joined(separator: "\n")
        log(detail)
        onWillChangeItem?()
        player.pause()
        onProgress?(saved.position, duration)
        onFailure?(saved, error)
    }
    private func log(_ text: String) {
        #if DEBUG
        events.append(text)
        if events.count > 80 { events.removeFirst(events.count - 80) }
        PlaybackDiagnostics.log(text)
        #endif
    }
    func replace(with source: PlaybackSource) {
        onWillChangeItem?()
        stop()
        self.source = source
        currentTime = 0; duration = 0; bitrate = 0; buffer = "unknown"; resolution = "unknown"
        start()
    }
    func stop() {
        active = false
        restoreTask?.cancel(); restoreTask = nil; restoring = false
        if let timer { player.removeTimeObserver(timer) }; timer = nil
        observations.forEach { $0.invalidate() }; observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        groups.removeAll()
        status = "stopped"
    }
}
