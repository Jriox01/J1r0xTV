import GroupActivities

struct J1ROXWatchTogetherActivity: GroupActivity, Sendable {
    static let activityIdentifier = "com.jirox.jiroxtv.watch-together"
    let content: WatchTogetherContent
    // Persist the latest logical selection in Apple's session as well as Messenger.
    // Optional for invitations/older activity payloads, which start at revision zero.
    var revision: WatchTogetherRevision? = nil

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = content.title
        metadata.subtitle = "Смотреть вместе"
        metadata.type = .watchTogether
        return metadata
    }
}
