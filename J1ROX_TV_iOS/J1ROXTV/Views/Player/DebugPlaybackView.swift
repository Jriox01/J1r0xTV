#if DEBUG
import SwiftUI

@MainActor private final class DebugPlaybackModel: ObservableObject {
    @Published var player: PlayerSession?
    @Published var detail = "Введите разрешённый тестовый URL. Он не сохраняется."
    @Published var busy = false
    private var task: Task<Void, Never>?

    func start(url: String, agent: String, headers: String) {
        stop()
        busy = true
        task = Task {
            defer { busy = false }
            let inspection = PlaybackInspectionRecorder()
            do {
                var fields: [String: String] = [:]
                if !headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let object = try JSONSerialization.jsonObject(with: Data(headers.utf8)) as? [String: String] else {
                        throw ProviderError.invalidResponse
                    }
                    fields = object
                }
                if !agent.isEmpty { fields["User-Agent"] = agent }
                let provider = try TestHLSProvider(url: url, headers: fields)
                let media = MediaItem.parse(["id": .string("debug"), "title": .string("Debug HLS")])
                let request = PlaybackRequest(media: media, sourceID: provider.id, providerID: provider.id)
                let resolved = try await ProviderResolver(providers: [provider], checker: inspection).resolve(request)
                guard let validation = await inspection.validation else { throw ProviderError.invalidResponse }
                try Task.checkCancellation()
                detail = "HTTP \(validation.probe.status) · \(validation.probe.mimeType) · \(validation.kind.rawValue)\n"
                    + "Preflight final: \(PlaybackDiagnostics.url(validation.probe.finalURL))\n"
                    + "Preflight redirects:\n" + (validation.probe.redirects.isEmpty ? "none" : validation.probe.redirects.joined(separator: "\n"))
                try Task.checkCancellation()
                let session = PlayerSession(source: resolved.source)
                session.onFailure = { [weak self] _, error in
                    self?.detail += "\n" + PlaybackDiagnostics.error(error)
                }
                player = session
                session.start()
            } catch {
                let cause = await inspection.failure ?? PlaybackDiagnostics.error(error)
                if !Task.isCancelled { detail = error.localizedDescription + "\n" + cause }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; player?.stop(); player = nil }
}

@MainActor struct DebugPlaybackView: View {
    @StateObject private var model = DebugPlaybackModel()
    @State private var url = ""
    @State private var agent = ""
    @State private var headers = "{}"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("HLS URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("User-Agent (optional)", text: $agent).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Headers — JSON object").font(.headline)
                    TextEditor(text: $headers).frame(minHeight: 90).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Произвольные headers передаются через существующий compatibility key AVURLAsset. Их доставка на HLS-сегменты и другие хосты не гарантирована. URL в диагностике скрыты до hostname.").font(.caption).foregroundStyle(.secondary)
                    Button("Start Playback") { model.start(url: url, agent: agent, headers: headers) }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    if model.busy { ProgressView("Проверка источника…") }
                    Text(model.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let session = model.player { DebugPlayerPanel(session: session) }
                }
                .padding(16)
            }
            .navigationTitle("Debug HLS Test")
            .onDisappear { model.stop() }
        }
    }
}

@MainActor private struct DebugPlayerPanel: View {
    @ObservedObject var session: PlayerSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerView(session: session).frame(height: 240)
            Text("status: \(session.status)\ntime: \(session.currentTime) / \(session.duration)\nbuffer: \(session.buffer)\nbitrate: \(session.bitrate)\nresolution: \(session.resolution)\nCDN host (access log): \(session.cdnHost)")
            Text("loadedTimeRanges: [\(session.loadedTimeRanges)]")
            if let error = session.lastError { Text(error).foregroundStyle(.red) }
            Text("AVFoundation не публикует полную цепочку redirect: выше показана цепочка отдельного preflight.")
            Text(session.events.joined(separator: "\n"))
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}
#endif
