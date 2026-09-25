# Установка J1ROX TV на Samsung TV (Windows)

Проект: `C:\J1r0xTV\J1ROX_TV_Tizen`. Платформа: Samsung Tizen TV 4.0+.
Application ID: `J1ROXTV001.TV`, package ID: `J1ROXTV001`.

## Текущее состояние

На проверенном компьютере Tizen Studio / CLI / TV Extension не найдены в PATH,
стандартных каталогах и списке установленных программ. Подписанная сборка пока
не создана. `dist\J1ROX-TV-Samsung-unsigned.wgt` — только ZIP/WGT для проверки
структуры, без подписей, не предназначен для установки на телевизор.
Сертификаты автоматически не создавались.

## 1. SDK

Установите [Tizen Studio и Samsung TV SDK](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html).
В Package Manager нужны Web CLI, TV Extensions и Samsung Certificate Extension.
Используйте актуальную Certificate Extension: версии до 2.0.73 не поддерживают
создание сертификатов после сентября 2025 года. Типовой каталог — `C:\tizen-studio`.

Проверьте в PowerShell:

```powershell
& 'C:\tizen-studio\tools\ide\bin\tizen.bat' version
& 'C:\tizen-studio\tools\sdb.exe' version
```

## 2. Сеть и Developer Mode

