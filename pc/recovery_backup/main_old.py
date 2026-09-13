import json
import base64
import urllib.parse
import re
import os
import sys
import threading
from dataclasses import dataclass
from typing import Any

import requests
import vlc
from PySide6.QtCore import Qt, Signal, QObject, QThread, QSize, QUrl
from PySide6.QtGui import QPixmap, QIcon
from PySide6.QtWidgets import (
    QApplication,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
    QComboBox,
    QSlider,
)


try:
    from PySide6.QtWebEngineWidgets import QWebEngineView
    WEB_ENGINE_AVAILABLE = True
except ImportError:
    QWebEngineView = None
    WEB_ENGINE_AVAILABLE = False

APP_NAME = "J1r0x TV"
API_BASE = "https://api.atodo.fun/"
REQUEST_TIMEOUT = 20
POSTER_WIDTH = 180
POSTER_HEIGHT = 270


@dataclass
class MediaItem:
    item_id: str
    media_type: str
    title: str
    original_title: str = ""
    overview: str = ""
    poster_url: str = ""
    backdrop_url: str = ""
    year: str = ""
    rating: str = ""
    raw: dict[str, Any] | None = None


def first_value(data: dict[str, Any], keys: tuple[str, ...], default: Any = "") -> Any:
    for key in keys:
        value = data.get(key)
        if value not in (None, "", [], {}):
            return value
    return default


def absolute_image_url(value: str) -> str:
    value = str(value or "").strip()
    if not value:
        return ""

    if value.startswith("//"):
        return "https:" + value

    if value.startswith(("http://", "https://")):
        return value

    if value.startswith("/"):
        return "https://image.tmdb.org/t/p/w500" + value

    return value


def unwrap_items(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]

    if not isinstance(payload, dict):
        return []

    candidates = (
        "results",
        "items",
        "data",
        "movies",
        "content",
        "list",
        "docs",
    )

    for key in candidates:
        value = payload.get(key)

        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]

        if isinstance(value, dict):
            nested = unwrap_items(value)
            if nested:
                return nested

    return []


def parse_media_item(data: dict[str, Any], fallback_type: str = "movie") -> MediaItem:
    media_type = str(
        first_value(data, ("media_type", "type_movie"), fallback_type)
    ).lower()

    if media_type not in ("movie", "tv"):
        media_type = fallback_type

    item_id = str(
        first_value(data, ("id", "movie_id", "tmdb_id", "kinopoisk_id", "kp_id"), "")
    )

    title = str(
        first_value(
            data,
            (
                "title",
                "name",
                "title_ru",
                "name_ru",
                "localized_name",
                "label",
            ),
            "Без названия",
        )
    )

    original_title = str(
        first_value(
            data,
            ("original_title", "original_name", "title_en", "name_en"),
            "",
        )
    )

    overview = str(
        first_value(
            data,
            ("overview", "description", "plot", "about", "text"),
            "",
        )
    )

    poster_url = absolute_image_url(
        str(
            first_value(
                data,
                ("poster_path", "poster", "poster_url", "image", "cover"),
                "",
            )
        )
    )

    backdrop_url = absolute_image_url(
        str(
            first_value(
                data,
                ("backdrop_path", "backdrop", "backdrop_url", "background"),
                "",
            )
        )
    )

    date_value = str(
        first_value(
            data,
            ("release_date", "first_air_date", "year", "premiere"),
            "",
        )
    )
    year = date_value[:4] if date_value else ""

    rating_value = first_value(
        data,
        ("vote_average", "rating", "kinopoisk_rating", "imdb_rating"),
        "",
    )
    rating = str(rating_value)[:4] if rating_value not in ("", None) else ""

    return MediaItem(
        item_id=item_id,
        media_type=media_type,
        title=title,
        original_title=original_title,
        overview=overview,
        poster_url=poster_url,
        backdrop_url=backdrop_url,
        year=year,
        rating=rating,
        raw=data,
    )


@dataclass
class SourceOption:
    source_id: str
    name: str
    raw: dict[str, Any]


def js_query_value(value: Any) -> str:
    """Повторяет преобразование значения в строку из JavaScript encodeURIComponent."""
    if value is None:
        return "null"

    if value is True:
        return "true"

    if value is False:
        return "false"

    if isinstance(value, dict):
        return "[object Object]"

    if isinstance(value, (list, tuple)):
        return ",".join(js_query_value(item) for item in value)

    return str(value)


def build_exact_source_params(item: MediaItem) -> dict[str, str]:
    """
    Atodo передаёт в sourceGet весь объект info почти без изменений.
    JavaScript превращает вложенные объекты в '[object Object]',
    а массивы — в строку через запятую.
    """
    raw = dict(item.raw or {})

    raw.pop("continue", None)
    raw.pop("poster_path", None)
    raw.pop("backdrop_path", None)

    if "id" not in raw and item.item_id:
        raw["id"] = item.item_id

    if item.media_type == "tv":
        raw.setdefault("media_type", "tv")
        raw.setdefault("type_movie", "tv")
    else:
        raw.setdefault("media_type", "movie")
        raw.setdefault("type_movie", "movie")

    return {
        str(key): js_query_value(value)
        for key, value in raw.items()
    }


def build_atodo_info(item: MediaItem) -> dict[str, Any]:
    """Точный объект info, который формирует оригинальный Atodo main.js."""
    raw = item.raw or {}
    external_ids = raw.get("external_ids")

    imdb_id = raw.get("imdb_id")
    if not imdb_id and isinstance(external_ids, dict):
        imdb_id = external_ids.get("imdb_id")

    title = str(
        first_value(
            raw,
            ("title", "name"),
            item.title,
        )
    )
    original_title = str(
        first_value(
            raw,
            ("original_title", "original_name"),
            item.original_title,
        )
    )
    date_value = str(
        first_value(
            raw,
            ("release_date", "first_air_date"),
            item.year,
        )
    )
    year = date_value[:4] if date_value else item.year

    return {
        "id": item.item_id,
        "title": title,
        "original_title": original_title,
        "original_language": raw.get("original_language"),
        "imdb_id": imdb_id,
        "year": year,
        "poster_path": raw.get("poster_path"),
        "backdrop_path": raw.get("backdrop_path"),
        "type": "movie" if item.media_type == "movie" else "tv",
    }


def build_source_params(item: MediaItem) -> dict[str, Any]:
    raw = item.raw or {}
    media_type = item.media_type if item.media_type in ("movie", "tv") else "movie"

    title = str(
        first_value(
            raw,
            ("title", "name", "title_ru", "name_ru"),
            item.title,
        )
    )
    original_title = str(
        first_value(
            raw,
            ("original_title", "original_name", "title_en", "name_en"),
            item.original_title,
        )
    )

    external_ids = raw.get("external_ids")
    imdb_id = raw.get("imdb_id")

    if not imdb_id and isinstance(external_ids, dict):
        imdb_id = external_ids.get("imdb_id")

    date_value = str(
        first_value(
            raw,
            ("release_date", "first_air_date", "year"),
            item.year,
        )
    )
    year = date_value[:4] if date_value else item.year

    params: dict[str, Any] = {
        "id": item.item_id,
        "type": media_type,
        "type_movie": media_type,
        "title": title,
        "name": title,
        "original_title": original_title,
        "original_name": original_title,
        "original_language": raw.get("original_language"),
        "imdb_id": imdb_id,
        "kinopoisk_id": raw.get("kinopoisk_id"),
        "year": year,
        "release_date": raw.get("release_date"),
        "first_air_date": raw.get("first_air_date"),
    }

    return {
        key: value
        for key, value in params.items()
        if value not in (None, "")
    }


