import Foundation
import Combine

@MainActor final class PlaybackSession: ObservableObject {
    @Published private(set) var selection: PlaybackSelection
    @Published private(set) var switching = false
    @Published private(set) var switched: Bool
    @Published private(set) var error: String?
    private let resolver: ProviderResolver
    private var excluded: Set<ProviderCandidate> = []
    private var renewed: Set<ProviderCandidate> = []
    private var recovery: Task<Void, Never>?

    init(selection: PlaybackSelection, resolver: ProviderResolver = ProviderResolver()) {
        self.selection = selection
        self.resolver = resolver
        switched = selection.switched
    }

    func failed(sourceID: UUID, position: Double) {
        guard selection.source.id == sourceID, !switching, error == nil else { return }
        let failed = selection.source
        var request = failed.request
        if position.isFinite && position > 0 { request.resumeAt = position }
        let allowRenewal = renewed.insert(failed.candidate).inserted
        switching = true
        recovery = Task {
            defer { switching = false }
            do {
                let result = try await resolver.recover(failed, request: request,
                    excluding: excluded, allowRenewal: allowRenewal)
                try Task.checkCancellation()
                if result.source.candidate != failed.candidate { excluded.insert(failed.candidate) }
                switched = switched || result.switched || result.source.candidate != failed.candidate
                selection = PlaybackSelection(source: result.source, switched: switched)
            } catch {
                if !Task.isCancelled { self.error = "Не удалось воспроизвести видео: доступные источники исчерпаны" }
            }
        }
    }

    func cancel() { recovery?.cancel(); recovery = nil }
}
