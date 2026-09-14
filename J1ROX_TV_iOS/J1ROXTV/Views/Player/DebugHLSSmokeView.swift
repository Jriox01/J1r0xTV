#if DEBUG
import SwiftUI
import AVFoundation
import AVKit

/// Only selected by an explicit simulator launch argument; never runs on normal launch.
@MainActor struct DebugHLSSmokeView: View {
    @State private var session: PlayerSession?
    @State private var rawPlayer: AVPlayer?
    @State private var showSession = false
    @State private var message = "HLS simulator smoke tests"
    var body: some View {
        VStack {
            Text(message)
            if showSession, let session { PlayerView(session: session).frame(height: 300) }
            if let rawPlayer { VideoPlayer(player: rawPlayer).frame(height: 300) }
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
        // Raw AVFoundation control separates CI media-service failure from session logic.
        let control = AVPlayer(url: URL(string: base + "img_bipbop_adv_example_ts/v5/prog_index.m3u8")!)
        control.play()
        for _ in 0..<80 {
            if control.currentItem?.status == .failed || control.currentTime().seconds >= 2 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let controlTime = control.currentTime().seconds
        results.append(["case": "raw-avplayer-control", "status": controlTime.isFinite && controlTime >= 2 ? "PASS" : "FAIL",
                        "time": controlTime.isFinite ? controlTime : 0, "itemStatus": control.currentItem?.status.rawValue ?? -1,
                        "error": control.currentItem?.error.map { PlaybackDiagnostics.error($0) } ?? "none"])
        control.pause(); control.replaceCurrentItem(with: nil)
        let media = MediaItem.parse(["id": .string("smoke"), "title": .string("Apple Bip Bop test")])
        do {
            let provider = try TestHLSProvider(url: base + "img_bipbop_adv_example_ts/v5/prog_index.m3u8")
            let source = try await provider.playback(for: .init(media: media))
            let direct = PlayerSession(source: source)
            direct.start()
            for _ in 0..<80 {
                if direct.status == "failed" || direct.currentTime >= 2 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            results.append(["case": "session-without-preflight", "status": direct.currentTime >= 2 ? "PASS" : "FAIL",
                            "itemStatus": direct.player.currentItem?.status.rawValue ?? -1,
                            "time": direct.player.currentTime().seconds, "events": direct.events])
            direct.stop()
            try await PlaybackSourceValidator().validate(source)
            let afterProbe = AVPlayer(url: source.url)
            afterProbe.play()
            for _ in 0..<80 {
                if afterProbe.currentItem?.status == .failed || afterProbe.currentTime().seconds >= 2 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let time = afterProbe.currentTime().seconds
            results.append(["case": "raw-after-preflight", "status": time.isFinite && time >= 2 ? "PASS" : "FAIL",
                            "itemStatus": afterProbe.currentItem?.status.rawValue ?? -1,
                            "time": time.isFinite ? time : 0])
            afterProbe.pause(); afterProbe.replaceCurrentItem(with: nil)
            let resolved = try await ProviderResolver(providers: [provider]).resolve(source.request)
            for useSession in [false, true] {
                let engine = PlayerSession(source: resolved.source)
                let raw = AVPlayer(url: resolved.source.url)
                let probe = useSession ? engine.player : raw
                if useSession { engine.start() } else { raw.play() }
                for _ in 0..<80 {
                    if probe.currentItem?.status == .failed || probe.currentTime().seconds >= 2 { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                let time = probe.currentTime().seconds
                results.append(["case": useSession ? "session-after-resolver" : "raw-after-resolver",
                                "status": time.isFinite && time >= 2 ? "PASS" : "FAIL",
                                "itemStatus": probe.currentItem?.status.rawValue ?? -1,
                                "time": time.isFinite ? time : 0,
                                "sameURL": resolved.source.url == source.url,
                                "sameHeaders": resolved.source.headers == source.headers,
                                "resumeAt": resolved.source.request.resumeAt,
                                "cancelled": Task.isCancelled, "events": engine.events])
                engine.stop(); raw.pause(); raw.replaceCurrentItem(with: nil)
            }
        } catch { results.append(["case": "preflight-isolation", "status": "FAIL", "error": PlaybackDiagnostics.error(error)]) }
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
                                "kind": validation.kind.rawValue, "presentation": "headless", "redirects": validation.probe.redirects,
                                "events": player.events])
                player.stop(); session = nil
            } catch {
                results.append(["case": name, "status": "FAIL", "error": PlaybackDiagnostics.error(error),
                                "reason": (error as? SmokeError)?.message ?? session?.lastError ?? "See error code",
                                "itemStatus": session?.status ?? "preflight", "time": session?.currentTime ?? 0,
                                "rawStatus": session?.player.currentItem?.status.rawValue ?? -1,
                                "rawTime": session?.player.currentTime().seconds ?? 0,
                                "events": session?.events ?? []])
                session?.stop(); session = nil
            }
        }
        for custom in [false, true] {
            let url = URL(string: base + "img_bipbop_adv_example_ts/v5/prog_index.m3u8")!
            let source = PlaybackSource(request: .init(media: media), url: url, providerID: "test", providerName: "Test")
            let engine = PlayerSession(source: source)
            let raw = AVPlayer(url: url)
            if custom { session = engine; showSession = true; engine.start() }
            else { rawPlayer = raw; raw.play() }
            let probe = custom ? engine.player : raw
            for _ in 0..<80 {
                if probe.currentItem?.status == .failed || probe.currentTime().seconds >= 2 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let time = probe.currentTime().seconds
            results.append(["case": custom ? "session-avkit-presentation" : "raw-swiftui-video-presentation",
                            "status": time.isFinite && time >= 2 ? "PASS" : "FAIL",
                            "itemStatus": probe.currentItem?.status.rawValue ?? -1,
                            "time": time.isFinite ? time : 0,
                            "error": probe.currentItem?.error.map { PlaybackDiagnostics.error($0) } ?? "none"])
            engine.stop(); raw.pause(); raw.replaceCurrentItem(with: nil)
            session = nil; rawPlayer = nil; showSession = false
            try? await Task.sleep(nanoseconds: 500_000_000)
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
