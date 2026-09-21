# Скачивание видео в J1ROX TV для iOS

## Архитектура и совместимость

До изменений проверены SwiftUI/MVVM, `DetailsView` / `DetailsViewModel`,
`StreamingService` / `VideoProvider`, API-клиенты, `MediaItem` / `EpisodeOption`,
Core Data, навигация и связка `PlayerScreen` → `PlaybackSession` → `PlayerSession` → AVPlayer.
Deployment Target остаётся iOS 16.0; проект использует Swift 5 language mode и Xcode 16 synchronized groups.

Добавлено отдельное хранилище Core Data `J1ROXDownloads`. Схема существующих избранного
и истории не меняется. В SQLite сохраняются UUID и сериализованный снимок записи,
аналогично существующему `rawJSON` библиотеки. Это не отдельный JSON-файл на диске.
Снимок содержит Movie ID/type, Episode ID/номер/сезон, название, оригинальное название,
описание, год, URL постера и его локальную миниатюру, озвучку, провайдера, качество,
размеры, исходный URL/headers/срок действия, относительный путь, даты, статус и resumeData.

Состояние менеджера, Core Data и публикации UI изолированы `MainActor`.
Делегат URLSession вызывается на `OperationQueue.main`; синхронный
`MainActor.assumeIsolated` сохраняет порядок событий и время жизни временного файла.
Новых сторонних зависимостей приложения нет.

## Источники: обязательный контракт разрешения

**Ссылка для просмотра сама по себе не разрешает скачивание.**
Новый `VideoProvider.downloads(for:)` по умолчанию возвращает пустой список.
Atodo читает поля из выбранной озвучки/серии либо ответа deferred source;
Cinemap — из ответа существующего `POST playback` настроенного Video API.
Не выполняется поиск альтернативного провайдера, озвучки или серии для скачивания.

Источник, которому разрешено предоставлять файл для офлайн-просмотра, должен вернуть:

```json
{
  "download_allowed": true,
  "drm": false,
  "downloads": [
    {
      "url": "https://your-authorized-host.example/video/movie-720.mp4",
      "quality": "720p",
      "size_bytes": 734003200,
      "expires_at": 1893456000,
      "headers": {}
    },
    {
      "url": "https://your-authorized-host.example/video/movie-1080.mp4",
      "quality": "1080p"
    }
  ]
}
```

`size_bytes`, `expires_at` (Unix seconds) и `headers` необязательны.
Для неизвестного размера выполняется HEAD; неподдерживаемый HEAD не запрещает загрузку.
При отсутствии Content-Length UI показывает неизвестный размер и не выдумывает процент/ETA.
Вариант может отдельно запретить скачивание через `download_allowed: false` или `drm: true`.
Права и отсутствие DRM должны быть заявлены логическими значениями, не строками.
Список качеств берётся из ответа; несуществующие 360p/480p/720p/1080p/4K не добавляются.

Поддерживаются прямые HTTP(S) MP4/M4V/MOV. URL с логином/паролем, HLS, DASH,
страницы, MKV/WebM и источники без явного разрешения не принимаются.
Нет получения DRM-ключей, обхода FairPlay, авторизации или защиты источников.
Ответ файла проверяется по HTTP-коду, MIME, заголовку контейнера и известной длине.
Конкретный кодек внутри контейнера должен поддерживаться AVPlayer.

**Текущая работа с реальным backend не подтверждена:** существующий API может не
возвращать этот новый контракт. Тогда приложение объясняет, что скачивание
недоступно. Адрес Cinemap API, оставленный пользователем пустым, не заполнялся.

## Файлы и хранение

Видео находятся в sandbox приложения:

```text
Library/Application Support/Downloads/<UUID>-<attempt UUID>.mp4
Library/Application Support/Downloads/metadata.sqlite
```

Расширение сохраняется как mp4/m4v/mov. Core Data может создавать рядом WAL/SHM
и файлы external binary storage. Каталог исключён из резервной копии iCloud.
Видео используют `completeUntilFirstUserAuthentication`, чтобы сохраняться после
блокировки устройства, которое уже разблокировали после перезагрузки.
Постоянное видео не хранится в tmp/Caches. Путь сохраняется относительно каталога,
поскольку абсолютный путь sandbox может измениться. Имена файлов не берутся из API.

