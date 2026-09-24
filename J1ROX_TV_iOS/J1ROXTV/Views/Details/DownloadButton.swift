import SwiftUI

struct DownloadButton: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var app: AppViewModel
    @ObservedObject var model: DetailsViewModel
    var episode: EpisodeOption? = nil
    var compact = false
    @State private var loading = false
    @State private var offer: DownloadOffer?
    private var entry: DownloadRecord? {
        if model.selectedTranslation != nil { return downloads.existing(model.downloadRequest(episode: episode)) }
        // Catalogue details need no source API call to show an already downloaded movie.
        return downloads.records.first {
            $0.media.id == model.item.id && $0.media.mediaType == model.item.mediaType &&
            $0.episode == episode?.number && (episode == nil || $0.season == model.selectedSeason?.number)
        }
    }

    var body: some View {
        Button {
            if let entry {
                switch entry.state {
                case .completed: app.playback = downloads.playback(entry.id)
                case .downloading, .queued: downloads.pause(entry.id)
                case .paused, .failed: downloads.resume(entry.id)
                }
            } else { prepare() }
        } label: {
            HStack(spacing: 10) {
                if loading { ProgressView() }
                else if compact {
                    Image(systemName: entry.map {
                        switch $0.state {
                        case .completed: return "checkmark.circle.fill"
                        case .failed: return "exclamationmark.circle"
                        case .queued, .downloading: return "hourglass"
                        case .paused: return "pause.circle"
                        }
                    } ?? "arrow.down.circle")
                    if let entry, entry.state == .downloading, let progress = entry.progress {
                        Text("\(Int(progress * 100))%").font(.caption)
                    }
                }
                else if let entry {
                    if entry.state == .downloading || entry.state == .queued {
                        ProgressView(value: entry.progress).frame(maxWidth: 100)
                    }
                    Label(title(entry), systemImage: entry.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                } else {
                    Label(episode == nil ? "Скачать" : "Скачать серию", systemImage: "arrow.down.circle")
                }
            }
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 44)
        }
        .accessibilityLabel(entry.map { title($0) } ?? "Скачать \(episode?.name ?? model.item.title)")
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(loading || model.loading || !downloads.ready || entry.map { downloads.pausing.contains($0.id) } == true)
        .contextMenu {
            if let entry {
                if entry.state == .completed { Button("Смотреть") { app.playback = downloads.playback(entry.id) } }
                Button("Удалить", role: .destructive) { downloads.remove(entry.id) }
            }
        }
        .sheet(item: $offer) { choice in
            NavigationStack {
                List(choice.variants) { variant in
                    Button {
                        downloads.enqueue(choice.request, variant: variant, episodeID: choice.episodeID)
                        offer = nil
                    } label: {
                        HStack {
                            Text(variant.quality)
                            Spacer()
                            Text(variant.expectedBytes.map { "≈ " + downloadBytes($0) } ?? "Размер неизвестен")
                                .foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                }
                .navigationTitle(choice.request.episode.map { "Скачать \($0) серию" } ?? "Качество загрузки")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { offer = nil } } }
            }.tint(.red)
        }
    }
    private func title(_ entry: DownloadRecord) -> String {
        switch entry.state {
        case .completed: return "Скачано"
        case .downloading: return entry.progress.map { "\(Int($0 * 100))% · Пауза" } ?? "Скачивается · Пауза"
        case .queued: return "В очереди · Пауза"
        case .paused: return "Продолжить загрузку"
        case .failed: return "Повторить загрузку"
        }
    }
    private func prepare() {
        loading = true
        Task {
            defer { loading = false }
            if model.selectedTranslation == nil { await model.prepare() }
            guard model.selectedTranslation != nil else {
                downloads.message = model.error ?? DownloadError.unavailable.localizedDescription; return
            }
            let request = model.downloadRequest(episode: episode)
            do {
                let (resolvedRequest, variants) = try await model.downloadVariants(for: request)
                if variants.count > 1 {
                    offer = DownloadOffer(request: resolvedRequest, episodeID: episode?.id, variants: variants)
                } else if let selected = variants.first(where: { $0.quality == downloads.settings.quality }) ?? variants.first {
                    downloads.enqueue(resolvedRequest, variant: selected, episodeID: episode?.id)
                }
            } catch { downloads.message = error.localizedDescription }
        }
    }
}

private struct DownloadOffer: Identifiable {
    let id = UUID()
    let request: PlaybackRequest
    let episodeID: String?
    let variants: [DownloadVariant]
}
