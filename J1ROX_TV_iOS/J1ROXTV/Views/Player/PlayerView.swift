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

    init(selection: PlaybackSelection) {
        _session = StateObject(wrappedValue: PlaybackSession(selection: selection))
        _playerSession = StateObject(wrappedValue: PlayerSession(source: selection.source))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerView(session: playerSession)
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
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
        }
        .background(.black)
        .onAppear {
            playerSession.onProgress = { position, duration in
                app.library.save(session.selection, position: position, duration: duration)
            }
            playerSession.onFailure = { snapshot, error in
                session.failed(sourceID: session.selection.source.id, snapshot: snapshot, failure: error)
            }
            playerSession.start()
        }
        .onChange(of: session.selection.source.id) { _ in
            playerSession.replace(with: session.selection.source)
        }
        .onDisappear {
            let saved = playerSession.snapshot()
            app.library.save(session.selection, position: saved.position, duration: playerSession.duration)
            playerSession.stop(); session.cancel(); app.playback = nil
        }
    }
}
