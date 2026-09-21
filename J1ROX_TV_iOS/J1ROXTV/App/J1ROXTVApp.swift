import SwiftUI

@main struct J1ROXTVApp:App{
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    @StateObject private var downloads = DownloadManager.shared
    private let persistence=PersistenceController.shared
    @StateObject private var model:AppViewModel
    init(){let library=LibraryStore(context:PersistenceController.shared.container.viewContext);_model=StateObject(wrappedValue:AppViewModel(library:library));UITabBar.appearance().backgroundColor=UIColor.black}
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--hls-smoke-test") {
                DebugHLSSmokeView()
            } else {
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--download-smoke-test") { DebugDownloadSmokeView() }
                else { root }
                #else
                root
                #endif
            }
            #else
            root
            #endif
        }
    }
    private var root: some View {
        RootView().environmentObject(model).environmentObject(downloads).environment(\.managedObjectContext, persistence.container.viewContext)
    }
}
