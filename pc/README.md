# J1r0x TV PC

Windows desktop application written in Python with PySide6 and VLC.

## Run

```powershell
cd C:\J1r0xTV\pc
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe main.py
```

VLC must be installed for desktop playback.

## Build

Run from this directory:

```powershell
.\.venv\Scripts\pyinstaller.exe "J1r0x TV.spec"
```

The optional Inno Setup script is `J1r0xTV.iss`.