def unwrap_source_data(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {}

    if isinstance(payload.get("data"), dict):
        return payload["data"]

    return payload


def normalize_stream_url(value: str) -> str:
    value = str(value or "").strip()
    value = value.replace("\\/", "/")

    if "|" in value:
        value = value.split("|", 1)[0].strip()

    if value.startswith("//"):
        value = "https:" + value

    return value


def extract_stream_candidates(value: Any) -> list[str]:
    result: list[str] = []
    visited_strings: set[str] = set()

    media_markers = (
        ".m3u8",
        ".mp4",
        ".mkv",
        ".webm",
        ".avi",
        ".ts",
        ".mpd",
        "manifest",
        "playlist",
        "stream",
    )

    url_pattern = re.compile(
        r'(?:(?:https?:)?//)[^\s\'"<>]+',
        re.IGNORECASE,
    )

    def add_candidate(candidate: str, parent_key: str = "") -> None:
        candidate = normalize_stream_url(candidate)

        if not candidate.startswith(("http://", "https://")):
            return

        lowered = candidate.lower()
        key_markers = (
            "url",
            "src",
            "file",
            "stream",
            "video",
            "hls",
            "dash",
            "playlist",
        )

        if (
            any(marker in lowered for marker in media_markers)
            or any(marker in parent_key for marker in key_markers)
        ):
            if candidate not in result:
                result.append(candidate)

    def inspect_string(raw: str, parent_key: str) -> None:
        raw = raw.strip()

        if not raw or raw in visited_strings:
            return

        visited_strings.add(raw)
        cleaned = raw.replace("\\/", "/")

        add_candidate(cleaned, parent_key)

        for match in url_pattern.findall(cleaned):
            add_candidate(match, parent_key)

        try:
            decoded_url = urllib.parse.unquote(cleaned)

            if decoded_url != cleaned:
                add_candidate(decoded_url, parent_key)

                for match in url_pattern.findall(decoded_url):
                    add_candidate(match, parent_key)

        except Exception:
            pass

        if cleaned[:1] in ("{", "["):
            try:
                walk(json.loads(cleaned), parent_key)
            except Exception:
                pass

        compact = cleaned.strip()

        if (
            len(compact) >= 16
            and len(compact) % 4 == 0
            and re.fullmatch(r"[A-Za-z0-9+/=_-]+", compact)
        ):
            for candidate_b64 in (
                compact,
                compact.replace("-", "+").replace("_", "/"),
            ):
                try:
                    padding = "=" * (-len(candidate_b64) % 4)
                    decoded = base64.b64decode(
                        candidate_b64 + padding,
                        validate=False,
                    ).decode("utf-8", errors="ignore").strip()

                    if decoded and decoded != cleaned:
                        inspect_string(decoded, parent_key)

                except Exception:
                    continue

    def walk(node: Any, parent_key: str = "") -> None:
        if isinstance(node, dict):
            for key in (
                "streams",
                "stream",
                "file",
                "url",
                "src",
                "hls",
                "dash",
            ):
                if key in node:
                    walk(node[key], key)

            for key, child in node.items():
                walk(child, str(key).lower())

            return

        if isinstance(node, (list, tuple, set)):
            for child in node:
                walk(child, parent_key)

            return

        if isinstance(node, str):
            inspect_string(node, parent_key)

    walk(value)
    return result


def extract_web_player_candidates(value: Any) -> list[str]:
    """Ищет ссылки на встроенный веб-плеер или iframe."""
    result: list[str] = []

    def walk(node: Any, parent_key: str = "") -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                walk(child, str(key).lower())
            return

        if isinstance(node, (list, tuple)):
            for child in node:
                walk(child, parent_key)
            return

        if not isinstance(node, str):
            return

        candidate = node.strip()

        if not candidate.startswith(("http://", "https://")):
            return

        lowered = candidate.lower()

        # Исключаем картинки и API-эндпоинты.
        if any(
            extension in lowered
            for extension in (
                ".jpg",
                ".jpeg",
                ".png",
                ".webp",
                ".gif",
                "/api/",
            )
        ):
            return

        key_markers = (
            "iframe",
            "embed",
            "player",
            "url",
            "link",
            "src",
            "html",
        )

        url_markers = (
            "player",
            "embed",
            "video",
            "watch",
            "iframe",
        )

        if (
            any(marker in parent_key for marker in key_markers)
            or any(marker in lowered for marker in url_markers)
        ):
            if candidate not in result:
                result.append(candidate)

    walk(value)
    return result


def choose_best_stream(urls: list[str]) -> str:
    if not urls:
        return ""

    priorities = (".m3u8", ".mp4", ".mkv", ".webm")

    for extension in priorities:
        for url in urls:
            if extension in url.lower():
                return url

    return urls[0]



class SourceUnavailableError(RuntimeError):
    pass


def encode_js_component(value: Any) -> str:
    """
    Аналог JavaScript encodeURIComponent для строковых значений.
    """
    return urllib.parse.quote(
        str(value),
        safe="-_.!~*'()",
        encoding="utf-8",
        errors="strict",
    )


def build_js_query(params: dict[str, Any]) -> str:
    parts: list[str] = []

    for key, value in params.items():
        if value is None:
            continue

        parts.append(
            f"{encode_js_component(key)}={encode_js_component(value)}"
        )

    return "&".join(parts)




class ApiClient:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.last_source_info: dict[str, Any] = {}
        self.session.headers.update(
            {
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
                "Origin": "https://atodo.fun",
                "Referer": "https://atodo.fun/fun.html",
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-origin",
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/150.0.0.0 Safari/537.36"
                ),
            }
        )

    def get_json(self, path: str, params: dict[str, Any] | None = None) -> Any:
        url = API_BASE.rstrip("/") + "/" + path.lstrip("/")
        response = self.session.get(
            url,
            params=params,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        return response.json()

    def get_json_exact(
        self,
        path: str,
        params: dict[str, Any],
    ) -> Any:
        """
        Формирует URL точно как функция G() из оригинального main.js.
        """
        base_url = API_BASE.rstrip("/") + "/" + path.lstrip("/")
        query = build_js_query(params)
        url = f"{base_url}?{query}" if query else base_url

        response = self.session.get(
            url,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        return response.json()

    def list_media(self, media_type: str, page: int = 1) -> list[MediaItem]:
        payload = self.get_json(
            "api/list",
            {"type_movie": media_type, "page": page},
        )
        return [
            parse_media_item(item, media_type)
            for item in unwrap_items(payload)
        ]

    def search(self, query: str, page: int = 1) -> list[MediaItem]:
        payload = self.get_json(
            "api/search",
            {"query": query, "page": page},
        )
        return [
            parse_media_item(item)
            for item in unwrap_items(payload)
        ]

    def details(self, media_type: str, item_id: str) -> MediaItem:
        payload = self.get_json(f"api/details/{media_type}/{item_id}")

        if isinstance(payload, dict):
            for key in ("data", "result", "item", "movie"):
                nested = payload.get(key)
                if isinstance(nested, dict):
                    payload = nested
                    break

        if not isinstance(payload, dict):
            raise RuntimeError("Сервер вернул неизвестный формат карточки.")

        item = parse_media_item(payload, media_type)

        # Сохраняем полную карточку, потому что источник использует дополнительные поля.
        item.raw = payload
        return item

    def source_list(self, item: MediaItem) -> list[SourceOption]:
        if item.media_type == "tv":
            current_info = build_atodo_info(item)

            if not current_info.get("imdb_id"):
                detailed = self.details("tv", item.item_id)

                # Обновляем тот же объект, который затем использует source_get.
                item.item_id = detailed.item_id
                item.media_type = "tv"
                item.title = detailed.title
                item.original_title = detailed.original_title
                item.overview = detailed.overview
                item.poster_url = detailed.poster_url
                item.backdrop_url = detailed.backdrop_url
                item.year = detailed.year
                item.rating = detailed.rating
                item.raw = detailed.raw

        info = build_atodo_info(item)
        info.pop("poster_path", None)
        info.pop("backdrop_path", None)

        if item.media_type == "tv":
            info["type"] = "tv"

        # Запоминаем ровно тот info, который ушёл в source/list.
        self.last_source_info = dict(info)

        payload = self.get_json_exact(
            "api/source/list",
            info,
        )
        data = unwrap_source_data(payload)

        balancers = data.get("balancers", [])
        if not isinstance(balancers, list):
            return []

        result: list[SourceOption] = []
        for source in balancers:
            if not isinstance(source, dict):
                continue

            source_id = str(
                first_value(source, ("id", "source_id", "key"), "")
            )
            name = str(
                first_value(source, ("name", "title", "label"), source_id)
            )

            if source_id:
                result.append(
                    SourceOption(
                        source_id=source_id,
                        name=name or source_id,
                        raw=source,
                    )
                )

        return result

    def source_get_tv_exact(
        self,
        item: MediaItem,
        source_id: str,
    ) -> dict[str, Any]:
        """
        Точная цепочка оригинального Atodo для сериалов:

        info.type = "tv"
        -> GET /api/source/{source_id}?<info>
        -> response.data.type = "show"
        -> translations -> seasons -> episodes
        """
        if (
            self.last_source_info
            and str(self.last_source_info.get("id", "")) == str(item.item_id)
            and self.last_source_info.get("type") == "tv"
        ):
            params = dict(self.last_source_info)
        else:
            params = build_atodo_info(item)
            params.pop("poster_path", None)
            params.pop("backdrop_path", None)
            params["type"] = "tv"

        try:
            payload = self.get_json_exact(
                f"api/source/{source_id}",
                params,
            )
        except requests.HTTPError as exc:
            status = (
                exc.response.status_code
                if exc.response is not None
                else "?"
            )
            body = ""

            if exc.response is not None:
                try:
                    body = exc.response.text[:1000]
                except Exception:
                    body = ""

            try:
                debug_path = os.path.join(
                    os.path.dirname(os.path.abspath(__file__)),
                    "failed_source_debug.json",
                )
                with open(debug_path, "w", encoding="utf-8") as debug_file:
                    json.dump(
                        {
                            "mode": "tv_exact",
                            "item": {
                                "id": item.item_id,
                                "type": item.media_type,
                                "title": item.title,
                            },
                            "source_id": source_id,
                            "params": params,
                            "query": build_js_query(params),
                            "status": status,
                            "response": body,
                        },
                        debug_file,
                        ensure_ascii=False,
                        indent=2,
                    )
            except Exception:
                pass

            raise SourceUnavailableError(
                f"Источник {source_id} не загрузил сериал "
                f"({status}: {body or 'без описания'})."
            ) from exc

        data = unwrap_source_data(payload)

        try:
            debug_path = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "successful_source_debug.json",
            )
            with open(debug_path, "w", encoding="utf-8") as debug_file:
                json.dump(
                    {
                        "mode": "tv_exact",
                        "item": {
                            "id": item.item_id,
                            "type": item.media_type,
                            "title": item.title,
                        },
                        "source_id": source_id,
                        "params": params,
                        "query": build_js_query(params),
                        "response": payload,
                    },
                    debug_file,
                    ensure_ascii=False,
                    indent=2,
                )
        except Exception:
            pass

        if not isinstance(data, dict) or not data:
            raise SourceUnavailableError(
                f"Источник {source_id} вернул пустой ответ для сериала."
            )

        # В ответе сериала Atodo использует type=show.
        response_type = str(data.get("type", "")).lower()
        if response_type and response_type != "show":
            raise SourceUnavailableError(
                f"Источник {source_id} вернул тип {response_type}, "
                "ожидался show."
            )

        return data

    def source_get(
        self,
        item: MediaItem,
        source_id: str,
    ) -> dict[str, Any]:
        if item.media_type == "tv":
            return self.source_get_tv_exact(
                item,
                source_id,
            )

        raw = item.raw or {}
        base_params = build_source_params(item)

        normalized_type = (
            item.media_type
            if item.media_type in ("movie", "tv")
            else "movie"
        )

        raw_type = str(raw.get("type", "")).strip()
        title = str(
            first_value(
                raw,
                ("name", "title", "name_ru", "title_ru"),
                item.title,
            )
        )
        original_title = str(
            first_value(
                raw,
                ("original_name", "original_title", "name_en", "title_en"),
                item.original_title,
            )
        )

        external_ids = raw.get("external_ids")
        imdb_id = raw.get("imdb_id")
        tvdb_id = raw.get("tvdb_id")

        if isinstance(external_ids, dict):
            imdb_id = imdb_id or external_ids.get("imdb_id")
            tvdb_id = tvdb_id or external_ids.get("tvdb_id")

        date_value = str(
            first_value(
                raw,
                ("first_air_date", "release_date", "year"),
                item.year,
            )
        )
        year = date_value[:4] if date_value else item.year

        type_variants = (
            ["tv", "show"]
            if normalized_type == "tv"
            else ["movie"]
        )

        for value in (
            raw_type,
            "serial" if normalized_type == "tv" else "",
            "series" if normalized_type == "tv" else "",
            "Scripted" if normalized_type == "tv" else "",
        ):
            if value and value not in type_variants:
                type_variants.append(value)

        attempts: list[dict[str, Any]] = []

        def add_attempt(params: dict[str, Any]) -> None:
            cleaned = {
                key: value
                for key, value in params.items()
                if value not in (None, "", [], {})
            }

            if cleaned not in attempts:
                attempts.append(cleaned)

        # 1. Точный объект info из оригинального Atodo main.js.
        atodo_info = build_atodo_info(item)
        atodo_info.pop("poster_path", None)
        atodo_info.pop("backdrop_path", None)
        add_attempt(atodo_info)

        # 2. Старый JS-подобный вариант оставлен как запасной.
        exact_params = build_exact_source_params(item)
        add_attempt(exact_params)

        # 2. Полный нормализованный набор.
        normalized_params = dict(base_params)
        add_attempt(normalized_params)

        # 3. Варианты, которыми обычно пользуются разные балансеры.
        for media_type in type_variants:
            common = {
                "id": item.item_id,
                "tmdb_id": item.item_id,
                "type": media_type,
                "media_type": normalized_type,
                "type_movie": normalized_type,
                "title": title,
                "name": title,
                "original_title": original_title,
                "original_name": original_title,
                "year": year,
                "imdb_id": imdb_id,
                "tvdb_id": tvdb_id,
            }
            add_attempt(common)

            add_attempt({
                "id": item.item_id,
                "type": media_type,
                "name": title,
                "original_name": original_title,
                "year": year,
            })

            add_attempt({
                "tmdb_id": item.item_id,
                "media_type": normalized_type,
                "title": title,
                "original_title": original_title,
                "year": year,
            })

            add_attempt({
                "id": item.item_id,
                "type": media_type,
            })

            add_attempt({
                "id": item.item_id,
            })

        # 4. Отдельные варианты поиска для сериалов.
        if normalized_type == "tv":
            add_attempt({
                "query": original_title or title,
                "type": "series",
                "year": year,
            })
            add_attempt({
                "query": title,
                "type": "tv",
                "year": year,
            })
            add_attempt({
                "name": title,
                "original_name": original_title,
                "first_air_date": raw.get("first_air_date"),
                "type": "tv",
            })

        attempt_log: list[dict[str, Any]] = []

        for index, params in enumerate(attempts, start=1):
            record: dict[str, Any] = {
                "attempt": index,
                "params": params,
                "query": build_js_query(params),
            }

            try:
                payload = self.get_json_exact(
                    f"api/source/{source_id}",
                    params,
                )
                data = unwrap_source_data(payload)

                record["status"] = 200
                record["response"] = payload
                attempt_log.append(record)

                if isinstance(data, dict) and data:
                    try:
                        debug_path = os.path.join(
                            os.path.dirname(os.path.abspath(__file__)),
                            "successful_source_debug.json",
                        )
                        with open(debug_path, "w", encoding="utf-8") as debug_file:
                            json.dump(
                                {
                                    "item": {
                                        "id": item.item_id,
                                        "type": item.media_type,
                                        "title": item.title,
                                    },
                                    "source_id": source_id,
                                    "successful_attempt": index,
                                    "params": params,
                                    "response": payload,
                                },
                                debug_file,
                                ensure_ascii=False,
                                indent=2,
                            )
                    except Exception:
                        pass

                    return data

            except requests.HTTPError as exc:
                status = (
                    exc.response.status_code
                    if exc.response is not None
                    else "?"
                )
                body = ""

                if exc.response is not None:
                    try:
                        body = exc.response.text[:500]
                    except Exception:
                        body = ""

                record["status"] = status
                record["response"] = body or "без описания"
                attempt_log.append(record)
                continue

            except requests.RequestException as exc:
                record["status"] = "request_error"
                record["response"] = str(exc)
                attempt_log.append(record)
                continue

        try:
            debug_path = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "failed_source_debug.json",
            )
            with open(debug_path, "w", encoding="utf-8") as debug_file:
                json.dump(
                    {
                        "item": {
                            "id": item.item_id,
                            "type": item.media_type,
                            "title": item.title,
                            "raw": item.raw,
                        },
                        "source_id": source_id,
                        "attempts_count": len(attempts),
                        "attempts": attempt_log,
                    },
                    debug_file,
                    ensure_ascii=False,
                    indent=2,
                )
        except Exception:
            pass

        last = attempt_log[-1] if attempt_log else {}
        short_error = (
            f"{last.get('status', '?')}: "
            f"{str(last.get('response', 'нет ответа'))[:180]}"
        )

        raise SourceUnavailableError(
            f"Источник {source_id} сейчас недоступен ({short_error})."
        )


    def resolve_streams(
        self,
        source_id: str,
        data_hash: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Точная логика из player.js:
        JSON -> UTF-8 -> Base64 -> api/source/{source}?data=...
        """
        raw_json = json.dumps(
            data_hash,
            ensure_ascii=False,
            separators=(",", ":"),
        )

        encoded = base64.b64encode(
            raw_json.encode("utf-8")
        ).decode("ascii")

        payload = self.get_json_exact(
            f"api/source/{source_id}",
            {"data": encoded},
        )

        return unwrap_source_data(payload)


class Worker(QObject):
    finished = Signal(object)
    failed = Signal(str)

    def __init__(self, callback) -> None:
        super().__init__()
        self.callback = callback

    def run(self) -> None:
        try:
            self.finished.emit(self.callback())
        except SourceUnavailableError as exc:
            self.failed.emit(str(exc))

        except requests.HTTPError as exc:
            status = exc.response.status_code if exc.response is not None else "?"
            body = ""
            if exc.response is not None:
                try:
                    body = exc.response.text[:300]
                except Exception:
                    body = ""

            message = f"Сервер вернул ошибку {status}."
            if body:
                message += f" Ответ: {body}"

            self.failed.emit(message)

        except requests.RequestException as exc:
            self.failed.emit(f"Ошибка подключения к серверу: {exc}")
        except Exception as exc:
            self.failed.emit(f"Ошибка: {exc}")


class ImageLabel(QLabel):
    def __init__(self, width: int, height: int) -> None:
        super().__init__()
        self.setFixedSize(width, height)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setObjectName("poster")
        self.setText("Нет постера")
        self._thread: QThread | None = None
        self._worker: Worker | None = None

    def load(self, url: str) -> None:
        if not url:
            return

        def fetch() -> bytes:
            response = requests.get(
                url,
                timeout=REQUEST_TIMEOUT,
                headers={"User-Agent": "Mozilla/5.0"},
            )
            response.raise_for_status()
            return response.content

        thread = QThread(self)
        worker = Worker(fetch)
        worker.moveToThread(thread)
        thread.started.connect(worker.run)

        def apply_image(content: bytes) -> None:
            pixmap = QPixmap()
            if pixmap.loadFromData(content):
                self.setPixmap(
                    pixmap.scaled(
                        self.size(),
                        Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                        Qt.TransformationMode.SmoothTransformation,
                    )
                )
                self.setText("")
            thread.quit()

        worker.finished.connect(apply_image)
        worker.failed.connect(lambda _: thread.quit())

        def cleanup() -> None:
            self._worker = None
            self._thread = None
            worker.deleteLater()
            thread.deleteLater()

        thread.finished.connect(cleanup)

        self._worker = worker
        self._thread = thread
        thread.start()


class MediaCard(QFrame):
    clicked = Signal(object)

    def __init__(self, item: MediaItem) -> None:
        super().__init__()
        self.item = item
        self.setObjectName("mediaCard")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedWidth(POSTER_WIDTH)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)

        poster = ImageLabel(POSTER_WIDTH, POSTER_HEIGHT)
        poster.load(item.poster_url)

        title = QLabel(item.title)
        title.setObjectName("cardTitle")
        title.setWordWrap(True)
        title.setMaximumHeight(44)

        meta_parts = []
        if item.year:
            meta_parts.append(item.year)
        if item.rating:
            meta_parts.append(f"★ {item.rating}")

        meta = QLabel("  •  ".join(meta_parts))
        meta.setObjectName("cardMeta")

        layout.addWidget(poster)
        layout.addWidget(title)
        layout.addWidget(meta)

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(self.item)
        super().mousePressEvent(event)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.api = ApiClient()
        self._threads: list[QThread] = []
        self._workers: list[Worker] = []
        self.current_items: list[MediaItem] = []

        self.setWindowTitle(APP_NAME)
        self.resize(1280, 820)
        self.setMinimumSize(960, 620)

        self.stack = QStackedWidget()
        self.setCentralWidget(self.stack)

        self.catalog_page = self.build_catalog_page()
        self.details_page = self.build_details_page()
        self.player_page = self.build_player_page()

        self.stack.addWidget(self.catalog_page)
        self.stack.addWidget(self.details_page)
        self.stack.addWidget(self.player_page)

        self.current_item: MediaItem | None = None
        self.current_source_payload: dict[str, Any] = {}
        self.current_translations: list[dict[str, Any]] = []
        self.vlc_instance = None
        self.vlc_player = None
        self.player_timer = None

        self.apply_style()
        self.load_catalog("movie")

    def build_catalog_page(self) -> QWidget:
        page = QWidget()
        root = QVBoxLayout(page)
        root.setContentsMargins(28, 22, 28, 24)
        root.setSpacing(18)

        header = QHBoxLayout()
        logo = QLabel("J1r0x TV")
        logo.setObjectName("logo")

        self.search_input = QLineEdit()
        self.search_input.setPlaceholderText("Поиск фильмов и сериалов...")
        self.search_input.returnPressed.connect(self.search)

        search_button = QPushButton("Найти")
        search_button.setObjectName("primaryButton")
        search_button.clicked.connect(self.search)

        header.addWidget(logo)
        header.addStretch()
        header.addWidget(self.search_input, 1)
        header.addWidget(search_button)

        nav = QHBoxLayout()
        self.movies_button = QPushButton("Фильмы")
        self.series_button = QPushButton("Сериалы")
        self.favorites_button = QPushButton("Избранное")
        self.history_button = QPushButton("История")

        self.movies_button.clicked.connect(lambda: self.load_catalog("movie"))
        self.series_button.clicked.connect(lambda: self.load_catalog("tv"))
        self.favorites_button.clicked.connect(
            lambda: self.show_message("Избранное добавим на следующем этапе.")
        )
        self.history_button.clicked.connect(
            lambda: self.show_message("Историю просмотра добавим на следующем этапе.")
        )

        for button in (
            self.movies_button,
            self.series_button,
            self.favorites_button,
            self.history_button,
        ):
            button.setObjectName("navButton")
            nav.addWidget(button)

        nav.addStretch()

        self.section_title = QLabel("Популярные фильмы")
        self.section_title.setObjectName("sectionTitle")

        self.status_label = QLabel("")
        self.status_label.setObjectName("status")

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)

        self.cards_host = QWidget()
        self.cards_layout = QGridLayout(self.cards_host)
        self.cards_layout.setContentsMargins(0, 0, 0, 0)
        self.cards_layout.setHorizontalSpacing(22)
        self.cards_layout.setVerticalSpacing(24)
        self.cards_layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        self.scroll.setWidget(self.cards_host)

        root.addLayout(header)
        root.addLayout(nav)
        root.addWidget(self.section_title)
        root.addWidget(self.status_label)
        root.addWidget(self.scroll, 1)
        return page

    def build_details_page(self) -> QWidget:
        page = QWidget()
        root = QVBoxLayout(page)
        root.setContentsMargins(30, 24, 30, 28)
        root.setSpacing(18)

        top = QHBoxLayout()
        back = QPushButton("← Назад")
        back.setObjectName("navButton")
        back.clicked.connect(lambda: self.stack.setCurrentWidget(self.catalog_page))
        top.addWidget(back)
        top.addStretch()

        content = QHBoxLayout()
        content.setSpacing(30)

        self.details_poster = ImageLabel(300, 450)

        text_layout = QVBoxLayout()
        self.details_title = QLabel("")
        self.details_title.setObjectName("detailsTitle")
        self.details_title.setWordWrap(True)

        self.details_meta = QLabel("")
        self.details_meta.setObjectName("detailsMeta")

        self.details_overview = QLabel("")
        self.details_overview.setObjectName("overview")
        self.details_overview.setWordWrap(True)
        self.details_overview.setAlignment(Qt.AlignmentFlag.AlignTop)

        self.play_button = QPushButton("Смотреть")
        self.play_button.setObjectName("primaryButton")
        self.play_button.clicked.connect(self.open_watch_page)

        text_layout.addWidget(self.details_title)
        text_layout.addWidget(self.details_meta)
        text_layout.addSpacing(12)
        text_layout.addWidget(self.details_overview)
        text_layout.addStretch()
        text_layout.addWidget(self.play_button, 0, Qt.AlignmentFlag.AlignLeft)

        content.addWidget(self.details_poster)
        content.addLayout(text_layout, 1)

        root.addLayout(top)
        root.addLayout(content, 1)
        return page

    def build_player_page(self) -> QWidget:
        page = QWidget()
        root = QVBoxLayout(page)
        root.setContentsMargins(20, 16, 20, 20)
        root.setSpacing(12)

        top = QHBoxLayout()

        back = QPushButton("← К фильму")
        back.setObjectName("navButton")
        back.clicked.connect(self.leave_player)

        self.player_title = QLabel("Плеер")
        self.player_title.setObjectName("sectionTitle")

        top.addWidget(back)
        top.addWidget(self.player_title)
        top.addStretch()

        selectors = QHBoxLayout()

        self.source_combo = QComboBox()
        self.source_combo.setPlaceholderText("Источник")
        self.source_combo.currentIndexChanged.connect(
            self.on_source_selected
        )

        self.translation_combo = QComboBox()
        self.translation_combo.setPlaceholderText("Озвучка")
        self.translation_combo.currentIndexChanged.connect(
            self.on_translation_selected
        )

        self.season_combo = QComboBox()
        self.season_combo.setPlaceholderText("Сезон")
        self.season_combo.currentIndexChanged.connect(
            self.on_season_selected
        )

        self.episode_combo = QComboBox()
        self.episode_combo.setPlaceholderText("Серия")

        self.play_stream_button = QPushButton("▶ Запустить")
        self.play_stream_button.setObjectName("primaryButton")
        self.play_stream_button.clicked.connect(
            self.play_selected_stream
        )

        selectors.addWidget(QLabel("Источник:"))
        selectors.addWidget(self.source_combo, 1)
        selectors.addWidget(QLabel("Озвучка:"))
        selectors.addWidget(self.translation_combo, 1)
        selectors.addWidget(self.season_combo)
        selectors.addWidget(self.episode_combo)
        selectors.addWidget(self.play_stream_button)

        self.player_status = QLabel("Выбери источник.")
        self.player_status.setObjectName("status")

        self.player_view_stack = QStackedWidget()

        self.video_frame = QFrame()
        self.video_frame.setObjectName("videoFrame")
        self.video_frame.setMinimumHeight(420)
        self.video_frame.setSizePolicy(
            QSizePolicy.Policy.Expanding,
            QSizePolicy.Policy.Expanding,
        )

        self.player_view_stack.addWidget(self.video_frame)

        if WEB_ENGINE_AVAILABLE:
            self.web_player = QWebEngineView()
            self.web_player.setObjectName("webPlayer")
            self.player_view_stack.addWidget(self.web_player)
        else:
            self.web_player = None

        controls = QHBoxLayout()

        self.pause_button = QPushButton("⏯")
        self.pause_button.clicked.connect(self.toggle_pause)

        self.stop_button = QPushButton("⏹")
        self.stop_button.clicked.connect(self.stop_video)

        self.position_slider = QSlider(Qt.Orientation.Horizontal)
        self.position_slider.setRange(0, 1000)
        self.position_slider.sliderReleased.connect(self.seek_video)

        self.time_label = QLabel("00:00 / 00:00")
        self.time_label.setObjectName("cardMeta")

        self.fullscreen_button = QPushButton("Полный экран")
        self.fullscreen_button.clicked.connect(self.toggle_fullscreen)

        controls.addWidget(self.pause_button)
        controls.addWidget(self.stop_button)
        controls.addWidget(self.position_slider, 1)
        controls.addWidget(self.time_label)
        controls.addWidget(self.fullscreen_button)

        root.addLayout(top)
        root.addLayout(selectors)
        root.addWidget(self.player_status)
        root.addWidget(self.player_view_stack, 1)
        root.addLayout(controls)

        return page

    def open_watch_page(self) -> None:
        if not self.current_item:
            QMessageBox.warning(
                self,
                APP_NAME,
                "Карточка фильма ещё не загружена.",
            )
            return

        self.stack.setCurrentWidget(self.player_page)
        self.player_title.setText(self.current_item.title)
        self.player_status.setText("Ищу доступные источники...")
        self.source_combo.blockSignals(True)
        self.source_combo.clear()
        self.source_combo.blockSignals(False)
        self.translation_combo.clear()
        self.season_combo.clear()
        self.episode_combo.clear()

        self.run_task(
            lambda: self.api.source_list(self.current_item),
            self.apply_source_list,
        )

    def apply_source_list(
        self,
        sources: list[SourceOption],
    ) -> None:
        self.source_combo.blockSignals(True)
        self.source_combo.clear()

        for source in sources:
            self.source_combo.addItem(
                source.name,
                source,
            )

        self.source_combo.blockSignals(False)

        if not sources:
            self.player_status.setText(
                "Для этой карточки источники не найдены."
            )
            return

        self.player_status.setText(
            f"Доступно источников: {len(sources)}"
        )
        self.source_combo.setCurrentIndex(0)
        self.on_source_selected(0)

    def on_source_selected(self, index: int) -> None:
        if (
            index < 0
            or not self.current_item
        ):
            return

        source = self.source_combo.itemData(index)
        if not isinstance(source, SourceOption):
            return

        self.player_status.setText(
            f"Загружаю источник: {source.name}..."
        )
        self.translation_combo.clear()
        self.season_combo.clear()
        self.episode_combo.clear()

        self.run_task(
            lambda: self.api.source_get(
                self.current_item,
                source.source_id,
            ),
            self.apply_source_payload,
            self.on_source_failed,
        )

    def on_source_failed(self, message: str) -> None:
        self.current_source_payload = {}
        self.current_translations = []
        self.translation_combo.clear()
        self.season_combo.clear()
        self.episode_combo.clear()

        current_index = self.source_combo.currentIndex()
        next_index = current_index + 1

        if next_index < self.source_combo.count():
            self.player_status.setText(
                message + " Пробую следующий источник..."
            )
            self.source_combo.setCurrentIndex(next_index)
            return

        self.player_status.setText(
            message
            + " Других источников нет. "
            + "Создан failed_source_debug.json."
        )

    def apply_source_payload(
        self,
        payload: dict[str, Any],
    ) -> None:
        self.current_source_payload = payload

        try:
            debug_path = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "source_debug.json",
            )

            with open(debug_path, "w", encoding="utf-8") as debug_file:
                json.dump(
                    payload,
                    debug_file,
                    ensure_ascii=False,
                    indent=2,
                )

        except Exception:
            pass
        translations = payload.get("translations", [])

        if isinstance(translations, dict):
            translations = list(translations.values())

        self.current_translations = [
            item
            for item in translations
            if isinstance(item, dict)
        ]

        self.translation_combo.blockSignals(True)
        self.translation_combo.clear()

        for index, translation in enumerate(
            self.current_translations
        ):
            name = str(
                first_value(
                    translation,
                    (
                        "translation_name",
                        "name",
                        "title",
                        "label",
                    ),
                    f"Озвучка {index + 1}",
                )
            )
            self.translation_combo.addItem(
                name,
                translation,
            )

        self.translation_combo.blockSignals(False)

        if not self.current_translations:
            # Некоторые источники могут возвращать поток без списка озвучек.
            direct_urls = extract_stream_candidates(payload)
            if direct_urls:
                self.player_status.setText(
                    "Найден прямой видеопоток."
                )
                self.translation_combo.addItem(
                    "Основной поток",
                    payload,
                )
                self.on_translation_selected(0)
                return

            self.player_status.setText(
                "Источник ответил, но видеопотоки не найдены."
            )
            return

        source_type = str(payload.get("type", "movie"))
        self.player_status.setText(
            f"Тип источника: {source_type}. "
            f"Озвучек: {len(self.current_translations)}"
        )
        self.translation_combo.setCurrentIndex(0)
        self.on_translation_selected(0)

    def on_translation_selected(self, index: int) -> None:
        if index < 0:
            return

        translation = self.translation_combo.itemData(index)
        if not isinstance(translation, dict):
            return

        self.season_combo.blockSignals(True)
        self.season_combo.clear()
        self.episode_combo.clear()

        seasons = translation.get("seasons", {})
        if isinstance(seasons, list):
            seasons = {
                str(i): season
                for i, season in enumerate(seasons)
                if isinstance(season, dict)
            }

        if isinstance(seasons, dict) and seasons:
            for key, season in seasons.items():
                if not isinstance(season, dict):
                    continue
                name = str(
                    first_value(
                        season,
                        ("season_name", "name", "title"),
                        f"Сезон {key}",
                    )
                )
                self.season_combo.addItem(name, season)

            self.season_combo.setVisible(True)
            self.episode_combo.setVisible(True)
            self.season_combo.blockSignals(False)

            if self.season_combo.count():
                self.season_combo.setCurrentIndex(0)
                self.on_season_selected(0)
        else:
            self.season_combo.blockSignals(False)
            self.season_combo.setVisible(False)
            self.episode_combo.setVisible(False)

            urls = extract_stream_candidates(
                translation.get("streams", translation)
            )

            self.player_status.setText(
                (
                    f"Найдено потоков: {len(urls)}"
                    if urls
                    else (
                        "Поток не удалось расшифровать. "
                        "Данные сохранены в source_debug.json."
                    )
                )
            )

    def on_season_selected(self, index: int) -> None:
        self.episode_combo.clear()

        if index < 0:
            return

        season = self.season_combo.itemData(index)
        if not isinstance(season, dict):
            return

        episodes = season.get("episodes", {})
        if isinstance(episodes, list):
            episodes = {
                str(i): episode
                for i, episode in enumerate(episodes)
                if isinstance(episode, dict)
            }

        if not isinstance(episodes, dict):
            return

        for key, episode in episodes.items():
            if not isinstance(episode, dict):
                continue
            name = str(
                first_value(
                    episode,
                    ("episode_name", "name", "title"),
                    f"Серия {key}",
                )
            )
            self.episode_combo.addItem(name, episode)

    def current_source_id(self) -> str:
        index = self.source_combo.currentIndex()

        if index < 0:
            return ""

        source = self.source_combo.itemData(index)

        if isinstance(source, SourceOption):
            return source.source_id

        return ""

    @staticmethod
    def extract_data_hash(
        container: dict[str, Any],
    ) -> dict[str, Any]:
        if not isinstance(container, dict):
            return {}

        data_value = container.get("data")

        if isinstance(data_value, dict) and data_value.get("token"):
            return data_value

        if container.get("token"):
            result = {
                "token": container.get("token"),
            }

            if "p" in container:
                result["p"] = container.get("p")

            return result

        return {}

    def selected_stream_container(self) -> dict[str, Any]:
        if (
            self.episode_combo.isVisible()
            and self.episode_combo.currentIndex() >= 0
        ):
            value = self.episode_combo.currentData()
            if isinstance(value, dict):
                return value

        value = self.translation_combo.currentData()
        return value if isinstance(value, dict) else {}

    def init_vlc(self) -> bool:
        if self.vlc_player is not None:
            return True

        try:
            self.vlc_instance = vlc.Instance(
                "--no-video-title-show",
                "--network-caching=2500",
            )
            self.vlc_player = self.vlc_instance.media_player_new()

            window_id = int(self.video_frame.winId())

            if sys.platform.startswith("win"):
                self.vlc_player.set_hwnd(window_id)
            elif sys.platform.startswith("linux"):
                self.vlc_player.set_xwindow(window_id)
            elif sys.platform == "darwin":
                self.vlc_player.set_nsobject(window_id)

            from PySide6.QtCore import QTimer

            self.player_timer = QTimer(self)
            self.player_timer.timeout.connect(
                self.update_player_position
            )
            self.player_timer.start(500)
            return True

        except Exception as exc:
            QMessageBox.critical(
                self,
                APP_NAME,
                (
                    "Не удалось запустить VLC.\n\n"
                    "Установи VLC Media Player 64-bit и перезапусти программу.\n\n"
                    f"Ошибка: {exc}"
                ),
            )
            return False

    def play_selected_stream(self) -> None:
        container = self.selected_stream_container()

        streams_value = (
            container.get("streams")
            if isinstance(container, dict)
            else None
        )

        urls = extract_stream_candidates(
            streams_value if streams_value is not None else container
        )

        if urls:
            self.start_direct_stream(
                choose_best_stream(urls)
            )
            return

        data_hash = self.extract_data_hash(container)
        source_id = self.current_source_id()

        if data_hash and source_id:
            self.player_status.setText(
                "Получаю видеопоток по токену..."
            )
            self.play_stream_button.setEnabled(False)

            self.run_task(
                lambda: self.api.resolve_streams(
                    source_id,
                    data_hash,
                ),
                self.apply_resolved_streams,
                self.on_resolve_stream_failed,
            )
            return

        web_urls = extract_web_player_candidates(container)

        if not web_urls:
            web_urls = extract_web_player_candidates(
                self.current_source_payload
            )

        if web_urls:
            self.open_embedded_web_player(web_urls[0])
            return

        QMessageBox.warning(
            self,
            APP_NAME,
            (
                "Источник не передал токен или прямой видеопоток.\n"
                "Попробуй другую озвучку или источник."
            ),
        )

    def apply_resolved_streams(
        self,
        payload: dict[str, Any],
    ) -> None:
        self.play_stream_button.setEnabled(True)

        try:
            debug_path = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "resolved_stream_debug.json",
            )

            with open(debug_path, "w", encoding="utf-8") as debug_file:
                json.dump(
                    payload,
                    debug_file,
                    ensure_ascii=False,
                    indent=2,
                )

        except Exception:
            pass

        streams = payload.get("streams", payload)
        urls = extract_stream_candidates(streams)

        if not urls:
            web_urls = extract_web_player_candidates(payload)

            if web_urls:
                self.open_embedded_web_player(web_urls[0])
                return

            self.player_status.setText(
                "Сервер ответил, но поток не найден."
            )
            QMessageBox.warning(
                self,
                APP_NAME,
                (
                    "Atodo принял токен, но не вернул распознаваемый поток.\n"
                    "Создан файл resolved_stream_debug.json рядом с main.py."
                ),
            )
            return

        self.start_direct_stream(
            choose_best_stream(urls)
        )

    def on_resolve_stream_failed(
        self,
        message: str,
    ) -> None:
        self.play_stream_button.setEnabled(True)
        self.player_status.setText(
            "Не удалось получить видеопоток."
        )
        QMessageBox.warning(
            self,
            APP_NAME,
            message,
        )

    def start_direct_stream(
        self,
        url: str,
    ) -> None:
        if not url:
            return

        if not self.init_vlc():
            return

        self.player_view_stack.setCurrentWidget(
            self.video_frame
        )

        media = self.vlc_instance.media_new(url)
        media.add_option(":http-user-agent=Mozilla/5.0")
        media.add_option(":http-referrer=https://atodo.fun/")
        media.add_option(":network-caching=2500")

        self.vlc_player.set_media(media)
        self.vlc_player.play()

        self.player_status.setText(
            "Воспроизведение запущено."
        )

    def open_embedded_web_player(self, url: str) -> None:
        if not WEB_ENGINE_AVAILABLE or self.web_player is None:
            QMessageBox.warning(
                self,
                APP_NAME,
                (
                    "Для этого источника нужен встроенный браузер.\n\n"
                    "Установи модуль командой:\n"
                    "pip install PySide6-Addons"
                ),
            )
            return

        if self.vlc_player:
            self.vlc_player.stop()

        self.web_player.setUrl(QUrl(url))
        self.player_view_stack.setCurrentWidget(
            self.web_player
        )
        self.player_status.setText(
            "Открыт встроенный веб-плеер источника."
        )

    def toggle_pause(self) -> None:
        if self.vlc_player:
            self.vlc_player.pause()

    def stop_video(self) -> None:
        if self.vlc_player:
            self.vlc_player.stop()
        self.position_slider.setValue(0)
        self.time_label.setText("00:00 / 00:00")

    def seek_video(self) -> None:
        if not self.vlc_player:
            return

        self.vlc_player.set_position(
            self.position_slider.value() / 1000.0
        )

    @staticmethod
    def format_milliseconds(value: int) -> str:
        if value < 0:
            value = 0

        total_seconds = value // 1000
        minutes, seconds = divmod(total_seconds, 60)
        hours, minutes = divmod(minutes, 60)

        if hours:
            return f"{hours:02}:{minutes:02}:{seconds:02}"

        return f"{minutes:02}:{seconds:02}"

    def update_player_position(self) -> None:
        if not self.vlc_player:
            return

        position = self.vlc_player.get_position()
        if position >= 0 and not self.position_slider.isSliderDown():
            self.position_slider.setValue(
                int(position * 1000)
            )

        current = self.vlc_player.get_time()
        duration = self.vlc_player.get_length()

        self.time_label.setText(
            f"{self.format_milliseconds(current)} / "
            f"{self.format_milliseconds(duration)}"
        )

    def toggle_fullscreen(self) -> None:
        if self.isFullScreen():
            self.showNormal()
            self.fullscreen_button.setText(
                "Полный экран"
            )
        else:
            self.showFullScreen()
            self.fullscreen_button.setText(
                "Выйти из полного экрана"
            )

    def leave_player(self) -> None:
        self.stack.setCurrentWidget(self.details_page)

    def run_task(
        self,
        callback,
        on_success,
        on_error=None,
    ) -> None:
        thread = QThread(self)
        worker = Worker(callback)
        worker.moveToThread(thread)

        self._threads.append(thread)
        self._workers.append(worker)

        thread.started.connect(worker.run)
        worker.finished.connect(on_success)
        worker.finished.connect(thread.quit)
        if on_error is None:
            worker.failed.connect(self.on_task_failed)
        else:
            worker.failed.connect(on_error)

        worker.failed.connect(thread.quit)

        def cleanup() -> None:
            if worker in self._workers:
                self._workers.remove(worker)
            if thread in self._threads:
                self._threads.remove(thread)
            worker.deleteLater()
            thread.deleteLater()

        thread.finished.connect(cleanup)
        thread.start()

    def on_task_failed(self, message: str) -> None:
        self.status_label.setText(message)
        QMessageBox.warning(self, APP_NAME, message)

    def load_catalog(self, media_type: str) -> None:
        self.section_title.setText(
            "Популярные фильмы" if media_type == "movie" else "Популярные сериалы"
        )
        self.status_label.setText("Загружаю каталог...")
        self.clear_cards()

        self.run_task(
            lambda: self.api.list_media(media_type, 1),
            self.show_items,
        )

    def search(self) -> None:
        query = self.search_input.text().strip()
        if not query:
            return

        self.section_title.setText(f"Поиск: {query}")
        self.status_label.setText("Ищу...")
        self.clear_cards()

        self.run_task(
            lambda: self.api.search(query, 1),
            self.show_items,
        )

    def clear_cards(self) -> None:
        while self.cards_layout.count():
            item = self.cards_layout.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()

    def show_items(self, items: list[MediaItem]) -> None:
        self.current_items = items
        self.status_label.setText(
            f"Найдено: {len(items)}" if items else "Сервер не вернул карточки."
        )
        self.clear_cards()

        width = max(self.scroll.viewport().width(), 800)
        columns = max(1, width // (POSTER_WIDTH + 24))

        for index, media in enumerate(items):
            card = MediaCard(media)
            card.clicked.connect(self.open_details)
            row, column = divmod(index, columns)
            self.cards_layout.addWidget(card, row, column)

    def open_details(self, item: MediaItem) -> None:
        self.current_item = item
        self.details_title.setText(item.title)
        self.details_meta.setText("Загружаю подробности...")
        self.details_overview.setText(item.overview or "Описание пока отсутствует.")
        self.details_poster.clear()
        self.details_poster.setText("Загрузка...")
        self.details_poster.load(item.poster_url)
        self.stack.setCurrentWidget(self.details_page)

        if not item.item_id:
            self.details_meta.setText("ID карточки отсутствует.")
            return

        self.run_task(
            lambda: self.api.details(item.media_type, item.item_id),
            self.apply_details,
        )

    def apply_details(self, item: MediaItem) -> None:
        if self.current_item and item.media_type not in ("movie", "tv"):
            item.media_type = self.current_item.media_type

        self.current_item = item
        self.details_title.setText(item.title)
        parts = [
            value
            for value in (
                item.year,
                f"Рейтинг: {item.rating}" if item.rating else "",
                item.media_type.upper(),
            )
            if value
        ]
        self.details_meta.setText("  •  ".join(parts))
        self.details_overview.setText(item.overview or "Описание отсутствует.")
        self.details_poster.clear()
        self.details_poster.load(item.poster_url)

    def show_message(self, text: str) -> None:
        QMessageBox.information(self, APP_NAME, text)

    def apply_style(self) -> None:
        self.setStyleSheet(
            """
            QWidget {
                background: #0b0b0d;
                color: #f5f5f7;
                font-family: "Segoe UI";
                font-size: 14px;
            }

            QLabel#logo {
                color: #e50914;
                font-size: 30px;
                font-weight: 800;
            }

            QLabel#sectionTitle {
                font-size: 24px;
                font-weight: 700;
            }

            QLabel#status, QLabel#cardMeta, QLabel#detailsMeta {
                color: #9b9ba3;
            }

            QLabel#cardTitle {
                font-size: 14px;
                font-weight: 600;
            }

            QLabel#detailsTitle {
                font-size: 36px;
                font-weight: 800;
            }

            QLabel#overview {
                color: #d2d2d7;
                font-size: 16px;
                line-height: 1.4;
            }

            QLabel#poster {
                background: #17171c;
                border: 1px solid #27272f;
                border-radius: 10px;
                color: #73737d;
            }

            QFrame#mediaCard {
                background: transparent;
                border: none;
            }

            QFrame#mediaCard:hover QLabel#poster {
                border: 2px solid #e50914;
            }

            QComboBox {
                background: #17171c;
                border: 1px solid #303039;
                border-radius: 9px;
                padding: 8px 12px;
                min-height: 22px;
            }

            QComboBox QAbstractItemView {
                background: #17171c;
                color: #f5f5f7;
                selection-background-color: #e50914;
            }

            QFrame#videoFrame,
            QWebEngineView#webPlayer {
                background: #000000;
                border: 1px solid #27272f;
                border-radius: 10px;
            }

            QSlider::groove:horizontal {
                height: 6px;
                background: #303039;
                border-radius: 3px;
            }

            QSlider::handle:horizontal {
                width: 16px;
                margin: -5px 0;
                background: #e50914;
                border-radius: 8px;
            }

            QLineEdit {
                background: #17171c;
                border: 1px solid #303039;
                border-radius: 10px;
                padding: 10px 14px;
                min-height: 22px;
            }

            QLineEdit:focus {
                border-color: #e50914;
            }

            QPushButton {
                background: #1b1b21;
                border: 1px solid #303039;
                border-radius: 9px;
                padding: 10px 16px;
                font-weight: 600;
            }

            QPushButton:hover {
                background: #27272e;
            }

            QPushButton#primaryButton {
                background: #e50914;
                border-color: #e50914;
                color: white;
            }

            QPushButton#primaryButton:hover {
                background: #f6121d;
            }

            QPushButton#navButton {
                background: transparent;
                border: none;
                padding: 8px 12px;
                color: #d5d5da;
            }

            QPushButton#navButton:hover {
                color: white;
                background: #1b1b21;
            }

            QScrollArea {
                border: none;
            }

            QScrollBar:vertical {
                background: #111116;
                width: 10px;
                margin: 0;
            }

            QScrollBar::handle:vertical {
                background: #3b3b45;
                border-radius: 5px;
                min-height: 30px;
            }
            """
        )

    def closeEvent(self, event) -> None:
        if self.player_timer:
            self.player_timer.stop()

        if self.vlc_player:
            self.vlc_player.stop()

        if self.web_player is not None:
            self.web_player.setUrl(QUrl("about:blank"))

        for thread in list(self._threads):
            thread.quit()
            thread.wait(1000)
        event.accept()


def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
