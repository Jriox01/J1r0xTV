#if DEBUG
import SwiftUI
import AVFoundation

/// Live diagnostic is separate from deterministic regression tests.
struct DebugZonaSmokeView: View {
    @State private var status = "Zona: проверка получения потоков"
    var body: some View {
        Text(status).padding().task {
            var report: [String: String] = [:]
            do {
                let raw = try await ZonaStreamBridge.streams(kpID: "258687", episodeKey: nil)
                let streams = ZonaProvider.streams(raw)
                report["sdk_batches"] = String(raw.count)
                report["compatible_streams"] = String(streams.count)
                guard !streams.isEmpty else { throw ProviderError.unavailable }
                var playable = false
                for stream in streams.prefix(3) {
                    do {
                        let media = MediaItem.parse(["id": .string("157336"), "title": .string("Интерстеллар")])
                        let source = PlaybackSource(request: .init(media: media), url: stream.url,
                                                    providerID: "zona", providerName: "Zona", headers: stream.headers)
                        try await PlaybackSourceValidator().validate(source)
                        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                        playable = try await asset.load(.isPlayable)
                        if playable { report["stream_host"] = stream.url.host; break }
                    } catch { report["validation_error"] = error.localizedDescription }
                }
                report["result"] = playable ? "PASS" : "FAIL"
                status = playable ? "Zona: ссылка проверена AVFoundation" : "Zona: ссылка не прошла проверку"
            } catch {
                report["result"] = "FAIL"; report["error"] = error.localizedDescription
                status = "Zona: " + error.localizedDescription
            }
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("zona-smoke-results.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: path, options: .atomic)
            }
        }
    }
}
#endif
