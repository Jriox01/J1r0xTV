import Foundation

struct ResolvedPlayback: Sendable {
    let source: PlaybackSource
    let switched: Bool
}

protocol PlaybackSourceChecking: Sendable {
    func validate(_ source: PlaybackSource) async throws
}

struct ProviderResolver: Sendable {
    let providers: [any VideoProvider]
    let checker: any PlaybackSourceChecking
    let timeout: TimeInterval

    init(providers: [any VideoProvider] = [AtodoProvider(), ZonaProvider()],
         checker: any PlaybackSourceChecking = PlaybackSourceValidator(), timeout: TimeInterval = 15) {
        self.providers = providers
        self.checker = checker
        self.timeout = timeout
    }

    func resolve(_ request: PlaybackRequest, excluding: Set<ProviderCandidate> = []) async throws -> ResolvedPlayback {
        for provider in providers {
            try Task.checkCancellation()
            Self.log("trying \(provider.name)")
            guard provider.availability == .available, provider.canHandle(request.media) else {
                Self.log("\(provider.name) FAILED (unsupported)")
                continue
            }
            do {
                let requests = try await withProviderTimeout(seconds: provider.resolutionTimeout ?? timeout) {
                    try await provider.requests(for: request)
                }
                for candidate in requests {
                    let key = ProviderCandidate(providerID: provider.id, sourceID: candidate.sourceID ?? "")
                    guard !excluding.contains(key) else { continue }
                    // One renewal only: no token manipulation and no unbounded retry loop.
                    for attempt in 0..<2 {
                        do {
                            let source = try await withProviderTimeout(seconds: provider.resolutionTimeout ?? timeout) {
                                let source = try await provider.playback(for: candidate)
                                guard source.expiresAt.map({ $0 > Date() }) ?? true else { throw ProviderError.expired }
                                try await checker.validate(source)
                                return source
                            }
                            Self.log("\(provider.name) OK")
                            Self.log("selected provider=\(provider.name)")
                            Self.log("playback host=\(source.url.host ?? "unknown")")
                            let switched = source.providerID != request.providerID ||
                                (request.sourceID != nil && source.request.sourceID != request.sourceID)
                            return ResolvedPlayback(source: source, switched: switched)
                        } catch {
                            try Task.checkCancellation()
                            Self.log("\(provider.name) FAILED " + PlaybackDiagnostics.error(error))
                            guard attempt == 0 && Self.needsRenewal(error) else { break }
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                Self.log("\(provider.name) FAILED " + PlaybackDiagnostics.error(error))
            }
        }
        throw ProviderError.unavailable
    }

    /// Renew an expired source once; a runtime failure otherwise advances to another candidate.
    func recover(_ failed: PlaybackSource, request: PlaybackRequest,
                 excluding: Set<ProviderCandidate>, allowRenewal: Bool = true) async throws -> ResolvedPlayback {
        if allowRenewal,
           let provider = providers.first(where: { $0.id == failed.providerID && $0.availability == .available }) {
            do {
                let renewed = try await withProviderTimeout(seconds: provider.resolutionTimeout ?? timeout) {
                    let source = try await provider.refresh(source: failed, request: request)
                    guard source.expiresAt.map({ $0 > Date() }) ?? true else { throw ProviderError.expired }
                    try await checker.validate(source)
                    return source
                }
                Self.log("selected provider=\(provider.name)")
                Self.log("playback host=\(renewed.url.host ?? "unknown")")
                return ResolvedPlayback(source: renewed, switched: false)
            } catch {
                try Task.checkCancellation()
                Self.log("\(provider.name) refresh FAILED " + PlaybackDiagnostics.error(error))
            }
        }
        return try await resolve(request, excluding: excluding.union([failed.candidate]))
    }

    private static func needsRenewal(_ error: Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        switch error {
        case .expired, .http(401), .http(403), .http(410): return true
        default: return false
        }
    }

    static func log(_ message: String) {
        #if DEBUG
        print("[ProviderResolver] \(message)")
        #endif
    }
}

// All production operations use cancellation-aware URLSession calls.
func withProviderTimeout<T: Sendable>(seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ProviderError.unavailable }
        return result
    }
}
