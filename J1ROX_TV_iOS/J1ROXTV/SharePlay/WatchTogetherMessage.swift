import Foundation

/// Only logical catalog identifiers travel between devices, never stream URLs or headers.
struct WatchTogetherContent: Codable, Equatable, Sendable {
    let mediaID: String
    let title: String
    let mediaType: String
    let season: String?
    let episode: String?
    let providerID: String
    let sourceID: String?
    let voiceID: String?
    let voiceName: String?

    init(_ request: PlaybackRequest) {
        mediaID = request.media.id; title = request.media.title; mediaType = request.media.mediaType
        season = request.season; episode = request.episode
        providerID = request.providerID; sourceID = request.sourceID
        voiceID = request.translationID; voiceName = request.translationName
    }

    var isValid: Bool {
        !mediaID.isEmpty && !providerID.isEmpty && sourceID?.isEmpty == false &&
        ["movie", "tv"].contains(mediaType) &&
        (mediaType != "tv" || (season?.isEmpty == false && episode?.isEmpty == false))
    }

    // Length prefixes prevent ambiguous identifiers even when catalog IDs contain separators.
    var playbackID: String {
        [mediaType, mediaID, season ?? "", episode ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// A provider may refresh a voice's opaque ID; its name still identifies the requested dub.
    func matches(_ request: PlaybackRequest) -> Bool {
        let other = Self(request)
        return playbackID == other.playbackID && providerID == other.providerID && sourceID == other.sourceID &&
            (voiceName.map { $0 == other.voiceName } ?? (voiceID == other.voiceID))
    }

    var coordinationID: String {
        playbackID + [providerID, sourceID ?? "", voiceName ?? voiceID ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    func request(media: MediaItem, resumeAt: Double = 0) -> PlaybackRequest {
        .init(media: media, sourceID: sourceID, translationID: voiceID, season: season,
              episode: episode, resumeAt: resumeAt, translationName: voiceName, providerID: providerID)
    }
}

/// Lamport ordering makes simultaneous selections converge without echoing received changes.
struct WatchTogetherRevision: Codable, Equatable, Comparable, Sendable {
    let counter: UInt64
    let author: String
    static let initial = Self(counter: 0, author: "")
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.author < rhs.author : lhs.counter < rhs.counter
    }
}

struct WatchTogetherMessage: Codable, Sendable {
    enum Event: String, Codable, Sendable {
        case changeSource, changeVoice, changeSeason, changeEpisode, snapshot, requestState
    }
    let event: Event
    let revision: WatchTogetherRevision
    let content: WatchTogetherContent
}

struct WatchTogetherState {
    private(set) var content: WatchTogetherContent?
    private(set) var revision = WatchTogetherRevision.initial

    init(content: WatchTogetherContent? = nil, revision: WatchTogetherRevision = .initial) {
        self.content = content; self.revision = revision
    }

    mutating func publish(_ value: WatchTogetherContent, author: String) -> Bool {
        guard value.isValid, value != content, revision.counter < UInt64.max else { return false }
        revision = .init(counter: revision.counter + 1, author: author)
        content = value
        return true
    }

    /// Returns true only when the player needs to load different logical content.
    mutating func receive(_ message: WatchTogetherMessage) -> Bool {
        guard message.event != .requestState, message.content.isValid, message.revision > revision else { return false }
        revision = message.revision
        let changed = content != message.content
        content = message.content
        return changed
    }

    static func automaticAdvanceOwner(in participants: Set<UUID>) -> UUID? {
        participants.min { $0.uuidString < $1.uuidString }
    }
}
