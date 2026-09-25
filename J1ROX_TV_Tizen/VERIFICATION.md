# Проверка Samsung Tizen клиента — 25 сентября 2026

## Восстановленное состояние

Исходный HEAD: `508f746` (`fix: resolve SharePlay iOS build errors`), ветка main.
Единственное незакоммиченное изменение — весь каталог `J1ROX_TV_Tizen/`.
До продолжения уже существовали HTML/CSS, 6 JS-модулей, изображения, 12 unit-тестов,
браузерные тесты, network-audit.py, check.cjs и подписывающий build.ps1.
Инструкции установки, lockfile и unsigned-сборки не было. TODO/FIXME не найдены.
Изучены runtime, тесты, инструменты, конфигурация, изображения и контракты
MediaRepository.kt / AtodoProvider.swift. Существующие проекты не изменены.

## Исправления и дополнения

- Завершённый просмотр больше не перезаписывается обработчиком паузы/времени.
- Ответ загрузки главной не перехватывает фокус в диалоге выхода.
- Быстрые нажатия перемотки суммируются при незавершённом AVPlay.seekTo.
- Заставка TV отключается во время просмотра, включается на паузе и при закрытии.
- Явная CSP в config.xml: локальные скрипты/WebAPI, API по HTTPS, динамические
  HTTP/HTTPS CDN для изображений и видео. Браузерный тест применяет ту же политику
  HTTP-заголовком; поведение WebAPI/CSP на самом TV ещё нужно проверить.
- DEBUG исходных/конечных API URL, HTTP status и stream URL; полные URL только
  при `localStorage['j1rox.debug'] = '1'`. Ошибки AVPlay показываются пользователю.
- Добавлены lockfile, установка для Windows, обзор проекта, unsigned packager
  с проверкой XML/ZIP и явным файлом статуса.

## Выполненные проверки

| Проверка | Результат |
| --- | --- |
| npm install | 0 найденных уязвимостей при установке |
| npm run check | Все 6 runtime JS проходят ES5 parser и проверку ссылок на ресурсы |
| npm test | 13/13, включая гонку повторных seek и отмену позднего prepare |
| npm run test:browser | PASS, Chromium с AVPlay test double, без JS исключений |
| Навигация | Каталог, поиск, горизонтальная прокрутка и сохранение видимого фокуса |
| Выбор | Озвучки, сезоны, серии, отсутствие выбранной серии явно блокирует Play |
| Player-сценарии | HLS URL → AVPlay, pause, seek, resume, следующая серия/сезон, ошибка, Back |
| Библиотека | Избранное после reload, прогресс без CDN-токенов, завершение просмотра |
| UI | 1920×1080 и масштаб сцены 2× при 3840×2160 |
| Гонки UI | Поздний каталог не закрывает подтверждение выхода |
| Live API в браузере | Главная и фильмы/сериалы, details, sources, voices и resolve без подмены Origin |
| config.xml / unsigned ZIP | XML разобран; ID, профиль, CSP, entry point, CRC и состав архива проверены |
| Tizen build.ps1 | Завершился с явным `Tizen CLI not found`; SDK-сборки нет |

Синтетические ответы используются только в тестах. Проверка AVPlay test double
не является декодированием видео или проверкой аппаратного пульта.

## Реальная сеть

Аудит `.build/network-audit.json`, время начала `2026-09-25T14:37:51Z`.
TLS проверялся штатно, Origin: null. API ответил HTTP 200, CORS `*`.
В live Chromium также успешно получены настоящие источники и stream URL.
При проверке изображений загрузились 11 из 38 постеров, остальные ещё ожидались;
подставленных заглушек на момент снимка не было. Полная загрузка всех постеров
не подтверждена, внешний CDN изображений может отвечать медленно.

| Образец | Результат |
| --- | --- |
| movie 550 / jator | 1 озвучка, HLS master + 4 variant playlist: 200; 12 образцов сегментов: 206 |
| tv 1399 / jator | 8 озвучек, 7 сезонов в первой; 10 серий в первом сезоне; HLS master + 3 variants: 200; 9 образцов сегментов: 206 |
| movie 550 / xinu | HTTP stream URL получен, проба ресурса вернула 400 |
| tv 1399 / xinu | Источник вернул 404 |

У jator master имеет ошибочный Content-Type `text/html; charset=UTF-8`, хотя
тело начинается с `#EXTM3U`; дочерние playlists имеют корректный HLS MIME.
Это возможный риск совместимости AVPlay, а не доказанный сбой на TV.
В проверенных HLS нет HTTP-вложений или redirect; аудит умеет следовать redirect,
но работоспособность непроверенных CDN из этого не следует. CODECS отсутствуют
в master, декодирование/звук и фактические кодеки на телевизоре не проверены.

## Артефакты и оставшиеся шаги

`dist/J1ROX-TV-Samsung-unsigned.wgt` содержит только 11 runtime-файлов.
Это **неподписанный структурный архив**, не результат Tizen CLI и не устанавливаемая
сборка. SHA256 записан рядом в `.status.txt`. Артефакты и локальные сетевые отчёты
игнорируются Git; воспроизводятся скриптами.

Tizen SDK/CLI, TV Extension и сертификат профиля не обнаружены; TV не подключён.
Осталось установить SDK с расширениями, настроить Samsung certificate с DUID TV,
создать подписанный `dist/J1ROX-TV-Samsung.wgt`, установить и выполнить аппаратные
проверки по [SAMSUNG-TV-INSTALL.md](SAMSUNG-TV-INSTALL.md). Нельзя считать, что
осталась только подпись: аппаратные проверки и SDK-сборка ещё не выполнялись.

Ссылки на использованную документацию:

- [Samsung AVPlay](https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html)
- [Samsung Screensaver](https://developer.samsung.com/smarttv/develop/guides/fundamentals/setting-screensaver.html)
- [Samsung CLI](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/command-line-interface.html)
