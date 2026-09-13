import SwiftUI

struct SearchView:View {
    @EnvironmentObject var model:AppViewModel;@State private var query=""
    private let columns=[GridItem(.adaptive(minimum:145),spacing:16)]
    var body:some View{NavigationStack{ScrollView{if model.isLoading && !query.isEmpty{ProgressView().padding(40)}else if !query.isEmpty&&model.searchResults.isEmpty{VStack(spacing:12){Image(systemName:"magnifyingglass").font(.largeTitle);Text("Ничего не найдено").font(.headline);Text("Попробуйте изменить запрос").foregroundStyle(.secondary)}.frame(maxWidth:.infinity).padding(60)}else{LazyVGrid(columns:columns,spacing:20){ForEach(model.searchResults){item in NavigationLink(value:item){MediaCard(item:item)}.buttonStyle(.plain)}}.padding()}}.background(Color.jiroxBackground).navigationTitle("Поиск").searchable(text:$query,prompt:"Фильмы и сериалы").onChange(of:query){model.search($0)}.navigationDestination(for:MediaItem.self){DetailsView(item:$0)}}}
}
