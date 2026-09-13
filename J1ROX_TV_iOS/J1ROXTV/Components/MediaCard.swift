import SwiftUI

struct MediaCard:View {
    let item:MediaItem; var progress:Double=0
    var body:some View { VStack(alignment:.leading,spacing:6){ZStack(alignment:.bottom){CachedAsyncImage(url:URL(string:item.posterURL),contentMode:.fill).frame(width:145,height:215).clipped().clipShape(RoundedRectangle(cornerRadius:12));if progress>0{ProgressView(value:progress).tint(.red).padding(6)}};Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width:145,alignment:.leading);HStack{Text(item.year);Spacer();if !item.rating.isEmpty{Label(item.rating,systemImage:"star.fill").foregroundStyle(.yellow)}}.font(.caption).foregroundStyle(.secondary).frame(width:145)} }
}
struct MediaRow:View {
    let title:String;let items:[MediaItem]
    var body:some View{VStack(alignment:.leading,spacing:12){Text(title).font(.title2.bold()).padding(.horizontal);ScrollView(.horizontal,showsIndicators:false){LazyHStack(spacing:14){ForEach(items){item in NavigationLink(value:item){MediaCard(item:item)}.buttonStyle(.plain)}}.padding(.horizontal)}}}
}