Сначала URLSession пишет временный файл. В `didFinishDownloadingTo` он проверяется
и синхронно переносится в Application Support до возврата из делегата. Только затем
запись становится завершённой. При сбое между переносом и сохранением метаданных
готовый файл распознаётся после запуска. Отсутствующий файл становится ошибкой.
Система сама управляет незавершёнными временными файлами URLSession.

Перед постановкой в очередь и стартом проверяется доступная ёмкость с учётом
известного остатка очереди и резерва 64 MiB. Проверка повторяется при прогрессе;
ошибки заполненного диска показываются пользователю. Для неизвестного размера
полностью гарантировать место до начала передачи невозможно.

## Background Download и очередь

Используются две постоянные background URLSession:
`com.jirox.jiroxtv.downloads.wifi` и `com.jirox.jiroxtv.downloads.any`.
Сетевая политика задаётся на уровне сессии, включая восстановленные задачи.
`sessionSendsLaunchEvents` включён; `UIApplicationDelegateAdaptor` принимает
`handleEventsForBackgroundURLSession`. Completion handler вызывается на главном
потоке после `urlSessionDidFinishEvents` и сохранения состояния.

При запуске `allTasks` сопоставляется с UUID записи и UUID попытки в
`taskDescription`. Неизвестные/устаревшие задачи отменяются. Поздние callbacks
удалённой или предыдущей попытки не восстанавливают запись.
Очередь запускает две передачи по умолчанию (настройка 1–4). Очередная задача
стартует после освобождения места в лимите. Уменьшение лимита приостанавливает
лишние передачи и возвращает их в очередь. Запись относится к одной серии;
будущее скачивание сезона можно реализовать последовательным `enqueue` для серий.

