# Удалённый просмотр через Apple SharePlay

Архитектура предназначена для iPhone в разных интернет-сетях, городах и странах.
Одна Wi-Fi сеть и нахождение рядом не требуются. Используются существующие
GroupActivity, GroupSession, GroupSessionMessenger и AVPlayerPlaybackCoordinator.
Видео не передаётся между iPhone. Доступность Apple SharePlay/FaceTime и CDN
зависит от региона и сети.

**Статус: подготовлено к тесту на двух физических iPhone; такой тест не выполнен.**
На Windows выполнена статическая проверка. Успешная iOS-сборка не заявляется.

## Приглашение и UI

A выбирает фильм, источник, озвучку и серию на Details, нажимает «Смотреть вместе».
Полноширинный Label с иконкой участников использует прежний DetailsControlStyle,
тот же размер шрифта, padding и промежутки, что соседние основные кнопки.
UIActivityViewController получает GroupActivity через NSItemProvider. A выбирает
системное действие SharePlay и контакт B; Apple ведёт приглашение через FaceTime/
SharePlay. B принимает его на своём iPhone с установленным приложением.
Отмена системного меню не активирует сессию приложением.

Из Player удалён весь нижний safeAreaInset с «Смотреть вместе» и «Настройки»,
его Spacer, padding и sheet настроек. Нативные AVKit controls и swipe-down сохранены.
По согласованному решению ручной выбор source/voice/season/episode остаётся
**на Details после закрытия Player**. Закрытие завершает участие в текущей сессии;
для другого выбора запускается новое приглашение. Протокол полных изменений
выбора и его входящая обработка сохранены, в Player он используется для next episode.
Приглашение позднего B в уже идущую сессию проверяется через системный интерфейс
FaceTime/SharePlay: отдельной кнопки приглашения в Player больше нет.

## Данные и синхронизация

Каждый iPhone разрешает собственный URL у существующего провайдера и получает
видео с CDN. Activity/Messenger передают mediaID/type/title, providerID, sourceID,
voiceID/name, season, episode и версию состояния. URL, токены, headers и видео
в этих Codable-сообщениях отсутствуют.

Play/pause/seek, playback position и playing/paused синхронизирует нативный
AVPlayerPlaybackCoordinator. В Messenger нет параллельных команд таймлайна.
coordinationID включает фильм/серию, provider/source и название озвучки (либо ID),
но не временный URL. Разные источники/озвучки не координируются до завершения
переключения обоими участниками. Оба iPhone должны использовать эту сборку:
у старой реализации был другой формат coordinationID.

При подключении берётся versioned content из session.activity. После joined
отправляется requestState. Активный участник отвечает полным snapshot. Равная
версия подтверждает неизменившийся выбор, новая заменяет старую. Окно ожидания
ответа — одна секунда, затем используется актуальная activity. Это не таймер
синхронизации позиции; более поздние новые версии также применяются с отменой
устаревшей загрузки. Выбор сохраняется в activity, чтобы поздний вход не зависел
от присутствия исходного автора.

Получатель сам разрешает точный source/voice/season/episode, готовит AVPlayerItem
и AVPlayer. После готовности вызывается coordinateWithSession(group). Первое
подключение обёрнуто в suspension; end() без proposingNewTime возвращает устройство
к таймлайну группы. Позицию позднего B (например, 00:27:35), play и pause определяет
**Apple coordinator**, а не Messenger. Локальная сохранённая позиция используется
только при подготовке и не предлагается группе как команда перемотки.

## Повторы, next episode и жизненный цикл

Lamport counter + ID автора упорядочивают одновременные изменения. Старые и равные
версии не вызывают повторную загрузку. publish вызывается после успешного локального
выбора; receive → apply никогда не вызывает publish. $activity использует тот же
reducer. Если конкурентная запись activity оказалась старее, сохраняется более
новая известная версия без повторного Messenger-события. Проверяется отправитель
сообщения по контексту GroupSession.

Countdown выполняет один участник с минимальным UUID. До initial sync и во время
получения потока право перехода отключено. При уходе владельца выбирается новый.
Право и текущая загрузка проверяются повторно перед переходом. Передаётся конкретная
следующая серия, а не команда «прибавить 1». Remote change отменяет countdown и
локальное незавершённое переключение; повтор не делает переход 4 → 6 вместо 4 → 5.

