import SwiftUI
import UIKit

final class ImageCache { static let shared = NSCache<NSURL, UIImage>() }
@MainActor final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var task: Task<Void, Never>?
    func load(_ url: URL?) {
        task?.cancel(); guard let url else { image=nil; return }
        if let cached=ImageCache.shared.object(forKey:url as NSURL) { image=cached; return }
        task=Task { do { let (data,response)=try await URLSession.shared.data(from:url); guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, let result=UIImage(data:data) else{return}; ImageCache.shared.setObject(result,forKey:url as NSURL); image=result } catch {} }
    }
    deinit { task?.cancel() }
}
struct CachedAsyncImage: View {
    let url: URL?; let contentMode: ContentMode
    @StateObject private var loader=ImageLoader()
    var body: some View { Group { if let image=loader.image { Image(uiImage:image).resizable().aspectRatio(contentMode:contentMode) } else { ZStack { Color.white.opacity(0.06); Image(systemName:"film").foregroundStyle(.secondary) } } }.onAppear{loader.load(url)}.onChange(of:url){loader.load($0)} }
}
