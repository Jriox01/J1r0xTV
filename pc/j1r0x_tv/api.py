import base64
import json
import threading
from collections import OrderedDict
from typing import Any

import requests

from .config import API_BASE, REQUEST_TIMEOUT, get_app_data_dir
from .models import MediaItem, SourceOption
from .utils import (
    build_atodo_info, build_exact_source_params, build_js_query,
    build_source_params, build_tv_canonical_info, collection_entries,
    first_value, parse_media_item, unwrap_items, unwrap_source_data,
)

class SourceUnavailableError(RuntimeError):
    pass

class ApiClient:
    def __init__(self) -> None:
        self.session = requests.Session()
        self._session_lock = threading.RLock()
        self._details_cache: OrderedDict[
            tuple[str, str], dict[str, Any]
        ] = OrderedDict()
        self._details_cache_limit = 100
        self.last_source_list_trace: dict[str, Any] = {}
        self.prepared_tv_item: MediaItem | None = None
        self.series_trace: dict[str, Any] = {
            "canonical_info": {},
            "source_list": {},
            "source_attempts": [],
        }
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

    def _get(self, url: str, **kwargs) -> requests.Response:
        """Keep the shared cookie jar and connection pool thread-safe."""
        with self._session_lock:
            return self.session.get(url, **kwargs)

    def get_json(self, path: str, params: dict[str, Any] | None = None) -> Any:
        url = API_BASE.rstrip("/") + "/" + path.lstrip("/")
        response = self._get(
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

        response = self._get(
            url,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        return response.json()

    def get_text_url(
        self,
        url: str,
        headers: dict[str, str] | None = None,
        timeout: int | float = REQUEST_TIMEOUT,
    ) -> str:
        """Fetch text through the shared cookie-aware HTTP session."""
        response = self._get(url, headers=headers, timeout=timeout)
        response.raise_for_status()
        return response.text

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
        cache_key = (media_type, item_id)
        with self._session_lock:
            payload = self._details_cache.get(cache_key)
            if payload is not None:
                self._details_cache.move_to_end(cache_key)
        if payload is None:
            payload = self.get_json(f"api/details/{media_type}/{item_id}")

            if isinstance(payload, dict):
                for key in ("data", "result", "item", "movie"):
                    nested = payload.get(key)
                    if isinstance(nested, dict):
                        payload = nested
                        break

        if not isinstance(payload, dict):
            raise RuntimeError("Сервер вернул неизвестный формат карточки.")

        with self._session_lock:
            self._details_cache[cache_key] = payload
            self._details_cache.move_to_end(cache_key)
            while len(self._details_cache) > self._details_cache_limit:
                self._details_cache.popitem(last=False)

        item = parse_media_item(payload, media_type)

        # Сохраняем полную карточку, потому что источник использует дополнительные поля.
        item.raw = payload
        return item

    def source_list(self, item: MediaItem) -> list[SourceOption]:
        if item.media_type == "tv":
            # The catalog/search item is intentionally not trusted here. Atodo
            # builds info from the full details card before requesting balancers.
            detailed_item = self.details("tv", item.item_id)
            item.title = detailed_item.title
            item.original_title = detailed_item.original_title
            item.overview = detailed_item.overview
            item.poster_url = detailed_item.poster_url
            item.backdrop_url = detailed_item.backdrop_url
            item.year = detailed_item.year
            item.rating = detailed_item.rating
            item.raw = detailed_item.raw
            item.media_type = "tv"
            item.canonical_info = build_tv_canonical_info(item)
            self.prepared_tv_item = item
            info = dict(item.canonical_info)
            self.series_trace = {
                "canonical_info": dict(info),
                "source_list": {},
                "source_attempts": [],
            }
        else:
            info = build_atodo_info(item)
            info.pop("poster_path", None)
            info.pop("backdrop_path", None)

        base_url = API_BASE.rstrip("/") + "/api/source/list"
        query = build_js_query(info)
        full_url = f"{base_url}?{query}" if query else base_url
        cookies_before = self.session.cookies.get_dict()

        try:
            response = self._get(
                full_url,
                timeout=REQUEST_TIMEOUT,
            )
        except requests.RequestException as exc:
            if item.media_type == "tv":
                self.series_trace["source_list"] = {
                    "url": full_url,
                    "params": dict(info),
                    "request_headers": dict(self.session.headers),
                    "cookies_before": cookies_before,
                    "cookies_after": self.session.cookies.get_dict(),
                    "status": "request_error",
                    "response_text": str(exc),
                    "response": None,
                }
                self.write_series_trace(self.series_trace)
            raise

        source_list_trace = {
            "params": info,
            "url": full_url,
            "request_headers": dict(response.request.headers),
            "cookies_before": cookies_before,
            "cookies_after": self.session.cookies.get_dict(),
            "status": response.status_code,
            "response_headers": dict(response.headers),
            "response_text": response.text,
        }

        try:
            source_list_trace["response"] = response.json()
        except ValueError:
            source_list_trace["response"] = None

        self.last_source_list_trace = source_list_trace
        if item.media_type == "tv":
            self.series_trace["source_list"] = source_list_trace
            self.write_series_trace(self.series_trace)

        response.raise_for_status()
        payload = response.json()
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

    def write_series_trace(
        self,
        trace: dict[str, Any],
    ) -> None:
        try:
            debug_dir = get_app_data_dir() / "debug"
            debug_dir.mkdir(parents=True, exist_ok=True)
            debug_path = debug_dir / "series_trace.json"
            with open(debug_path, "w", encoding="utf-8") as debug_file:
                json.dump(
                    trace,
                    debug_file,
                    ensure_ascii=False,
                    indent=2,
                )
        except Exception:
            pass

    def source_get_tv_exact(
        self,
        item: MediaItem,
        source_id: str,
    ) -> dict[str, Any]:
        """
        Диагностическая цепочка только для сериалов:
        source/list -> cookies -> выбранный balancer -> source/{id}.
        """
        if not item.canonical_info:
            raise SourceUnavailableError(
                "Полный canonical_info сериала не был подготовлен через source/list."
            )

        params = dict(item.canonical_info)

        selected_balancer = None
        source_list_response = self.last_source_list_trace.get("response", {})
        balancers = (
            source_list_response.get("balancers", [])
            if isinstance(source_list_response, dict)
            else []
        )

        if isinstance(balancers, list):
            for balancer in balancers:
                if not isinstance(balancer, dict):
                    continue

                balancer_id = str(
                    first_value(
                        balancer,
                        ("id", "source_id", "key"),
                        "",
                    )
                )

                if balancer_id == source_id:
                    selected_balancer = balancer
                    break

        base_url = (
            API_BASE.rstrip("/")
            + f"/api/source/{source_id}"
        )
        query = build_js_query(params)
        full_url = f"{base_url}?{query}" if query else base_url

        cookies_before = self.session.cookies.get_dict()

        try:
            response = self._get(
                full_url,
                timeout=REQUEST_TIMEOUT,
            )
        except requests.RequestException as exc:
            source_get_trace = {
                "source_id": source_id,
                "selected_balancer": selected_balancer,
                "url": full_url,
                "params": params,
                "request_headers": dict(self.session.headers),
                "cookies_before": cookies_before,
                "cookies_after": self.session.cookies.get_dict(),
                "status": "request_error",
                "response_text": str(exc),
                "response": None,
            }
            self.series_trace["source_attempts"].append(source_get_trace)
            self.write_series_trace(self.series_trace)
            raise SourceUnavailableError(
                f"Источник {source_id} недоступен: {exc}. "
                "Создан series_trace.json."
            ) from exc

        source_get_trace: dict[str, Any] = {
            "source_id": source_id,
            "selected_balancer": selected_balancer,
            "params": params,
            "url": full_url,
            "cookies_before": cookies_before,
            "request_headers": dict(response.request.headers),
            "status": response.status_code,
            "response_headers": dict(response.headers),
            "cookies_after": self.session.cookies.get_dict(),
            "response_text": response.text,
        }

        try:
            source_get_trace["response"] = response.json()
        except ValueError:
            source_get_trace["response"] = None

        self.series_trace["source_attempts"].append(source_get_trace)
        self.write_series_trace(self.series_trace)

        try:
            response.raise_for_status()
        except requests.HTTPError as exc:
            body = response.text[:1000]

            raise SourceUnavailableError(
                f"Источник {source_id} не загрузил сериал "
                f"({response.status_code}: {body or 'без описания'}). "
                "Создан series_trace.json."
            ) from exc

        payload = response.json()
        data = unwrap_source_data(payload)

        if (
            not isinstance(data, dict)
            or not data
            or data.get("type") != "show"
            or not collection_entries(
                data.get("translations", []),
                ("id", "translation_id"),
            )
        ):
            raise SourceUnavailableError(
                f"Источник {source_id} не вернул type=show с озвучками. "
                "Создан series_trace.json."
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
                        debug_dir = get_app_data_dir() / "debug"
                        debug_dir.mkdir(parents=True, exist_ok=True)
                        debug_path = debug_dir / "successful_source_debug.json"
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
            debug_dir = get_app_data_dir() / "debug"
            debug_dir.mkdir(parents=True, exist_ok=True)
            debug_path = debug_dir / "failed_source_debug.json"
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
