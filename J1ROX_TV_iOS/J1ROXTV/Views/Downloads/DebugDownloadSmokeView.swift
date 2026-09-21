#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Uses a separate sandbox directory selected by the launch argument. Never clears user downloads.
@MainActor struct DebugDownloadSmokeView: View {
    @State private var message = "Download smoke tests"
    var body: some View { Text(message).task { await run() } }

    private func run() async {
        let manager = DownloadManager.shared
        let phase = ProcessInfo.processInfo.arguments.contains("--offline") ? "offline" :
            ProcessInfo.processInfo.arguments.contains("--restore") ? "restore" : "prepare"
        do {
            try await wait { manager.ready }
            if phase == "prepare" {
                manager.removeAll()
                manager.settings = DownloadSettings(quality: "720p", askQuality: false, wifiOnly: false, simultaneous: 2)
                // Exercise the actual HLS session factory, not an unsafe downcast from URLSession.
                // The local server returns 404; this must become a visible error, never a crash.
                guard let hlsURL = URL(string: "http://127.0.0.1:18766/missing.m3u8") else { throw Failure("HLS fixture URL") }
                let hlsRequest = PlaybackRequest(media: MediaItem.parse(["id": .string("hls-error"), "title": .string("HLS error fixture")]))
                manager.enqueue(hlsRequest, variant: .init(url: hlsURL, quality: "720p", expectedBytes: nil,
                    headers: [:], expiresAt: nil, minimumBitrate: 2400000), episodeID: nil)
                guard let hlsEntry = manager.existing(hlsRequest) else { throw Failure("HLS enqueue failed") }
                try require(hlsEntry.state == .downloading, "HLS asset task created")
                try await wait { manager.record(hlsEntry.id)?.state == .failed }
                try require(manager.record(hlsEntry.id)?.failure != nil && manager.message != nil, "HLS error presented")
                manager.remove(hlsEntry.id); manager.message = nil
                let (bytes, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18766/metadata")!)
                let size = try JSONDecoder().decode([String: Int64].self, from: bytes)["size"]!
                for index in 0..<3 { enqueue(manager, name: "movie-\(index)", size: size) }
                try require(manager.records.filter { $0.state == .downloading }.count == 2, "two download slots")
                try require(manager.records.filter { $0.state == .queued }.count == 1, "third file queued")
                let first = manager.records[0].id, second = manager.records[1].id
                try await wait { (manager.record(first)?.received ?? 0) > 100_000 }
                manager.pause(first)
                try await wait { !manager.pausing.contains(first) }
                try require(manager.record(first)?.state == .paused, "paused")
                manager.remove(second)
                manager.resume(first)
                try await wait { manager.records.count == 2 && manager.records.allSatisfy { $0.state == .completed } }
                try require(manager.record(second) == nil, "cancelled task cannot resurrect")
                enqueue(manager, name: "interrupted", size: size)
                let interrupted = manager.records.last!.id
                try await wait { (manager.record(interrupted)?.received ?? 0) > 100_000 }
                manager.pause(interrupted)
                try await wait { !manager.pausing.contains(interrupted) }
                for name in ["403", "html"] {
                    enqueue(manager, name: name, size: 0)
                    let id = manager.records.last!.id
                    try await wait { manager.record(id)?.state == .failed }
                    manager.remove(id)
                }
                try require(manager.records.count == 3, "only successful/paused entries retained")
            } else if phase == "restore" {
                try require(manager.records.count == 3, "metadata survives restart")
                try require(manager.records.filter { $0.state == .completed }.count == 2, "completed files restored")
                guard let paused = manager.records.first(where: { $0.state == .paused }) else { throw Failure("paused download lost") }
                manager.resume(paused.id)
                try await wait { manager.records.allSatisfy { $0.state == .completed } }
            } else {
                try require(manager.records.count == 3 && manager.records.allSatisfy { $0.state == .completed }, "offline list")
                guard let selection = manager.playback(manager.records[0].id) else { throw Failure("no offline selection") }
                try require(selection.source.url.isFileURL, "local file URL")
                let player = PlayerSession(source: selection.source)
                defer { player.stop() }
                player.start()
                try await wait { player.currentTime > 0.5 }
                let recovery = PlaybackSession(selection: selection)
                recovery.failed(sourceID: selection.source.id, snapshot: .init(position: 0), failure: .avFoundation(Failure("local error")))
                try require(recovery.error != nil && !recovery.switching, "local errors never resolve remote providers")
            }
            write(phase, result: ["status": "PASS", "phase": phase])
            message = "DOWNLOAD \(phase) PASS"
        } catch {
            write(phase, result: ["status": "FAIL", "phase": phase, "error": error.localizedDescription,
                                  "manager": manager.message ?? "", "states": manager.records.map { $0.state.rawValue }.joined(separator: ",")])
            message = "DOWNLOAD \(phase) FAIL: \(error.localizedDescription)"
        }
    }
    private func enqueue(_ manager: DownloadManager, name: String, size: Int64) {
        let media = MediaItem.parse(["id": .string(name), "title": .string("Local test \(name)")])
        manager.enqueue(.init(media: media, providerID: "own-fixture"), variant: .init(
            url: URL(string: "http://127.0.0.1:18766/\(name).mp4")!, quality: "720p",
            expectedBytes: size > 0 ? size : nil, headers: [:], expiresAt: nil), episodeID: nil)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw Failure("Timeout")
    }
    private func require(_ condition: Bool, _ reason: String) throws { if !condition { throw Failure(reason) } }
    private func write(_ phase: String, result: [String: String]) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do { try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("download-\(phase).json"), options: .atomic) }
        catch { message = error.localizedDescription }
    }
    private struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
#endif
