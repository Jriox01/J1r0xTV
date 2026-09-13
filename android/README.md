# J1r0x TV Android

Нативное Kotlin-приложение для Android 5.0+ (телефоны, планшеты, Android TV и Google TV).

## Сборка

Откройте каталог `android` в Android Studio или выполните:

```powershell
.\gradlew.bat testDebugUnitTest assembleDebug
.\gradlew.bat assembleRelease bundleRelease
```

Артефакты находятся в `app/build/outputs/apk` и `app/build/outputs/bundle`.
Текущая release-сборка подписывается debug-ключом только для тестовой ручной установки. Перед публикацией замените `signingConfig` на собственный защищённый keystore.
