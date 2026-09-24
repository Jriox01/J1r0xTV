# J1ROX TV: первая проверка в Codemagic

## Реальные параметры проекта

| Параметр | Значение |
| --- | --- |
| Xcode project | `J1ROX_TV_iOS/J1ROXTV.xcodeproj` |
| Workspace | Отсутствует; используется `-project` |
| Shared scheme | `J1ROXTV` |
| Target / product | `J1ROXTV` / `J1ROXTV.app` |
| Bundle ID | `com.jirox.jiroxtv` |
| Deployment target | iOS 16.0 (Debug и Release) |
| Swift language mode | 5.0 |
| CI machine / Xcode | `mac_mini_m2` / `latest` |

Scheme уже находится в `J1ROXTV.xcodeproj/xcshareddata/xcschemes/J1ROXTV.xcscheme`,
ссылается на существующий target `A10000000000000000000008` и отслеживается Git.
Новый target или scheme не создавался. Проект использует synchronized groups
Xcode 16: Swift-файлы каталога `J1ROXTV` автоматически входят в target; пустой
массив `PBXSourcesBuildPhase.files` в данном формате не означает отсутствие кода.

Внешних SPM packages, CocoaPods и Carthage нет. `pod install`, новый workspace,
`Package.resolved` и отдельное разрешение пакетов не требуются.

## Запуск

1. Закоммитьте подготовленные изменения приложения, тестов и CI, затем выполните
   push в `main`. Один `git push` без commit не отправляет рабочие изменения.
2. В Codemagic подключите GitHub-репозиторий и используйте конфигурацию
   **codemagic.yaml** из корня. Для первой сборки выберите ветку `main` и workflow
   **ios-check**, затем **Start new build**.
3. Для последующих автоматических сборок проверьте, что интеграция GitHub создала
   webhook Codemagic. YAML объявляет push/PR в `main` и фильтр изменений iOS/CI.
   Push в другую ветку этим workflow автоматически не запускается; её можно
   выбрать при ручном запуске.

Правила YAML/webhook сверены с официальной документацией:
[Codemagic YAML](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/),
[автоматический запуск](https://docs.codemagic.io/yaml-running-builds/starting-builds-automatically/).

Никакие пользовательские environment variables или Apple signing credentials
для **ios-check** не нужны. `CM_BUILD_DIR` предоставляет Codemagic;
`XCODE_PROJECT=J1ROXTV.xcodeproj` и `XCODE_SCHEME=J1ROXTV` объявлены в YAML.
Доступ к закрытому GitHub-репозиторию настраивается через интеграцию Codemagic,
а не через токен в исходниках. `latest` выбирает актуальный образ; фактическая
версия Xcode/Swift записывается в лог каждой сборки.

## Этапы

1. **Diagnostics**: Xcode/Swift version, commit SHA, `xcodebuild -list`,
   `-showBuildSettings` (scheme/target, SDK, deployment target, bundle ID).
2. **BUILD — Debug Simulator**: полноценная компиляция приложения и ресурсов.
3. **ARTIFACT**: ZIP реального `.app` до изменения тестами его Info.plist.
4. **BUILD — Release device**: компиляция для `iphoneos`, без подписи,
   с `SWIFT_STRICT_CONCURRENCY=complete`.
5. **TESTS**: существующие standalone-тесты провайдеров/плеера/загрузок/серий
   в Debug и Release на macOS; затем HLS и загрузки в iPhone Simulator.
   У scheme нет XCTest target, поэтому вместо фиктивного `xcodebuild test`
   используются существующие исполняемые регрессионные скрипты.

Первая реальная команда сборки после перехода в `J1ROX_TV_iOS`:

```sh
xcodebuild -project J1ROXTV.xcodeproj -scheme J1ROXTV \
  -configuration Debug -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build/DerivedData-debug \
  -resultBundlePath build/results/debug-build.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SWIFT_SUPPRESS_WARNINGS=NO GCC_WARN_INHIBIT_ALL_WARNINGS=NO \
  build 2>&1 | tee build/logs/debug-build.log
```

Все этапы используют `set -euo pipefail`: `tee` не скрывает код ошибки компилятора.
Предупреждения не подавляются и не превращаются искусственно в ошибки.
При ошибке Debug сборки тесты не запускаются. При успешной Debug, но ошибке
Release, ZIP симулятора уже создан. Если сборки прошли, сбой отдельного набора
тестов не мешает запустить остальные; итоговый TESTS-этап всё равно завершается
ошибкой при любом FAIL. `regression-summary.txt` отличает ошибки тестов от build.

## Артефакты и поиск ошибок

- `J1ROXTV-Debug-iphonesimulator.zip`: настоящий simulator `.app`, для запуска на
  совместимом iOS Simulator на Mac. Это не IPA для iPhone.
- `xcode-environment.log`: версии, SHA, target и build settings.
- `debug-build.log`, `unsigned-build.log`: полный вывод компиляции с errors/warnings.
- `debug-build.xcresult`, `release-build.xcresult`, `.xcactivitylog`: диагностика Xcode.
- `provider-and-series.log`, отдельные compile/runtime логи тестов,
  `hls-simulator.log`, `download-simulator.log`, JSON/скриншоты smoke-тестов.
- `regression-summary.txt`: PASS/FAIL каждого набора.

После ошибки пришлите соответствующий полный build log или test log и summary.
Ошибка сборки приложения будет в этапе **BUILD**, тестов — в **TESTS**.

Для штатно устанавливаемого device IPA впоследствии понадобятся сертификат и
provisioning profile. Существующие `ios-ipa` и `ios-testflight` сохранены;
их не нужно выбирать для первой проверки. Секреты TestFlight передаются через
secure environment group Codemagic, они не нужны этому workflow и в Git не добавляются.

## Что обнаружено до удалённого запуска

- Раньше тесты предшествовали app build: их ошибка могла скрыть ошибки SwiftUI.
  Теперь обе компиляции выполняются до тестов.
- Не сохранялся simulator `.app`; добавлен проверяемый ZIP без подписи.
- Отсутствовал явный вывод версии Xcode; добавлен вместе с build settings.
- Новые `SeriesTests.swift` должны попасть в commit вместе с обновлённым runner.
- Для работы synchronized groups нужен Xcode 16+; выбран актуальный образ.
- Windows CRLF могут ломать bash; `.gitattributes` фиксирует LF для `.sh` и YAML.
- Для цепочки `compactMap`/`sorted` вариантов загрузки явно указан возвращаемый
  `DownloadVariant?`, чтобы не полагаться на вывод generic-типа Swift.
- Все функции последнего изменения сохранены. Компиляция и warnings оцениваются
  настоящим Swift compiler на CI; локальная структурная проверка их не заменяет.

Локально на Windows проверяются YAML, bash-синтаксис всех CI-команд и скриптов,
shared scheme/target references, plist/assets, наличие необходимых файлов в Git,
а также поведение runner при PASS и FAIL. Настройка аккаунта/webhook и запуск
удалённой сборки не выполнялись из этой сессии.
