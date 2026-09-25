import SwiftUI

struct RootView:View{
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject var app:AppViewModel;@State private var splash=true
    var body: some View {
        ZStack {
            if splash { SplashView().transition(.opacity) }
            else {
                TabView {
                    HomeView().tabItem { Label("Главная", systemImage: "house.fill") }
                    SearchView().tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                    FavoritesView().tabItem { Label("Избранное", systemImage: "heart.fill") }
                    HistoryView().tabItem { Label("История", systemImage: "clock.fill") }
                    DownloadsView().tabItem { Label("Загрузки", systemImage: "arrow.down.circle.fill") }
                    #if DEBUG
                    DebugPlaybackView().tabItem { Label("HLS Test", systemImage: "stethoscope") }
                    #endif
                }.tint(.red)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Загрузки", isPresented: Binding(get: { downloads.message != nil }, set: { if !$0 { downloads.message = nil } })) {
            Button("OK") { downloads.message = nil }
        } message: { Text(downloads.message ?? "") }
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.6)) { splash = false }
        }
        .modifier(WatchTogetherAlert())
        .fullScreenCover(item: $app.playback) {
            PlayerScreen(selection: $0).environmentObject(app).environmentObject(app.watchTogether)
        }
    }
}
struct SplashView:View{@State private var glow=false;var body:some View{ZStack{Color.black.ignoresSafeArea();Circle().fill(.red.opacity(glow ? 0.22:0.06)).frame(width:300).blur(radius:70).scaleEffect(glow ? 1.1:0.8);VStack(spacing:18){Text("J1ROX TV").font(.system(size:46,weight:.black,design:.rounded)).foregroundStyle(.white).shadow(color:.red.opacity(0.8),radius:glow ? 24:8);Text("КИНО ВСЕГДА С ТОБОЙ").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.secondary);ProgressView().tint(.red).padding(.top,18)}}.onAppear{withAnimation(.easeInOut(duration:1.2).repeatForever(autoreverses:true)){glow=true}}}}
