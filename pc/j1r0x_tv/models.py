from dataclasses import dataclass
from typing import Any

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
    canonical_info: dict[str, Any] | None = None

@dataclass
class SourceOption:
    source_id: str
    name: str
    raw: dict[str, Any]
