import GroupActivities
import SwiftUI

@MainActor struct WatchTogetherButton: View {
    @EnvironmentObject private var together: WatchTogetherManager
    let prepare: () async throws -> PlaybackRequest
    @State private var invitation: Invitation?
    @State private var preparing = false

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
                }
            } else {
                Button {
                    preparing = true
                    Task { @MainActor in
                        defer { preparing = false }
                        do {
                            let content = WatchTogetherContent(try await prepare())
                            guard content.isValid else { throw ProviderError.selectionUnavailable }
                            invitation = Invitation(activity: J1ROXWatchTogetherActivity(content: content))
                        } catch is CancellationError {
                        } catch { together.message = error.localizedDescription }
                    }
                } label: {
                    Label(preparing ? "Подготовка…" : "Смотреть вместе", systemImage: "person.2.fill")
                }
                .disabled(preparing)
            }
        }
        .sheet(item: $invitation) { invitation in
            WatchTogetherInvitation(activity: invitation.activity)
        }
    }
}

@MainActor private struct WatchTogetherInvitation: UIViewControllerRepresentable {
    let activity: J1ROXWatchTogetherActivity
    func makeUIViewController(context: Context) -> GroupActivitySharingController {
        // The system handles eligibility, cancellation, FaceTime and the participant picker.
        GroupActivitySharingController(preparationHandler: { activity })
    }
    func updateUIViewController(_ controller: GroupActivitySharingController, context: Context) {}
}

@MainActor struct WatchTogetherAlert: ViewModifier {
    @EnvironmentObject private var together: WatchTogetherManager
    func body(content: Content) -> some View {
        content.alert("Смотреть вместе", isPresented: Binding(
            get: { together.message != nil }, set: { if !$0 { together.message = nil } }
        )) { Button("OK") { together.message = nil } } message: { Text(together.message ?? "") }
    }
}
