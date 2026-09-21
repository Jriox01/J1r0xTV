# J1ROX TV for iOS

Нативный iPhone/iPad-клиент существующего J1ROX TV: SwiftUI, URLSession, Core Data и системный AVPlayer. Минимальная версия — iOS 16.0. Проект не содержит mock-каталога и подключается к реальному `https://api.atodo.fun/`.

## Требования

- macOS и Xcode 16 или новее (проект использует synchronized groups Xcode 16);
- iOS Simulator 16+ либо iPhone/iPad с iOS 16+;
- интернет-соединение;
- бесплатный или платный Apple Developer account для установки на устройство.

API настраивается в `J1ROXTV/Networking/APIConfig.swift`. Общие headers, cookie-сессия и timeout находятся там же и в `APIClient.swift`.

## Офлайн-загрузки

Добавлены «Скачать» / «Скачать серию», очередь фоновых загрузок, пауза/продолжение,
вкладка «Загрузки» с разделом «Скачанные» и настройки. Для скачивания источник должен
явно предоставить разрешённые прямые MP4/M4V/MOV; обычная потоковая ссылка не считается
разрешением. Скачанные файлы открываются существующим AVPlayer без запроса API.

Контракт API, хранение, ограничения iOS, список файлов и инструкции проверки:
[DOWNLOADS.md](DOWNLOADS.md). Сборка и устройство требуют проверки на macOS/iPhone.

## Открытие и сборка

1. Скопируйте всю папку `J1ROX_TV_iOS` на Mac.
2. Откройте `J1ROXTV.xcodeproj`.
3. Выберите scheme `J1ROXTV` и iPhone/iPad Simulator.
4. Нажмите Run или выполните `xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV -sdk iphonesimulator build`.

## Установка на iPhone

1. В Signing & Capabilities выберите Apple ID / Team.
2. При необходимости замените `com.jirox.jiroxtv` на уникальный Bundle Identifier.
3. Подключите iPhone и включите Developer Mode.
4. Выберите iPhone как destination и нажмите Run.
5. Если iOS запросит подтверждение, разрешите доверие сертификату разработчика в настройках устройства.

## Реальный streaming flow

`details → source/list → source/{id} → translation → season/episode → direct streams`.

Если контейнер содержит `data`, JSON сериализуется в UTF-8, кодируется Base64 и отправляется в `source/{id}?data=...`. Для AVPlayer выбирается HLS (`.m3u8`), затем MP4. URL потока не сохраняется: при продолжении просмотра цепочка выполняется заново.

## Ограничения

- Сборку необходимо подтвердить на Mac, поскольку Xcode/iOS SDK недоступны на Windows.
- Доступность конкретных источников зависит от backend и правообладателей.
- AVPlayer намеренно не открывает MKV/WebM/DASH как прямой источник.

## Сборка iOS без Mac

Рабочая цепочка:

```text
Windows → git push → GitHub → Codemagic/Xcode → App Store Connect → TestFlight → iPhone
```

В корне репозитория находится `codemagic.yaml` с двумя workflow:

- `ios-check` — автоматически проверяет Release-компиляцию без подписи при push или pull request в `main`, если менялись `J1ROX_TV_iOS/**` или `codemagic.yaml`;
- `ios-testflight` — запускается вручную, выполняет такую же unsigned-проверку, затем получает signing files, создаёт archive/IPA и загружает приложение в TestFlight.

TestFlight workflow использует номер `$BUILD_NUMBER` от Codemagic как `CFBundleVersion`, поэтому повторная загрузка не получает прежний build number. Версия приложения задаётся переменной `MARKETING_VERSION` в `codemagic.yaml`.

### 1. GitHub с Windows

1. На github.com нажмите **New repository**.
2. Создайте пустой репозиторий, не добавляя чужой README или `.gitignore`.
3. В PowerShell из корня проекта выполните:

```powershell
git init
git add .
git commit -m "Add J1ROX TV iOS and Codemagic"
git branch -M main
git remote add origin https://github.com/ВАШ_ЛОГИН/ВАШ_РЕПОЗИТОРИЙ.git
git push -u origin main
```

В Git должны попасть `codemagic.yaml`, `.gitignore` и вся папка `J1ROX_TV_iOS`. Сертификаты, `.p8`, provisioning profiles, archives и IPA добавлять нельзя.

### 2. Apple Developer

