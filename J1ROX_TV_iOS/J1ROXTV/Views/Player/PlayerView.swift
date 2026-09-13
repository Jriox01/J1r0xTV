import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let selection:PlaybackSelection;let library:LibraryStore
    func makeCoordinator()->Coordinator{Coordinator(selection:selection,library:library)}
    func makeUIViewController(context:Context)->AVPlayerViewController{let asset=AVURLAsset(url:selection.url,options:["AVURLAssetHTTPHeaderFieldsKey":selection.headers]);let player=AVPlayer(playerItem:AVPlayerItem(asset:asset));let controller=AVPlayerViewController();controller.player=player;controller.allowsPictureInPicturePlayback=true;controller.canStartPictureInPictureAutomaticallyFromInline=true;controller.entersFullScreenWhenPlaybackBegins=true;controller.delegate=context.coordinator;context.coordinator.attach(player);return controller}
    func updateUIViewController(_ controller:AVPlayerViewController,context:Context){}
    static func dismantleUIViewController(_ controller:AVPlayerViewController,coordinator:Coordinator){coordinator.save();coordinator.detach();controller.player?.pause()}
    final class Coordinator:NSObject,AVPlayerViewControllerDelegate{
        let selection:PlaybackSelection;let library:LibraryStore;weak var player:AVPlayer?;var observer:Any?;var background:NSObjectProtocol?
        init(selection:PlaybackSelection,library:LibraryStore){self.selection=selection;self.library=library}
        func attach(_ player:AVPlayer){self.player=player;try? AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback);try? AVAudioSession.sharedInstance().setActive(true);if selection.request.resumeAt>0{player.seek(to:CMTime(seconds:selection.request.resumeAt,preferredTimescale:600))};observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:10,preferredTimescale:600),queue:.main){[weak self]_ in self?.save()};background=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main){[weak self]_ in self?.save()};player.play()}
        func save(){guard let player else{return};let position=player.currentTime().seconds;let duration=player.currentItem?.duration.seconds ?? 0;if position.isFinite&&position>=0{Task{@MainActor in self.library.save(self.selection,position:position,duration:duration.isFinite ? duration:0)}}}
        func detach(){if let observer,let player{player.removeTimeObserver(observer)};if let background{NotificationCenter.default.removeObserver(background)};observer=nil;background=nil}
    }
}
struct PlayerScreen:View{let selection:PlaybackSelection;@EnvironmentObject var app:AppViewModel;var body:some View{ZStack(alignment:.topTrailing){PlayerView(selection:selection,library:app.library).ignoresSafeArea();Button { app.playback = nil } label: {Image(systemName:"xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.palette).foregroundStyle(.white,.black.opacity(0.7))}.padding()}.background(.black).onDisappear{app.playback=nil}}}
