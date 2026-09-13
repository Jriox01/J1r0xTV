import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .config import get_app_data_dir
from .models import MediaItem
from .utils import parse_media_item


class LocalDatabase:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or get_app_data_dir() / "data" / "j1r0xtv.db"
        self.init_database()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def init_database(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS favorites (
                    media_id TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    original_title TEXT NOT NULL DEFAULT '',
                    poster_url TEXT NOT NULL DEFAULT '',
                    backdrop_url TEXT NOT NULL DEFAULT '',
                    year TEXT NOT NULL DEFAULT '',
                    rating TEXT NOT NULL DEFAULT '',
                    raw_json TEXT NOT NULL DEFAULT '{}',
                    added_at TEXT NOT NULL,
                    PRIMARY KEY (media_id, media_type)
                );

                CREATE TABLE IF NOT EXISTS watch_history (
                    media_id TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    original_title TEXT NOT NULL DEFAULT '',
                    poster_url TEXT NOT NULL DEFAULT '',
                    backdrop_url TEXT NOT NULL DEFAULT '',
                    year TEXT NOT NULL DEFAULT '',
                    rating TEXT NOT NULL DEFAULT '',
                    raw_json TEXT NOT NULL DEFAULT '{}',
                    source_id TEXT NOT NULL DEFAULT '',
                    provider_id TEXT NOT NULL DEFAULT '',
                    translation_id TEXT NOT NULL DEFAULT '',
                    translation_name TEXT NOT NULL DEFAULT '',
                    season TEXT NOT NULL DEFAULT '',
                    episode TEXT NOT NULL DEFAULT '',
                    stream_url TEXT NOT NULL DEFAULT '',
                    position_ms INTEGER NOT NULL DEFAULT 0,
                    duration_ms INTEGER NOT NULL DEFAULT 0,
                    progress REAL NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (media_id, media_type, season, episode)
                );
                """
            )
            columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(watch_history)")
            }
            for name in ("provider_id", "translation_id"):
                if name not in columns:
                    connection.execute(
                        f"ALTER TABLE watch_history ADD COLUMN {name} TEXT NOT NULL DEFAULT ''"
                    )

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).isoformat()

    @staticmethod
    def _raw_json(item: MediaItem) -> str:
        try:
            return json.dumps(item.raw or {}, ensure_ascii=False)
        except (TypeError, ValueError):
            return "{}"

    def is_favorite(self, media_id: str, media_type: str) -> bool:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT 1 FROM favorites WHERE media_id=? AND media_type=?",
                (str(media_id), media_type),
            ).fetchone()
        return row is not None

    def toggle_favorite(self, item: MediaItem) -> bool:
        if self.is_favorite(item.item_id, item.media_type):
            with self.connect() as connection:
                connection.execute(
                    "DELETE FROM favorites WHERE media_id=? AND media_type=?",
                    (item.item_id, item.media_type),
                )
            return False

        with self.connect() as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO favorites
                (media_id, media_type, title, original_title, poster_url,
                 backdrop_url, year, rating, raw_json, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item.item_id, item.media_type, item.title,
                    item.original_title, item.poster_url, item.backdrop_url,
                    item.year, item.rating, self._raw_json(item), self._now(),
                ),
            )
        return True

    def get_favorites(self) -> list[MediaItem]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM favorites ORDER BY added_at DESC"
            ).fetchall()
        return [self._row_to_item(row) for row in rows]

    def get_favorite_keys(self) -> set[tuple[str, str]]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT media_id, media_type FROM favorites"
            ).fetchall()
        return {(str(row["media_id"]), row["media_type"]) for row in rows}

    @staticmethod
    def _decode_raw(value: str) -> dict[str, Any]:
        try:
            result = json.loads(value or "{}")
            return result if isinstance(result, dict) else {}
        except (TypeError, ValueError):
            return {}

    def _row_to_item(self, row: sqlite3.Row) -> MediaItem:
        raw = self._decode_raw(row["raw_json"])
        item = parse_media_item(raw, row["media_type"]) if raw else MediaItem(
            str(row["media_id"]), row["media_type"], row["title"]
        )
        item.item_id = str(row["media_id"])
        item.media_type = row["media_type"]
        item.title = row["title"]
        item.original_title = row["original_title"]
        item.poster_url = row["poster_url"]
        item.backdrop_url = row["backdrop_url"]
        item.year = row["year"]
        item.rating = row["rating"]
        item.raw = raw
        return item

    def save_history(
        self,
        item: MediaItem,
        source_id: str = "",
        provider_id: str = "",
        translation_id: str = "",
        translation_name: str = "",
        season: str = "",
        episode: str = "",
        stream_url: str = "",
        position_ms: int = 0,
        duration_ms: int = 0,
    ) -> None:
        progress = position_ms / duration_ms if duration_ms > 0 else 0.0
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO watch_history
                (media_id, media_type, title, original_title, poster_url,
                 backdrop_url, year, rating, raw_json, source_id,
                 provider_id, translation_id, translation_name, season, episode,
                 stream_url, position_ms,
                 duration_ms, progress, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_id, media_type, season, episode) DO UPDATE SET
                    title=excluded.title, original_title=excluded.original_title,
                    poster_url=excluded.poster_url, backdrop_url=excluded.backdrop_url,
                    year=excluded.year, rating=excluded.rating,
                    raw_json=excluded.raw_json, source_id=excluded.source_id,
                    provider_id=excluded.provider_id,
                    translation_id=excluded.translation_id,
                    translation_name=excluded.translation_name,
                    stream_url=excluded.stream_url, position_ms=excluded.position_ms,
                    duration_ms=excluded.duration_ms, progress=excluded.progress,
                    updated_at=excluded.updated_at
                """,
                (
                    item.item_id, item.media_type, item.title, item.original_title,
                    item.poster_url, item.backdrop_url, item.year, item.rating,
                    self._raw_json(item), source_id, provider_id, translation_id,
                    translation_name,
                    season, episode, stream_url, max(0, int(position_ms)),
                    max(0, int(duration_ms)), max(0.0, progress), self._now(),
                ),
            )

    def update_watch_progress(
        self,
        media_id: str,
        media_type: str,
        season: str,
        episode: str,
        position_ms: int,
        duration_ms: int,
    ) -> None:
        progress = position_ms / duration_ms if duration_ms > 0 else 0.0
        if duration_ms > 0 and progress >= 0.90:
            self.remove_history(media_id, media_type, season, episode)
            return
        with self.connect() as connection:
            connection.execute(
                """
                UPDATE watch_history SET position_ms=?, duration_ms=?,
                    progress=?, updated_at=?
                WHERE media_id=? AND media_type=? AND season=? AND episode=?
                """,
                (
                    max(0, int(position_ms)), max(0, int(duration_ms)),
                    max(0.0, progress), self._now(), str(media_id), media_type,
                    season, episode,
                ),
            )

    def remove_history(
        self,
        media_id: str,
        media_type: str,
        season: str = "",
        episode: str = "",
    ) -> None:
        with self.connect() as connection:
            connection.execute(
                """DELETE FROM watch_history
                   WHERE media_id=? AND media_type=? AND season=? AND episode=?""",
                (str(media_id), media_type, season, episode),
            )

    def clear_history(self) -> None:
        with self.connect() as connection:
            connection.execute("DELETE FROM watch_history")

    def get_history(self) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                """SELECT * FROM watch_history
                   WHERE progress < 0.90 ORDER BY updated_at DESC"""
            ).fetchall()
        result = []
        for row in rows:
            entry = dict(row)
            entry["item"] = self._row_to_item(row)
            result.append(entry)
        return result
