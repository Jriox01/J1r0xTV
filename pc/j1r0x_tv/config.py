APP_NAME = "J1r0x TV"
import os
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def get_app_data_dir() -> Path:
    base = os.getenv("LOCALAPPDATA")
    if base:
        root = Path(base)
    else:
        root = Path.home() / "AppData" / "Local"

    app_dir = root / "J1r0x TV"
    app_dir.mkdir(parents=True, exist_ok=True)
    return app_dir


API_BASE = "https://api.atodo.fun/"
REQUEST_TIMEOUT = 20
POSTER_WIDTH = 180
POSTER_HEIGHT = 270
