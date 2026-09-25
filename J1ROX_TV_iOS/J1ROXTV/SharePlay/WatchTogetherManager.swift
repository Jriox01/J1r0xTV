import AVFoundation
import Combine
import GroupActivities

@MainActor final class WatchTogetherManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var participantCount = 0
    @Published private(set) var isAutomaticAdvanceOwner = true
    @Published private(set) var resolving = false
    @Published var message: String?
    var onOpen: ((PlaybackSelection) -> Void)?

    private var group: GroupSession<J1ROXWatchTogetherActivity>?
    private var messenger: GroupSessionMessenger?
    private var listener: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var resolution: Task<Void, Never>?
    private var sends: [UUID: Task<Void, Never>] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var state = WatchTogetherState()
    private var desired: WatchTogetherContent? { state.content }
    private var revision: WatchTogetherRevision { state.revision }
    private var generation = UUID()
    private var participants = Set<UUID>()
    private weak var playerSession: PlayerSession?
    private var onSelection: ((PlaybackSelection, PlaybackSnapshot?) -> Void)?
    private var onRemoteChange: (() -> Void)?
    private let identity = WatchTogetherItemIdentity()
    private var coordinatedSession: UUID?
    private var suspension: AVCoordinatedPlaybackSuspension?
    private var pendingSelection: PlaybackSelection?

    func startListening() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await session in J1ROXWatchTogetherActivity.sessions() {
                guard !Task.isCancelled else { return }
                self?.accept(session)
            }
        }
    }

    private func accept(_ session: GroupSession<J1ROXWatchTogetherActivity>) {
        guard group?.id != session.id else { return }
        leave()
        guard session.activity.content.isValid else { session.leave(); return }
        Self.log("Session detected")
        group = session; isActive = true; message = nil
        state = WatchTogetherState(content: session.activity.content)
        participants = Set(session.activeParticipants.map(\.id)).union([session.localParticipant.id])
        participantCount = participants.count
        isAutomaticAdvanceOwner = WatchTogetherState.automaticAdvanceOwner(in: participants) == session.localParticipant.id
        let transport = GroupSessionMessenger(session: session)
        messenger = transport
        session.$state.sink { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session, self.group?.id == session.id else { return }
                switch state {
                case .invalidated: self.cleanup()
                case .joined:
                    Self.log("Joined session")
                    self.send(event: .requestState)
                    self.send(event: .snapshot)
                    self.coordinateIfReady()
                default: break
                }
            }
        }.store(in: &subscriptions)
        session.$activeParticipants.sink { [weak self, weak session] values in
            Task { @MainActor in
                guard let self, let session, self.group?.id == session.id else { return }
                let ids = Set(values.map(\.id)).union([session.localParticipant.id])
                let joined = ids.subtracting(self.participants)
                if !joined.isEmpty { Self.log("Participant joined") }
                if !self.participants.subtracting(ids).isEmpty { Self.log("Participant left") }
                self.participants = ids
                self.participantCount = ids.count
                self.isAutomaticAdvanceOwner = WatchTogetherState.automaticAdvanceOwner(in: ids) == session.localParticipant.id
                // Every peer can answer; version ordering discards duplicates and stale snapshots.
                if !joined.isEmpty { self.send(event: .snapshot) }
            }
        }.store(in: &subscriptions)
        receiver = Task { [weak self, weak session] in
            do {
                for try await (value, context) in transport.messages(of: WatchTogetherMessage.self) {
                    guard let self, let session, !Task.isCancelled, self.group?.id == session.id else { return }
                    guard context.source.id != session.localParticipant.id else { continue }
                    if value.event != .snapshot && value.event != .requestState &&
                        value.revision.author != context.source.id.uuidString { continue }
                    self.receive(value)
                }
            } catch {
                guard let self, let session, !Task.isCancelled, self.group?.id == session.id else { return }
                self.message = "Связь с совместным просмотром потеряна. Можно продолжить просмотр самостоятельно."
                self.leave()
            }
        }
        session.join()
        if let current = playerSession, current.status != "failed", current.status != "stopped",
           WatchTogetherContent(current.source.request) == desired {
            coordinateIfReady()
        } else if let desired { apply(desired) }
    }

    func attach(_ player: PlayerSession,
                onRemoteChange: @escaping () -> Void,
                onSelection: @escaping (PlaybackSelection, PlaybackSnapshot?) -> Void) {
        playerSession = player
        self.onSelection = onSelection; self.onRemoteChange = onRemoteChange
        player.player.playbackCoordinator.delegate = identity
        if let item = player.player.currentItem { identity.register(item, request: player.source.request) }
        player.onWillChangeItem = { [weak self] in self?.beginPlayerChange() }
        player.onItemCreated = { [weak self] item, request in self?.identity.register(item, request: request) }
        player.onReady = { [weak self] in self?.coordinateIfReady() }
        if let pendingSelection {
            self.pendingSelection = nil
            if pendingSelection.source.id != player.source.id { onSelection(pendingSelection, nil) }
        }
        coordinateIfReady()
    }

    func detach(_ player: PlayerSession) {
        guard playerSession === player else { return }
        // Leave before the screen pauses/stops AVPlayer, so closing is local to this participant.
        leave()
        player.onWillChangeItem = nil; player.onItemCreated = nil; player.onReady = nil
        player.player.playbackCoordinator.delegate = nil
        playerSession = nil; onSelection = nil; onRemoteChange = nil
    }

    private func coordinateIfReady() {
        guard let group, group.state == .joined, let player = playerSession, player.isReadyForCoordination,
              WatchTogetherContent(player.source.request).playbackID == desired?.playbackID else { return }
        if coordinatedSession != group.id {
            player.player.playbackCoordinator.coordinateWithSession(group)
            coordinatedSession = group.id
        }
        // Never propose the local saved time to an existing group.
        suspension?.end(); suspension = nil
    }

    private func beginPlayerChange() {
        guard isActive, coordinatedSession != nil, suspension == nil, let player = playerSession else { return }
        suspension = player.player.playbackCoordinator.beginSuspension(for: .init(rawValue: "com.jirox.loading"))
    }

    func localChangeStarted() {
        resolution?.cancel(); resolution = nil; generation = UUID(); resolving = false
    }

    func localChangeFailed() {
        guard let desired, let playerSession else { return }
        if WatchTogetherContent(playerSession.source.request) != desired { apply(desired) }
        else { coordinateIfReady() }
    }

    /// Called only for a successful, explicit local selection, never for fallback or received state.
    func publish(_ request: PlaybackRequest, event: WatchTogetherMessage.Event) {
        guard let group else { return }
        let content = WatchTogetherContent(request)
        guard state.publish(content, author: group.localParticipant.id.uuidString) else { return }
        localChangeStarted()
        Self.log(event.logDescription)
        send(event: event)
    }

    private func receive(_ value: WatchTogetherMessage) {
        guard value.content.isValid else { return }
        if value.event == .requestState { send(event: .snapshot); return }
        if state.receive(value) {
            Self.log(value.event.logDescription)
            apply(value.content)
        }
    }

    private func send(event: WatchTogetherMessage.Event) {
        guard let messenger, let group, group.state == .joined, let desired else { return }
        let value = WatchTogetherMessage(event: event, revision: revision, content: desired)
        let id = UUID(), sessionID = group.id
        sends[id] = Task { [weak self] in
            defer { self?.sends[id] = nil }
            do { try await messenger.send(value) }
            catch {
                guard let self, !Task.isCancelled, self.group?.id == sessionID else { return }
                self.message = "Не удалось синхронизировать совместный просмотр. Можно продолжить самостоятельно."
                self.leave()
            }
        }
    }

    private func apply(_ content: WatchTogetherContent) {
        resolution?.cancel(); onRemoteChange?()
        let token = UUID(); generation = token
        let current = playerSession?.source.request
        let sameEpisode = current.map { WatchTogetherContent($0).playbackID == content.playbackID } ?? false
        let snapshot = sameEpisode ? playerSession?.snapshot() : nil
        resolving = true
        resolution = Task { [weak self] in
            do {
                let selection = try await WatchTogetherResolver().resolve(content, current: current, position: snapshot?.position ?? 0)
                try Task.checkCancellation()
                guard let self, self.isActive, self.generation == token else { return }
                self.resolving = false
                if WatchTogetherContent(selection.request) != content {
                    self.message = "Выбранный источник или озвучка недоступны. Используется доступный вариант той же серии."
                }
                if let onSelection = self.onSelection { onSelection(selection, snapshot) }
                else {
                    self.pendingSelection = selection
                    self.onOpen?(selection)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.message = "Не удалось открыть видео участников. Совместный просмотр отключён; текущее видео сохранено."
                self.leave()
            }
        }
    }

    func leave(endForEveryone: Bool = false) {
        if let group {
            if case .invalidated = group.state { cleanup(); return }
            if endForEveryone { group.end() } else { group.leave() }
        }
        cleanup()
    }

    private func cleanup() {
        let wasActive = isActive
        generation = UUID(); resolution?.cancel(); resolution = nil
        receiver?.cancel(); receiver = nil
        for task in sends.values { task.cancel() }; sends.removeAll()
        subscriptions.removeAll()
        messenger = nil; group = nil; state = WatchTogetherState()
        pendingSelection = nil
        coordinatedSession = nil
        suspension?.end(); suspension = nil
        participants.removeAll(); participantCount = 0
        isActive = false; isAutomaticAdvanceOwner = true; resolving = false
        // GroupSession leave/invalidation disconnects the coordinator. Keep the AVPlayer and item.
        if wasActive { Self.log("Session ended") }
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("[SharePlay] \(message)")
        #endif
    }
}

private extension WatchTogetherMessage.Event {
    var logDescription: String {
        switch self {
        case .changeSource: return "Source changed"
        case .changeVoice: return "Voice changed"
        case .changeSeason, .changeEpisode: return "Episode changed"
        case .snapshot: return "State received"
        case .requestState: return "State requested"
        }
    }
}

/// AVFoundation may ask on its own queue. Identity belongs to the item, not mutable UI selection.
private final class WatchTogetherItemIdentity: NSObject, AVPlayerPlaybackCoordinatorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let identifiers = NSMapTable<AVPlayerItem, NSString>.weakToStrongObjects()
    func register(_ item: AVPlayerItem, request: PlaybackRequest) {
        lock.lock(); defer { lock.unlock() }
        identifiers.setObject(WatchTogetherContent(request).playbackID as NSString, forKey: item)
    }
    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem) -> String {
        lock.lock(); defer { lock.unlock() }
        if let id = identifiers.object(forKey: playerItem) { return id as String }
        // Keep an unknown item unique; do not accidentally coordinate two unrelated videos.
        let id = UUID().uuidString as NSString
        identifiers.setObject(id, forKey: playerItem)
        return id as String
    }
}