В совместном режиме недоступные source/provider/voice не подменяются молча.
Участник получает ошибку и выходит из SharePlay. Ошибка уже играющего AVPlayer
допускает одно обновление той же shared selection. Повторная ошибка отключает
SharePlay перед обычным восстановлением одиночного плеера. Обычный ProviderResolver
и его fallback не изменены. Новый opaque voiceID допустим при том же имени озвучки.

Замены item выполняются в suspension, end() возвращает к группе после готовности.
Закрытие Player вызывает leave до pause/stop: локальное закрытие не должно останавливать
других. Invalidation/leave отменяют initialSync, resolution, receive/send tasks,
subscriptions, countdown и UI-загрузки, очищают pending selection. Generation/session ID
защищают новую сессию от старых ответов. Единственный app-level sessions() listener
сохраняется для повторных приглашений и отменяется при уничтожении manager.

## Изменённые файлы и проверки

Пять существующих SharePlay/*.swift, Views/Player/PlayerView.swift,
Tests/WatchTogetherTests.swift и этот документ. Новых Manager/Activity нет.
PlayerSession, DetailsViewModel, прогресс, downloads, ATS Info.plist, Android и Tizen
не изменены. Одиночный режим сохраняет прежнюю реализацию; требуется регрессионный
прогон на iPhone, включая согласованный перенос ручного выбора на Details.

- Изменённые Swift-файлы разобраны tree-sitter-swift без ERROR/missing nodes.
  Это синтаксический parser, не Swift type checker и не build.
- Info.plist/entitlements разобраны. Minimum iOS 16.0, Group Activities capability
  и com.apple.developer.group-session сохранены для Debug/Release.
- Поиск iOS runtime на MultipeerConnectivity, NearbyInteraction, NWBrowser,
  Bonjour, local IP, Bluetooth, CoreBluetooth, MCSession, NetService: совпадений нет.
- Сигнатуры coordinateWithSession, activity get/set, participants, suspension.end
  сверены с Apple: используются API iOS 15+, доступные при minimum iOS 16.
- Проверены MainActor, Codable/Sendable wire payload, weak captures, отмена Tasks,
  version ordering и отсутствие параллельной ручной синхронизации play/pause/seek.
- WatchTogetherTests расширены: strict selection, wire format, coordination identity,
  duplicate/stale/concurrent updates, late join/rejoin, owner election.
  Swift-тесты здесь не исполнялись: Swift compiler и Xcode/iOS SDK отсутствуют.
- Существующий Codemagic ios-check настроен на Debug/Release build и тесты после
  push. Наличие конфигурации не является подтверждением успешного CI.

На Mac:

```sh
cd J1ROX_TV_iOS
bash Tests/run-provider-tests.sh
xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
```

## Проверка на двух физических iPhone — ещё не выполнена

Установить одинаковую подписанную сборку с Group Activities entitlement на два
устройства с разными Apple ID. A — домашний Wi-Fi; B — мобильный интернет с
выключенным Wi-Fi, затем другая внешняя Wi-Fi сеть.

1. Пригласить B с Details; проверить принятие и отмену.
2. A смотрит S2E4 на 27:35. Поздний B получает тот же выбор, позицию и состояние.
   Повторить при паузе A: подключение B не должно запускать A или перематывать к нулю.
3. Play/pause/seek на каждом устройстве; проверить отсутствие циклов и скачков.
4. Конец серии: один countdown и один переход. Уход владельца, отмена countdown,
   поздний вход после перехода, повторное подключение.
5. Закрыть Player, сменить source/voice/season/episode на Details, начать новую сессию.
   Старый участник не должен остановиться от локального закрытия другого Player.
6. Недоступная озвучка, потеря сети, background/foreground, системный выход из
   SharePlay, завершение FaceTime. Проверить очистку старых задач при новом приглашении.
7. Одиночный просмотр: прогресс, скачанное видео, next episode, AVKit controls.
   Swipe следует за пальцем, короткий drag возвращается, достаточный drag закрывает.
8. Details: три кнопки одной ширины и сопоставимой высоты, включая Dynamic Type.
   Player: удалённой нижней полосы нет. Визуальная проверка на iPhone не выполнялась.

## Документация Apple

- [Coordinated media playback](https://developer.apple.com/documentation/avfoundation/supporting-coordinated-media-playback)
- [TN3128: SharePlay без существующего звонка](https://developer.apple.com/documentation/technotes/tn3128-starting-shareplay-without-an-existing-facetime-call)
- [GroupSession.activity](https://developer.apple.com/documentation/groupactivities/groupsession/activity)
- [Suspension.end](https://developer.apple.com/documentation/avfoundation/avcoordinatedplaybacksuspension/end())
