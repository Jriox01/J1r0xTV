#if DEBUG
import SwiftUI
import AVFoundation

/// Only selected by an explicit simulator launch argument; never runs on normal launch.
@MainActor struct DebugHLSSmokeView: View {
    @State private var session: PlayerSession?
    @State private var message = "HLS simulator smoke tests"
    var body: some View {
        VStack {
            Text(message)
            if let session { PlayerView(session: session).frame(height: 300) }
        }
        .task { await run() }
    }

    private func run() async {
        let base = "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
        let cases = [
            ("master-ts", base + "img_bipbop_adv_example_ts/master.m3u8"),
            ("media-ts", base + "img_bipbop_adv_example_ts/v5/prog_index.m3u8"),
            ("master-fmp4", base + "img_bipbop_adv_example_fmp4/master.m3u8"),
            ("media-fmp4", base + "img_bipbop_adv_example_fmp4/v5/prog_index.m3u8"),
            ("http-to-https-redirect", "http://127.0.0.1:18765/redirect.m3u8"),
            ("aes128-own-key", "http://127.0.0.1:18765/aes.m3u8")
        ]
        var results: [[String: Any]] = []
        let media = MediaItem.parse(["id": .string("smoke"), "title": .string("Apple Bip Bop test")])
        for (name, url) in cases {
            message = name
            do {
                let provider = try TestHLSProvider(url: url)
                let request = PlaybackRequest(media: media, providerID: provider.id)
                let input = try await provider.playback(for: request)
                let validation = try await PlaybackSourceValidator().inspect(input)
                let resolved = try await ProviderResolver(providers: [provider]).resolve(request)
                let player = PlayerSession(source: resolved.source)
                session = player
                player.start()
                try await waitFor(player) { player.status == "readyToPlay" && player.currentTime >= 2 }
                let playedTime = player.currentTime
                var source = resolved.source
                var saved = player.snapshot()
                saved.position = 7
                saved.isPlaying = false
                source.resumeState = saved
                player.replace(with: source)
                try await waitFor(player) { player.status == "readyToPlay" && abs(player.currentTime - 7) < 1 && player.player.rate == 0 }
                let restored = player.snapshot()
                guard restored.audioLanguage == saved.audioLanguage,
                      restored.subtitleLanguage == saved.subtitleLanguage,
                      restored.subtitlesOff == saved.subtitlesOff else { throw SmokeError.failed("media selection not restored") }
                results.append(["case": name, "status": "PASS", "playedTime": playedTime,
                                "resumedTime": player.currentTime, "paused": player.player.rate == 0,
                                "kind": validation.kind.rawValue, "redirects": validation.probe.redirects,
                                "events": player.events])
                player.stop(); session = nil
            } catch {
                results.append(["case": name, "status": "FAIL", "error": PlaybackDiagnostics.error(error),
                                "reason": (error as? SmokeError)?.message ?? session?.lastError ?? "See error code",
                                "itemStatus": session?.status ?? "preflight", "time": session?.currentTime ?? 0,
                                "events": session?.events ?? []])
                session?.stop(); session = nil
            }
        }
        for code in [403, 404, 410] {
            do {
                let provider = try TestHLSProvider(url: "http://127.0.0.1:18765/\(code).m3u8")
                let source = try await provider.playback(for: .init(media: media))
                try await PlaybackSourceValidator().validate(source)
                results.append(["case": "HTTP-\(code)", "status": "FAIL"])
            } catch ProviderError.http(let actual) {
                results.append(["case": "HTTP-\(code)", "status": actual == code ? "PASS" : "FAIL"])
            } catch { results.append(["case": "HTTP-\(code)", "status": "FAIL", "error": PlaybackDiagnostics.error(error)]) }
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("hls-smoke-results.json"), options: .atomic)
            message = results.allSatisfy { $0["status"] as? String == "PASS" } ? "HLS SMOKE PASS" : "HLS SMOKE FAILED"
        } catch { message = "Cannot write smoke results" }
    }
    private func waitFor(_ player: PlayerSession, condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if player.status == "failed" { throw SmokeError.failed(player.lastError ?? "AVPlayer failed") }
            if condition() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SmokeError.failed("Timed out waiting for playback/resume")
    }
    private enum SmokeError: Error {
        case failed(String)
        var message: String { switch self { case .failed(let message): return message } }
    }
}
#endif