Подключите компьютер и TV к одной локальной сети. Узнайте IPv4 компьютера:

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object InterfaceAlias, IPAddress
```

При проверке Wi-Fi компьютера имел адрес `172.20.10.3`, Ethernet 8 — `172.20.10.6`.
Это снимок состояния: выберите актуальный адрес адаптера в одной сети с TV.
Адрес телевизора смотрите в Настройки → Сеть → Состояние сети → Настройки IP
(названия пунктов зависят от модели); адрес TV пока неизвестен.

На TV откройте Smart Hub → Apps → App Settings и введите `12345` пультом
или экранной цифровой клавиатурой. На старых моделях ввод выполняется прямо
в Apps. Включите Developer Mode, укажите **IP компьютера**, подтвердите и
перезагрузите TV. В Apps должна появиться отметка Develop Mode.
Основание: [Samsung — подключение TV](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html).

## 3. Подключение устройства

Tizen Studio → Tools → Device Manager → Remote Device Manager → `+`:
задайте имя, **IP телевизора**, порт `26101`, затем Connection → On.
Проверка из PowerShell (замените пример своим адресом):

```powershell
$tvIp = '192.168.1.50'
Test-NetConnection -ComputerName $tvIp -Port 26101
& 'C:\tizen-studio\tools\sdb.exe' connect "${tvIp}:26101"
& 'C:\tizen-studio\tools\sdb.exe' devices
```

Сохраните serial из первого столбца `sdb devices`; он понадобится при установке.
Если соединения нет, проверьте IP компьютера в Developer Mode, перезагрузку TV,
изоляцию Wi-Fi-клиентов, VPN и разрешения Windows Firewall для SDK в частной сети.

## 4. Сертификат Samsung

Tools → Certificate Manager → `+` → **Samsung** → **TV**.
Создайте профиль, например `J1ROX-Samsung`, выберите существующий author certificate
или создайте свой с учётной записью Samsung. Создайте distributor certificate
с DUID подключённого телевизора. DUID доступен в Device Manager; убедитесь,
что он включён в сертификат. Сохраните author certificate и пароль отдельно:
они нужны для обновлений приложения. Не помещайте ключи и пароли в Git.

Сделайте профиль активным. В Device Manager нажмите правой кнопкой по TV →
**Permit to install applications**. Подробности: [Samsung — сертификаты](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html).

## 5. Проверки и сборка

```powershell
Set-Location -LiteralPath 'C:\J1r0xTV\J1ROX_TV_Tizen'
npm.cmd ci
npm.cmd run check
npm.cmd test
npm.cmd run test:browser
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build.ps1 -CertificateProfile 'J1ROX-Samsung'
```

Если SDK находится в другом месте, добавьте `-TizenCli 'D:\tizen-studio\tools\ide\bin\tizen.bat'`.
Скрипт копирует только runtime-файлы в отдельный staging-каталог, выполняет
`build-web` и `package -t wgt -s <profile>`. При ошибке он завершается без сообщения
об успешной сборке. Итоговый подписанный файл:

`C:\J1r0xTV\J1ROX_TV_Tizen\dist\J1ROX-TV-Samsung.wgt`

Без SDK можно проверить только структуру:

```powershell
python .\tools\package-unsigned.py
```

Это создаёт **другой** файл `J1ROX-TV-Samsung-unsigned.wgt` и файл статуса с SHA256.
Переименование unsigned-файла не добавляет подпись.

## 6. Установка и запуск

Используйте serial из `sdb devices`, а не пример ниже:

```powershell
$tvSerial = '192.168.1.50:26101'
& 'C:\tizen-studio\tools\ide\bin\tizen.bat' install -s $tvSerial -n 'J1ROX-TV-Samsung.wgt' -- 'C:\J1r0xTV\J1ROX_TV_Tizen\dist'
& 'C:\tizen-studio\tools\ide\bin\tizen.bat' run -s $tvSerial -p 'J1ROXTV001.TV'
```

Команды соответствуют [Samsung TV CLI](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/command-line-interface.html).
Альтернатива: импорт Web-проекта в Tizen Studio, затем Run As → Tizen Web Application.
Для диагностики используйте Debug As → Tizen Web Application, открывающий Web Inspector.

## 7. Диагностика

| Симптом | Проверка |
| --- | --- |
| CLI не найден | Установите Web CLI, проверьте путь к SDK |
| Профиль не найден | Certificate Manager: имя и активный профиль; `tizen cli-config -l` показывает конфигурацию CLI |
| 1010 / ошибка подписи | Samsung TV certificate, срок действия, DUID TV, Permit to install applications; пересоберите пакет |
| Обновление отклонено | Нужен прежний author certificate; удаление старого приложения может удалить локальный прогресс |
| 1013 / ошибка запуска | Проверьте application ID и перезагрузите TV |
| Каталог недоступен | Web Inspector → Network: HTTP status, TLS, DNS, CORS; приложение показывает ошибку и повтор |
| Видео не запускается | Зафиксируйте AVPlay error, источник, модель TV и прошивку; попробуйте другой источник |
| Работает в Chrome, не работает на TV | Проверьте CSP, WebAPI, модельные ограничения кодеков и реальную сеть TV |

В консоли Web Inspector включите подробные URL-логи:

```javascript
localStorage.setItem('j1rox.debug', '1');
location.reload();
// После диагностики:
localStorage.removeItem('j1rox.debug');
```

Логируются исходный API URL, итоговый URL ответа и HTTP status XHR, а также
разрешённый stream URL перед AVPlay.open. Полные URL могут содержать временные
токены: перед отправкой логов удалите их. AVPlay не предоставляет приложению
итоговый URL после CDN-redirect и HTTP status каждого сегмента; не подменяем их
догадками. Сетевой аудит с переходами по redirect:

```powershell
python .\tools\network-audit.py
```

Отчёт: `.build\network-audit.json`. Он проверяет HTTP/HLS, но не декодирование
на Samsung. HTTP и HTTPS сохраняются как у источника, TLS не отключается,
Origin/Referer/User-Agent не подделываются. Некоторые источники могут отказать
телевизору даже при работающем каталоге.

## 8. Проверка на реальном TV

Проверьте главную, оба каталога, поиск экранной клавиатурой, карточку, источники,
озвучки, сезоны и серии. Стрелки перемещают фокус; OK выбирает; Return возвращает.
В плеере OK показывает/скрывает панель, ↑/↓ выбирают действия панели и OK запускает
выбранное действие. ←/→ перематывают на 10 секунд; Play/Pause управляет просмотром.
Return сначала скрывает панель, затем закрывает плеер. Проверьте переход в следующий
сезон, восстановление прогресса после перезапуска, ошибки источника и возврат
после сворачивания. Оцените изображение, звук и синхронизацию минимум на одном
фильме и сериале. Эти проверки ещё не выполнены на физическом телевизоре.
