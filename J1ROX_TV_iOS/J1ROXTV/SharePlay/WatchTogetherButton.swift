import GroupActivities
import SwiftUI
import UIKit

@MainActor struct WatchTogetherButton: View {
    @EnvironmentObject private var together: WatchTogetherManager
    let prepare: () async throws -> PlaybackRequest
    @State private var invitation: Invitation?
    @State private var preparing = false
    @State private var preparationTask: Task<Void, Never>?

    private struct Invitation: Identifiable {
        let id = UUID()
        let activity: J1ROXWatchTogetherActivity
    }

    var body: some View {
        Group {
            if together.isActive {
                Menu {
                    Button("Выйти из совместного просмотра") { together.leave() }
                    Button("Завершить для всех", role: .destructive) { together.leave(endForEveryone: true) }
                } label: {
                    Label("Смотреть вместе · \(together.participantCount)", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    preparing = true
                    preparationTask?.cancel()
                    preparationTask = Task { @MainActor in
                        defer { preparing = false }
                        do {
                            let content = WatchTogetherContent(try await prepare())
                            try Task.checkCancellation()
                            guard content.isValid else { throw ProviderError.selectionUnavailable }
                            invitation = Invitation(activity: J1ROXWatchTogetherActivity(content: content))
                        } catch is CancellationError {
                        } catch { together.message = error.localizedDescription }
                    }
                } label: {
                    Label(preparing ? "Подготовка…" : "Смотреть вместе", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(preparing)
            }
        }
        .sheet(item: $invitation) { invitation in
            WatchTogetherInvitation(activity: invitation.activity)
        }
        .onDisappear { preparationTask?.cancel(); preparationTask = nil; preparing = false }
    }
}

@MainActor private struct WatchTogetherInvitation: UIViewControllerRepresentable {
    let activity: J1ROXWatchTogetherActivity
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Apple TN3128: registering the activity makes the system SharePlay action
        // invite participants and start this activity, even without an existing call.
        // These APIs are available from iOS 15.4, below our iOS 16 deployment target.
        let provider = NSItemProvider()
        provider.registerGroupActivity(activity)
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor struct WatchTogetherAlert: ViewModifier {
    @EnvironmentObject private var together: WatchTogetherManager
    func body(content: Content) -> some View {
        content.alert("Смотреть вместе", isPresented: Binding(
            get: { together.message != nil }, set: { if !$0 { together.message = nil } }
        )) { Button("OK") { together.message = nil } } message: { Text(together.message ?? "") }
    }
}
