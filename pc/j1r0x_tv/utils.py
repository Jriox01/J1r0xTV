import base64
import json
import re
import urllib.parse
from typing import Any

from .models import MediaItem

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


def build_tv_canonical_info(item: MediaItem) -> dict[str, Any]:
    """Build the immutable Atodo info object used by both TV source requests."""
    raw = item.raw or {}
    external_ids = raw.get("external_ids")
    imdb_id = raw.get("imdb_id")

    if not imdb_id and isinstance(external_ids, dict):
        imdb_id = external_ids.get("imdb_id")

    date_value = first_value(
        raw,
        ("first_air_date", "release_date", "year"),
        item.year,
    )
    year = str(date_value)[:4] if date_value not in (None, "") else ""

    info: dict[str, Any] = {
        "id": item.item_id,
        "title": first_value(raw, ("title", "name"), item.title),
        "original_title": first_value(
            raw,
            ("original_title", "original_name"),
            item.original_title,
        ),
        "original_language": raw.get("original_language"),
        "imdb_id": imdb_id,
        "year": year,
        "type": "tv",
    }

    # JavaScript must not receive Python's textual "None" value.
    return {
        key: value
        for key, value in info.items()
        if value not in (None, "")
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


def collection_entries(
    value: Any,
    number_keys: tuple[str, ...],
) -> list[tuple[str, dict[str, Any]]]:
    """Preserve dict keys and support Atodo collections represented as lists."""
    if isinstance(value, dict):
        return [
            (str(key), child)
            for key, child in value.items()
            if isinstance(child, dict)
        ]

    if isinstance(value, list):
        result: list[tuple[str, dict[str, Any]]] = []
        for index, child in enumerate(value, start=1):
            if not isinstance(child, dict):
                continue
            key = first_value(child, number_keys, index)
            result.append((str(key), child))
        return result

    return []


def extract_atodo_video_urls(streams: Any) -> list[str]:
    """Follow player.js stream priority before falling back to generic discovery."""
    result: list[str] = []

    def add_known_urls(value: Any) -> None:
        if isinstance(value, str):
            candidate = normalize_stream_url(value)
            if candidate.startswith(("http://", "https://")) and candidate not in result:
                result.append(candidate)
            return

        if isinstance(value, dict):
            for child in value.values():
                add_known_urls(child)
            return

        if isinstance(value, (list, tuple)):
            for child in value:
                add_known_urls(child)

    root = streams.get("streams", streams) if isinstance(streams, dict) else streams
    video = root.get("video", {}) if isinstance(root, dict) else {}
    hls = video.get("hls", {}) if isinstance(video, dict) else {}
    http = video.get("http", {}) if isinstance(video, dict) else {}

    if isinstance(hls, dict):
        add_known_urls(hls.get("master"))
        add_known_urls(hls.get("qualities"))

    if isinstance(http, dict):
        add_known_urls(http.get("qualities"))

    for candidate in extract_stream_candidates(root):
        if candidate not in result:
            result.append(candidate)

    return result

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
        parts.append(
            f"{encode_js_component(key)}={encode_js_component(value)}"
        )

    return "&".join(parts)