Требуется активная подписка Apple Developer Program для подписи и TestFlight.

1. Откройте developer.apple.com/account.
2. Перейдите **Certificates, Identifiers & Profiles → Identifiers → + → App IDs → App**.
3. Description: `J1ROX TV`; Explicit Bundle ID: `com.jirox.jiroxtv`.
4. Team ID находится в **Membership details**. Скопируйте 10-символьное значение.

Если Bundle ID уже занят или принадлежит другой команде, выберите уникальный ID и одинаково замените его в App Store Connect, `codemagic.yaml` (`BUNDLE_ID`) и Xcode build settings.

### 3. App Store Connect

1. Откройте appstoreconnect.apple.com → **My Apps → + → New App**.
2. Platforms: iOS; Name: `J1ROX TV`; Primary Language: нужный язык.
3. Bundle ID: зарегистрированный `com.jirox.jiroxtv`; SKU: например `jirox-tv-ios`.
4. Откройте **Users and Access → Integrations → App Store Connect API → +**.
5. Название ключа: `Codemagic`; Access: **App Manager**; нажмите Generate.
6. Сохраните показанные **Issuer ID** и **Key ID**.
7. Нажмите Download API Key. Файл `.p8` можно скачать только один раз; храните его вне GitHub.

### 4. Codemagic

1. Войдите на codemagic.io через GitHub.
2. Нажмите **Add application**, выберите GitHub и созданный repository.
3. Выберите **Codemagic YAML** и ветку `main`, затем **Check for configuration file**.
4. Откройте **Team settings → Environment variables** и создайте группу `appstore_credentials`.
5. Добавьте пять переменных:

```text
APPLE_TEAM_ID = Team ID из Apple Developer Membership details
APP_STORE_CONNECT_ISSUER_ID = Issuer ID со страницы App Store Connect API
APP_STORE_CONNECT_KEY_IDENTIFIER = Key ID созданного API key
APP_STORE_CONNECT_PRIVATE_KEY = полное текстовое содержимое файла AuthKey_*.p8
CERTIFICATE_PRIVATE_KEY = отдельный RSA private key для создания Apple Distribution certificate
```

`CERTIFICATE_PRIVATE_KEY` можно создать на Windows через OpenSSL (он входит, например, в Git for Windows):

```powershell
openssl genrsa -out ios_distribution_private_key 2048
Get-Content .\ios_distribution_private_key -Raw
```

Вставьте показанный PEM-текст в Codemagic и удалите локальный файл после сохранения секрета. Для ключей вставляйте весь текст вместе со строками `BEGIN ... PRIVATE KEY` и `END ... PRIVATE KEY`. Все пять переменных рекомендуется отметить **Secure/Secret**, оба private key — обязательно.

6. В Codemagic нажмите **Start new build**, выберите `main` и сначала workflow `ios-check`.
7. После успешной compile-проверки выберите `ios-testflight` и запустите его вручную.
8. При первом запуске Codemagic создаст или получит Apple Distribution certificate и App Store provisioning profile для Bundle ID.

Автоматический webhook запускает только `ios-check`. TestFlight workflow намеренно не имеет `triggering`, поэтому случайный commit не публикуется.

### 5. TestFlight и iPhone

1. После загрузки откройте App Store Connect → **My Apps → J1ROX TV → TestFlight**.
2. Дождитесь завершения Apple Processing. Иногда потребуется ответить на вопрос об использовании шифрования.
3. Для себя откройте **Internal Testing**, создайте группу и добавьте Apple ID пользователя из **Users and Access**.
4. На iPhone установите приложение **TestFlight** из App Store и войдите под тем же Apple ID.
5. Примите приглашение или откройте J1ROX TV в TestFlight и нажмите **Install**.

Создание Bundle ID, приложения App Store Connect, API key и использование TestFlight требуют активной Apple Developer Program. Без подписки workflow `ios-check` продолжает работать, но signing/archive/upload завершить нельзя.

## Диагностика CI

Codemagic сохраняет:

- `unsigned-build.log` с Swift filename/line errors;
- `archive.log` с signing и provisioning errors;
- `export.log` с ошибками создания IPA;
- IPA и dSYM после успешного экспорта.

Артефакты доступны на странице конкретного build в Codemagic. Ошибка публикации в App Store Connect происходит после создания IPA, поэтому готовый IPA остаётся среди artifacts.
