import SwiftUI

struct DetailsView: View {
    @EnvironmentObject private var app: AppViewModel
    @StateObject private var model: DetailsViewModel

    init(item: MediaItem) {
        _model = StateObject(wrappedValue: DetailsViewModel(item: item, streaming: StreamingService()))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                information
                if !model.item.overview.isEmpty {
                    Text(model.item.overview)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions
                sourcePicker
                if model.loading {
                    ProgressView("Загрузка…")
                        .frame(maxWidth: .infinity)
                }
                if let error = model.error {
                    ErrorPanel(message: error) {
                        Task { await model.prepare() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.jiroxBackground)
        // The system TabView already contributes its actual bar height to the safe area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var hero: some View {
        Color.jiroxSurface
            .frame(height: 240)
            .overlay {
                CachedAsyncImage(url: URL(string: model.item.backdropURL), contentMode: .fill)
            }
            .overlay(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL(string: model.item.posterURL), contentMode: .fill)
                    .frame(width: 104, height: 156)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.item.title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            if !model.item.originalTitle.isEmpty {
                Text(model.item.originalTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text([model.item.year, model.item.rating.isEmpty ? "" : "★ \(model.item.rating)"]
                .filter { !$0.isEmpty }.joined(separator: "  •  "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !model.item.genres.isEmpty {
                Text(model.item.genres.joined(separator: " • "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.prepare() }
            } label: {
                Label(model.item.mediaType == "tv" ? "Выбрать серию" : "Смотреть", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DetailsControlStyle(selected: true))
            DetailsFavoriteButton(library: app.library, item: model.item)
            if model.item.mediaType != "tv" { DownloadButton(model: model) }
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        if !model.sources.isEmpty {
            selectionSection("Источник") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.sources) { source in
                            chip(source.name, selected: model.activeSource == source.id) {
                                Task { try? await model.select(source: source) }
                            }
                        }
                    }
                }
            }
        }
        if !model.translations.isEmpty {
            selectionSection("Озвучка") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.translations) { translation in
                            chip(translation.name, selected: model.selectedTranslation?.id == translation.id) {
                                model.select(translation: translation)
                            }
                        }
                    }
                }
            }
        }
        if !model.seasons.isEmpty {
            selectionSection("Сезоны") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.seasons) { season in
                            chip(season.name, selected: model.selectedSeason?.id == season.id) {
                                model.select(season: season)
                            }
                        }
                    }
                }
            }
        }
        if !model.episodes.isEmpty {
            selectionSection("Серии") {
                LazyVStack(spacing: 8) {
                    ForEach(model.episodes) { episode in
                        Button {
                            Task {
                                do { app.playback = try await model.play(episode: episode) }
                                catch { model.error = error.localizedDescription }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Color.jiroxSurface
                                    .frame(height: 120)
                                    .overlay {
                                        CachedAsyncImage(url: URL(string: episode.imageURL), contentMode: .fill)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Label {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(episode.name).font(.body.weight(.semibold))
                                        Text("Серия \(episode.number)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "play.circle.fill").foregroundStyle(Color.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(DetailsControlStyle())
                        DownloadButton(model: model, episode: episode)
                    }
                }
            }
        } else if model.selectedTranslation != nil && model.seasons.isEmpty {
            Button {
                Task {
                    do { app.playback = try await model.play() }
                    catch { model.error = error.localizedDescription }
                }
            } label: {
                Label("Воспроизвести", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DetailsControlStyle(selected: true))
        }
    }

    private func selectionSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.jiroxSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if selected { Image(systemName: "checkmark") }
                Text(title)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(DetailsControlStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DetailsControlStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(selected ? Color.red : Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct DetailsFavoriteButton: View {
    @ObservedObject var library: LibraryStore
    let item: MediaItem

    var body: some View {
        Button {
            library.toggle(item)
        } label: {
            Label(library.isFavorite(item) ? "В избранном" : "В избранное",
                  systemImage: library.isFavorite(item) ? "heart.fill" : "heart")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DetailsControlStyle())
    }
}

struct ErrorPanel: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить", action: retry)
                .buttonStyle(DetailsControlStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.jiroxSurface, in: RoundedRectangle(cornerRadius: 16))
    }
}
