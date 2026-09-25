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
    private var initialSync: Task<Void, Never>?
    private var awaitingInitialState = false
    private var recoveryAttempts = 0
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

    deinit {
        listener?.cancel(); receiver?.cancel(); resolution?.cancel(); initialSync?.cancel()
        for task in sends.values { task.cancel() }
    }

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
        state = WatchTogetherState(content: session.activity.content, revision: session.activity.revision ?? .initial)
        awaitingInitialState = true
        participants = Set(session.activeParticipants.map(\.id)).union([session.localParticipant.id])
        participantCount = participants.count
        isAutomaticAdvanceOwner = false
        let transport = GroupSessionMessenger(session: session)
        messenger = transport
        session.$state.sink { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session, self.group?.id == session.id else { return }
                switch state {
                case .invalidated: self.cleanup()
                case .joined:
                    Self.log("Joined session")
                    self.synchronizeInitialState(session)
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
                self.refreshAdvanceOwner()
                // Every peer can answer; version ordering discards duplicates and stale snapshots.
                if !joined.isEmpty { self.send(event: .snapshot) }
            }
        }.store(in: &subscriptions)
        session.$activity.sink { [weak self, weak session] activity in
            Task { @MainActor in
                guard let self, let session, self.group?.id == session.id else { return }
                self.receive(.init(event: .snapshot, revision: activity.revision ?? .initial, content: activity.content), confirmsInitialState: false)
            }
        }.store(in: &subscriptions)
        receiver = Task { [weak self, weak session] in
            // Messages.Iterator.next() is async, not throwing. Session invalidation
            // is observed through $state; an unexpectedly finished stream is handled below.
            for await (value, context) in transport.messages(of: WatchTogetherMessage.self) {
                guard let self, let session, !Task.isCancelled, self.group?.id == session.id else { return }
                guard context.source.id != session.localParticipant.id else { continue }
                guard session.activeParticipants.contains(context.source) else { continue }
                if value.event != .snapshot && value.event != .requestState &&
                    value.revision.author != context.source.id.uuidString { continue }
                self.receive(value)
            }
            guard let self, let session, !Task.isCancelled, self.group?.id == session.id else { return }
            if case .invalidated = session.state {
                self.cleanup()
            } else {
                self.message = "Связь с совместным просмотром потеряна. Можно продолжить просмотр самостоятельно."
                self.leave()
            }
        }
        session.join()
    }

    private func synchronizeInitialState(_ session: GroupSession<J1ROXWatchTogetherActivity>) {
        guard awaitingInitialState, initialSync == nil else { coordinateIfReady(); return }
        send(event: .requestState)
        // Give an already-playing peer a chance to send its latest selection. The session's
        // versioned activity is the fallback when everyone joins together or the author left.
        initialSync = Task { [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, let session, self.group?.id == session.id, !Task.isCancelled else { return }
            _ = self.state.receive(.init(event: .snapshot, revision: session.activity.revision ?? .initial,
                                         content: session.activity.content))
            self.finishInitialSynchronization()
        }
    }

    private func finishInitialSynchronization() {
        guard awaitingInitialState, group?.state == .joined, let desired else { return }
        initialSync?.cancel(); initialSync = nil; awaitingInitialState = false
        if let current = playerSession, current.status != "failed", current.status != "stopped",
           desired.matches(current.source.request) {
            coordinateIfReady()
        } else { apply(desired) }
        send(event: .snapshot)
    }

    private func refreshAdvanceOwner() {
        guard let group else { isAutomaticAdvanceOwner = true; return }
        isAutomaticAdvanceOwner = !awaitingInitialState && !resolving &&
            group.state == .joined && WatchTogetherState.automaticAdvanceOwner(in: participants) == group.localParticipant.id
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
        guard !awaitingInitialState, !resolving, let group, group.state == .joined,
              let player = playerSession, player.isReadyForCoordination, let desired else { return }
        guard desired.matches(player.source.request) else {
            message = "Источник или озвучка участников недоступны. Совместный просмотр завершён на этом устройстве."
            leave(); return
        }
        if coordinatedSession != group.id {
            // Joining is a catch-up, never a proposal to rewind the already-playing group.
            suspension = player.player.playbackCoordinator.beginSuspension(for: .init(rawValue: "com.jirox.joining"))
            player.player.playbackCoordinator.coordinateWithSession(group)
            coordinatedSession = group.id
        }
        // Never propose the local saved time to an existing group.
        suspension?.end(); suspension = nil
        refreshAdvanceOwner()
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

    /// Retry only the shared selection once. Solo fallback must not silently change the group's dub.
    func recoverPlayback() -> Bool {
        guard isActive, let desired else { return false }
        guard recoveryAttempts == 0 else {
            message = "Видео участников не воспроизводится. Совместный просмотр отключён; пробуем обычное восстановление."
            leave(); return false
        }
        recoveryAttempts += 1
        apply(desired)
        return true
    }

    /// Called only for a successful, explicit local selection, never for fallback or received state.
    func publish(_ request: PlaybackRequest, event: WatchTogetherMessage.Event) {
        guard !awaitingInitialState, let group, group.state == .joined else { return }
        let content = WatchTogetherContent(request)
        guard state.publish(content, author: group.localParticipant.id.uuidString) else { return }
        recoveryAttempts = 0
        localChangeStarted()
        Self.log(event.logDescription)
        // Apple retains this for participants joining after the original sender disconnects.
        group.activity = J1ROXWatchTogetherActivity(content: content, revision: revision)
        send(event: event)
    }

    private func receive(_ value: WatchTogetherMessage, confirmsInitialState: Bool = true) {
        guard value.content.isValid else { return }
        if value.event == .requestState { send(event: .snapshot); return }
        let changed = state.receive(value)
        if changed { recoveryAttempts = 0 }
        if let group, group.state == .joined, let desired, (group.activity.revision ?? .initial) < revision {
            // Repair a concurrent, lower-version activity write without echoing a Messenger command.
            group.activity = J1ROXWatchTogetherActivity(content: desired, revision: revision)
        }
        if awaitingInitialState {
            // Equal snapshots also confirm an unchanged film: revision zero is legitimate.
            if confirmsInitialState && value.revision == revision && value.content == desired { finishInitialSynchronization() }
        } else if changed {
            Self.log(value.event.logDescription)
            apply(value.content)
        }
    }

    private func send(event: WatchTogetherMessage.Event) {
        guard let messenger, let group, group.state == .joined, let desired else { return }
        guard !awaitingInitialState || event == .requestState else { return }
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
        beginPlayerChange()
        let token = UUID(); generation = token
        let current = playerSession?.source.request
        let sameEpisode = current.map { WatchTogetherContent($0).playbackID == content.playbackID } ?? false
        let snapshot = sameEpisode ? playerSession?.snapshot() : nil
        resolving = true
        refreshAdvanceOwner()
        resolution = Task { [weak self] in
            do {
                let selection = try await WatchTogetherResolver().resolve(content, current: current, position: snapshot?.position ?? 0)
                try Task.checkCancellation()
                guard let self, self.isActive, self.generation == token else { return }
                self.resolving = false
                if let onSelection = self.onSelection { onSelection(selection, snapshot) }
                else {
                    self.pendingSelection = selection
                    self.onOpen?(selection)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.message = "Выбранные участниками источник, озвучка или серия недоступны. Совместный просмотр отключён; текущее видео сохранено."
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
        if wasActive { onRemoteChange?() }
        initialSync?.cancel(); initialSync = nil; awaitingInitialState = false
        recoveryAttempts = 0
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
        identifiers.setObject(WatchTogetherContent(request).coordinationID as NSString, forKey: item)
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
