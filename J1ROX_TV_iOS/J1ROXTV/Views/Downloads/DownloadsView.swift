import SwiftUI

func downloadBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var completedOnly = false
    private var visible: [DownloadRecord] { downloads.records.reversed().filter { !completedOnly || $0.state == .completed } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $completedOnly) {
                    Text("Загрузки").tag(false)
                    Text("Скачанные").tag(true)
                }.pickerStyle(.segmented).padding()
                if visible.isEmpty {
                    Spacer()
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text(completedOnly ? "Скачанных видео пока нет" : "Загрузок пока нет").padding(.top, 8)
                    Text("Выберите «Скачать» на странице фильма или серии.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Spacer()
                } else {
                    List {
                        ForEach(visible) { entry in
                            DownloadRow(entry: entry)
                                .listRowBackground(Color.jiroxSurface)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { visible[$0].id }
                            for id in ids { downloads.remove(id) }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
            .background(Color.jiroxBackground)
            .navigationTitle(completedOnly ? "Скачанные" : "Загрузки")
            .toolbar {
                NavigationLink { DownloadSettingsView() } label: { Label("Настройки", systemImage: "gearshape") }
            }
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var app: AppViewModel
    let entry: DownloadRecord
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let data = entry.posterData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").resizable().scaledToFit().padding().foregroundStyle(.secondary)
                    }
                }.frame(width: 66, height: 96).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.media.title).font(.headline)
                    Text(entry.episodeLabel).font(.subheadline)
                    if let voice = entry.translationName { Text(voice).font(.caption).foregroundStyle(.secondary) }
                    Text("\(entry.variant.quality) · \(entry.state.title)").font(.caption).foregroundStyle(.secondary)
                    Text("\(downloadBytes(entry.received)) / \(entry.total > 0 ? downloadBytes(entry.total) : "неизвестно")")
                        .font(.caption).monospacedDigit()
                }
            }
            if entry.state != .completed {
                ProgressView(value: entry.progress).tint(.red)
                HStack {
                    Text(entry.progress.map { "\(Int($0 * 100))%" } ?? "Размер неизвестен")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let speed = downloads.speed(entry.id, at: context.date)
                        Text(speed > 0 ? "\(downloadBytes(Int64(speed)))/с · \(remaining(speed))" : "— /с · время неизвестно")
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if entry.state == .downloading && downloads.settings.wifiOnly {
                    Text("Только Wi-Fi. Без Wi-Fi загрузка ожидает подключения.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = entry.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                switch entry.state {
                case .queued, .downloading:
                    Button("Пауза") { downloads.pause(entry.id) }
                case .paused, .failed:
                    Button(entry.state == .failed ? "Повторить" : "Продолжить") { downloads.resume(entry.id) }
                case .completed:
                    Button { app.playback = downloads.playback(entry.id) } label: { Label("Смотреть", systemImage: "play.fill") }
                }
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Информация")
                Button(role: .destructive) { downloads.remove(entry.id) } label: {
                    Image(systemName: entry.state == .completed ? "trash" : "xmark.circle")
                }.accessibilityLabel(entry.state == .completed ? "Удалить" : "Отменить загрузку")
            }.buttonStyle(.bordered).disabled(downloads.pausing.contains(entry.id))
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                List {
                    Text(entry.media.title).font(.headline)
                    if !entry.media.originalTitle.isEmpty { Text(entry.media.originalTitle) }
                    Text(entry.media.year + " · " + entry.episodeLabel)
                    Text(entry.variant.quality + " · " + downloadBytes(entry.received))
                    if let date = entry.completedAt { Text("Скачано: " + date.formatted(date: .abbreviated, time: .shortened)) }
                    Text(entry.media.overview)
                }.navigationTitle("Информация")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showInfo = false } } }
            }
        }
    }
    private func remaining(_ speed: Double) -> String {
        guard entry.total > entry.received else { return "время неизвестно" }
        let seconds = Double(entry.total - entry.received) / speed
        guard seconds.isFinite, seconds < Double(Int.max) else { return "время неизвестно" }
        return "≈ \(max(1, Int(ceil(seconds / 60)))) мин"
    }
}

struct DownloadSettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section("Загрузки") {
                Picker("Качество по умолчанию", selection: $downloads.settings.quality) {
                    ForEach(["360p", "480p", "720p", "1080p", "4K", "Оригинал"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Спрашивать качество", isOn: $downloads.settings.askQuality)
                Toggle("Только по Wi-Fi", isOn: $downloads.settings.wifiOnly)
                Stepper("Одновременных загрузок: \(downloads.settings.simultaneous)", value: $downloads.settings.simultaneous, in: 1...4)
                Text("Если выбранного качества нет, используется первый доступный вариант источника.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Хранилище") {
                LabeledContent("Скачанные видео", value: downloadBytes(downloads.usedBytes))
                Button("Удалить все загрузки", role: .destructive) { confirmDelete = true }.disabled(downloads.records.isEmpty)
            }
        }
        .navigationTitle("Настройки")
        .confirmationDialog("Удалить все видео и отменить загрузки?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) { downloads.removeAll() }
            Button("Отмена", role: .cancel) { }
        }
    }
}
