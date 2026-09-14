import SwiftUI

@main struct J1ROXTVApp:App{
    private let persistence=PersistenceController.shared
    @StateObject private var model:AppViewModel
    init(){let library=LibraryStore(context:PersistenceController.shared.container.viewContext);_model=StateObject(wrappedValue:AppViewModel(library:library));UITabBar.appearance().backgroundColor=UIColor.black}
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--hls-smoke-test") {
                DebugHLSSmokeView()
            } else { root }
            #else
            root
            #endif
        }
    }
    private var root: some View {
        RootView().environmentObject(model).environment(\.managedObjectContext, persistence.container.viewContext)
    }
}