Фоновые передачи выполняет iOS. Момент запуска и пробуждения не гарантируется:
ограничения батареи/сети и системное ограничение частоты пробуждений могут задерживать
переход к следующему элементу очереди. После принудительного закрытия приложения
пользователем система отменяет фоновые передачи; приложение нужно открыть снова.
Это отличается от обычного ухода в фон или выгрузки процесса системой.
См. [документацию Apple о background downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

## Пауза, продолжение, отмена

Пауза активной задачи вызывает `cancel(byProducingResumeData:)` и сохраняет
resumeData в Core Data. Возобновление создаёт новую задачу через
`downloadTask(withResumeData:)`. UI блокирует повторное нажатие на время получения
resumeData. При его отсутствии передача начинается с нуля. Если ранее сохранённые
данные больше нельзя использовать, ошибка позволяет повторить загрузку с новыми
resumeData из ошибки либо с нуля. Автоматического бесконечного повторения нет.

Сервер должен поддерживать возобновление; временный файл может быть удалён iOS.
См. [условия Apple для pause/resume](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads).
Изменение Wi-Fi-политики переносит активные задачи в другую сессию с началом с нуля:
непрозрачные resumeData не переписываются. Уменьшение лимита сохраняет resumeData.
Истёкшая ссылка требует заново выбрать скачивание на странице материала;
подписанные URL не продлеваются подменой токена.

Отмена удаляет запись и отменяет задачу. Удаление готовой записи также удаляет видео.
«Удалить всё» требует подтверждения в интерфейсе. Поздние события отменённой задачи
не должны повторно создавать файл или запись.

## Как пользоваться офлайн

На странице фильма нажмите «Скачать». Для сериала выберите озвучку и сезон,
затем «Скачать серию». При нескольких качествах появляется выбор, если он включён
в настройках. Кнопка показывает прогресс/паузу, затем «Скачано».

Откройте вкладку **Загрузки → Скачанные → Смотреть**. Воспроизведение использует
тот же `PlayerScreen`/AVPlayer и локальный file URL без запроса API. Метаданные и
сохранённая миниатюра доступны без сети. Если постер не успел загрузиться,
показывается значок фильма. История сначала ищет соответствующую локальную запись.
Ошибка локального файла не запускает сетевое переключение провайдеров.

В **Загрузки → шестерёнка** находятся качество по умолчанию, запрос качества,
Wi-Fi, лимит передач, размер завершённых видео и удаление всех загрузок.
Временные файлы, незавершённые передачи и SQLite не входят в размер завершённых видео.

## Проверки и ограничения проверки

В этой Windows-сессии выполнены:

- `python Tests/test-download-server.py`: 4 теста HTTP fixture прошли (HEAD, Range/ETag, 403/416, HTML, размер).
- `git diff --check`: без ошибок whitespace.
- Bash syntax check обоих изменённых/новых runner scripts: прошёл.
- YAML Codemagic: успешно разобран.
- Разбор Swift через tree-sitter: новых синтаксических ошибок относительно HEAD нет.

**Xcode/Swift Compiler, Simulator и реальный iPhone здесь недоступны.**
Проверка типов, SDK availability, MainActor/Sendable diagnostics, реальный background,
офлайн-воспроизведение и перезапуск на устройстве не объявляются пройденными.
Tree-sitter не заменяет Swift Compiler.

На Mac:

```bash
cd J1ROX_TV_iOS
bash Tests/run-provider-tests.sh
bash Tests/run-download-simulator.sh
xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
```

`DownloadTests.swift` проверяет разрешения/DRM, прямые форматы, путь sandbox,
нехватку места и повторное открытие SQLite с постером, серией и resumeData.
Simulator runner создаёт свой MP4 через AVAssetWriter, запускает localhost-сервер
с Range и отдельный временный Simulator. Проверяет лимит 2+1, паузу/продолжение,
отмену без воскрешения записи, HTTP 403/HTML, завершённые/приостановленные записи
после перезапуска и AVPlayer при выключенном сервере. DEBUG smoke использует
отдельный каталог `DownloadsSmoke`; обычные загрузки не удаляются.
ATS-исключение меняется только в собранном simulator app, не в production Info.plist.
В `ios-check` добавлены запуск этого сценария и strict-concurrency Release compilation.
CI не запускался и изменения не отправлялись в GitHub.

На реальном iPhone обязательно проверить разрешённый большой файл: экран блокировки,
выгрузку процесса системой, отдельный сценарий force quit, потерю/смену Wi-Fi и LTE,
Wi-Fi-only, уменьшение лимита, малый объём диска, удаление на паузе, просроченный URL,
режим полёта после скачивания и восстановление списка после перезагрузки.
Не отключайте устройство от сети до завершения получения видео для проверки офлайна.

## Список изменений

Созданы:

- `J1ROXTV/Models/DownloadModels.swift`
- `J1ROXTV/Persistence/DownloadStore.swift`
- `J1ROXTV/Services/DownloadManager.swift`
- `J1ROXTV/Views/Details/DownloadButton.swift`
- `J1ROXTV/Views/Downloads/DownloadsView.swift`
- `J1ROXTV/Views/Downloads/DebugDownloadSmokeView.swift`
- `Tests/DownloadTests.swift`
- `Tests/CreateDownloadFixture.swift`
- `Tests/download-fixture-server.py`
- `Tests/test-download-server.py`
- `Tests/run-download-simulator.sh`
- `DOWNLOADS.md`

Изменены:

- `J1ROXTV/App/J1ROXTVApp.swift`, `RootView.swift`: lifecycle, окружение, навигация, ошибки.
- `J1ROXTV/Providers/VideoProvider.swift`, `AtodoProvider.swift`, `CinemapProvider.swift`: отдельная download capability.
- `J1ROXTV/Services/MediaServices.swift`, `SourceAPIClient.swift`: получение разрешённых вариантов/размеров.
- `J1ROXTV/ViewModels/DetailsViewModel.swift`, `AppViewModel.swift`, `PlaybackSession.swift`: запросы серий, локальная история, ошибки локального плеера.
- `J1ROXTV/Views/Details/DetailsView.swift`: кнопки фильма и серий.
- `Tests/ProviderTests.swift`, `Tests/run-provider-tests.sh`: download tests и актуальные ожидания Cinemap.
- `README.md` и корневой `codemagic.yaml`.

`SourceAPIClient.swift` уже существовал как untracked-файл, а Cinemap уже имел
пользовательские изменения до этой работы. Они сохранены; в SourceAPIClient также
исправлен вызов `ProviderError.network(error)` с отсутствовавшим аргументом.
PlayerSession, схема Core Data библиотеки, Deployment Target и production Info.plist не менялись.
