import Foundation
import Combine

@MainActor final class PlaybackSession: ObservableObject {
    @Published private(set) var selection: PlaybackSelection
    @Published private(set) var switching = false
    @Published private(set) var switched: Bool
    @Published private(set) var error: String?
    private let resolver: ProviderResolver
    private var excluded: Set<ProviderCandidate> = []
    private var retries: [ProviderCandidate: PlaybackRetryBudget] = [:]
    @Published private(set) var diagnostic: String?
    private var recovery: Task<Void, Never>?
    private var generation = UUID()

    init(selection: PlaybackSelection, resolver: ProviderResolver = ProviderResolver()) {
        self.selection = selection
        self.resolver = resolver
        switched = selection.switched
    }

    func failed(sourceID: UUID, snapshot: PlaybackSnapshot, failure: PlaybackError) {
        let position = snapshot.position
        guard selection.source.id == sourceID, !switching, error == nil else { return }
        let failed = selection.source
        if failed.url.isFileURL {
            error = "Не удалось открыть скачанный файл. Удалите его и скачайте заново."
            diagnostic = PlaybackDiagnostics.error(failure)
            return
        }
        var request = failed.request
        if position.isFinite && position > 0 { request.resumeAt = position }
        diagnostic = PlaybackDiagnostics.error(failure)
        var budget = retries[failed.candidate] ?? PlaybackRetryBudget()
        let allowRenewal = budget.consume()
        retries[failed.candidate] = budget
        switching = true
        let token = UUID(); generation = token
        recovery = Task {
            defer { if generation == token { switching = false } }
            do {
                let result = try await resolver.recover(failed, request: request,
                    excluding: excluded, allowRenewal: allowRenewal)
                try Task.checkCancellation()
                guard generation == token else { return }
                if result.source.candidate != failed.candidate { excluded.insert(failed.candidate) }
                switched = switched || result.switched || result.source.candidate != failed.candidate
                var restored = result.source
                restored.resumeState = snapshot
                selection = PlaybackSelection(source: restored, switched: switched)
            } catch {
                if !Task.isCancelled {
                    self.error = "Не удалось воспроизвести видео: доступные источники исчерпаны"
                    self.diagnostic = PlaybackDiagnostics.error(PlaybackError.refreshFailed(error))
                    PlaybackDiagnostics.log(self.diagnostic ?? "refresh failed")
                }
            }
        }
    }

    func replace(_ value: PlaybackSelection, snapshot: PlaybackSnapshot? = nil) {
        cancel()
        var source = value.source
        source.resumeState = snapshot
        selection = PlaybackSelection(source: source, switched: value.switched)
        switched = value.switched; switching = false; error = nil; diagnostic = nil
        excluded.removeAll(); retries.removeAll()
    }

    func cancel() { generation = UUID(); recovery?.cancel(); recovery = nil; switching = false }
}
