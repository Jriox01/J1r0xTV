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
        .onChange(of: app.playback?.id) { id in
            guard id == nil, let saved = app.library.history.first(where: { $0.mediaID == model.item.id && $0.mediaType == model.item.mediaType }) else { return }
            Task {
                await model.synchronize(.init(media: model.item, sourceID: saved.sourceID,
                    translationID: saved.translationID, season: saved.season, episode: saved.episode))
            }
        }
        .task {
            if let saved = app.library.history.first(where: { $0.mediaID == model.item.id && $0.mediaType == model.item.mediaType }) {
                model.restore(.init(media: model.item, sourceID: saved.sourceID, translationID: saved.translationID, season: saved.season, episode: saved.episode, resumeAt: saved.position))
            }
            await model.load()
            if model.item.mediaType == "tv" { await model.prepare() }
        }
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
            WatchTogetherButton {
                if model.sources.isEmpty { await model.prepare() }
                guard model.selectedTranslation != nil else { throw ProviderError.unavailable }
                let episode = model.episodes.first { $0.number == model.selectedEpisode } ?? model.episodes.first
                if model.item.mediaType == "tv", episode == nil { throw ProviderError.selectionUnavailable }
                return model.downloadRequest(episode: episode)
            }
            .buttonStyle(DetailsControlStyle())
            DetailsFavoriteButton(library: app.library, item: model.item)
            if model.item.mediaType != "tv" { DownloadButton(model: model) }
        }
    }

    @ViewBuilder private var sourcePicker: some View {
        ContentSelectors(model: model)
        if !model.episodes.isEmpty {
            selectionSection("Серии") {
                LazyVStack(spacing: 6) {
                    ForEach(model.episodes) { episode in
                        HStack {
                            Button {
                                Task {
                                    let saved = app.library.history.first { $0.mediaID == model.item.id && $0.mediaType == model.item.mediaType && $0.season == model.selectedSeason?.number && $0.episode == episode.number }
                                    do { app.playback = try await model.play(episode: episode, resume: saved.map { $0.duration > 0 && $0.position >= $0.duration - 5 ? 0 : $0.position } ?? 0) }
                                    catch is CancellationError {}
                                    catch { model.error = error.localizedDescription }
                                }
                            } label: {
                                Label(episode.name, systemImage: "play.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .tint(model.selectedEpisode == episode.number ? .red : .primary)
                            DownloadButton(model: model, episode: episode, compact: true)
                        }
                        .padding(.horizontal, 8)
                        .background(model.selectedEpisode == episode.number ? Color.red.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } else if model.item.mediaType != "tv", model.selectedTranslation != nil {
            Button("Воспроизвести") {
                Task {
                    do { app.playback = try await model.play() }
                    catch { model.error = error.localizedDescription }
                }
            }.buttonStyle(DetailsControlStyle(selected: true))
        } else if !model.loading && !model.sources.isEmpty {
            Text("Нет доступных серий").foregroundStyle(.secondary)
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

struct ContentSelectors: View {
    @ObservedObject var model: DetailsViewModel
    var sourceSelected: ((SourceOption) -> Void)? = nil
    var translationSelected: ((TranslationOption) -> Void)? = nil
    var seasonSelected: ((SeasonOption) -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            if !model.sources.isEmpty {
                Menu {
                    ForEach(model.sources) { source in
                        Button {
                            if let sourceSelected { sourceSelected(source) }
                            else { Task { do { try await model.select(source: source) } catch is CancellationError {} catch { model.error = error.localizedDescription } } }
                        } label: { choice(source.name, selected: source.id == model.activeSource) }
                    }
                } label: { field("Источник", model.sources.first { $0.id == model.activeSource }?.name ?? "—") }
            }
            if !model.translations.isEmpty {
                Menu {
                    ForEach(model.translations) { value in
                        Button { if let translationSelected { translationSelected(value) } else { model.select(translation: value) } } label: {
                            choice(value.name, selected: value.id == model.selectedTranslation?.id)
                        }
                    }
                } label: { field("Озвучка", model.selectedTranslation?.name ?? "—") }
            }
            if !model.seasons.isEmpty {
                Menu {
                    ForEach(model.seasons) { value in
                        Button { if let seasonSelected { seasonSelected(value) } else { model.select(season: value) } } label: {
                            choice("Сезон \(value.number)", selected: value.id == model.selectedSeason?.id)
                        }
                    }
                } label: { field("Сезон", model.selectedSeason.map { "Сезон \($0.number)" } ?? "—") }
            }
        }
        .tint(.red)
        .environment(\.colorScheme, .dark)
    }
    private func choice(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "")
            .foregroundStyle(.white)
    }
    private func field(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white)
            Text(value).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").foregroundStyle(.red)
        }.font(.subheadline).foregroundStyle(.white).padding(12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.jiroxSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}
