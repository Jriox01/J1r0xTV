import AVKit
import SwiftUI

@MainActor struct PlayerView: UIViewControllerRepresentable {
    // AVPlayer owns its item changes. Metric publications must not rebind AVKit.
    let session: PlayerSession
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.player = session.player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== session.player { controller.player = session.player }
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
    @State private var showControls = false
    @State private var closed = false

    init(selection: PlaybackSelection) {
        let model = DetailsViewModel(item: selection.request.media, streaming: StreamingService())
        model.restore(selection.request)
        _controls = StateObject(wrappedValue: model)
        _session = StateObject(wrappedValue: PlaybackSession(selection: selection))
        _playerSession = StateObject(wrappedValue: PlayerSession(source: selection.source))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerView(session: playerSession)
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    if !session.selection.source.url.isFileURL {
                        Button("Серии и озвучка") { showControls.toggle() }
                            .buttonStyle(.borderedProminent).tint(.red)
                    }
                    Spacer()
                    Button { app.playback = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                if showControls {
                    ScrollView {
                        VStack(spacing: 8) {
                            ContentSelectors(model: controls,
                                sourceSelected: { value in change(source: value) },
                                translationSelected: { value in change(translation: value) },
                                seasonSelected: { value in
                                    cancelCountdown(); changeTask?.cancel(); changeID = UUID(); changing = false
                                    controls.select(season: value)
                                })
                            ForEach(controls.episodes) { episode in
                                Button {
                                    change(episode: episode)
                                } label: {
                                    Label(episode.name, systemImage: session.selection.request.episode == episode.number && session.selection.request.season == controls.selectedSeason?.number ? "play.circle.fill" : "play.circle")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.tint(.red)
                            }
                        }
                    }.frame(maxHeight: 240).padding(8).background(.black.opacity(0.85))
                }
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
        .task(id: session.selection.source.id) {
            if !session.selection.source.url.isFileURL { await controls.synchronize(session.selection.request) }
        }
        .onAppear {
            closed = false
            playerSession.onEnded = { scheduleNext() }
            playerSession.onProgress = { position, duration in
                app.library.save(PlaybackSelection(source: playerSession.source), position: position, duration: duration)
            }
            playerSession.onFailure = { snapshot, error in
                guard !changing else { return }
                cancelCountdown()
                session.failed(sourceID: session.selection.source.id, snapshot: snapshot, failure: error)
            }
            playerSession.start()
        }
        .onChange(of: session.selection.source.id) { _ in
            cancelCountdown()
            playerSession.replace(with: session.selection.source)
        }
        .onDisappear {
            closed = true
            changeID = UUID(); changeTask?.cancel(); controls.cancel(); cancelCountdown()
            playerSession.onEnded = nil
            let saved = playerSession.snapshot()
            app.library.save(PlaybackSelection(source: playerSession.source), position: saved.position, duration: playerSession.duration)
            playerSession.stop(); session.cancel(); app.playback = nil
        }
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
        guard let next = nextEpisode, !changing else { return }
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
                showControls = false
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
