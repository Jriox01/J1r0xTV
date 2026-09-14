import AVKit
import SwiftUI

@MainActor struct PlayerView: UIViewControllerRepresentable {
    let source: PlaybackSource
    let onProgress: (Double, Double) -> Void
    let onFailure: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, onProgress: onProgress, onFailure: onFailure)
    }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = true
        if source.expiresAt.map({ $0 <= Date() }) ?? false {
            context.coordinator.reportFailure()
            return controller
        }
        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        controller.player = player
        context.coordinator.attach(player)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.save()
        coordinator.detach()
        controller.player?.pause()
    }

    @MainActor final class Coordinator: NSObject {
        let source: PlaybackSource
        let onProgress: (Double, Double) -> Void
        let onFailure: (Double) -> Void
        weak var player: AVPlayer?
        var observer: Any?
        var background: NSObjectProtocol?
        var failedToEnd: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
        var reportedFailure = false
        var detached = false

        init(source: PlaybackSource, onProgress: @escaping (Double, Double) -> Void,
             onFailure: @escaping (Double) -> Void) {
            self.source = source
            self.onProgress = onProgress
            self.onFailure = onFailure
        }
        func attach(_ player: AVPlayer) {
            self.player = player
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if source.request.resumeAt > 0 {
                player.seek(to: CMTime(seconds: source.request.resumeAt, preferredTimescale: 600))
            }
            statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                if item.status == .failed {
                    Task { @MainActor [weak self] in self?.reportFailure() }
                }
            }
            failedToEnd = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reportFailure() }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.save() }
            }
            background = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.save() }
            }
            player.play()
        }
        func reportFailure() {
            guard !reportedFailure, !detached else { return }
            reportedFailure = true
            player?.pause()
            save()
            let position = player?.currentTime().seconds ?? source.request.resumeAt
            // Defer callbacks out of UIViewControllerRepresentable creation/update.
            Task { @MainActor [weak self] in
                guard let self, !self.detached else { return }
                self.onFailure(position.isFinite ? position : self.source.request.resumeAt)
            }
        }
        func save() {
            guard !detached, let player else { return }
            let position = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            if position.isFinite && position >= 0 {
                onProgress(position, duration.isFinite ? duration : 0)
            }
        }
        func detach() {
            detached = true
            if let observer, let player { player.removeTimeObserver(observer) }
            if let background { NotificationCenter.default.removeObserver(background) }
            if let failedToEnd { NotificationCenter.default.removeObserver(failedToEnd) }
            statusObservation?.invalidate()
            observer = nil
            background = nil
            failedToEnd = nil
            statusObservation = nil
        }
    }
}

@MainActor struct PlayerScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @StateObject private var session: PlaybackSession

    init(selection: PlaybackSelection) {
        _session = StateObject(wrappedValue: PlaybackSession(selection: selection))
    }

    var body: some View {
        let current = session.selection
        ZStack(alignment: .topTrailing) {
            PlayerView(source: current.source, onProgress: { position, duration in
                app.library.save(current, position: position, duration: duration)
            }, onFailure: { position in
                session.failed(sourceID: current.source.id, position: position)
            })
            .id(current.source.id)
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Источник: \(current.source.providerName)")
                        if session.switched { Text("Источник переключён").foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    Spacer()
                    Button { app.playback = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                if session.switching { ProgressView("Проверка источника…") }
                if let error = session.error { Text(error).font(.callout) }
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .background(.black)
        .onDisappear { session.cancel(); app.playback = nil }
    }
}
