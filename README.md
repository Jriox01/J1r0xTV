# J1r0x TV

This repository contains two independent applications:

- `/pc` — Windows desktop version (Python, PySide6, VLC).
- `/android` — Android, Android TV, Google TV, phone, and tablet version (Kotlin, Jetpack Compose, Media3).

Neither application imports files from the other.

## PC

```powershell
cd C:\J1r0xTV\pc
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe main.py
```

Build the Windows application from `C:\J1r0xTV\pc`:

```powershell
.\.venv\Scripts\pyinstaller.exe "J1r0x TV.spec"
```

## Android

Build and test using only the Android directory:

```powershell
cd C:\J1r0xTV\android
.\gradlew.bat testDebugUnitTest assembleDebug
```

Release artifacts can be built with:

```powershell
.\gradlew.bat assembleRelease bundleRelease
```
