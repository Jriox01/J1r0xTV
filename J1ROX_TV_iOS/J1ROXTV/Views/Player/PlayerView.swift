import AVKit
import SwiftUI

@MainActor struct PlayerView: UIViewControllerRepresentable {
    // AVPlayer owns its item changes. Metric publications must not rebind AVKit.
    let session: PlayerSession
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: ((CGFloat, CGFloat, Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.player = session.player
        context.coordinator.install(on: controller.view)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = onDragChanged != nil
        if controller.player !== session.player { controller.player = session.player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        if let pan = coordinator.pan { controller.view.removeGestureRecognizer(pan) }
        coordinator.pan = nil
    }

    // UIKit hit testing lets native AVKit controls reject the gesture before it
    // begins. A high-priority SwiftUI gesture over the player cannot do that.
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerView
        weak var pan: UIPanGestureRecognizer?
        init(_ parent: PlayerView) { self.parent = parent }

        func install(on view: UIView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.isEnabled = parent.onDragChanged != nil
            view.addGestureRecognizer(pan)
            self.pan = pan
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.onDragChanged != nil, let view = gestureRecognizer.view else { return false }
            // Reserve edge areas for AVKit's scrubber/volume/top controls, including
            // versions whose controls are not public UIControl subclasses.
            let point = touch.location(in: view)
            let top = max(view.safeAreaInsets.top, 24) + 44
            let bottom = max(view.safeAreaInsets.bottom, 20) + 88
            guard point.y > top, point.y < view.bounds.height - bottom,
                  point.x > 32, point.x < view.bounds.width - 32 else { return false }
            var hit: UIView? = touch.view
            while let current = hit, current !== view {
                if current is UIControl || current is UIScrollView ||
                    current.accessibilityTraits.contains(.button) ||
                    current.accessibilityTraits.contains(.adjustable) { return false }
                hit = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func drag(_ pan: UIPanGestureRecognizer) {
            // Window coordinates stay fixed while SwiftUI moves the entire player.
            let translation = pan.translation(in: pan.view?.window)
            let velocity = pan.velocity(in: pan.view?.window)
            switch pan.state {
            case .began, .changed: parent.onDragChanged?(max(0, translation.y))
            case .ended:
                let vertical = translation.y > abs(translation.x) * 1.5
                parent.onDragEnded?(max(0, translation.y), velocity.y, !vertical)
            case .cancelled, .failed: parent.onDragEnded?(0, 0, true)
            default: break
            }
        }
    }
}

@MainActor struct PlayerScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @StateObject private var session: PlaybackSession
    @StateObject private var playerSession: PlayerSession
    @StateObject private var controls: DetailsViewModel
    @State private var countdown: Int?
    @State private var nextEpisode: (SeasonOption, EpisodeOption)?
    @State private var countdownTask: Task<Void, Never>?
    @State private var changeTask: Task<Void, Never>?
    @State private var changeID = UUID()
    @State private var changing = false
    @State private var closed = false
    @State private var dragOffset: CGFloat = 0
    @State private var dismissTask: Task<Void, Never>?

    init(selection: PlaybackSelection) {
        let model = DetailsViewModel(item: selection.request.media, streaming: StreamingService())
        model.restore(selection.request)
        _controls = StateObject(wrappedValue: model)
        _session = StateObject(wrappedValue: PlaybackSession(selection: selection))
        _playerSession = StateObject(wrappedValue: PlayerSession(source: selection.source))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                PlayerView(session: playerSession,
                    onDragChanged: closed ? nil : { dragOffset = $0 },
                    onDragEnded: { distance, velocity, cancelled in
                        finishDrag(distance: distance, velocity: velocity, cancelled: cancelled, height: geometry.size.height)
                    })
                .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 8) {
                    if changing { ProgressView("Загрузка видео…") }
                    if let error = controls.error { Text(error).font(.callout) }
                    if session.switching { ProgressView("Проверка источника…") }
                    if let error = session.error { Text(error).font(.callout) }
                }
                .foregroundStyle(.white)
                .padding(16)
                if let countdown, let nextEpisode {
                    VStack(spacing: 12) {
                        Text("Следующая серия через \(countdown) секунд").font(.headline)
                        Text("Сезон \(nextEpisode.0.number) · \(nextEpisode.1.name)")
                        HStack {
                            Button("Отмена") { cancelCountdown() }
                            Button("Смотреть сейчас") { playNext() }
                        }.buttonStyle(.borderedProminent).tint(.red)
                    }.padding(20).background(Color.jiroxSurface, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 60)
                }
            }
            .background(.black)
            .offset(y: dragOffset)
        }
        .background(.black)
        .accessibilityAction(.escape) { dismissPlayer() }
        .task(id: session.selection.source.id) {
            if !closed, !session.selection.source.url.isFileURL { await controls.synchronize(session.selection.request) }
        }
        .onAppear {
            closed = false
            dragOffset = 0
            playerSession.onEnded = { scheduleNext() }
            playerSession.onProgress = { position, duration in
                app.library.save(PlaybackSelection(source: playerSession.source), position: position, duration: duration)
            }
            playerSession.onFailure = { snapshot, error in
                guard !closed, !changing else { return }
                cancelCountdown()
                session.failed(sourceID: session.selection.source.id, snapshot: snapshot, failure: error)
            }
            playerSession.start()
        }
        .onChange(of: session.selection.source.id) { _ in
            guard !closed else { return }
            cancelCountdown()
            playerSession.replace(with: session.selection.source)
        }
        .onDisappear {
            dismissTask?.cancel(); dismissTask = nil
            prepareToClose()
            playerSession.stop()
            app.playback = nil
        }
    }

    private func finishDrag(distance: CGFloat, velocity: CGFloat, cancelled: Bool, height: CGFloat) {
        guard !closed else { return }
        let threshold = min(200, max(100, height * 0.22))
        let projected = distance + max(0, velocity) * 0.18
        let fastSwipe = distance >= 44 && velocity >= 900 && projected >= threshold
        if !cancelled && (distance >= threshold || fastSwipe) {
            prepareToClose()
            withAnimation(.easeOut(duration: 0.2)) { dragOffset = height + 100 }
            dismissTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                dismissPlayer()
            }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { dragOffset = 0 }
        }
    }

    private func dismissPlayer() {
        prepareToClose()
        // The interactive offset already animates the exit. Avoid a second cover slide.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { app.playback = nil }
    }

    private func prepareToClose() {
        guard !closed else { return }
        closed = true
        changeID = UUID(); changeTask?.cancel(); changeTask = nil
        controls.cancel(); cancelCountdown(); session.cancel()
        playerSession.onEnded = nil
        playerSession.onFailure = nil
        playerSession.onProgress = nil
        let saved = playerSession.snapshot()
        app.library.save(PlaybackSelection(source: playerSession.source), position: saved.position, duration: playerSession.duration)
        // Retain the last video frame during the exit animation; stop on disappearance.
        playerSession.player.pause()
    }

    private func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        countdown = nil; nextEpisode = nil
    }

    private func scheduleNext() {
        guard !closed, !changing, countdownTask == nil, !session.selection.source.url.isFileURL else { return }
        let sourceID = session.selection.source.id
        countdownTask = Task { @MainActor in
            // Metadata may still be loading when a short episode finishes.
            while controls.loading {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            if controls.sources.isEmpty { await controls.synchronize(session.selection.request) }
            guard !Task.isCancelled, !closed, session.selection.source.id == sourceID,
                  let next = controls.next(after: session.selection.request) else {
                countdownTask = nil; return
            }
            nextEpisode = next; countdown = 5
            for remaining in stride(from: 4, through: 0, by: -1) {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard !Task.isCancelled, !closed, session.selection.source.id == sourceID else { return }
                if remaining == 0 { playNext() } else { countdown = remaining }
            }
        }
    }

    private func playNext() {
        guard !closed, let next = nextEpisode, !changing else { return }
        cancelCountdown()
        controls.select(season: next.0)
        change(episode: next.1)
    }

    private func change(source: SourceOption? = nil, translation: TranslationOption? = nil, episode: EpisodeOption? = nil) {
        cancelCountdown()
        changeTask?.cancel(); controls.cancel(); session.cancel()
        let token = UUID(); changeID = token
        let current = session.selection.request
        let snapshot = playerSession.snapshot()
        app.library.save(session.selection, position: snapshot.position, duration: playerSession.duration)
        changing = true; controls.error = nil
        changeTask = Task { @MainActor in
            defer { if changeID == token { changing = false } }
            do {
                if let source { try await controls.select(source: source) }
                if let translation { controls.select(translation: translation) }
                var target = episode
                if episode == nil, let season = current.season {
                    guard let selected = controls.seasons.first(where: { $0.number == season }) else { throw ProviderError.selectionUnavailable }
                    controls.select(season: selected)
                    target = controls.episodes.first { $0.number == current.episode }
                    guard target != nil else { throw ProviderError.selectionUnavailable }
                }
                let result = try await controls.play(episode: target, resume: episode == nil ? snapshot.position : 0)
                try Task.checkCancellation()
                guard !closed, changeID == token else { return }
                session.replace(result, snapshot: episode == nil ? snapshot : nil)
            } catch {
                if !Task.isCancelled, changeID == token {
                    let message = error.localizedDescription
                    await controls.synchronize(current)
                    if !Task.isCancelled, changeID == token { controls.error = message }
                }
            }
        }
    }

}
