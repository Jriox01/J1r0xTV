import GroupActivities

struct J1ROXWatchTogetherActivity: GroupActivity {
    static let activityIdentifier = "com.jirox.jiroxtv.watch-together"
    let content: WatchTogetherContent

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = content.title
        metadata.subtitle = "Смотреть вместе"
        metadata.type = .watchTogether
        return metadata
    }
}
